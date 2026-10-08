import AIChatCore
import AIChatUI
import Combine
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

    func snapshot(_ session: ChatSession, label: String) {
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

    private static func describe(_ entry: ChatSession.Entry) -> String {
        switch entry {
        case .userMessage(let message):
            return "user id=\(short(message.id)) \(ChatTrace.clip(message.text, 80))"
        case .aiMessage(let message):
            return "assistant id=\(short(message.id)) stream=\(message.isStreaming) \(ChatTrace.clip(message.text, 80))"
        case .reasoning(let reasoning):
            return "reasoning think=\(reasoning.isThinking) \(ChatTrace.clip(reasoning.text, 80))"
        case .toolCall(let call):
            return "toolCall \(call.name)"
        case .knowledgeRetrieval(let knowledge):
            return "knowledge \(ChatTrace.clip(knowledge.query, 80))"
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
    let session: ChatSession
    var modelID: String
    var answers: [UUID: ChatTranscript.Unpacked] = [:]
    @ObservationIgnored private var conversation: Conversation?
    @ObservationIgnored private var ticks: AnyCancellable?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored var onTick: (() -> Void)?

    init(conversation: Conversation, project: Project?) {
        conversationID = conversation.id
        providerID = conversation.providerID
        self.conversation = conversation
        let bridge = CursorConversationBridge(conversation: conversation, project: project ?? conversation.project)
        self.bridge = bridge
        modelID = conversation.modelID
        session = Self.makeSession(bridge: bridge, conversation: conversation)
        answers = Dictionary(uniqueKeysWithValues: conversation.orderedMessages.compactMap { message in
            guard message.role == .assistant else { return nil }
            let answer = ChatTranscript.unpack(message.content)
            guard !answer.sources.isEmpty || answer.work?.hasContent == true else { return nil }
            return (message.id, answer)
        })
        ticks = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.onTick?()
            }
        }
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
        for entry in session.entries {
            let stored: ChatMessage?
            switch entry {
            case .userMessage(let user) where !user.isCancelled && !user.isFailed:
                stored = ChatMessage(id: user.id, role: .user, content: user.text)
            case .aiMessage(let reply) where !reply.text.isEmpty:
                stored = ChatMessage(id: reply.id, role: .assistant, content: packed(reply))
            default:
                stored = nil
            }
            guard let stored else { continue }
            if let existing = known[stored.id] {
                if existing.content != stored.content {
                    existing.content = stored.content
                }
            } else {
                conversation.messages.append(stored)
                known[stored.id] = stored
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
        let sent = send(pending.text)
        ChatTrace.event("consumePending session.send=\(sent)")
    }

    func send(_ text: String) -> Bool {
        guard !session.isGenerating else { return false }
        bridge.debugLog.add("SEND model=\(modelID) generating=\(session.isGenerating) \(ChatTrace.clip(text, 120))")
        bridge.debugLog.snapshot(session, label: "session before send")
        rememberAnswer()
        bridge.beginTurn()
        let sent = session.send(text)
        if sent {
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

    private static func makeSession(bridge: CursorConversationBridge, conversation: Conversation) -> ChatSession {
        let provider: any ChatProvider
        if let project = bridge.project, !project.workerProviderID.isEmpty {
            let path = WorkerPath(rawValue: project.workerPath) ?? .local
            let workerModel = project.workerModelID.isEmpty && project.workerProviderID == conversation.providerID
                ? conversation.modelID
                : project.workerModelID
            provider = ProjectWorkerChatProvider(
                id: conversation.providerID,
                name: TalkProvider(rawValue: conversation.providerID)?.title ?? "Chat",
                bridge: bridge,
                chatProviderID: conversation.providerID,
                workerProviderID: project.workerProviderID,
                workerModelID: workerModel,
                workerPath: path
            )
        } else {
            switch TalkProvider(rawValue: conversation.providerID) {
            case .cursor:
                provider = CursorChatProvider(bridge: bridge)
            case .chatgpt:
                provider = ChatGPTProvider(bridge: bridge)
            case .unconfigured, .none:
                provider = UnavailableChatProvider(
                    id: conversation.providerID,
                    name: "Not configured",
                    message: "Choose a chat provider in Settings, then start a new chat."
                )
            }
        }
        let session = ChatSession(provider: provider, model: conversation.modelID)
        var entries: [ChatSession.Entry] = []
        var history: [AIChatCore.ChatMessage] = []
        for message in conversation.orderedMessages where !message.content.isEmpty {
            switch message.role {
            case .user:
                entries.append(.userMessage(.init(id: message.id, text: message.content)))
                history.append(.init(id: message.id, role: .user, content: message.content))
            case .assistant:
                let answer = ChatTranscript.unpack(message.content)
                entries.append(.aiMessage(.init(id: message.id, text: message.content, isStreaming: false)))
                history.append(.init(id: message.id, role: .assistant, content: answer.text))
            }
        }
        session.loadSnapshot(entries: entries, history: history)
        return session
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

    private func packed(_ reply: ChatSession.AIEntry) -> String {
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
