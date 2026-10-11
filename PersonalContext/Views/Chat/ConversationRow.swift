import SwiftData
import SwiftUI

struct ConversationTitleRow: View {
    var row: TitleIndex
    var isSelected: Bool
    var onSelect: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var confirmDelete = false

    var body: some View {
        Button(action: onSelect) {
            SidebarRow(
                title: row.displayTitle,
                systemImage: "bubble.left",
                isSelected: isSelected,
                isMarkedForDeletion: row.isMarked
            )
            .help(row.owner)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if let conversation = TitleIndexStore.conversation(row.id, in: context) {
                    app.present(.editConversation(conversation))
                }
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button {
                app.open(row, newTab: true)
            } label: {
                Label("Open in New Tab", systemImage: "plus.square.on.square")
            }
            Button {
                if let conversation = TitleIndexStore.conversation(row.id, in: context) {
                    let brief = conversation.orderedMessages.last(where: { $0.role == .user })?.content ?? ""
                    app.presentNewRun(origin: .chat, project: conversation.project, chat: conversation, brief: brief)
                }
            } label: {
                Label("Start Run…", systemImage: "play.circle")
            }
            Button {
                if let conversation = TitleIndexStore.conversation(row.id, in: context) {
                    conversation.isArchived.toggle()
                    conversation.updatedAt = .now
                    try? context.persist()
                }
            } label: {
                Label(row.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            Divider()
            if row.isMarked {
                Button {
                    keepMark()
                } label: {
                    Label("Keep", systemImage: "arrow.uturn.backward")
                }
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Delete this conversation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                guard let conversation = TitleIndexStore.conversation(row.id, in: context) else { return }
                let project = conversation.project
                if app.selectedConversation == conversation.id { app.selectedConversation = nil }
                DeletionMarks.remove(targetingIDs: [conversation.id], in: context)
                try? FileStore.default(context: context).releaseConversation(conversation)
                context.delete(conversation)
                project?.touch()
                try? context.persist()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from this Mac. Decisions, notes, and tracks from it stay.")
        }
    }

    private func keepMark() {
        guard let mark = DeletionMarks.existing(for: row.id, in: context) else { return }
        DeletionMarks.keep(mark, in: context)
        if let id = row.projectID {
            TitleIndexStore.project(id, in: context)?.touch()
        }
        try? context.persist()
    }
}

struct ConversationRow: View {
    @Bindable var conversation: Conversation
    var isSelected: Bool
    var isMarkedForDeletion = false
    var onSelect: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var confirmDelete = false

    var body: some View {
        Button(action: onSelect) {
            SidebarRow(
                title: conversation.title,
                systemImage: "bubble.left",
                isSelected: isSelected,
                isMarkedForDeletion: isMarkedForDeletion
            )
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
                app.open(conversation, newTab: true)
            } label: {
                Label("Open in New Tab", systemImage: "plus.square.on.square")
            }
            Button {
                let brief = conversation.orderedMessages.last(where: { $0.role == .user })?.content ?? ""
                app.presentNewRun(origin: .chat, project: conversation.project, chat: conversation, brief: brief)
            } label: {
                Label("Start Run…", systemImage: "play.circle")
            }
            Button {
                conversation.isArchived.toggle()
                conversation.updatedAt = .now
            } label: {
                Label(conversation.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            if conversation.providerID == TalkProvider.cursor.rawValue, !conversation.externalSessionID.isEmpty {
                Button {
                    CraftClipboard.copy(conversation.externalSessionID)
                } label: {
                    Label("Copy Agent ID", systemImage: "doc.on.doc")
                }
            }
            Divider()
            if isMarkedForDeletion {
                Button {
                    keepMark()
                } label: {
                    Label("Keep", systemImage: "arrow.uturn.backward")
                }
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Delete this conversation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let project = conversation.project
                if app.selectedConversation == conversation.id { app.selectedConversation = nil }
                DeletionMarks.remove(targetingIDs: [conversation.id], in: context)
                try? FileStore.default(context: context).releaseConversation(conversation)
                context.delete(conversation)
                project?.touch()
                try? context.persist()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from this Mac. Decisions, notes, and tracks from it stay.")
        }
    }

    private func keepMark() {
        guard let project = conversation.project,
              let mark = DeletionMarks.existing(for: conversation.id, in: project) else { return }
        DeletionMarks.keep(mark, in: context)
        project.touch()
        try? context.persist()
    }

    private var subtitle: String {
        var parts = [
            conversation.updatedAt.relativeLabel,
            TalkProvider(rawValue: conversation.providerID)?.title ?? "Unknown provider",
            app.modelName(for: conversation.modelID, providerID: conversation.providerID)
        ]
        if app.showAgentIDs,
           conversation.providerID == TalkProvider.cursor.rawValue,
           !conversation.externalSessionID.isEmpty {
            parts.append(conversation.externalSessionID)
        }
        return parts.joined(separator: " · ")
    }
}
