import Foundation

/// Composer payload. Text works now; attachments are a typed placeholder for the next phase.
struct ChatSubmission: Equatable, Sendable {
    var text: String
    var attachments: [ChatAttachmentRef] = []

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasContent: Bool {
        !trimmedText.isEmpty || !attachments.isEmpty
    }
}

/// Durable attachment identity for a later storage/encoding phase. No bytes here.
struct ChatAttachmentRef: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case image
        case file
    }

    var id: UUID
    var kind: Kind
    var filename: String
    var mimeType: String
}

enum TalkRole: String, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct TalkToolCall: Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

enum TalkContent: Equatable, Sendable {
    case text(String)
    case attachment(ChatAttachmentRef)
}

/// Provider-facing history. Distinct from the persisted SwiftData `ChatMessage`.
struct TalkMessage: Identifiable, Sendable {
    var id: UUID
    var role: TalkRole
    var content: [TalkContent]
    var toolCallID: String?
    var toolCalls: [TalkToolCall]?

    init(
        id: UUID = UUID(),
        role: TalkRole,
        content: [TalkContent],
        toolCallID: String? = nil,
        toolCalls: [TalkToolCall]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    init(id: UUID = UUID(), role: TalkRole, text: String) {
        self.init(id: id, role: role, content: [.text(text)])
    }

    var text: String {
        content.compactMap { part in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n")
    }

    var attachments: [ChatAttachmentRef] {
        content.compactMap { part in
            if case .attachment(let attachment) = part { return attachment }
            return nil
        }
    }
}

struct ChatTurnOptions: Sendable, Equatable {
    init() {}
}

enum ChatStreamEvent: Sendable, Equatable {
    case text(String)
    case done
}

protocol ChatProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var zeroResponseMessage: String { get }

    func stream(
        messages: [TalkMessage],
        model: String,
        options: ChatTurnOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

enum ChatEngineError: LocalizedError, Equatable {
    case attachmentsNotImplemented
    case emptySubmission

    var errorDescription: String? {
        switch self {
        case .attachmentsNotImplemented:
            return "Attachments aren’t available yet. Send text only."
        case .emptySubmission:
            return "Type a message to send."
        }
    }
}

enum ChatEntry: Identifiable {
    case userMessage(User)
    case aiMessage(Assistant)
    case activity(Activity)

    var id: String {
        switch self {
        case .userMessage(let user): "user-\(user.id)"
        case .aiMessage(let assistant): "ai-\(assistant.id)"
        case .activity(let activity): "activity-\(activity.id)"
        }
    }

    struct User: Identifiable, Equatable {
        var id: UUID
        var text: String
        var attachments: [ChatAttachmentRef] = []
        var isCancelled = false
        var isFailed = false
    }

    struct Assistant: Identifiable, Equatable {
        var id: UUID
        var text: String
        var isStreaming: Bool
    }

    struct Activity: Identifiable, Equatable {
        var id: UUID
        var text: String
        var isError = false
    }
}
