import AIChatCore
import AIChatUI
import Combine
import SwiftData
import SwiftUI

/// The independent session and persistence state for exactly one conversation ID.
@MainActor
@Observable
final class ChatRuntime {
    let conversationID: UUID
    let bridge: CursorConversationBridge
    let session: ChatSession
    var modelID: String
    var answers: [UUID: ChatTranscript.Unpacked] = [:]
    @ObservationIgnored private var conversation: Conversation?
    @ObservationIgnored private var ticks: AnyCancellable?
    @ObservationIgnored var onTick: (() -> Void)?

    init(conversation: Conversation, project: Project?) {
        conversationID = conversation.id
        self.conversation = conversation
        let bridge = CursorConversationBridge(conversation: conversation, project: project ?? conversation.project)
        self.bridge = bridge
        modelID = conversation.model
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
        conversation.model = modelID
        try? conversation.modelContext?.save()
    }

    func persist() {
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
        let sent = session.send(pending.text)
        ChatTrace.event("consumePending session.send=\(sent)")
    }

    private static func makeSession(bridge: CursorConversationBridge, conversation: Conversation) -> ChatSession {
        let session = ChatSession(provider: CursorChatProvider(bridge: bridge), model: conversation.model)
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
