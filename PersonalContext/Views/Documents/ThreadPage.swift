import SwiftData
import SwiftUI

struct ThreadPage: View {
    @Bindable var thread: ProjectThread
    var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var namingTheme = false
    @State private var newThemeName = ""

    var body: some View {
        DeletionChrome(
            mark: DeletionMarks.existing(for: thread.id, in: project),
            deleteTitle: "Delete \(thread.title.isEmpty ? "this track" : thread.title)?",
            deleteMessage: "Child tracks are removed too. Notes and decisions stay in the project.",
            onKeep: keepMark,
            onConfirmDelete: deleteMarked
        ) {
        DocumentPage {
            if let parent = thread.parent {
                Button {
                    app.open(parent)
                } label: {
                    Label(parent.title.isEmpty ? "Untitled" : parent.title, systemImage: "arrow.turn.left.up")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
                .findHighlight(.parent)
            }

            DocumentTitle(text: $thread.title)

            TextField("One-line summary", text: $thread.summary, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineLimit(1...4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DocumentMeasure.proseWidth, alignment: .leading)
                .padding(.top, 4)
                .findHighlight(.summary)

            TagBar(tags: thread.tags) { thread.tags = $0; touch() }
                .padding(.top, 8)

            HStack(spacing: 6) {
                PropertyPill(title: thread.kind.label, systemImage: thread.kind.symbol, field: .kind) {
                    ForEach(ThreadKind.allCases) { kind in
                        Button(kind.label, systemImage: kind.symbol) { thread.kind = kind; touch() }
                    }
                }
                PropertyPill(title: thread.status.label, systemImage: thread.status.symbol, field: .status) {
                    ForEach(ThreadStatus.allCases) { status in
                        Button(status.label, systemImage: status.symbol) { thread.status = status; touch() }
                    }
                }
                // Tracks no longer nest. One still under another can be taken out, or made a stop on it.
                if let parent = thread.parent {
                    PropertyPill(
                        title: parent.title.isEmpty ? "Untitled" : parent.title,
                        systemImage: "arrow.turn.left.up",
                        field: .parent,
                        onOpen: { app.open(parent) }
                    ) {
                        Button("Make This Its Own Track") { thread.parent = nil; touch() }
                        Button("Make This a Stop on \(parent.title.isEmpty ? "Untitled" : parent.title)") { becomeStop(on: parent) }
                            .disabled(!thread.children.isEmpty)
                    }
                }
                themePill
                activePill
                linked
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            MarkdownEditor(text: $thread.body, minHeight: 360, findField: .body, traceKind: "thread", traceObjectID: thread.id.uuidString)
                .padding(.top, 16)
                .findAnchor(.body)

            StopsSection(thread: thread)

            JunctionsSection(thread: thread, project: project)

            AgendaLinkedSection(items: AgendaStore.items(on: thread, includingChildren: true)) { item in
                item.liveTracks.first { $0.id != thread.id }?.title
            }

            if !thread.children.isEmpty {
                DocumentSection("Sub-tracks") {
                    ForEach(thread.orderedChildren) { child in
                        RecordRow(
                            systemImage: child.kind.symbol,
                            title: child.title.isEmpty ? "Untitled" : child.title,
                            subtitle: plainPreview(child.summary.isEmpty ? child.body : child.summary),
                            meta: "\(child.status.label) · \(child.updatedAt.relativeLabel)",
                            findField: .child(child.id)
                        ) {
                            app.open(child)
                        }
                    }
                }
            }
        }
        }
        .objectFindable(id: thread.id, fields: findFields)
        .onAppear { NavTrace.event("thread appear id=\(thread.id)") }
        .onChange(of: thread.title) { _, _ in touch() }
        .onChange(of: thread.summary) { _, _ in touch() }
        .onChange(of: thread.body) { _, _ in touch() }
    }

    private var themePill: some View {
        PropertyPill(title: thread.theme?.displayName ?? "No theme", systemImage: "square.stack") {
            Button("No theme") { ThemeStore.setTheme("", on: thread, in: context) }
            ForEach(project.orderedThemes) { theme in
                Button(theme.displayName) { ThemeStore.setTheme(theme.name, on: thread, in: context) }
            }
            Divider()
            Button("New Theme…") { namingTheme = true }
        }
        .alert("New Theme", isPresented: $namingTheme) {
            TextField("Name", text: $newThemeName)
            Button("Cancel", role: .cancel) { newThemeName = "" }
            Button("Add") {
                ThemeStore.setTheme(newThemeName, on: thread, in: context)
                newThemeName = ""
            }
        } message: {
            Text("A theme groups tracks. It holds no work of its own.")
        }
    }

    private func becomeStop(on parent: ProjectThread) {
        do {
            try StopStore.absorb(thread, in: context)
            app.open(parent)
        } catch {
            app.flash(error.localizedDescription)
        }
    }

    private var activePill: some View {
        let isActive = project.activeTrackID == thread.id
        return PropertyPill(title: isActive ? "Active track" : "Not active", systemImage: isActive ? "scope" : "circle.dashed") {
            if isActive {
                Button("Stop Working on This Track") { TaskStore.setActiveTrack(nil, on: project, in: context) }
            } else {
                Button("Make This the Active Track") { TaskStore.setActiveTrack(thread, on: project, in: context) }
            }
        }
    }

    @ViewBuilder
    private var linked: some View {
        let count = thread.decisions.count + thread.notes.count + thread.conversations.count
        PropertyPill(title: count == 0 ? "Link" : "\(count) linked", systemImage: "link", field: .linked) {
            if !thread.decisions.isEmpty {
                Section("Decisions") {
                    ForEach(thread.decisions) { decision in
                        Button(decision.title.isEmpty ? "Untitled" : decision.title) {
                            app.open(decision)
                        }
                    }
                }
            }
            if !thread.notes.isEmpty {
                Section("Notes") {
                    ForEach(thread.notes) { note in
                        Button(note.displayTitle) {
                            app.open(note)
                        }
                    }
                }
            }
            if !thread.conversations.isEmpty {
                Section("Chats") {
                    ForEach(thread.conversations) { conversation in
                        Button(conversation.title) { app.open(conversation) }
                    }
                }
            }
            let candidates = project.conversations.filter { $0.thread?.id != thread.id && !$0.isArchived }
            if !candidates.isEmpty {
                Menu("Link Chat") {
                    ForEach(candidates) { conversation in
                        Button(conversation.title) { conversation.thread = thread; touch() }
                    }
                }
            }
        }
    }

    private var findFields: [(ObjectFind.Field, String)] {
        let parentTitle = thread.parent.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "No parent"
        let linkedCount = thread.decisions.count + thread.notes.count + thread.conversations.count
        var fields: [(ObjectFind.Field, String)] = [
            (.parent, parentTitle),
            (.title, thread.title),
            (.summary, thread.summary),
            (.kind, thread.kind.label),
            (.status, thread.status.label),
            (.tags, thread.tags.map(\.displayName).joined(separator: ", ")),
            (.linked, linkedCount == 0 ? "Link" : "\(linkedCount) linked"),
            (.body, thread.body),
        ]
        for child in thread.orderedChildren {
            let title = child.title.isEmpty ? "Untitled" : child.title
            let preview = plainPreview(child.summary.isEmpty ? child.body : child.summary)
            fields.append((.child(child.id), "\(title) \(preview) \(child.status.label) \(child.updatedAt.relativeLabel)"))
        }
        for item in AgendaStore.items(on: thread, includingChildren: true) {
            fields.append((.agenda(item.id), item.displayTitle))
        }
        return fields
    }

    private func touch() {
        thread.updatedAt = .now
        project.touch()
    }

    private func keepMark() {
        guard let mark = DeletionMarks.existing(for: thread.id, in: project) else { return }
        DeletionMarks.keep(mark, in: context)
        project.touch()
        try? context.persist()
    }

    private func deleteMarked() {
        if app.selectedThread == thread.id { app.selectedThread = thread.parent?.id }
        DeletionMarks.remove(targetingIDs: thread.deletionTargetIDs, in: context)
        context.delete(thread)
        project.touch()
        try? context.persist()
    }
}

/// The track's stops in order, each with its tasks. New stops are typed into the last row.
private struct StopsSection: View {
    var thread: ProjectThread
    @Environment(\.modelContext) private var context
    @State private var newTitle = ""

    var body: some View {
        let stops = thread.orderedStops
        DocumentSection("Stops") {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                StopRow(stop: stop, number: index + 1, isFirst: index == 0, isLast: index == stops.count - 1)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                TextField("Add a stop", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(add)
            }
        }
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        StopStore.add(title, to: thread, in: context)
        newTitle = ""
    }
}

private struct StopRow: View {
    @Bindable var stop: TrackStop
    var number: Int
    var isFirst: Bool
    var isLast: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var expanded = false
    @State private var hovering = false

    private var tasks: [AgendaItem] {
        stop.tasks.filter { $0.kind == .task }.sorted { $0.createdAt < $1.createdAt }
    }

    private var progress: String {
        let all = tasks
        guard !all.isEmpty else { return "" }
        return "\(all.count { $0.isCompleted }) of \(all.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    StopStore.setDone(!stop.isDone, on: stop, in: context)
                } label: {
                    Image(systemName: stop.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(stop.isDone ? .secondary : .tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(stop.isDone ? "Mark not done" : "Mark done")
                .accessibilityLabel(stop.isDone ? "Mark stop \(number) not done" : "Mark stop \(number) done")

                Text("\(number)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 14, alignment: .trailing)

                TextField("Stop", text: $stop.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(stop.isDone ? .secondary : .primary)

                Text(progress)
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide details" : "Show details")
                .accessibilityLabel(expanded ? "Hide details" : "Show details")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("What this stop covers", text: $stop.body, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1...8)
                    ForEach(tasks) { task in
                        Button {
                            app.present(.editTask(task))
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                Text(task.displayTitle)
                                    .font(.system(size: 13))
                                    .strikethrough(task.isCompleted)
                                    .foregroundStyle(task.isCompleted ? .tertiary : .primary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if tasks.isEmpty {
                        Text("No tasks on this stop.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 58)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? CraftColor.hover : Color.clear)
                .padding(.horizontal, -8)
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Move Up") { StopStore.move(stop, by: -1, in: context) }
                .disabled(isFirst)
            Button("Move Down") { StopStore.move(stop, by: 1, in: context) }
                .disabled(isLast)
            Divider()
            Button("Delete Stop", role: .destructive) { StopStore.delete(stop, in: context) }
        }
        .onChange(of: stop.title) { _, _ in stop.updatedAt = .now }
        .onChange(of: stop.body) { _, _ in stop.updatedAt = .now }
    }
}

/// The junctions this track meets: what it waits on, what waits on it, and what it is merging with.
private struct JunctionsSection: View {
    var thread: ProjectThread
    var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    private var others: [ProjectThread] {
        project.threads
            .filter { $0.id != thread.id }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        DocumentSection("Junctions") {
            ForEach(thread.junctions) { junction in
                JunctionRow(junction: junction, thread: thread)
            }
            Menu {
                Menu("Wait On") {
                    ForEach(others) { other in
                        Button(other.title.isEmpty ? "Untitled" : other.title) { add(.wait, first: other, second: thread) }
                    }
                }
                Menu("Merge With") {
                    ForEach(others) { other in
                        Button(other.title.isEmpty ? "Untitled" : other.title) { add(.merge, first: thread, second: other) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .frame(width: 28, height: 28)
                    Text("Add a junction")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.tertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(others.isEmpty)
        }
    }

    private func add(_ kind: JunctionKind, first: ProjectThread, second: ProjectThread) {
        do {
            try JunctionStore.add(kind, first: first, second: second, in: context)
        } catch {
            app.flash(error.localizedDescription)
        }
    }
}

private struct JunctionRow: View {
    var junction: TrackJunction
    var thread: ProjectThread
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var newText = ""
    @State private var confirmingMerge = false

    private func name(_ track: ProjectThread?) -> String {
        guard let title = track?.title, !title.isEmpty else { return "Untitled" }
        return title
    }

    private var waitsHere: Bool { junction.second?.id == thread.id }

    private var heading: String {
        switch junction.kind {
        case .merge: "Merging with \(name(junction.other(than: thread)))"
        case .wait: waitsHere ? "Waits on \(name(junction.first))" : "\(name(junction.second)) waits on this"
        }
    }

    private var progress: String {
        let all = junction.requirements
        if all.isEmpty {
            return junction.kind == .wait ? (junction.isMet ? "Met" : "Until that track is completed") : "Nothing listed yet"
        }
        return junction.isMet ? "Met" : "\(all.count { $0.isMet }) of \(all.count)"
    }

    /// Stops a requirement can point at: the waited-on track's for a wait, either track's for a merge.
    private var stopChoices: [TrackStop] {
        let tracks = junction.kind == .wait ? [junction.first] : [junction.first, junction.second]
        let used = Set(junction.requirements.compactMap { $0.stop?.id })
        return tracks.compactMap { $0 }.flatMap(\.orderedStops).filter { !used.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: junction.kind == .merge ? "arrow.triangle.merge" : "hourglass")
                    .font(.system(size: 12))
                    .foregroundStyle(junction.isMet ? .tertiary : .secondary)
                    .frame(width: 28, height: 28)
                Button(heading) {
                    if let other = junction.other(than: thread) { app.open(other) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                if junction.kind == .wait, waitsHere {
                    heldStopMenu
                }
                Spacer(minLength: 8)
                Text(progress)
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(junction.orderedRequirements) { requirement in
                    row(requirement)
                }
                HStack(spacing: 6) {
                    TextField(
                        junction.kind == .merge ? "Add something to reconcile" : "Add something that has to be done first",
                        text: $newText
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(addText)
                    if !stopChoices.isEmpty {
                        Menu("Add a Stop") {
                            ForEach(stopChoices) { stop in
                                Button(stop.displayTitle) { add(stop: stop) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(CraftFont.caption)
                    }
                }
                .padding(.top, 2)
                if junction.kind == .merge {
                    Button("Merge into \(name(junction.first))") { confirmingMerge = true }
                        .disabled(!junction.isMet)
                        .padding(.top, 6)
                }
            }
            .padding(.leading, 36)
            .padding(.bottom, 10)
        }
        .contextMenu {
            Button(junction.kind == .wait ? "Change to a Merge" : "Change to a Wait") {
                attempt { try JunctionStore.update(junction, kind: junction.kind == .wait ? .merge : .wait, heldStop: nil, in: context) }
            }
            Divider()
            Button("Delete Junction", role: .destructive) { JunctionStore.delete(junction, in: context) }
        }
        .confirmationDialog(
            "Merge \(name(junction.second)) into \(name(junction.first))?",
            isPresented: $confirmingMerge
        ) {
            Button("Merge") { merge() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its stops, tasks, decisions, notes, and chats move to \(name(junction.first)). What it said is kept as a note there, and the track is removed.")
        }
    }

    private var heldStopMenu: some View {
        Menu(junction.heldStop.map { "before \($0.displayTitle)" } ?? "whole track") {
            Button("Whole Track") { hold(nil) }
            ForEach(thread.orderedStops) { stop in
                Button(stop.displayTitle) { hold(stop) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(CraftFont.caption)
        .foregroundStyle(.secondary)
    }

    private func row(_ requirement: JunctionRequirement) -> some View {
        let byHand = requirement.stop == nil && requirement.task == nil
        return HStack(spacing: 6) {
            Button {
                JunctionStore.setChecked(!requirement.isChecked, on: requirement, in: context)
            } label: {
                Image(systemName: requirement.isMet ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(requirement.isMet ? .secondary : .tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!byHand)
            .help(byHand ? (requirement.isMet ? "Mark not done" : "Mark done") : "Done when the stop or task is done")
            .accessibilityLabel(requirement.isMet ? "Done: \(requirement.displayText)" : "Not done: \(requirement.displayText)")
            Text(requirement.displayText)
                .font(.system(size: 13))
                .foregroundStyle(requirement.isMet ? .secondary : .primary)
                .lineLimit(2)
            if let stop = requirement.stop {
                Text("Stop on \(name(stop.thread))")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            } else if requirement.task != nil {
                Text("Task")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            if let task = requirement.task {
                Button("Open Task") { app.present(.editTask(task)) }
            }
            Button("Remove", role: .destructive) { JunctionStore.delete(requirement, in: context) }
        }
    }

    private func addText() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        attempt { try JunctionStore.addRequirement(text, to: junction, in: context) }
        newText = ""
    }

    private func add(stop: TrackStop) {
        attempt { try JunctionStore.addRequirement("", stop: stop, to: junction, in: context) }
    }

    private func hold(_ stop: TrackStop?) {
        attempt { try JunctionStore.update(junction, kind: .wait, heldStop: stop, in: context) }
    }

    private func merge() {
        do {
            let merged = try JunctionStore.merge(junction, in: context)
            app.open(merged)
        } catch {
            app.flash(error.localizedDescription)
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { app.flash(error.localizedDescription) }
    }
}
