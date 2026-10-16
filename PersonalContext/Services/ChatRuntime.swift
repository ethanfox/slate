import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ChatDebugLog {
    struct Line: Identifiable, Equatable {
        var id = UUID()
        var at = Date()
        var text: String
    }

    @ObservationIgnored private var stored: [Line] = []
    private(set) var lines: [Line] = []
    var pace: StreamPace?

    var copyText: String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss.SSS"
        var parts: [String] = []
        if let pace {
            parts.append(pace.summary())
        }
        parts.append(contentsOf: stored.map { "\(clock.string(from: $0.at)) \($0.text)" })
        return parts.joined(separator: "\n")
    }

    func add(_ text: String) {
        #if DEBUG
        stored.append(Line(text: text))
        if stored.count > 500 { stored.removeFirst(stored.count - 500) }
        #endif
    }

    func snapshot(_ session: ChatEngine, label: String) {
        add(label)
        for (index, entry) in session.entries.enumerated() {
            add("  [\(index)] \(Self.describe(entry))")
        }
    }

    func publish() {
        lines = stored
    }

    func clear() {
        stored = []
        lines = []
        pace = nil
    }

    private static func describe(_ entry: ChatEntry) -> String {
        switch entry {
        case .userMessage(let message):
            return "user id=\(short(message.id)) \(ChatTrace.clip(message.text, 80))"
        case .aiMessage(let message):
            return "assistant id=\(short(message.id)) stream=\(message.isStreaming) \(ChatTrace.clip(message.text, 80))"
        case .activity(let activity):
            return "activity error=\(activity.isError) \(ChatTrace.clip(activity.text, 80))"
        }
    }

    private static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}

/// AppModel-retained session for exactly one conversation ID.
@MainActor
@Observable
final class ChatRuntime {
    let conversationID: UUID
    var providerID: String
    let session: ChatEngine
    let debugLog: ChatDebugLog
    var modelID: String
    var draft = ""
    var draftAttachments: [ComposerAttachment] = []
    /// A message the user sent while the answer was still writing. It goes the moment the turn ends.
    private(set) var queued: ChatSubmission?
    @ObservationIgnored private let store: ConversationStore
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored var onTick: (() -> Void)?

    init(
        conversation: Conversation,
        provider: any ChatProvider,
        store: ConversationStore? = nil,
        debugLog: ChatDebugLog? = nil
    ) {
        conversationID = conversation.id
        providerID = conversation.providerID
        self.store = store ?? ConversationStore(conversation: conversation)
        self.debugLog = debugLog ?? ChatDebugLog()
        modelID = conversation.modelID
        session = ChatEngine(provider: provider, model: conversation.modelID)
        let snapshot = self.store.load()
        session.loadSnapshot(entries: snapshot.entries, history: snapshot.history)
        session.onChange = { [weak self] in
            self?.applyMetadata()
            self?.schedulePersist()
            self?.onTick?()
        }
        session.onFinish = { [weak self] in
            self?.applyMetadata()
            self?.restoreFailedDraft()
            self?.persist()
            self?.sendQueued()
        }
        session.traceObjectID = conversation.id.uuidString
        session.traceRuntime = DraftTrace.runtimeID(self)
    }

    convenience init(conversation: Conversation, project: Project?, provider: any ChatProvider) {
        self.init(conversation: conversation, provider: provider)
        provider.attach(conversation: conversation, project: project)
    }

    func attach(conversation: Conversation, project: Project?) {
        store.attach(conversation: conversation)
        session.provider.attach(conversation: conversation, project: project)
    }

