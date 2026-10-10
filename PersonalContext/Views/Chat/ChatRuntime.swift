import SwiftData
import SwiftUI

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

/// The independent session and persistence state for exactly one conversation ID.
@MainActor
@Observable
final class ChatRuntime {
    let conversationID: UUID
    let providerID: String
    let bridge: CursorConversationBridge
    let session: ChatEngine
    var modelID: String
    var draft = ""
    var draftAttachments: [ComposerAttachment] = []
    var answers: [UUID: ChatTranscript.Unpacked] = [:]
    @ObservationIgnored private var conversation: Conversation?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored var onTick: (() -> Void)?

    init(conversation: Conversation, project: Project?, provider: (any ChatProvider)? = nil) {
        conversationID = conversation.id
        providerID = conversation.providerID
        self.conversation = conversation
        let bridge = CursorConversationBridge(conversation: conversation, project: project ?? conversation.project)
        self.bridge = bridge
        modelID = conversation.modelID
        session = Self.makeSession(bridge: bridge, conversation: conversation, provider: provider)
        answers = Dictionary(uniqueKeysWithValues: conversation.orderedMessages.compactMap { message in
            guard message.role == .assistant else { return nil }
            let answer = ChatTranscript.unpack(message.content)
            guard !answer.sources.isEmpty || answer.work?.hasContent == true else { return nil }
            return (message.id, answer)
        })
        session.onChange = { [weak self] in
            self?.onTick?()
        }
        session.traceObjectID = conversation.id.uuidString
        session.traceRuntime = DraftTrace.runtimeID(self)
    }

    func attach(conversation: Conversation, project: Project?) {
        self.conversation = conversation
        bridge.conversation = conversation
        bridge.project = project ?? conversation.project
    }

