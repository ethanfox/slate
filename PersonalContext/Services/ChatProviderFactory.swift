import Foundation

enum ChatProviderFactory {
    @MainActor
    static func make(
        conversation: Conversation,
        project: Project?,
        debugLog: ChatDebugLog
    ) -> any ChatProvider {
        let workspace = ChatWorkspace(
            conversation: conversation,
            project: project ?? conversation.project,
            debugLog: debugLog
        )
        switch TalkProvider(rawValue: conversation.providerID) {
        case .cursor:
            return CursorChatProvider(bridge: CursorConversationBridge(workspace: workspace))
        case .chatgpt:
            return ChatGPTProvider(workspace: workspace)
        case .compatible:
            return GenericChatProvider(
                endpoint: UserDefaults.standard.string(forKey: Keys.compatibleEndpoint) ?? "",
                apiKey: KeychainStore.read(.compatibleAPIKey)
            )
        case .apple:
            return AppleChatProvider(workspace: workspace)
        case .unconfigured, .none:
            return UnavailableChatProvider(
                id: conversation.providerID,
                name: "Not configured",
                message: "Choose a chat provider in Settings, then start a new chat."
            )
        }
    }
}
