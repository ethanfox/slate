import AIChatCore
import Foundation

struct ProjectWorkerChatProvider: ChatProvider {
    let id: String
    let name: String
    let bridge: CursorConversationBridge
    let chatProviderID: String
    let workerProviderID: String
    let workerModelID: String
    let workerPath: WorkerPath

    var zeroResponseMessage: String { "The chat provider didn’t return a reply." }

    func stream(
        messages: [AIChatCore.ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let bridge = bridge
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let question = Self.text(from: messages.last(where: { $0.role == .user }))
                    let workerContext = try await consult(question: question, options: options)
                    let augmented = Self.augment(messages: messages, context: workerContext)
                    let chatProvider = Self.provider(
                        id: chatProviderID,
                        bridge: bridge,
                        includeSlateTools: true,
                        includeProjectTools: false,
                        resumeConversation: true,
                        path: .local
                    )
                    for try await event in chatProvider.stream(messages: augmented, model: model, options: options) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
            }
        }
    }

    func complete(
        messages: [AIChatCore.ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult {
        throw ProjectWorkspaceError("Project Worker conversations stream only.")
    }

    @MainActor
    private func consult(question: String, options: ChatRequestOptions) async throws -> String {
        let workerBridge = CursorConversationBridge(
            conversation: bridge.conversation,
            project: bridge.project
        )
        let provider = Self.provider(
            id: workerProviderID,
            bridge: workerBridge,
            includeSlateTools: false,
            includeProjectTools: true,
            resumeConversation: false,
            path: workerPath
        )
        let prompt = """
        Inspect the attached project code to answer the question below. This is read-only consultation: do not edit files, create commits, or change Slate records. Return concise findings with repository-relative file paths and line numbers.

        \(question)
        """
        let message = AIChatCore.ChatMessage(id: UUID(), role: .user, content: prompt)
        var output = ""
        for try await event in provider.stream(messages: [message], model: workerModelID, options: options) {
            if case .text(let text) = event {
                output += text
            }
        }
        for tool in workerBridge.tools {
            bridge.applyTool(
                name: tool.name,
                status: tool.status.rawValue,
                id: tool.id,
                detail: tool.detail
            )
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectWorkspaceError("The project Worker returned no code context.")
        }
        return output
    }

    private static func provider(
        id: String,
        bridge: CursorConversationBridge,
        includeSlateTools: Bool,
        includeProjectTools: Bool,
        resumeConversation: Bool,
        path: WorkerPath
    ) -> any ChatProvider {
        switch TalkProvider(rawValue: id) {
        case .cursor:
            return CursorChatProvider(
                bridge: bridge,
                includeSlateTools: includeSlateTools,
                includeProjectTools: includeProjectTools,
                resumeConversation: resumeConversation,
                runtime: path
            )
        case .chatgpt:
            return ChatGPTProvider(
                bridge: bridge,
                includeSlateTools: includeSlateTools,
                includeProjectTools: includeProjectTools
            )
        default:
            return UnavailableChatProvider(
                id: id,
                name: "Disconnected worker",
                message: "The custom project Worker is not connected. Update it in Project Settings."
            )
        }
    }

    private static func augment(
        messages: [AIChatCore.ChatMessage],
        context: String
    ) -> [AIChatCore.ChatMessage] {
        guard let last = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        var output = messages
        let request = text(from: messages[last])
        output[last] = AIChatCore.ChatMessage(
            id: messages[last].id,
            role: .user,
            content: """
            A Worker selected in this Slate project inspected the attached code. Use its findings as code context, then answer the original request yourself.

            <worker-context>
            \(context)
            </worker-context>

            <user-request>
            \(request)
            </user-request>
            """
        )
        return output
    }

    private static func text(from message: AIChatCore.ChatMessage?) -> String {
        guard let message else { return "" }
        return message.content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
    }
}
