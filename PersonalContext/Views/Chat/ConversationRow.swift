import SwiftData
import SwiftUI

struct ConversationRow: View {
    @Bindable var conversation: Conversation
    var isSelected: Bool
    var onSelect: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var confirmDelete = false

    var body: some View {
        Button(action: onSelect) {
            SidebarRow(title: conversation.title, systemImage: "bubble.left", isSelected: isSelected)
                .help(subtitle)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                app.present(.editConversation(conversation))
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button {
                conversation.isArchived.toggle()
                conversation.updatedAt = .now
            } label: {
                Label(conversation.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            if !conversation.cursorAgentId.isEmpty {
                Button {
                    CraftClipboard.copy(conversation.cursorAgentId)
                } label: {
                    Label("Copy Agent ID", systemImage: "doc.on.doc")
                }
            }
            Divider()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Delete this conversation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                context.delete(conversation)
                try? context.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from this Mac. Decisions, notes, and tracks from it stay.")
        }
    }

    private var subtitle: String {
        var parts = [conversation.updatedAt.relativeLabel, app.modelName(for: conversation.model)]
        if app.showAgentIDs, !conversation.cursorAgentId.isEmpty {
            parts.append(conversation.cursorAgentId)
        }
        return parts.joined(separator: " · ")
    }
}
