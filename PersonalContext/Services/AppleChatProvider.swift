import Foundation
import FoundationModels

/// Apple's on-device model: free, private, and there without an account.
/// Its window is small, so it gets a short brief of the Space, the end of the chat, and a few tools
/// with a way to find the rest.
struct AppleChatProvider: ChatProvider {
    let id = TalkProvider.apple.rawValue
    let name = TalkProvider.apple.title
    let workspace: ChatWorkspace

    var zeroResponseMessage: String { "Apple Intelligence didn’t return a reply." }

    /// The one model there is. The picker needs an id to show it chosen.
    static let modelID = "on-device"
    static let modelName = "On this Mac"

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac can’t run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings to chat with it."
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready. Try again in a few minutes."
        case .unavailable: "Apple Intelligence isn’t available on this Mac."
        }
    }

    /// Characters of earlier chat kept in the brief. The model's whole window is about 4,000 tokens.
    private static let historyBudget = 2_500
    private static let attachmentBudget = 3_000

    func stream(
        messages: [TalkMessage],
        model: String,
        options: ChatTurnOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let workspace = workspace
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = Self.unavailableReason {
                        throw ChatGPTAuthError(reason)
                    }
                    let last = messages.last(where: { $0.role == .user })
                    let prompt = Self.prompt(for: last, options: options)
                    let (instructions, metadata, tools) = await MainActor.run {
                        let box = AppleToolBox(workspace: workspace)
                        box.report = { continuation.yield($0) }
                        let (instructions, metadata) = Self.prepare(
                            workspace: workspace, messages: messages, userText: last?.text ?? ""
                        )
                        return (instructions, metadata, box.tools)
                    }
                    continuation.yield(.metadata(metadata))
                    let session = LanguageModelSession(tools: tools, instructions: instructions)
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        let content = snapshot.content
                        if content.hasPrefix(sent) {
                            let delta = String(content.dropFirst(sent.count))
                            if !delta.isEmpty { continuation.yield(.text(delta)) }
                        } else {
                            continuation.yield(.text(content))
                        }
                        sent = content
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: ChatGPTAuthError(Self.message(for: error)))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor
    private static func prepare(
        workspace: ChatWorkspace,
        messages: [TalkMessage],
        userText: String
    ) -> (String, ChatTurnMetadata) {
        var metadata = ChatTurnMetadata()
        let conversation = workspace.conversation
        if conversation.title == "New chat" || conversation.title.isEmpty {
            metadata.title = conversationTitle(from: userText)
        }
        var parts = [
            "You are Membrae, a personal workspace on the user's Mac. Answer clearly and briefly.",
            "Use the tools to look things up and to add or change them. Copy ids exactly from tool results. For anything the other tools can't do, call find_tool, then use_tool."
        ]
        if let space = workspace.project {
            var brief = "The chat is in the Space \"\(space.name)\"."
            let summary = space.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty { brief += " " + summary }
            let direction = space.currentDirection.trimmingCharacters(in: .whitespacesAndNewlines)
            if !direction.isEmpty { brief += " Current direction: " + String(direction.prefix(600)) }
            parts.append(brief)
        }
        if let history = TalkMessage.conversationTranscript(messages) {
            parts.append("The chat so far:\n" + String(history.suffix(historyBudget)))
        }
        return (parts.joined(separator: "\n\n"), metadata)
    }

    /// The model reads text only, so a file goes in as the text taken out of it.
    private static func prompt(for message: TalkMessage?, options: ChatTurnOptions) -> String {
        guard let message else { return "" }
        var parts = [message.text]
        for attachment in message.attachments {
            if let prepared = options.payload(for: attachment.id), case .extracted(let extracted) = prepared.route {
                parts.append("Attached file: \(extracted.filename)\n" + String(extracted.text.prefix(attachmentBudget)))
            } else {
                parts.append("Attachment \(attachment.filename) can’t be read on this Mac and was not sent.")
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            "This chat is too long for Apple Intelligence. Start a new chat, or connect ChatGPT or Cursor for longer ones."
        case .guardrailViolation:
            "Apple Intelligence wouldn’t answer that."
        case .unsupportedLanguageOrLocale:
            "Apple Intelligence doesn’t support this language yet."
        case .assetsUnavailable:
            "Apple Intelligence is still getting ready. Try again in a few minutes."
        case .rateLimited, .concurrentRequests:
            "Apple Intelligence is busy. Try again in a moment."
        default:
            error.localizedDescription
        }
    }
}
