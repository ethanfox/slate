import Foundation

enum ProjectWorker {
    static func isConfigured(on project: Project?) -> Bool {
        guard let project else { return false }
        return !project.workerProviderID.isEmpty
    }

    @MainActor
    static func consult(
        brief: String,
        reportingTo bridge: CursorConversationBridge,
        options: ChatTurnOptions
    ) async throws -> String {
        let question = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            throw ProjectWorkspaceError("brief is required")
        }
        guard let project = bridge.project, isConfigured(on: project) else {
            throw ProjectWorkspaceError("This project has no Worker. Set one in Project Settings.")
        }
        let workerBridge = CursorConversationBridge(
            conversation: bridge.conversation,
            project: project
        )
        let provider = chatProvider(
            id: project.workerProviderID,
            bridge: workerBridge,
            includeSlateTools: false,
            includeProjectTools: true,
            resumeConversation: false,
            path: WorkerPath(rawValue: project.workerPath) ?? .local
        )
        let model = modelID(project: project, conversation: bridge.conversation)
        let prompt = """
        Inspect the attached project code to answer the question below. This is read-only consultation: do not edit files, create commits, or change Slate records. Return concise findings with repository-relative file paths and line numbers.

        \(question)
        """
        let message = TalkMessage(id: UUID(), role: .user, text: prompt)
        var output = ""
        for try await event in provider.stream(messages: [message], model: model, options: options) {
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

    static func chatProvider(
        id: String,
        bridge: CursorConversationBridge,
        includeSlateTools: Bool = true,
        includeProjectTools: Bool = true,
        resumeConversation: Bool = true,
        path: WorkerPath = .local
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

    private static func modelID(project: Project, conversation: Conversation) -> String {
        if project.workerModelID.isEmpty, project.workerProviderID == conversation.providerID {
            return conversation.modelID
        }
        return project.workerModelID
    }
}
