import SwiftData
import SwiftUI

struct ChatScreen: View {
    @Bindable var conversation: Conversation
    var project: Project?
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        PageBody {
            ConversationChat(conversation: conversation, project: project)
                .onAppear {
                    app.selectedConversation = conversation.id
                }
        }
    }
}
