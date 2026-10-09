import SwiftData
import SwiftUI

struct TaskInspector: View {
    @Environment(AppModel.self) private var app
    @Query(filter: #Predicate<AgendaItem> { $0.kindRaw == "task" })
    private var tasks: [AgendaItem]

    private var selected: AgendaItem? {
        guard let id = app.selectedTaskID else { return nil }
        return tasks.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let item = selected {
                TaskDocument(item: item)
                    .id(item.id)
            } else {
                Text("Select a task.")
                    .font(CraftFont.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onExitCommand { app.selectTask(nil) }
        .onChange(of: app.selectedTaskID) { _, id in
            guard let id, !tasks.contains(where: { $0.id == id }) else { return }
            app.selectedTaskID = nil
        }
    }
}

private struct TaskDocument: View {
    @Bindable var item: AgendaItem
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var pickingDue = false
    @State private var blockerQuery = ""
    @State private var confirmDelete = false
    @State private var conflict: AssociationConflict?
    @State private var resolveConflict: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DocumentTitle(text: $item.title)

                    HStack(alignment: .center, spacing: 6) {
                        statusPill
                        nextPill
                        duePill
                        if item.due != nil {
                            ModalDateField(date: dueDate, includesTime: true, isPresented: $pickingDue)
                            repeatPill
                        }
                    }
                    .padding(.top, 8)

                    HStack(alignment: .center, spacing: 6) {
                        projectPill
                        tracksPill
                        notesPill
                        TagField(tags: item.tags) { AssociationService.apply(tags: $0, to: item) }
                    }
                    .padding(.top, 6)

                    if !item.liveNotes.isEmpty {
                        DocumentSection("Linked notes") {
                            ForEach(item.liveNotes, id: \.id) { note in
                                HStack(spacing: 8) {
                                    Button(note.displayTitle) { app.open(note) }
                                        .buttonStyle(.plain)
                                        .font(CraftFont.body)
                                        .underline()
                                    Spacer(minLength: 4)
                                    Button {
                                        AssociationService.unlink(noteID: note.id, from: item, in: context)
                                        try? context.save()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 28, height: 28)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Unlink")
                                    .accessibilityLabel("Unlink \(note.displayTitle)")
                                }
                            }
                        }
                    }

                    MarkdownEditor(text: $item.notes, placeholder: "Comment", minHeight: 120)
                        .padding(.top, 16)

                    if item.workflowStatus == .blocked
                        || !item.blockedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !item.unresolvedBlockers.isEmpty {
                        DocumentSection("Blocked") {
                            TaskBlockedSection(item: item, query: $blockerQuery)
                        }
                    }

                    Button("Start Run…") {
                        app.presentNewRun(origin: .task, project: item.project, task: item)
                    }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .padding(.top, 24)

                    Button("Delete Task", role: .destructive, action: { confirmDelete = true })
                        .buttonStyle(.plain)
                        .font(CraftFont.body)
                        .foregroundStyle(.red)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .onChange(of: item.title) { _, _ in item.touch() }
        .onChange(of: item.notes) { _, _ in item.touch() }
        .onChange(of: item.due) { _, due in
            if due == nil { item.repeatRule = .none }
            item.touch()
        }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Task", role: .destructive) {
                guard RunStore.canDelete(item, in: context) else {
                    app.flash(RunStoreError.stillActive.localizedDescription)
                    return
                }
                TaskStore.delete(item, in: context)
                app.selectTask(nil)
            }
        }
        .confirmationDialog(
            conflict.map { "Switch to \($0.incoming.displayName)?" } ?? "Switch project?",
            isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
            titleVisibility: .visible
        ) {
            Button("Switch Project") {
                resolveConflict?()
                conflict = nil
                resolveConflict = nil
            }
            Button("Keep \(conflict?.current.displayName ?? "Project")", role: .cancel) {
                conflict = nil
                resolveConflict = nil
            }
        } message: {
            Text("This belongs to a different project. Switching moves this item and drops links that don’t belong.")
        }
    }