    func reattach(in context: ModelContext) {
        persistTask?.cancel()
        persistTask = nil
        let id = conversationID
        let found = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })))?.first
        guard let found else { return }
        store.attach(conversation: found)
        session.provider.attach(conversation: found, project: found.project)
        let snapshot = store.load()
        if session.isGenerating {
            session.mergeFromStore(entries: snapshot.entries, history: snapshot.history)
        } else {
            session.loadSnapshot(entries: snapshot.entries, history: snapshot.history)
        }
    }

    var lastUserText: String? {
        for entry in session.entries.reversed() {
            if case .userMessage(let user) = entry, !user.text.isEmpty {
                return user.text
            }
        }
        return nil
    }

    var liveWaitLabel: String {
        if let title = session.currentTurn.tools.last(where: { $0.status == .running })?.title {
            return title
        }
        return session.currentTurn.waitState.label
    }

    var lastReply: String {
        for entry in session.entries.reversed() {
            if case .aiMessage(let reply) = entry, !reply.text.isEmpty {
                return ChatTranscript.unpack(reply.text).text
            }
        }
        return ""
    }

    func applyModel() {
        let changed = session.model != modelID
        let held = holdQueue()
        if changed, session.isGenerating {
            session.cancel()
        }
        session.model = modelID
        store.applyModel(modelID)
        if changed, let cursor = session.provider as? CursorChatProvider {
            cursor.bridge.stop()
        }
        releaseQueue(held)
    }

    func applyProvider() {
        if session.provider.id == providerID { return }
        let held = holdQueue()
        if session.isGenerating { session.cancel() }
        guard let conversation = store.applyProvider(providerID) else {
            releaseQueue(held)
            return
        }
        session.provider = ChatProviderFactory.make(
            conversation: conversation,
            project: conversation.project,
            debugLog: debugLog
        )
        releaseQueue(held)
    }

    /// A queued message waits out a model or provider switch and goes on the new one.
    private func holdQueue() -> ChatSubmission? {
        let held = queued
        queued = nil
        return held
    }

    private func releaseQueue(_ held: ChatSubmission?) {
        guard let held else { return }
        queued = held
        sendQueued()
    }

    func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    func persist() {
        persistTask?.cancel()
        persistTask = nil
        let lastUser = session.entries.reversed().compactMap { entry -> ChatEntry.User? in
            if case .userMessage(let user) = entry { return user }
            return nil
        }.first
        store.apply(
            ConversationStoreUpdate(
                upsert: session.entries,
                deleteIDs: session.takeRemovedIDs(),
                releaseDraft: !session.isGenerating && queued == nil && lastUser?.isFailed != true && lastUser?.isCancelled != true
            )
        )
    }

    func consumePending(from app: AppModel) {
        guard let pending = app.pendingSend else {
            ChatTrace.event("consumePending skip conversation=\(conversationID) reason=none")
            return
        }
        guard pending.conversationID == conversationID else {
            ChatTrace.event("consumePending skip conversation=\(conversationID) pending=\(pending.conversationID)")
            return
        }
        app.pendingSend = nil
        ChatTrace.event("consumePending send conversation=\(conversationID) chars=\(pending.text.count) generating=\(session.isGenerating)")
        let sent = send(pending.submission)
        ChatTrace.event("consumePending session.send=\(sent)")
    }

    func send(_ text: String) -> Bool {
        send(ChatSubmission(text: text))
    }

    /// Sending while the answer is still writing queues the message; it goes as the next turn when this one ends.
    func send(_ submission: ChatSubmission) -> Bool {
        if session.isGenerating {
            guard submission.hasContent else { return false }
            queue(submission)
            return true
        }
        return sendNow(submission)
    }

    /// Ends the answer now; whatever is queued goes next.
    func stop() {
        session.cancel()
    }

    /// Stops the answer and sends the queued message right away.
    func sendQueuedNow() {
        guard queued != nil else { return }
        if session.isGenerating {
            session.cancel()
        } else {
            sendQueued()
        }
    }

    func clearQueued() {
        queued = nil
    }

    private func queue(_ submission: ChatSubmission) {
        guard var merged = queued else {
            queued = submission
            ChatTrace.event("queued conversation=\(conversationID) chars=\(submission.trimmedText.count) files=\(submission.attachments.count)")
            return
        }
        let text = submission.trimmedText
        if !text.isEmpty {
            merged.text = merged.trimmedText.isEmpty ? text : merged.trimmedText + "\n\n" + text
        }
        merged.attachments.append(contentsOf: submission.attachments.filter { next in
            !merged.attachments.contains { $0.id == next.id }
        })
        queued = merged
        ChatTrace.event("queued more conversation=\(conversationID) chars=\(merged.trimmedText.count) files=\(merged.attachments.count)")
    }

    private func sendQueued() {
        guard let submission = queued, !session.isGenerating else { return }
        queued = nil
        ChatTrace.event("queued send conversation=\(conversationID) chars=\(submission.trimmedText.count)")
        _ = sendNow(submission)
    }

    private func sendNow(_ submission: ChatSubmission) -> Bool {
        guard !session.isGenerating else { return false }
        debugLog.pace = StreamPace()
        debugLog.add("SEND model=\(modelID) generating=\(session.isGenerating) \(ChatTrace.clip(submission.trimmedText, 120))")
        debugLog.snapshot(session, label: "session before send")
        let options: ChatTurnOptions
        do {
            options = try prepareTurn(submission)
        } catch {
            session.failValidation(error)
            return false
        }
        let sent = session.send(submission, options: options)
        DraftTrace.send(
            kind: "runtime",
            object: conversationID.uuidString,
            runtime: DraftTrace.runtimeID(self),
            chars: submission.trimmedText.count,
            accepted: sent
        )
        if sent {
            persist()
        }
        debugLog.snapshot(session, label: "session after send=\(sent) generating=\(session.isGenerating)")
        return sent
    }

    private func prepareTurn(_ submission: ChatSubmission) throws -> ChatTurnOptions {
        guard !submission.attachments.isEmpty || session.providerHistory.contains(where: { !$0.attachments.isEmpty }) else {
            return ChatTurnOptions()
        }
        let provider = TalkProvider(rawValue: providerID) ?? .unconfigured
        let endpoint = provider == .compatible
            ? (UserDefaults.standard.string(forKey: Keys.compatibleEndpoint) ?? "")
            : ""
        let includeHistory: Bool
        switch provider {
        case .chatgpt, .compatible:
            includeHistory = true
        case .cursor:
            includeHistory = store.includeCursorHistory
        case .unconfigured:
            includeHistory = false
        }
        let files = try store.fileStore()
        let prepared = try AttachmentPrep.prepare(
            refs: submission.attachments,
            history: session.providerHistory,
            provider: provider,
            model: modelID,
            endpoint: endpoint,
            store: files,
            includeHistory: includeHistory
        )
        try store.replaceDraft(assetIDs: submission.attachments.map(\.id), conversationID: conversationID)
        return ChatTurnOptions(attachments: prepared)
    }

    func restoreFailedDraft() {
        guard draft.isEmpty, draftAttachments.isEmpty else { return }
        for entry in session.entries.reversed() {
            if case .userMessage(let user) = entry {
                if user.isFailed || user.isCancelled, !user.attachments.isEmpty {
                    draft = user.text
                    draftAttachments = user.attachments.map {
                        ComposerAttachment(
                            id: $0.id,
                            filename: $0.filename,
                            mimeType: $0.mimeType,
                            kind: $0.kind,
                            status: .ready
                        )
                    }
                }
                return
            }
        }
    }

    private func applyMetadata() {
        store.applyMetadata(session.takeMetadata())
    }
}
