import Foundation
import SwiftData

struct ConversationStoreUpdate {
    var upsert: [ChatEntry] = []
    var deleteIDs: [UUID] = []
    var releaseDraft: Bool = false
}

/// Encodes, decodes, and applies explicit conversation persistence. Does not infer deletions.
@MainActor
final class ConversationStore {
    private var conversation: Conversation?

    init(conversation: Conversation) {
        self.conversation = conversation
    }

    func attach(conversation: Conversation) {
        self.conversation = conversation
    }

    var includeCursorHistory: Bool {
        conversation?.externalSessionID.isEmpty == true
    }

    func fileStore() throws -> FileStore {
        guard let context = conversation?.modelContext else {
            throw AttachmentError.missingAsset("attachment")
        }
        return FileStore.default(context: context)
    }

    func load() -> (entries: [ChatEntry], history: [TalkMessage]) {
        guard let conversation else { return ([], []) }
        var entries: [ChatEntry] = []
        var history: [TalkMessage] = []
        let files = conversation.modelContext.map(FileStore.default(context:))
        for message in conversation.orderedMessages {
            let attachments = files?.attachments(ownerKind: .chatMessage, ownerID: message.id) ?? []
            guard let decoded = Self.decode(message, attachments: attachments) else { continue }
            entries.append(decoded.entry)
            if let talk = decoded.history {
                history.append(talk)
            }
        }
        return (entries, history)
    }

    func apply(_ update: ConversationStoreUpdate) {
        guard let conversation, conversation.modelContext != nil else { return }
        var known = Dictionary(uniqueKeysWithValues: conversation.messages.map { ($0.id, $0) })
        for entry in update.upsert {
            guard let encoded = Self.encode(entry) else { continue }
            if let existing = known[encoded.id] {
                if existing.content != encoded.content {
                    existing.content = encoded.content
                }
            } else {
                conversation.messages.append(encoded)
                known[encoded.id] = encoded
            }
        }
        let files = conversation.modelContext.map(FileStore.default(context:))
        for id in update.deleteIDs {
            guard let message = known[id] else { continue }
            try? files?.release(ownerKind: .chatMessage, ownerID: id)
            conversation.messages.removeAll { $0.id == id }
            if let context = conversation.modelContext {
                context.delete(message)
            }
            known[id] = nil
        }
        if let files {
            for entry in update.upsert {
                if case .userMessage(let user) = entry, user.isCompleted {
                    try? files.replace(
                        assetIDs: user.attachments.map(\.id),
                        ownerKind: .chatMessage,
                        ownerID: user.id
                    )
                }
            }
            if update.releaseDraft {
                try? files.release(ownerKind: .chatDraft, ownerID: conversation.id)
            }
        }
        conversation.updatedAt = .now
        try? conversation.modelContext?.persist()
    }

    func applyMetadata(_ metadata: ChatTurnMetadata) {
        guard let conversation, metadata.hasContent else { return }
        if let id = metadata.externalSessionID, !id.isEmpty {
            conversation.externalSessionID = id
        }
        if let title = metadata.title, !title.isEmpty {
            conversation.title = title
        }
        if let snapshot = metadata.contextSnapshot {
            conversation.contextSnapshot = snapshot
        }
        conversation.updatedAt = .now
        conversation.project?.touch()
        try? conversation.modelContext?.persist()
    }

    func applyModel(_ modelID: String) {
        guard let conversation, conversation.modelContext != nil else { return }
        let changed = conversation.modelID != modelID
        conversation.modelID = modelID
        if changed, conversation.providerID == TalkProvider.cursor.rawValue {
            conversation.externalSessionID = ""
            conversation.updatedAt = .now
            conversation.project?.touch()
        }
        try? conversation.modelContext?.persist()
    }

    func applyProvider(_ providerID: String) -> Conversation? {
        guard let conversation else { return nil }
        conversation.providerID = providerID
        conversation.externalSessionID = ""
        conversation.updatedAt = .now
        conversation.project?.touch()
        try? conversation.modelContext?.persist()
        return conversation
    }

    func replaceDraft(assetIDs: [UUID], conversationID: UUID) throws {
        guard let context = conversation?.modelContext else {
            throw AttachmentError.missingAsset("attachment")
        }
        try FileStore.default(context: context).replace(
            assetIDs: assetIDs,
            ownerKind: .chatDraft,
            ownerID: conversationID
        )
    }

    static func encode(_ entry: ChatEntry) -> ChatMessage? {
        switch entry {
        case .userMessage(let user):
            guard user.isCancelled || user.isFailed || !user.text.isEmpty || !user.attachments.isEmpty else {
                return nil
            }
            let state: ChatPersistedState? = user.isFailed ? .failed : user.isCancelled ? .cancelled : nil
            return ChatMessage(
                id: user.id,
                role: .user,
                content: ChatTranscript.pack(text: user.text, state: state)
            )
        case .aiMessage(let reply):
            guard !reply.text.isEmpty || reply.work.hasContent else { return nil }
            return ChatMessage(
                id: reply.id,
                role: .assistant,
                content: ChatTranscript.pack(text: reply.displayText, sources: reply.sources, work: reply.work)
            )
        case .activity(let activity) where activity.isError:
            return ChatMessage(
                id: activity.id,
                role: .assistant,
                content: ChatTranscript.pack(text: activity.text, isActivity: true)
            )
        default:
            return nil
        }
    }

    static func decode(
        _ message: ChatMessage,
        attachments: [ChatAttachmentRef]
    ) -> (entry: ChatEntry, history: TalkMessage?)? {
        let unpacked = ChatTranscript.unpack(message.content)
        if unpacked.isActivity {
            return (.activity(.init(id: message.id, text: unpacked.text, isError: true)), nil)
        }
        switch message.role {
        case .user:
            if unpacked.text.isEmpty && attachments.isEmpty && unpacked.state == nil { return nil }
            var user = ChatEntry.User(id: message.id, text: unpacked.text, attachments: attachments)
            user.isFailed = unpacked.state == .failed
            user.isCancelled = unpacked.state == .cancelled
            var history: TalkMessage?
            if user.isCompleted {
                var content: [TalkContent] = []
                if !unpacked.text.isEmpty { content.append(.text(unpacked.text)) }
                content.append(contentsOf: attachments.map { .attachment($0) })
                history = TalkMessage(id: message.id, role: .user, content: content)
            }
            return (.userMessage(user), history)
        case .assistant:
            if unpacked.text.isEmpty && unpacked.work?.hasContent != true && attachments.isEmpty { return nil }
            var assistant = ChatEntry.Assistant(id: message.id, text: unpacked.text, isStreaming: false)
            assistant.sources = unpacked.sources
            if let work = unpacked.work {
                assistant.thinking = work.thinking
                assistant.items = work.tools.map { ChatTurnItem(id: $0.id, kind: .tool($0)) }
                if work.seconds > 0 {
                    assistant.startedAt = message.createdAt.addingTimeInterval(TimeInterval(-work.seconds))
                    assistant.finishedAt = message.createdAt
                }
            }
            if !unpacked.text.isEmpty, !assistant.hasTextItems {
                assistant.items.append(ChatTurnItem(id: message.id.uuidString, kind: .text(unpacked.text)))
            }
            let history = unpacked.text.isEmpty
                ? nil
                : TalkMessage(id: message.id, role: .assistant, text: unpacked.text)
            return (.aiMessage(assistant), history)
        }
    }
}

private extension ChatEntry.User {
    var isCompleted: Bool { !isFailed && !isCancelled }
}
