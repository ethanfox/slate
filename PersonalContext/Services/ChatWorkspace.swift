import Foundation
import Observation
import SwiftData

/// Provider-neutral conversation context: identity, debug, and shared turn preparation.
@MainActor
@Observable
final class ChatWorkspace {
    var conversation: Conversation
    var project: Project?
    let debugLog: ChatDebugLog
    var mcp: MembraeMCPClient { .shared }

    init(conversation: Conversation, project: Project?, debugLog: ChatDebugLog) {
        self.conversation = conversation
        self.project = project ?? conversation.project
        self.debugLog = debugLog
    }

    func attach(conversation: Conversation, project: Project?) {
        self.conversation = conversation
        self.project = project ?? conversation.project
    }

    func prepareTurn(userText: String, includeMembraeTools: Bool = true) -> (prompt: String, metadata: ChatTurnMetadata) {
        var metadata = ChatTurnMetadata()
        if conversation.title == "New chat" || conversation.title.isEmpty {
            metadata.title = conversationTitle(from: userText)
        }
        let opening = conversation.contextSnapshot.isEmpty
        let context = project.map(ContextBuilder.identity(for:)) ?? ""
        let routing = routing(includeMembraeTools: includeMembraeTools)
        if opening {
            metadata.contextSnapshot = context.isEmpty ? routing : context
        }
        let prompt = includeMembraeTools
            ? ContextBuilder.prompt(
                userText: "",
                context: context,
                opening: opening,
                focusedThread: conversation.thread,
                routing: routing
            )
            : ContextBuilder.codeConsultationPrompt(userText: "", context: context)
        return (prompt, metadata)
    }

    /// A chat outside every Space files what it is given wherever it belongs.
    func routing(includeMembraeTools: Bool = true) -> String {
        guard includeMembraeTools, project == nil else { return "" }
        return ContextBuilder.routing(in: conversation.modelContext)
    }

    func currentCodeRoots() async throws -> [ProjectCodeRoot] {
        let store = conversation.modelContext?.container.configurations.first?.url
        let current = ProjectCodeWorkspace.authorizedRoots(for: project, storeURL: store)
        if !current.isEmpty { return current }
        return try await ProjectCodeWorkspace.prepare(for: project, storeURL: store)
    }
}
