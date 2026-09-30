import SwiftData
import SwiftUI

struct ProjectColumn: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var collapsed: Set<UUID> = []
    @State private var pendingThreadDelete: ProjectThread?
    @State private var pendingNoteDelete: Note?
    @State private var pendingDecisionDelete: Decision?

    private var tab: ProjectTab { app.tab(for: project.id) }

    private var conversations: [Conversation] {
        project.conversations.filter { !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var notes: [Note] {
        project.notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var decisions: [Decision] {
        project.decisions.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status == .active }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var body: some View {
        ScrollView {
            PageBody {
            VStack(alignment: .leading, spacing: 1) {
                Button { show(.overview) } label: {
                    SidebarRow(title: "Overview", systemImage: "doc.text", isSelected: tab == .overview)
                }
                .buttonStyle(.plain)

                if !conversations.isEmpty {
                    header("Chats", add: newChat)
                    ForEach(conversations) { conversation in
                        ConversationRow(conversation: conversation, isSelected: tab == .chat && app.selectedConversation == conversation.id) {
                            app.selectedConversation = conversation.id
                            show(.chat)
                        }
                    }
                }

                header("Tracks", add: { createThread(parent: nil) })
                ForEach(project.rootThreads) { thread in
                    ThreadBranch(
                        thread: thread,
                        depth: 0,
                        selectedID: tab == .threads ? app.selectedThread : nil,
                        collapsed: $collapsed,
                        onSelect: { app.selectedThread = $0; show(.threads) },
                        onCreateChild: { createThread(parent: $0) },
                        onDelete: { pendingThreadDelete = $0 }
                    )
                }

                header("Notes", add: createNote)
                ForEach(notes) { note in
                    Button {
                        app.selectedNote = note.id
                        show(.notes)
                    } label: {
                        SidebarRow(title: note.displayTitle, systemImage: "note.text", isSelected: tab == .notes && app.selectedNote == note.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            app.present(.editNote(note))
                        } label: {
                            Label("Edit…", systemImage: "pencil")
                        }
                        Button {
                            app.present(.newReminderFromNote(note))
                        } label: {
                            Label("New Reminder…", systemImage: "checklist")
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingNoteDelete = note
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                header("Decisions", add: createDecision)
                ForEach(decisions) { decision in
                    Button {
                        app.selectedDecision = decision.id
                        show(.decisions)
                    } label: {
                        SidebarRow(
                            title: decision.title.isEmpty ? "Untitled" : decision.title,
                            systemImage: decision.status == .active ? "checkmark.seal" : "xmark.seal",
                            isSelected: tab == .decisions && app.selectedDecision == decision.id
                        )
                        .opacity(decision.status == .active ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            app.present(.editDecision(decision))
                        } label: {
                            Label("Edit…", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingDecisionDelete = decision
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 16)
            }
        }
        .scrollContentBackground(.hidden)
        .alert(
            "Delete \(pendingThreadDelete?.title ?? "this track")?",
            isPresented: Binding(get: { pendingThreadDelete != nil }, set: { if !$0 { pendingThreadDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let thread = pendingThreadDelete {
                    if app.selectedThread == thread.id { app.selectedThread = thread.parent?.id }
                    context.delete(thread)
                    project.touch()
                    try? context.save()
                }
                pendingThreadDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingThreadDelete = nil }
        } message: {
            Text("Child tracks are removed too. Notes and decisions stay in the project.")
        }
        .alert(
            "Delete this note?",
            isPresented: Binding(get: { pendingNoteDelete != nil }, set: { if !$0 { pendingNoteDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let note = pendingNoteDelete {
                    if app.selectedNote == note.id { app.selectedNote = nil }
                    context.delete(note)
                    project.touch()
                    try? context.save()
                }
                pendingNoteDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingNoteDelete = nil }
        }
        .alert(
            "Delete this decision?",
            isPresented: Binding(get: { pendingDecisionDelete != nil }, set: { if !$0 { pendingDecisionDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let decision = pendingDecisionDelete {
                    if app.selectedDecision == decision.id { app.selectedDecision = nil }
                    context.delete(decision)
                    project.touch()
                    try? context.save()
                }
                pendingDecisionDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDecisionDelete = nil }
        }
    }

    private func header(_ title: String, add: @escaping () -> Void) -> some View {
        SidebarSectionHeader(title: title) {
            SectionAddButton(title: String(title.dropLast()), action: add)
        }
    }

    private func show(_ tab: ProjectTab) {
        app.tabs[project.id] = tab
    }

    private func newChat() {
        app.selectedConversation = nil
        show(.chat)
    }

    private func createThread(parent: ProjectThread?) {
        let thread = ProjectThread(title: "", kind: parent == nil ? .direction : .feature, project: project, parent: parent)
        context.insert(thread)
        project.touch()
        try? context.save()
        if let parent { collapsed.remove(parent.id) }
        app.selectedThread = thread.id
        show(.threads)
    }

    private func createNote() {
        let note = Note(content: "", project: project)
        context.insert(note)
        project.touch()
        try? context.save()
        app.selectedNote = note.id
        show(.notes)
    }

    private func createDecision() {
        let decision = Decision(title: "", decision: "", project: project)
        context.insert(decision)
        project.touch()
        try? context.save()
        app.selectedDecision = decision.id
        show(.decisions)
    }
}

private struct SectionAddButton: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(CraftFont.sidebarIcon)
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? CraftColor.selection : Color.clear)
                        .animation(Motion.hover, value: hovering)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New \(title)")
        .accessibilityLabel("New \(title)")
    }
}
