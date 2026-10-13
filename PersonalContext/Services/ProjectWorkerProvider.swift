import Foundation

enum ProjectWorker {
    /// Projects no longer choose a worker. The chat reads attached code itself, and code work goes to a Run.
    static func isConfigured(on _: Project?) -> Bool {
        false
    }

    @MainActor
    static func consult(
        brief: String,
        reportingTo workspace: ChatWorkspace,
        options: ChatTurnOptions,
        onTool: ((String, String, String?, String?) -> Void)? = nil
    ) async throws -> String {
        let question = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            throw ProjectWorkspaceError("brief is required")
        }
        guard let project = workspace.project, isConfigured(on: project) else {
            throw ProjectWorkspaceError("This project has no Worker. Set one in Project Settings.")
        }
        let workerBridge = CursorConversationBridge(
            conversation: workspace.conversation,
            project: project
        )
        let provider = chatProvider(
            id: project.workerProviderID,
            bridge: workerBridge,
            includeMembraeTools: false,
            includeProjectTools: true,
            resumeConversation: false,
            path: WorkerPath(rawValue: project.workerPath) ?? .local
        )
        let model = modelID(project: project, conversation: workspace.conversation)
        let prompt = """
        Inspect the attached project code to answer the question below. This is read-only consultation: do not edit files, create commits, or change Membrae records. Return concise findings with repository-relative file paths and line numbers.

        \(question)
        """
        let message = TalkMessage(id: UUID(), role: .user, text: prompt)
        var output = ""
        for try await event in provider.stream(messages: [message], model: model, options: options) {
            switch event {
            case .text(let text):
                output += text
            case .tool(let name, let status, let id, let detail, _):
                onTool?(name, status, id, detail)
            default:
                break
            }
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectWorkspaceError("The project Worker returned no code context.")
        }
        return output
    }

    static func chatProvider(
        id: String,
        bridge: CursorConversationBridge,
        includeMembraeTools: Bool = true,
        includeProjectTools: Bool = true,
        resumeConversation: Bool = true,
        path: WorkerPath = .local
    ) -> any ChatProvider {
        switch TalkProvider(rawValue: id) {
        case .cursor:
            return CursorChatProvider(
                bridge: bridge,
                includeMembraeTools: includeMembraeTools,
                includeProjectTools: includeProjectTools,
                resumeConversation: resumeConversation,
                runtime: path
            )
        case .chatgpt:
            return ChatGPTProvider(
                workspace: bridge.workspace,
                includeMembraeTools: includeMembraeTools,
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
