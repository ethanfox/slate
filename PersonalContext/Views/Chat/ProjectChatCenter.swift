import SwiftData
import SwiftUI

struct ProjectChatCenter: View {
    var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var draft = ""

    var body: some View {
        if let id = app.selectedConversation,
           let conversation = project.conversations.first(where: { $0.id == id }) {
            ConversationChat(conversation: conversation, project: project)
                .id(conversation.id)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ChatTitleBar(title: "New chat")
                EmptyLine(text: "Start a chat. It gets this project’s summary and direction. Decisions, tracks, and notes are looked up as needed.")
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Hairline()
                ChatInput(
                    text: $draft,
                    modelID: Bindable(app).talkModelID,
                    providerID: Bindable(app).talkProviderID,
                    placeholder: "Message \(project.name)",
                    onSend: startChat,
                    draftKind: "project-new",
                    draftObjectID: project.id.uuidString
                )
                .frame(maxWidth: 680)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func startChat(_ text: String) -> Bool {
        let conversation = app.makeConversation(in: project, context: context)
        app.pendingSend = PendingSend(conversationID: conversation.id, text: text)
        ChatTrace.event("project composer queued conversation=\(conversation.id) project=\(project.name) chars=\(text.count)")
        return true
    }
}