    private var header: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: { app.selectTask(nil) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var statusPill: some View {
        PropertyPill(title: item.workflowStatus.label, systemImage: statusSymbol) {
            ForEach(TaskWorkflowStatus.allCases) { status in
                Button(status.label) {
                    TaskStore.setStatus(status, on: item, in: context)
                }
            }
        }
    }

    private var nextPill: some View {
        PropertyPill(title: item.isNext ? "Next" : "Not next", systemImage: "arrow.forward") {
            if item.isNext {
                Button("Clear Next") { TaskStore.clearNext(on: item, in: context) }
            } else {
                Button("Mark Next") {
                    do { try TaskStore.setNext(item, in: context) }
                    catch { app.flash(error.localizedDescription) }
                }
                .disabled(!item.canBeNext)
            }
        }
    }

    private var duePill: some View {
        PropertyPill(title: item.due == nil ? "No due date" : "Due", systemImage: "calendar") {
            if item.due != nil {
                Button("Clear due date") {
                    item.due = nil
                    item.repeatRule = .none
                    item.touch()
                }
            } else {
                Button("Add due date") {
                    item.due = .now
                    item.touch()
                    pickingDue = true
                }
            }
        }
    }

    private var repeatPill: some View {
        PropertyPill(title: item.repeatRule.label, systemImage: "repeat") {
            ForEach(TaskRepeat.pickerCases(including: item.repeatRule)) { rule in
                Button(rule.label) {
                    item.repeatRule = rule
                    item.touch()
                }
            }
        }
    }

    private var projectPill: some View {
        PropertyPill(
            title: item.project?.displayName ?? "No project",
            systemImage: item.project.map { $0.symbol.isEmpty ? "square.stack" : $0.symbol } ?? "square.stack"
        ) {
            Button("No project") {
                AssociationService.clearProject(from: item)
                try? context.save()
            }
            ForEach(projects) { project in
                Button(project.displayName) {
                    AssociationService.assignUserProject(project, on: item)
                    try? context.save()
                }
            }
        }
    }

    private var tracksPill: some View {
        PropertyPill(
            title: item.liveTracks.first.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "No track",
            systemImage: TrackStyle.symbol
        ) {
            Button("No track") {
                for thread in item.liveTracks {
                    AssociationService.unlink(threadID: thread.id, from: item, in: context)
                }
                try? context.save()
            }
            ForEach(tracksInScope) { thread in
                Button(thread.title.isEmpty ? "Untitled" : thread.title) {
                    toggle(thread)
                }
            }
        }
    }

    private var notesPill: some View {
        PropertyPill(
            title: notesPillTitle,
            systemImage: "note.text"
        ) {
            Button("New Note…") { createNote() }
                .disabled(item.project == nil)
            if !notesInScope.isEmpty {
                Divider()
                ForEach(notesInScope) { note in
                    Button {
                        toggle(note)
                    } label: {
                        Label(note.displayTitle, systemImage: linkedNoteIDs.contains(note.id) ? "checkmark" : "note.text")
                    }
                }
            }
        }
    }

    private var notesPillTitle: String {
        let notes = item.liveNotes
        if notes.isEmpty { return "Notes" }
        if notes.count == 1 { return notes[0].displayTitle }
        return "\(notes.count) notes"
    }

    private var linkedNoteIDs: Set<UUID> { Set(item.noteLinks.map(\.noteID)) }

    private var statusSymbol: String {
        switch item.workflowStatus {
        case .ready: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.octagon"
        case .done: "checkmark.circle"
        }
    }

    private var dueDate: Binding<Date> {
        Binding(
            get: { item.due ?? .now },
            set: { item.due = $0 }
        )
    }

    private var tracksInScope: [ProjectThread] {
        var pool = item.project?.threads ?? projects.flatMap(\.threads)
        for thread in item.liveTracks where !pool.contains(where: { $0.id == thread.id }) {
            pool.append(thread)
        }
        return pool.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var notesInScope: [Note] {
        var pool = item.project?.notes ?? projects.flatMap(\.notes)
        for note in item.liveNotes where !pool.contains(where: { $0.id == note.id }) {
            pool.append(note)
        }
        return pool.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    private func toggle(_ thread: ProjectThread) {
        if item.trackLinks.contains(where: { $0.threadID == thread.id }) {
            AssociationService.unlink(threadID: thread.id, from: item, in: context)
            try? context.save()
            return
        }
        if let conflict = AssociationService.link(thread: thread, onto: item) {
            self.conflict = conflict
            resolveConflict = {
                AssociationService.switchProject(conflict.incoming, on: item)
                AssociationService.applyLink(thread: thread, onto: item)
                try? context.save()
            }
            return
        }
        try? context.save()
    }

    private func toggle(_ note: Note) {
        if item.noteLinks.contains(where: { $0.noteID == note.id }) {
            AssociationService.unlink(noteID: note.id, from: item, in: context)
            try? context.save()
            return
        }
        if let conflict = AssociationService.link(note: note, onto: item) {
            self.conflict = conflict
            resolveConflict = {
                AssociationService.switchProject(conflict.incoming, on: item)
                AssociationService.applyLink(note: note, onto: item)
                try? context.save()
            }
            return
        }
        try? context.save()
    }

    private func createNote() {
        guard let project = item.project else { return }
        let note = Note(content: "", project: project, title: "")
        context.insert(note)
        AssociationService.applyLink(note: note, onto: item)
        project.touch()
        try? context.save()
        app.open(note)
    }
}

private struct TaskBlockedSection: View {
    var item: AgendaItem
    @Binding var query: String
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<AgendaItem> { $0.kindRaw == "task" }, sort: \AgendaItem.updatedAt, order: .reverse)
    private var tasks: [AgendaItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Why it’s blocked", text: blockedReason, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CraftFont.chatBody)
                .lineLimit(2...4)

            TextField("Blocked by…", text: $query)
                .textFieldStyle(.plain)
                .font(CraftFont.body)

            ForEach(item.unresolvedBlockers, id: \.id) { blocker in
                HStack(spacing: 8) {
                    Button(blocker.displayTitle, action: { app.selectTask(blocker.id) })
                        .buttonStyle(.plain)
                        .font(CraftFont.body)
                        .underline()
                    Spacer(minLength: 4)
                    Button {
                        TaskStore.removeBlocker(blocker, from: item, in: context)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                    .accessibilityLabel("Remove \(blocker.displayTitle)")
                }
            }

            ForEach(matches) { candidate in
                Button {
                    do { try TaskStore.addBlocker(candidate, to: item, in: context) }
                    catch { app.flash(error.localizedDescription) }
                    query = ""
                } label: {
                    HStack {
                        Text(candidate.displayTitle)
                            .font(CraftFont.body)
                        if let name = candidate.project?.displayName {
                            Text(name)
                                .font(CraftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var blockedReason: Binding<String> {
        Binding(
            get: { item.blockedReason },
            set: { TaskStore.setBlockedReason($0, on: item, in: context) }
        )
    }

    private var matches: [AgendaItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let linked = Set(item.blockerLinks.compactMap { $0.blockingTask?.id })
        return Array(tasks.filter { candidate in
            candidate.id != item.id
                && !linked.contains(candidate.id)
                && candidate.displayTitle.localizedCaseInsensitiveContains(needle)
        }.prefix(8))
    }
}
