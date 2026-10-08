import SwiftData
import SwiftUI

enum ProjectColumnMetrics {
    static let expandedWidth: CGFloat = 250
    static let railWidth: CGFloat = 52
    static let subtrackIndent: CGFloat = 28
    static let hoverOpenDelay: Duration = .milliseconds(100)
    static let chatPreviewLimit = 10
    static let openMotion = Animation.easeOut(duration: 0.22)
    static let closeMotion = Animation.easeOut(duration: 0.14)
}

struct ProjectColumn: View {
    @Bindable var project: Project
    var compact: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var collapsed: Set<UUID> = []
    @State private var expandedCompleted: Set<UUID> = []
    @State private var showingAllChats = false
    @State private var pendingThreadDelete: ProjectThread?
    @State private var pendingNoteDelete: Note?
    @State private var pendingDecisionDelete: Decision?

    init(project: Project, compact: Bool) {
        self.project = project
        self.compact = compact
        _collapsed = State(initialValue: Set(project.threads.filter { !$0.children.isEmpty }.map(\.id)))
    }

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

    private var markedIDs: Set<UUID> {
        Set(project.deletionMarks.map(\.targetID))
    }

    var body: some View {
        Group {
            if compact {
                rail
            } else {
                fullList
            }
        }
        .alert(
            "Delete \(pendingThreadDelete?.title ?? "this track")?",
            isPresented: Binding(get: { pendingThreadDelete != nil }, set: { if !$0 { pendingThreadDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let thread = pendingThreadDelete {
                    if app.selectedThread == thread.id { app.selectedThread = thread.parent?.id }
                    DeletionMarks.remove(targetingIDs: thread.deletionTargetIDs, in: context)
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
                    DeletionMarks.remove(targetingIDs: [note.id], in: context)
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
                    DeletionMarks.remove(targetingIDs: [decision.id], in: context)
                    context.delete(decision)
                    project.touch()
                    try? context.save()
                }
                pendingDecisionDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDecisionDelete = nil }
        }
        .onChange(of: project.id, initial: true) { _, _ in
            showingAllChats = false
            revealTracks(reset: true)
        }
        .onChange(of: app.selectedThread) { _, id in
            expandTrackPath(to: id)
        }
        .onChange(of: app.selectedConversation) { _, id in
            revealSelectedChat(id)
        }
    }

    private var rail: some View {
        VStack(alignment: .center, spacing: 1) {
            ProjectColumnToggle(collapsed: app.projectColumnCollapsed, action: app.toggleProjectColumn)
            ColumnIconButton(
                systemImage: "doc.text",
                isSelected: tab == .overview,
                label: "Overview",
                action: { show(.overview) }
            )
            ColumnIconButton(
                systemImage: "checklist",
                isSelected: tab == .tasks,
                label: "Tasks",
                action: { show(.tasks) }
            )
            if !conversations.isEmpty {
                ColumnIconButton(
                    systemImage: ProjectColumnSection.chats.symbol,
                    isSelected: tab == .chat,
                    label: ProjectColumnSection.chats.title,
                    action: { show(.chat) }
                )
            }
            ColumnIconButton(
                systemImage: ProjectColumnSection.tracks.symbol,
                isSelected: tab == .threads,
                label: ProjectColumnSection.tracks.title,
                action: { show(.threads) }
            )
            ColumnIconButton(
                systemImage: ProjectColumnSection.notes.symbol,
                isSelected: tab == .notes,
                label: ProjectColumnSection.notes.title,
                action: { show(.notes) }
            )
            ColumnIconButton(
                systemImage: ProjectColumnSection.decisions.symbol,
                isSelected: tab == .decisions,
                label: ProjectColumnSection.decisions.title,
                action: { show(.decisions) }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var fullList: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 0) {
                        Button { show(.overview) } label: {
                            SidebarRow(title: "Overview", systemImage: "doc.text", isSelected: tab == .overview)
                        }
                        .buttonStyle(.plain)
                        ProjectColumnToggle(collapsed: app.projectColumnCollapsed, action: app.toggleProjectColumn)
                    }

                    HStack(spacing: 0) {
                        Button { show(.tasks) } label: {
                            SidebarRow(title: "Tasks", systemImage: "checklist", isSelected: tab == .tasks)
                        }
                        .buttonStyle(.plain)
                        SectionAddButton(title: "Task") { createTask() }
                    }

                    if !conversations.isEmpty {
                        header(.chats, add: newChat)
                        if isSectionOpen(.chats) {
                            ForEach(visibleConversations) { conversation in
                                ConversationRow(
                                    conversation: conversation,
                                    isSelected: tab == .chat && app.selectedConversation == conversation.id,
                                    isMarkedForDeletion: markedIDs.contains(conversation.id)
                                ) {
                                    app.open(conversation)
                                }
                            }
                            if conversations.count > ProjectColumnMetrics.chatPreviewLimit {
                                ColumnShowMoreButton(
                                    expanded: showingAllChats,
                                    remaining: conversations.count - ProjectColumnMetrics.chatPreviewLimit
                                ) {
                                    showingAllChats.toggle()
                                }
                            }
                        }
                    }

                    header(.tracks, add: { createThread(parent: nil) })
                    if isSectionOpen(.tracks) {
                        ForEach(project.rootThreads) { thread in
                            ThreadBranch(
                                thread: thread,
                                depth: 0,
                                selectedID: tab == .threads ? app.selectedThread : nil,
                                collapsed: $collapsed,
                                expandedCompleted: $expandedCompleted,
                                markedIDs: markedIDs,
                                onSelect: { id in
                                    if let thread = project.threads.first(where: { $0.id == id }) {
                                        app.open(thread)
                                    }
                                },
                                onCreateChild: { createThread(parent: $0) },
                                onKeep: keepMark,
                                onDelete: { pendingThreadDelete = $0 }
                            )
                        }
                    }

                    header(.notes, add: createNote)
                    if isSectionOpen(.notes) {
                        ForEach(notes) { note in
                            Button {
                                app.open(note)
                            } label: {
                                SidebarRow(
                                    title: note.displayTitle,
                                    systemImage: "note.text",
                                    isSelected: tab == .notes && app.selectedNote == note.id,
                                    isMarkedForDeletion: markedIDs.contains(note.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    app.present(.editNote(note))
                                } label: {
                                    Label("Edit…", systemImage: "pencil")
                                }
                                Button {
                                    app.present(.newTaskFromNote(note))
                                } label: {
                                    Label("New Task…", systemImage: "checklist")
                                }
                                Divider()
                                if markedIDs.contains(note.id) {
                                    Button {
                                        keepMark(note.id)
                                    } label: {
                                        Label("Keep", systemImage: "arrow.uturn.backward")
                                    }
                                }
                                Button(role: .destructive) {
                                    pendingNoteDelete = note
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    header(.decisions, add: createDecision)
                    if isSectionOpen(.decisions) {
                        ForEach(decisions) { decision in
                            Button {
                                app.open(decision)
                            } label: {
                                SidebarRow(
                                    title: decision.title.isEmpty ? "Untitled" : decision.title,
                                    systemImage: decision.status == .active ? "checkmark.seal" : "xmark.seal",
                                    isSelected: tab == .decisions && app.selectedDecision == decision.id,
                                    isMarkedForDeletion: markedIDs.contains(decision.id)
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
                                if markedIDs.contains(decision.id) {
                                    Button {
                                        keepMark(decision.id)
                                    } label: {
                                        Label("Keep", systemImage: "arrow.uturn.backward")
                                    }
                                }
                                Button(role: .destructive) {
                                    pendingDecisionDelete = decision
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
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
    }

    private func header(_ section: ProjectColumnSection, add: @escaping () -> Void) -> some View {
        SidebarSectionHeader(
            title: section.title,
            isExpanded: isSectionOpen(section),
            onToggle: { app.toggleProjectSection(section, tab: tab) }
        ) {
            SectionAddButton(title: String(section.title.dropLast()), action: add)
        }
    }

    private func show(_ tab: ProjectTab) {
        app.open(project, tab: tab)
        if let section = ProjectColumnSection.allCases.first(where: { $0.tab == tab }) {
            app.openProjectSection(section)
        }
    }

    private func isSectionOpen(_ section: ProjectColumnSection) -> Bool {
        app.isProjectSectionOpen(section, tab: tab)
    }

    private var visibleConversations: [Conversation] {
        if showingAllChats { return conversations }
        return Array(conversations.prefix(ProjectColumnMetrics.chatPreviewLimit))
    }

    private func revealTracks(reset: Bool) {
        if reset {
            collapsed = Set(project.threads.filter { !$0.children.isEmpty }.map(\.id))
        }
        expandTrackPath(to: tab == .threads ? app.selectedThread : nil)
    }

    private func expandTrackPath(to id: UUID?) {
        var current = project.threads.first { $0.id == id }
        while let thread = current {
            collapsed.remove(thread.id)
            current = thread.parent
        }
    }

    private func revealSelectedChat(_ id: UUID?) {
        guard let id else { return }
        let preview = conversations.prefix(ProjectColumnMetrics.chatPreviewLimit)
        if !preview.contains(where: { $0.id == id }) {
            showingAllChats = true
        }
    }

    private func createTask() {
        app.open(project, tab: .tasks)
        app.present(.newTask(project))
    }

    private func newChat() {
        app.openProjectSection(.chats)
        app.showNewChat(in: project)
    }

    private func createThread(parent: ProjectThread?) {
        app.openProjectSection(.tracks)
        let thread = ProjectThread(title: "", kind: parent == nil ? .direction : .feature, project: project, parent: parent)
        context.insert(thread)
        project.touch()
        try? context.save()
        if let parent { collapsed.remove(parent.id) }
        app.open(thread)
    }

    private func createNote() {
        app.openProjectSection(.notes)
        let note = Note(content: "", project: project)
        context.insert(note)
        project.touch()
        try? context.save()
        app.open(note)
    }

    private func keepMark(_ id: UUID) {
        guard let mark = DeletionMarks.existing(for: id, in: project) else { return }
        DeletionMarks.keep(mark, in: context)
        project.touch()
        try? context.save()
    }

    private func keepMark(_ thread: ProjectThread) {
        keepMark(thread.id)
    }

    private func createDecision() {
        app.openProjectSection(.decisions)
        let decision = Decision(title: "", decision: "", project: project)
        context.insert(decision)
        project.touch()
        try? context.save()
        app.open(decision)
    }
}

private struct ProjectColumnToggle: View {
    var collapsed: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.leading")
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
        .help(collapsed ? "Expand Project Sidebar" : "Collapse Project Sidebar")
        .accessibilityLabel(collapsed ? "Expand Project Sidebar" : "Collapse Project Sidebar")
    }
}

private struct ColumnIconButton: View {
    var systemImage: String
    var isSelected: Bool
    var label: String
    var action: () -> Void

    @Environment(\.appearsActive) private var appearsActive
    @State private var hovering = false

    private var iconColor: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.primary) }
        if appearsActive { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tertiary)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(CraftFont.sidebarIcon)
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? CraftColor.selection : Color.clear)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(!isSelected && hovering ? CraftColor.hover : Color.clear)
                        .animation(Motion.hover, value: hovering)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ColumnShowMoreButton: View {
    var expanded: Bool
    var remaining: Int
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(expanded ? "Show less" : "Show more")
                .font(CraftFont.sidebar)
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? CraftColor.hover : Color.clear)
                        .animation(Motion.hover, value: hovering)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(expanded ? "Show less" : "Show more")
        .accessibilityHint(expanded ? "Hides older chats" : "Shows \(remaining) more chats")
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
