import SwiftData
import SwiftUI

struct ProjectChatCenter: View {
    var project: Project
    @Environment(AppModel.self) private var app

    var body: some View {
        if let id = app.selectedConversation,
           let conversation = project.conversations.first(where: { $0.id == id }) {
            ConversationChat(conversation: conversation, project: project)
                .id(conversation.id)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                EmptyLine(text: "Start a chat. It gets this project’s summary, direction, tracks, and decisions as context.")
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                PinnedComposer(project: project)
            }
        }
    }
}
