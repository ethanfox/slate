import SwiftData
import SwiftUI

struct OverviewPage: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(spacing: 0) {
            OverviewCanvas(project: project)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            ChatInput(
                modelID: Bindable(app).talkModelID,
                placeholder: "Message \(project.name)",
                onSend: startChat
            )
            .frame(maxWidth: 680)
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
    }

    private func startChat(_ text: String) -> Bool {
        let conversation = app.makeConversation(in: project, context: context)
        app.pendingSend = PendingSend(conversationID: conversation.id, text: text)
        ChatTrace.event("project composer queued conversation=\(conversation.id) project=\(project.name) chars=\(text.count)")
        return true
    }
}
