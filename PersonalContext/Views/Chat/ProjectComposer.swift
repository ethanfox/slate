import SwiftData
import SwiftUI

struct ProjectComposer: View {
    var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var text = ""

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ComposerPlate {
            VStack(alignment: .leading, spacing: 8) {
                ModelPicker(selection: Bindable(app).defaultModelID)
                ComposerFieldRow(
                    placeholder: "Message \(project.name)",
                    text: $text,
                    canSend: canSend,
                    onSend: send
                )
            }
        }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let conversation = app.makeConversation(in: project, context: context)
        app.tabs[project.id] = .chat
        app.pendingSend = PendingSend(conversationID: conversation.id, text: trimmed)
        ChatTrace.event("project composer queued conversation=\(conversation.id) project=\(project.name) chars=\(trimmed.count)")
        text = ""
    }
}
