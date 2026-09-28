import SwiftData
import SwiftUI

struct ThreadChatPane: View {
    var thread: ProjectThread
    var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var conversation: Conversation?

    var body: some View {
        ZStack {
            CraftColor.canvas
            if let conversation {
                ConversationChat(conversation: conversation, project: project, compact: true)
                    .id(conversation.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: thread.id) {
            conversation = app.makeTrackConversation(for: thread, in: project, context: context)
        }
    }
}
