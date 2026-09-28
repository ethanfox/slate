import AppKit
import SwiftData
import SwiftUI

struct ConversationRow: View {
    @Bindable var conversation: Conversation
    var isSelected: Bool
    var onSelect: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var confirmDelete = false

    var body: some View {
        Button(action: onSelect) {
            if renaming {
                TextField("Title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(CraftFont.sidebar)
                    .onSubmit { commitRename() }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
            } else {
                SidebarRow(title: conversation.title, systemImage: "bubble.left", isSelected: isSelected)
                    .help(subtitle)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename") {
                draftTitle = conversation.title
                renaming = true
            }
            Button(conversation.isArchived ? "Unarchive" : "Archive") {
                conversation.isArchived.toggle()
                conversation.updatedAt = .now
            }
            if !conversation.cursorURL.isEmpty, let url = URL(string: conversation.cursorURL), url.scheme == "https" {
                Button("Open in Cursor") {
                    NSWorkspace.shared.open(url)
                }
            }
            if !conversation.cursorAgentId.isEmpty {
                Button("Copy Agent ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(conversation.cursorAgentId, forType: .string)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { confirmDelete = true }
        }
        .alert("Delete this conversation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                context.delete(conversation)
                try? context.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from this Mac. The Cursor cloud agent is left as it is.")
        }
    }

    private var subtitle: String {
        var parts = [conversation.updatedAt.relativeLabel, app.modelName(for: conversation.model)]
        if app.showAgentIDs, !conversation.cursorAgentId.isEmpty {
            parts.append(conversation.cursorAgentId)
        }
        return parts.joined(separator: " · ")
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { conversation.title = trimmed }
        renaming = false
    }
}