    func reattach(in context: ModelContext) {
        let id = conversationID
        let found = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })))?.first
        conversation = found
        if let found {
            bridge.conversation = found
            bridge.project = found.project
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
        if let title = bridge.tools.last(where: { $0.status == .running })?.title {
            return title
        }
        return bridge.waitState.label
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
        session.model = modelID
        guard let conversation, conversation.modelContext != nil else { return }
        conversation.modelID = modelID
        try? conversation.modelContext?.save()
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
        guard let conversation, conversation.modelContext != nil else { return }
        var known = Dictionary(uniqueKeysWithValues: conversation.messages.map { ($0.id, $0) })
        var keepIDs = Set<UUID>()
        for entry in session.entries {
            let stored: ChatMessage?
            switch entry {
            case .userMessage(let user) where !user.isCancelled && !user.isFailed:
                stored = (!user.text.isEmpty || !user.attachments.isEmpty)
                    ? ChatMessage(id: user.id, role: .user, content: user.text)
                    : nil
            case .aiMessage(let reply) where !reply.text.isEmpty:
                stored = ChatMessage(id: reply.id, role: .assistant, content: packed(reply))
            default:
                stored = nil
            }
            guard let stored else { continue }
            keepIDs.insert(stored.id)
            if let existing = known[stored.id] {
                if existing.content != stored.content {
                    existing.content = stored.content
                }
            } else {
                conversation.messages.append(stored)
                known[stored.id] = stored
            }
        }
        let stale = conversation.messages.filter { !keepIDs.contains($0.id) }
        if let context = conversation.modelContext {
            let store = FileStore.default(context: context)
            for message in stale {
                try? store.release(ownerKind: .chatMessage, ownerID: message.id)
                conversation.messages.removeAll { $0.id == message.id }
                context.delete(message)
            }
            for entry in session.entries {
                if case .userMessage(let user) = entry, !user.isCancelled, !user.isFailed {
                    try? store.replace(
                        assetIDs: user.attachments.map(\.id),
                        ownerKind: .chatMessage,
                        ownerID: user.id
                    )
                }
            }
            if !session.isGenerating {
                let lastUser = session.entries.reversed().compactMap { entry -> ChatEntry.User? in
                    if case .userMessage(let user) = entry { return user }
                    return nil
                }.first
                if lastUser?.isFailed != true, lastUser?.isCancelled != true {
                    try? store.release(ownerKind: .chatDraft, ownerID: conversationID)
                }
            }
        } else {
            for message in stale {
                conversation.messages.removeAll { $0.id == message.id }
            }
        }
        conversation.updatedAt = .now
        try? conversation.modelContext?.save()
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

    func send(_ submission: ChatSubmission) -> Bool {
        guard !session.isGenerating else { return false }
        bridge.debugLog.add("SEND model=\(modelID) generating=\(session.isGenerating) \(ChatTrace.clip(submission.trimmedText, 120))")
        bridge.debugLog.snapshot(session, label: "session before send")
        rememberAnswer()
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
            bridge.beginTurn()
            persist()
            for entry in session.entries.reversed() {
                if case .userMessage(let user) = entry {
                    bridge.bindTurn(to: user.id)
                    break
                }
            }
        }
        bridge.debugLog.snapshot(session, label: "session after send=\(sent) generating=\(session.isGenerating) turn=\(bridge.turn.count) turnUser=\(bridge.turnUserID?.uuidString.prefix(8) ?? "nil")")
        return sent
    }

        static func makeChatProvider(bridge: CursorConversationBridge, conversation: Conversation) -> any ChatProvider {
        switch TalkProvider(rawValue: conversation.providerID) {
        case .cursor:
            return CursorChatProvider(bridge: bridge)
        case .chatgpt:
            return ChatGPTProvider(bridge: bridge)
        case .compatible:
            return GenericChatProvider(
                endpoint: UserDefaults.standard.string(forKey: Keys.compatibleEndpoint) ?? "",
                apiKey: KeychainStore.read(.compatibleAPIKey)
            )
        case .unconfigured, .none:
            return UnavailableChatProvider(
                id: conversation.providerID,
                name: "Not configured",
                message: "Choose a chat provider in Settings, then start a new chat."
            )
        }
    }

    private func prepareTurn(_ submission: ChatSubmission) throws -> ChatTurnOptions {
        guard !submission.attachments.isEmpty || session.providerHistory.contains(where: { !$0.attachments.isEmpty }) else {
            return ChatTurnOptions()
        }
        guard let context = conversation?.modelContext else {
            throw AttachmentError.missingAsset(submission.attachments.first?.filename ?? "attachment")
        }
        let store = FileStore.default(context: context)
        let provider = TalkProvider(rawValue: providerID) ?? .unconfigured
        let endpoint = provider == .compatible
            ? (UserDefaults.standard.string(forKey: Keys.compatibleEndpoint) ?? "")
            : ""
        let includeHistory: Bool
        switch provider {
        case .chatgpt, .compatible:
            includeHistory = true
        case .cursor:
            includeHistory = conversation?.externalSessionID.isEmpty != false
        case .unconfigured:
            includeHistory = false
        }
        let prepared = try AttachmentPrep.prepare(
            refs: submission.attachments,
            history: session.providerHistory,
            provider: provider,
            model: modelID,
            endpoint: endpoint,
            store: store,
            includeHistory: includeHistory
        )
        try store.replace(
            assetIDs: submission.attachments.map(\.id),
            ownerKind: .chatDraft,
            ownerID: conversationID
        )
        return ChatTurnOptions(attachments: prepared)
    }

    private static func makeSession(
        bridge: CursorConversationBridge,
        conversation: Conversation,
        provider: (any ChatProvider)?
    ) -> ChatEngine {
        let session = ChatEngine(
            provider: provider ?? makeChatProvider(bridge: bridge, conversation: conversation),
            model: conversation.modelID
        )
        var entries: [ChatEntry] = []
        var history: [TalkMessage] = []
        let store = conversation.modelContext.map(FileStore.default(context:))
        for message in conversation.orderedMessages {
            let attachments = store?.attachments(ownerKind: .chatMessage, ownerID: message.id) ?? []
            if message.content.isEmpty && attachments.isEmpty { continue }
            switch message.role {
            case .user:
                var content: [TalkContent] = []
                if !message.content.isEmpty { content.append(.text(message.content)) }
                content.append(contentsOf: attachments.map { .attachment($0) })
                entries.append(.userMessage(.init(id: message.id, text: message.content, attachments: attachments)))
                history.append(TalkMessage(id: message.id, role: .user, content: content))
            case .assistant:
                let answer = ChatTranscript.unpack(message.content)
                entries.append(.aiMessage(.init(id: message.id, text: message.content, isStreaming: false)))
                history.append(TalkMessage(id: message.id, role: .assistant, text: answer.text))
            }
        }
        session.loadSnapshot(entries: entries, history: history)
        return session
    }

    func restoreFailedDraft() {
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

    func rememberAnswer() {
        for entry in session.entries.reversed() {
            if case .aiMessage(let reply) = entry, !reply.text.isEmpty {
                let text = ChatTranscript.unpack(reply.text).text
                answers[reply.id] = ChatTranscript.Unpacked(
                    text: text,
                    sources: bridge.sources,
                    work: bridge.work
                )
                persist()
                return
            }
        }
    }

    private func packed(_ reply: ChatEntry.Assistant) -> String {
        if let answer = answers[reply.id] {
            return ChatTranscript.pack(text: answer.text, sources: answer.sources, work: answer.work)
        }
        let answer = ChatTranscript.unpack(reply.text)
        guard !bridge.turnText.isEmpty, answer.text == bridge.turnText || reply.text == bridge.turnText else {
            return reply.text
        }
        return ChatTranscript.pack(text: answer.text, sources: bridge.sources, work: bridge.work)
    }
}
