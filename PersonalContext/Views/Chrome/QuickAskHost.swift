import SwiftData
import SwiftUI

struct QuickAskHost: View {
    var id: UUID
    @Query private var conversations: [Conversation]

    var body: some View {
        if let conversation = conversations.first(where: { $0.id == id }) {
            ChatScreen(conversation: conversation, project: nil)
        } else {
            ScrollView {
                PageBody {
                    EmptyLine(text: "This conversation is no longer here.")
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}
