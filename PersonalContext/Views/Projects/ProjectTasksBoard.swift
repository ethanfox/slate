import SwiftData
import SwiftUI

struct ProjectTasksBoard: View {
    var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<AgendaItem> { $0.kindRaw == "task" }, sort: \AgendaItem.updatedAt, order: .reverse)
    private var membraeTasks: [AgendaItem]
    @Query private var completions: [TaskCompletion]
    @State private var inspectCompletion: TaskCompletion?

    /// The track the board is limited to, or nil when it shows every task.
    private var shownTrack: ProjectThread? {
        TaskTrackFilterMenu.track(for: project, filter: app.taskTrackFilters[project.id] ?? .all)
    }

    /// Ids of the tasks on the shown track, or nil when the board is not limited.
    private var shownTaskIDs: Set<UUID>? {
        shownTrack.map { Set(AgendaStore.items(on: $0, includingChildren: true).map(\.id)) }
    }

    private var projectTasks: [AgendaItem] {
        let all = membraeTasks.filter { $0.project?.id == project.id }
        guard let ids = shownTaskIDs else { return all }
        return all.filter { ids.contains($0.id) }
    }

    private var projectCompletions: [TaskCompletion] {
        let ids = shownTaskIDs
        return completions
            .filter { completion in
                guard completion.project?.id == project.id else { return false }
                guard let ids else { return true }
                return completion.parentTask.map { ids.contains($0.id) } ?? false
            }
            .sorted { $0.completedAt > $1.completedAt }
    }

    var body: some View {
        Group {
            switch app.spaceTasksLayout {
            case .kanban:
                boardScroll
            case .list:
                listScroll
            }
        }
        .popover(item: $inspectCompletion, arrowEdge: .bottom) { completion in
            CompletionPopover(completion: completion)
        }
        .background {
            Button("Close task") { app.selectTask(nil) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!app.inspectorOpen && app.selectedTaskID == nil)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onChange(of: app.inspectorOpen) { _, open in
            if !open { app.selectedTaskID = nil }
        }
        // The pane belongs to this view. Leaving it takes the pick, and the pane, with it.
        .onDisappear { app.selectTask(nil) }
    }

    private var boardScroll: some View {
        GeometryReader { geo in
            let width = columnWidth(in: geo.size.width)
            ScrollView([.horizontal, .vertical]) {
                PageBody {
                    VStack(alignment: .leading, spacing: 20) {
                        SpaceSectionPills(space: project, current: .tasks)
                        HStack(alignment: .top, spacing: BoardMetrics.gap) {
                            ForEach(TaskWorkflowStatus.allCases) { status in
                                column(status)
                                    .frame(width: width, alignment: .topLeading)
                            }
                        }
                    }
                    .padding(BoardMetrics.inset)
                    .frame(minHeight: geo.size.height, alignment: .topLeading)
                }
            }
            .scrollContentBackground(.hidden)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { app.selectTask(nil) }
            }
        }
    }

    private func columnWidth(in container: CGFloat) -> CGFloat {
        let usable = container - BoardMetrics.inset * 2 - BoardMetrics.gap * 3
        return max(BoardMetrics.minColumn, usable / 4)
    }

    private var listScroll: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 24) {
                    SpaceSectionPills(space: project, current: .tasks)
                    ForEach(TaskWorkflowStatus.allCases) { status in
                        listSection(status)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { app.selectTask(nil) }
        }
    }

    private func rows(for status: TaskWorkflowStatus) -> [BoardRow] {
        let tasks = projectTasks.filter { $0.workflowStatus == status }.sorted(by: TaskStore.boardSort)
        if status == .done {
            return tasks.map(BoardRow.task) + projectCompletions.map(BoardRow.completion)
        }
        return tasks.map(BoardRow.task)
    }

    private func listSection(_ status: TaskWorkflowStatus) -> some View {
        let rows = rows(for: status)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StatusPip(status: status)
                Text(status.label)
                    .font(CraftFont.section)
                Text("\(rows.count)")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 8)
            if rows.isEmpty {
                Text("No tasks.")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(rows) { row in
                    switch row {
                    case .task(let item):
                        TaskListRow(item: item)
                    case .completion(let completion):
                        CompletionListRow(completion: completion) {
                            inspectCompletion = completion
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.label), \(rows.count)")
    }

    private func column(_ status: TaskWorkflowStatus) -> some View {
        let rows = rows(for: status)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusPip(status: status)
                Text(status.label)
                    .font(CraftFont.section)
                    .lineLimit(1)
                Text("\(rows.count)")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Button {
                    app.present(.newTask(project))
                } label: {
                    Image(systemName: "plus")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Task")
                .accessibilityLabel("New Task")
            }
            .frame(height: 28)
            ForEach(rows) { row in
                switch row {
                case .task(let item):
                    TaskBoardCard(item: item)
                case .completion(let completion):
                    CompletionBoardCard(completion: completion) {
                        inspectCompletion = completion
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.label), \(rows.count)")
    }
}

private enum BoardMetrics {
    static let minColumn: CGFloat = 220
    static let gap: CGFloat = 20
    static let inset: CGFloat = 32
}

private struct StatusPip: View {
    var status: TaskWorkflowStatus

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(status.tint)
            .frame(width: 3, height: 12)
            .accessibilityHidden(true)
    }
}

private enum BoardRow: Identifiable {
    case task(AgendaItem)
    case completion(TaskCompletion)

    var id: String {
        switch self {
        case .task(let item): "task-\(item.id.uuidString)"
        case .completion(let completion): "completion-\(completion.id.uuidString)"
        }
    }
}

private struct TaskBoardCard: View {
    var item: AgendaItem
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if TaskStore.isNext(item) {
                Text("Next")
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CraftColor.selection, in: Capsule())
            }
            Text(item.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            CardTagStrip(tags: item.tags)
            if let due = item.due {
                Text(TaskDue.label(due))
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(item.liveTracks, id: \.id) { thread in
                Button {
                    app.open(thread)
                } label: {
                    Text(trackLabel(thread))
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ForEach(item.unresolvedBlockers, id: \.id) { blocker in
                Button {
                    app.selectTask(blocker.id)
                } label: {
                    HStack(spacing: 4) {
                        Text("Blocked by \(blocker.displayTitle)")
                        if let name = blocker.project?.displayName, blocker.project?.id != item.project?.id {
                            Text("· \(name)")
                        }
                    }
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            let reason = item.blockedReason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty {
                Text(reason)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            app.selectedTaskID == item.id ? CraftColor.selection : CraftColor.elevated,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CraftColor.hairline)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            app.selectTask(app.selectedTaskID == item.id ? nil : item.id)
        }
        .contextMenu { menu }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Task", role: .destructive) {
                guard RunStore.canDelete(item, in: context) else {
                    app.flash(RunStoreError.stillActive.localizedDescription)
                    return
                }
                TaskStore.delete(item, in: context)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.displayTitle)
        .accessibilityHint("Opens the task")
    }

    private func trackLabel(_ thread: ProjectThread) -> String {
        let title = thread.title.isEmpty ? "Untitled" : thread.title
        guard let stop = item.stop, stop.thread?.id == thread.id else { return title }
        return "\(title) · \(stop.displayTitle)"
    }

    @ViewBuilder
    private var menu: some View {
        if item.project?.activeTrack == nil {
            if item.isNext {
                Button("Clear Next") { TaskStore.clearNext(on: item, in: context) }
            } else {
                Button("Mark Next") {
                    do { try TaskStore.setNext(item, in: context) }
                    catch { app.flash(error.localizedDescription) }
                }
                .disabled(!item.canBeNext)
            }
            Divider()
        }
        ForEach(TaskWorkflowStatus.allCases) { status in
            Button("Move to \(status.label)") {
                TaskStore.setStatus(status, on: item, in: context)
            }
        }
        Divider()
        Button("Edit…") { app.selectTask(item.id) }
        Button("Start Run…") {
            app.presentNewRun(origin: .task, project: item.project, task: item)
        }
        Button("Delete…", role: .destructive) { confirmDelete = true }
    }
}

private struct TaskListRow: View {
    var item: AgendaItem
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var hovering = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                TaskStore.toggleComplete(item, in: context)
            } label: {
                Image(systemName: item.workflowStatus == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.workflowStatus.tint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.workflowStatus == .done ? "Mark incomplete" : "Mark complete")

            Button {
                app.selectTask(app.selectedTaskID == item.id ? nil : item.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.displayTitle)
                            .font(.system(size: 13, weight: .medium))
                            .strikethrough(item.workflowStatus == .done)
                            .foregroundStyle(item.workflowStatus == .done ? .tertiary : .primary)
                            .lineLimit(1)
                        if TaskStore.isNext(item) {
                            Text("Next")
                                .font(CraftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let due = item.due {
                        Text(TaskDue.label(due))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    CardTagStrip(tags: item.tags)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(app.selectedTaskID == item.id ? CraftColor.selection : (hovering ? CraftColor.hover : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Task", role: .destructive) {
                guard RunStore.canDelete(item, in: context) else {
                    app.flash(RunStoreError.stillActive.localizedDescription)
                    return
                }
                TaskStore.delete(item, in: context)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if item.project?.activeTrack == nil {
            if item.isNext {
                Button("Clear Next") { TaskStore.clearNext(on: item, in: context) }
            } else {
                Button("Mark Next") {
                    do { try TaskStore.setNext(item, in: context) }
                    catch { app.flash(error.localizedDescription) }
                }
                .disabled(!item.canBeNext)
            }
            Divider()
        }
        ForEach(TaskWorkflowStatus.allCases) { status in
            Button("Move to \(status.label)") {
                TaskStore.setStatus(status, on: item, in: context)
            }
        }
        Divider()
        Button("Edit…") { app.selectTask(item.id) }
        Button("Start Run…") {
            app.presentNewRun(origin: .task, project: item.project, task: item)
        }
        Button("Delete…", role: .destructive) { confirmDelete = true }
    }
}

private struct CompletionListRow: View {
    var completion: TaskCompletion
    var onOpen: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if TaskStore.isLatest(completion) {
                Button {
                    do { try TaskStore.undoLatestCompletion(completion, in: context) }
                    catch { app.flash(error.localizedDescription) }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Undo")
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.titleSnapshot)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(completion.completedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? CraftColor.hover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .contextMenu {
            if !TaskStore.isLatest(completion) {
                Button("Delete", role: .destructive) {
                    try? TaskStore.deleteCompletion(completion, in: context)
                }
            }
        }
    }
}

private struct CompletionBoardCard: View {
    var completion: TaskCompletion
    var onOpen: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if TaskStore.isLatest(completion) {
                Button {
                    do { try TaskStore.undoLatestCompletion(completion, in: context) }
                    catch { app.flash(error.localizedDescription) }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Undo")
                .accessibilityLabel("Undo latest completion")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(completion.titleSnapshot)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(completion.completedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CraftColor.hairline)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            if !TaskStore.isLatest(completion) {
                Button("Delete", role: .destructive) {
                    try? TaskStore.deleteCompletion(completion, in: context)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(completion.titleSnapshot)
    }
}

private struct CompletionPopover: View {
    var completion: TaskCompletion
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(completion.titleSnapshot)
                .font(CraftFont.body)
            Text(completion.completedAt.formatted(date: .abbreviated, time: .omitted))
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
            if let parent = completion.parentTask {
                Button(parent.displayTitle) {
                    app.selectTask(parent.id)
                }
                .buttonStyle(.plain)
                .font(CraftFont.caption)
            }
        }
        .padding(16)
        .frame(minWidth: 200, alignment: .leading)
    }
}

/// Toolbar menu that picks which track's tasks the board shows.
struct TaskTrackFilterMenu: View {
    var project: Project
    @Environment(AppModel.self) private var app

    static func track(for project: Project, filter: TaskTrackFilter) -> ProjectThread? {
        switch filter {
        case .active: project.activeTrack
        case .all: nil
        case .track(let id): project.threads.first { $0.id == id }
        }
    }

    private var filter: TaskTrackFilter { app.taskTrackFilters[project.id] ?? .all }

    private var title: String {
        guard let track = Self.track(for: project, filter: filter) else { return "All Tasks" }
        return track.title.isEmpty ? "Untitled" : track.title
    }

    /// Tracks with open tasks, so the menu lists only places there is work.
    private var tracksWithWork: [ProjectThread] {
        project.threads
            .filter { track in
                track.id != project.activeTrackID
                    && track.agendaTrackLinks.contains { $0.item.map { $0.kind == .task && !$0.isCompleted } ?? false }
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Menu {
            if let active = project.activeTrack {
                Toggle(isOn: binding(.active)) {
                    Text("Active Track: \(active.title.isEmpty ? "Untitled" : active.title)")
                }
            }
            Toggle("All Tasks", isOn: binding(project.activeTrack == nil ? .active : .all, alsoMatching: .all))
            if !tracksWithWork.isEmpty {
                Divider()
                ForEach(tracksWithWork) { track in
                    Toggle(track.title.isEmpty ? "Untitled" : track.title, isOn: binding(.track(track.id)))
                }
            }
        } label: {
            Label(title, systemImage: "line.3.horizontal.decrease")
                .lineLimit(1)
                .frame(maxWidth: 220)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular, in: Capsule())
        .help("Show tasks for one track")
        .accessibilityLabel("Track filter")
        .accessibilityValue(title)
    }

    private func binding(_ value: TaskTrackFilter, alsoMatching other: TaskTrackFilter? = nil) -> Binding<Bool> {
        Binding(
            get: { filter == value || (other.map { filter == $0 } ?? false) },
            set: { _ in app.taskTrackFilters[project.id] = value }
        )
    }
}
