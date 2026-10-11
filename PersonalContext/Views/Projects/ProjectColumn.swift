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
    @Query private var index: [TitleIndex]
    @State private var expanded: Set<UUID> = []
    @State private var expandedCompleted: Set<UUID> = []
    @State private var showingAllChats = false
    @State private var showingAllRuns = false
    @State private var pendingThreadDelete: UUID?
    @State private var pendingNoteDelete: UUID?
    @State private var pendingDecisionDelete: UUID?
    @State private var decisionQuery = ""
    @State private var historyExpanded = false
    @State private var collapsedActiveGroups: Set<String> = []
    @State private var collapsedHistoryGroups: Set<String> = []

    init(project: Project, compact: Bool) {
        self.project = project
        self.compact = compact
        let key = project.id.uuidString.lowercased()
        _index = Query(
            filter: #Predicate<TitleIndex> { $0.projectIDString == key },
            sort: \TitleIndex.updatedAt,
            order: .reverse
        )
    }

    private var tab: ProjectTab { app.tab(for: project.id) }

    private var conversations: [TitleIndex] {
        index.filter { $0.kind == .chat && !$0.isArchived }
    }

    private var projectRuns: [TitleIndex] {
        index.filter { $0.kind == .run }
    }

    private var notes: [TitleIndex] {
        index.filter { $0.kind == .note }
    }

    private var trackRoots: [TrackNode] {
        TitleIndexStore.trackTree(from: index)
    }

    private var decisionLayout: DecisionListLayout.TitleSnapshot {
        DecisionListLayout.snapshot(
            decisions: index.filter { $0.kind == .decision }.map {
                DecisionListLayout.TitleDecision(
                    id: $0.id,
                    title: $0.displayTitle,
                    status: $0.decisionStatus,
                    trackID: $0.parentID,
                    createdAt: $0.createdAt
                )
            },
            tracks: trackRoots,
            query: decisionQuery
        )
    }

    private var showsDecisionHistory: Bool {
        if historyExpanded || decisionLayout.revealsHistory { return true }
        guard let id = app.selectedDecision else { return false }
        return index.contains { $0.id == id && $0.kind == .decision && $0.decisionStatus == .superseded }
    }

    private var markedIDs: Set<UUID> {
        Set(index.filter(\.isMarked).map(\.id))
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
            "Delete \(index.first { $0.id == pendingThreadDelete }?.displayTitle ?? "this track")?",
            isPresented: Binding(get: { pendingThreadDelete != nil }, set: { if !$0 { pendingThreadDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingThreadDelete, let thread = TitleIndexStore.thread(id, in: context) {
                    if app.selectedThread == thread.id { app.selectedThread = thread.parent?.id }
                    DeletionMarks.remove(targetingIDs: thread.deletionTargetIDs, in: context)
                    context.delete(thread)
                    project.touch()
                    try? context.persist()
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
                if let id = pendingNoteDelete, let note = TitleIndexStore.note(id, in: context) {
                    if app.selectedNote == note.id { app.selectedNote = nil }
                    DeletionMarks.remove(targetingIDs: [note.id], in: context)
                    context.delete(note)
                    project.touch()
                    try? context.persist()
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
                if let id = pendingDecisionDelete, let decision = TitleIndexStore.decision(id, in: context) {
                    if app.selectedDecision == decision.id { app.selectedDecision = nil }
                    DeletionMarks.remove(targetingIDs: [decision.id], in: context)
                    context.delete(decision)
                    project.touch()
                    try? context.persist()
                }
                pendingDecisionDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDecisionDelete = nil }
        }
        .onAppear {
            NavTrace.event(
                "project.column appear compact=\(compact) rows=\(index.count) chats=\(conversations.count) tracks=\(trackRoots.count) notes=\(notes.count)"
            )
        }
        .onChange(of: project.id, initial: true) { _, _ in
            showingAllChats = false
            showingAllRuns = false
            decisionQuery = ""
            historyExpanded = false
            collapsedActiveGroups = []
            collapsedHistoryGroups = []
            revealTracks(reset: true)
        }
        .onChange(of: app.selectedThread) { _, id in
            expandTrackPath(to: id)
        }
        .onChange(of: app.selectedConversation) { _, id in
            revealSelectedChat(id)
        }
        .onChange(of: app.selectedRun) { _, id in
            revealSelectedRun(id)
        }
    }

    private var rail: some View {
        VStack(alignment: .center, spacing: 1) {
            ProjectColumnToggle(collapsed: app.projectColumnCollapsed, action: app.toggleProjectColumn)
            railButton(.overview, symbol: "doc.text", label: "Overview")
            railButton(.tasks, symbol: "checklist", label: "Tasks")
            railButton(.runs, symbol: ProjectColumnSection.runs.symbol, label: ProjectColumnSection.runs.title)
            railButton(.chat, symbol: ProjectColumnSection.chats.symbol, label: ProjectColumnSection.chats.title)
            railButton(.threads, symbol: ProjectColumnSection.tracks.symbol, label: ProjectColumnSection.tracks.title)
            railButton(.notes, symbol: ProjectColumnSection.notes.symbol, label: ProjectColumnSection.notes.title)
            railButton(.decisions, symbol: ProjectColumnSection.decisions.symbol, label: ProjectColumnSection.decisions.title)
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
                        .contextMenu { openSectionInNewTab(.overview) }
                        ProjectColumnToggle(collapsed: app.projectColumnCollapsed, action: app.toggleProjectColumn)
                    }

                    HStack(spacing: 0) {
                        Button { show(.tasks) } label: {
                            SidebarRow(title: "Tasks", systemImage: "checklist", isSelected: tab == .tasks)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { openSectionInNewTab(.tasks) }
                        SectionAddButton(title: "Task") { createTask() }
                    }

                    header(.runs, add: newRun)
                    if isSectionOpen(.runs) {
                        ForEach(visibleRuns) { run in
                            Button {
                                app.open(run)
                            } label: {
                                SidebarRow(
                                    title: run.displayTitle,
                                    systemImage: "play.circle",
                                    isSelected: tab == .runs && app.selectedRun == run.id,
                                    isBusy: run.isBusy
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu { RunTitleMenu(row: run) }
                        }
                        if projectRuns.count > ProjectColumnMetrics.chatPreviewLimit {
                            ColumnShowMoreButton(
                                expanded: showingAllRuns,
                                remaining: projectRuns.count - ProjectColumnMetrics.chatPreviewLimit
                            ) {
                                showingAllRuns.toggle()
                            }
                        }
                    }

                    header(.chats, add: newChat)
                    if isSectionOpen(.chats) {
                        ForEach(visibleConversations) { conversation in
                            ConversationTitleRow(
                                row: conversation,
                                isSelected: tab == .chat && app.selectedConversation == conversation.id
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

                    header(.tracks, add: { createThread(parent: nil) })
                    if isSectionOpen(.tracks) {
                        ForEach(trackRoots) { node in
                            ThreadBranch(
                                node: node,
                                depth: 0,
                                selectedID: tab == .threads ? app.selectedThread : nil,
                                expanded: $expanded,
                                expandedCompleted: $expandedCompleted,
                                markedIDs: markedIDs,
                                onSelect: { id in
                                    if let row = index.first(where: { $0.id == id }) {
                                        app.open(row)
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
                                    isMarkedForDeletion: note.isMarked
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    if let record = TitleIndexStore.note(note.id, in: context) {
                                        app.present(.editNote(record))
                                    }
                                } label: {
                                    Label("Edit…", systemImage: "pencil")
                                }
                                Button {
                                    app.open(note, newTab: true)
                                } label: {
                                    Label("Open in New Tab", systemImage: "plus.square.on.square")
                                }
                                Button {
                                    if let record = TitleIndexStore.note(note.id, in: context) {
                                        app.present(.newTaskFromNote(record))
                                    }
                                } label: {
                                    Label("New Task…", systemImage: "checklist")
                                }
                                Divider()
                                if note.isMarked {
                                    Button {
                                        keepMark(note.id)
                                    } label: {
                                        Label("Keep", systemImage: "arrow.uturn.backward")
                                    }
                                }
                                Button(role: .destructive) {
                                    pendingNoteDelete = note.id
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    header(.decisions, add: createDecision)
                    if isSectionOpen(.decisions) {
                        decisionFilter
                        decisionGroups(decisionLayout.active, dimmed: false, history: false)
                        if decisionLayout.historyCount > 0 {
                            DecisionDisclosureHeader(
                                title: "History",
                                count: decisionLayout.historyCount,
                                isExpanded: showsDecisionHistory,
                                onToggle: { historyExpanded.toggle() }
                            )
                            if showsDecisionHistory {
                                decisionGroups(decisionLayout.history, dimmed: true, history: true)
                            }
                        } else if decisionLayout.active.isEmpty, !decisionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("No matching decisions")
                                .font(CraftFont.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
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

    private func railButton(_ tab: ProjectTab, symbol: String, label: String) -> some View {
        ColumnIconButton(
            systemImage: symbol,
            isSelected: self.tab == tab,
            label: label,
            action: { show(tab) }
        )
        .contextMenu { openSectionInNewTab(tab) }
    }

    @ViewBuilder
    private func openSectionInNewTab(_ tab: ProjectTab) -> some View {
        Button {
            if tab == .runs {
                app.showProjectRuns(in: project, newTab: true)
            } else {
                app.open(project, tab: tab, newTab: true)
            }
        } label: {
            Label("Open in New Tab", systemImage: "plus.square.on.square")
        }
    }

    private func show(_ tab: ProjectTab) {
        if tab == .runs {
            app.showProjectRuns(in: project)
        } else {
            app.open(project, tab: tab)
        }
        if let section = ProjectColumnSection.allCases.first(where: { $0.tab == tab }) {
            app.openProjectSection(section)
        }
    }

    private func isSectionOpen(_ section: ProjectColumnSection) -> Bool {
        app.isProjectSectionOpen(section, tab: tab)
    }

    private var visibleConversations: [TitleIndex] {
        if showingAllChats { return conversations }
        return Array(conversations.prefix(ProjectColumnMetrics.chatPreviewLimit))
    }

    private var visibleRuns: [TitleIndex] {
        if showingAllRuns { return projectRuns }
        return Array(projectRuns.prefix(ProjectColumnMetrics.chatPreviewLimit))
    }

    private func revealTracks(reset: Bool) {
        if reset {
            expanded = []
        }
        guard isSectionOpen(.tracks) else { return }
        expandTrackPath(to: tab == .threads ? app.selectedThread : nil)
    }

    private func expandTrackPath(to id: UUID?) {
        guard var current = id else { return }
        var guardrail = 0
        while guardrail < 32 {
            expanded.insert(current)
            guard let parent = index.first(where: { $0.id == current })?.parentID else { break }
            current = parent
            guardrail += 1
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

    private func revealSelectedRun(_ id: UUID?) {
        guard let id else { return }
        let preview = projectRuns.prefix(ProjectColumnMetrics.chatPreviewLimit)
        if !preview.contains(where: { $0.id == id }) {
            showingAllRuns = true
        }
    }

    private func newRun() {
        app.presentNewRun(origin: .project, project: project)
    }

    private func newChat() {
        app.openProjectSection(.chats)
        app.showNewChat(in: project)
    }

    private func createThread(parent: UUID?) {
        app.openProjectSection(.tracks)
        let parentThread = parent.flatMap { TitleIndexStore.thread($0, in: context) }
        let thread = ProjectThread(
            title: "",
            kind: parent == nil ? .direction : .feature,
            project: project,
            parent: parentThread
        )
        context.insert(thread)
        project.touch()
        try? context.persist()
        if let parent { expanded.insert(parent) }
        app.open(thread)
    }

    private func createNote() {
        app.openProjectSection(.notes)
        let note = Note(content: "", project: project)
        context.insert(note)
        project.touch()
        try? context.persist()
        app.open(note)
    }

    private func keepMark(_ id: UUID) {
        guard let mark = DeletionMarks.existing(for: id, in: context) else { return }
        DeletionMarks.keep(mark, in: context)
        project.touch()
        try? context.persist()
    }

    private var decisionFilter: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(CraftFont.caption)
                .foregroundStyle(.tertiary)
            TextField("Filter", text: $decisionQuery)
                .textFieldStyle(.plain)
                .font(CraftFont.sidebar)
            if !decisionQuery.isEmpty {
                Button {
                    decisionQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(CraftColor.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .accessibilityLabel("Filter decisions")
    }

    @ViewBuilder
    private func decisionGroups(_ groups: [DecisionListLayout.TitleGroup], dimmed: Bool, history: Bool) -> some View {
        ForEach(groups) { group in
            let expanded = showsDecisionGroup(group, history: history)
            DecisionDisclosureHeader(
                title: group.title,
                count: group.decisions.count,
                isExpanded: expanded,
                onToggle: { toggleDecisionGroup(group, history: history) }
            )
            if expanded {
                ForEach(group.decisions) { decision in
                    decisionRow(decision, dimmed: dimmed)
                }
            }
        }
    }

    private var isDecisionSearchActive: Bool {
        !decisionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func showsDecisionGroup(_ group: DecisionListLayout.TitleGroup, history: Bool) -> Bool {
        if isDecisionSearchActive { return true }
        if group.decisions.contains(where: { $0.id == app.selectedDecision }) { return true }
        let collapsed = history ? collapsedHistoryGroups : collapsedActiveGroups
        return !collapsed.contains(group.id)
    }

    private func toggleDecisionGroup(_ group: DecisionListLayout.TitleGroup, history: Bool) {
        if history {
            if collapsedHistoryGroups.contains(group.id) {
                collapsedHistoryGroups.remove(group.id)
            } else {
                collapsedHistoryGroups.insert(group.id)
            }
        } else if collapsedActiveGroups.contains(group.id) {
            collapsedActiveGroups.remove(group.id)
        } else {
            collapsedActiveGroups.insert(group.id)
        }
    }

    private func decisionRow(_ decision: DecisionListLayout.TitleDecision, dimmed: Bool) -> some View {
        Button {
            if let row = index.first(where: { $0.id == decision.id }) {
                app.open(row)
            }
        } label: {
            SidebarRow(
                title: decision.title,
                systemImage: decision.status == .active ? "checkmark.seal" : "xmark.seal",
                isSelected: tab == .decisions && app.selectedDecision == decision.id,
                isMarkedForDeletion: markedIDs.contains(decision.id)
            )
            .opacity(dimmed ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if let record = TitleIndexStore.decision(decision.id, in: context) {
                    app.present(.editDecision(record))
                }
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button {
                if let row = index.first(where: { $0.id == decision.id }) {
                    app.open(row, newTab: true)
                }
            } label: {
                Label("Open in New Tab", systemImage: "plus.square.on.square")
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
                pendingDecisionDelete = decision.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func createDecision() {
        app.openProjectSection(.decisions)
        let decision = Decision(title: "", decision: "", project: project)
        context.insert(decision)
        project.touch()
        try? context.persist()
        app.open(decision)
    }
}

private struct DecisionDisclosureHeader: View {
    var title: String
    var count: Int
    var isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                Text(title)
                    .font(CraftFont.section)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(count)")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .padding(.trailing, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows \(count) decisions")
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
