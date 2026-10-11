import EventKit
import SwiftData
import SwiftUI

struct TasksView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<AgendaItem> { $0.kindRaw == "task" }, sort: \AgendaItem.updatedAt, order: .reverse)
    private var membraeTasks: [AgendaItem]
    @State private var filter: TasksFilter = .today
    @State private var draft = ""
    @State private var tasksCompletedOpen = false
    @State private var remindersCompletedOpen = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        PageBody {
            HStack(alignment: .top, spacing: 0) {
                mainColumn
                if showsRail {
                    remindersRail
                        .frame(width: 248)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : Motion.smooth, value: showsRail)
        }
        .background {
            Button("Add reminder") { addReminder() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task { await app.eventKit.prepareReminders() }
    }

    private var mainColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                head
                remindersAccessLine
                if taskSections.isEmpty, allReminderGroups.isEmpty, completedTasks.isEmpty {
                    EmptyLine(text: emptyCopy)
                } else {
                    ForEach(taskSections) { section in
                        taskSection(section)
                    }
                    if filter == .all {
                        ForEach(allReminderGroups) { group in
                            reminderSection(group)
                        }
                    }
                    if !completedTasks.isEmpty {
                        completedBlock(
                            count: completedTasks.count,
                            open: $tasksCompletedOpen,
                            hint: "Shows completed tasks"
                        ) {
                            ForEach(completedTasks) { item in
                                TaskRow(item: item, hideTodayDue: filter == .today) {
                                    AgendaStore.toggleComplete(item, in: context)
                                }
                            }
                            if filter == .all {
                                ForEach(completedReminders) { item in
                                    ReminderRow(item: item, compact: false) { toggle(item) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    private var remindersRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Reminders")
                        .font(CraftFont.section)
                    Text("\(railReminders.count)")
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("Due or flagged")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(railReminders) { item in
                        ReminderRow(item: item, compact: true) { toggle(item) }
                    }
                    if !railCompleted.isEmpty {
                        completedBlock(
                            count: railCompleted.count,
                            open: $remindersCompletedOpen,
                            hint: "Shows completed reminders"
                        ) {
                            ForEach(railCompleted) { item in
                                ReminderRow(item: item, compact: true) { toggle(item) }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .padding(.top, 28)
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(CraftColor.hairline)
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reminders due or flagged")
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(TasksFilter.allCases) { item in
                    filterChip(item)
                }
            }
            composer
        }
    }

    private func filterChip(_ item: TasksFilter) -> some View {
        Button {
            filter = item
        } label: {
            Text(item.title)
                .font(.system(size: 13, weight: filter == item ? .medium : .regular))
                .foregroundStyle(filter == item ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(filter == item ? CraftColor.selection : Color.clear, in: RoundedRectangle(cornerRadius: CraftRadius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == item ? .isSelected : [])
        .accessibilityLabel(item.title)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
            TextField("New task", text: $draft)
                .textFieldStyle(.plain)
                .font(CraftFont.body)
                .focused($composerFocused)
                .onSubmit(addTask)
                .accessibilityLabel("New task")
                .accessibilityHint("Return adds a task. Command Return adds a reminder.")
            Button("⌘↩ Reminder", action: addReminder)
                .buttonStyle(.plain)
                .font(CraftFont.caption)
                .foregroundStyle(.tertiary)
                .help("Add a reminder")
        }
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CraftColor.hairline)
                .frame(height: 1)
        }
    }

    private func taskSection(_ section: TasksSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(section.title)
                    .font(CraftFont.section)
                    .foregroundStyle(section.id == "overdue" ? app.accent(for: .calendar) : Color.primary)
                Text("\(section.items.count)")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 8)
            ForEach(section.items) { item in
                TaskRow(item: item, hideTodayDue: filter == .today) {
                    AgendaStore.toggleComplete(item, in: context)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title), \(section.items.count)")
    }

    private func reminderSection(_ group: ReminderGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(group.tint.color)
                    .frame(width: 6, height: 6)
                Text(group.title)
                    .font(CraftFont.section)
                Text("\(group.items.count)")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 8)
            ForEach(group.items) { item in
                ReminderRow(item: item, compact: false) { toggle(item) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title), \(group.items.count)")
    }

    private func completedBlock<Content: View>(
        count: Int,
        open: Binding<Bool>,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open.wrappedValue.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text("Completed")
                        .font(CraftFont.section)
                    Text("\(count)")
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Completed")
            .accessibilityValue(open.wrappedValue ? "Expanded" : "Collapsed")
            .accessibilityHint(hint)

            if open.wrappedValue {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var remindersAccessLine: some View {
        if !app.eventKit.canReadReminders {
            switch app.eventKit.remindersAccess {
            case .notDetermined, .writeOnly:
                EventKitAccessLine(
                    text: "Membrae can also show Apple Reminders here.",
                    actionTitle: "Allow Reminders Access"
                ) {
                    Task { await app.eventKit.requestRemindersAccess() }
                }
            default:
                EmptyView()
            }
        }
    }

    private var showsRail: Bool {
        filter != .all && (!railReminders.isEmpty || !railCompleted.isEmpty)
    }

    private var taskSections: [TasksSection] {
        TasksLayout.sections(from: membraeTasks, filter: filter)
    }

    private var completedTasks: [AgendaItem] {
        membraeTasks.filter(\.isCompleted)
    }

    private var completedReminders: [ReminderItem] {
        app.eventKit.reminders.filter(\.isCompleted)
    }

    private var allReminderGroups: [ReminderGroup] {
        guard filter == .all else { return [] }
        return ReminderItem.groups(from: app.eventKit.reminders.filter { !$0.isCompleted })
    }

    private var railReminders: [ReminderItem] {
        app.eventKit.reminders.filter { ReminderItem.isAttention($0) }
    }

    private var railCompleted: [ReminderItem] {
        app.eventKit.reminders.filter { ReminderItem.isCompletedToday($0) }
    }

    private var emptyCopy: String {
        switch filter {
        case .today: "No tasks due today."
        case .upcoming: "Nothing upcoming."
        case .inbox: "Inbox is empty."
        case .all: "No tasks."
        }
    }

    private func addTask() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let item = AgendaItem(kind: .task, eventKitID: "", title: title)
        let calendar = Calendar.current
        switch filter {
        case .today:
            item.due = calendar.startOfDay(for: .now)
        case .upcoming:
            item.due = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))
        case .inbox, .all:
            break
        }
        context.insert(item)
        try? context.save()
        draft = ""
        composerFocused = true
    }

    private func addReminder() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            if !app.eventKit.canWriteReminders {
                await app.eventKit.requestRemindersAccess()
            }
            guard app.eventKit.canWriteReminders else {
                app.eventKit.openSettings(for: .reminder)
                return
            }
            if app.eventKit.defaultReminderListID.isEmpty {
                await app.eventKit.prepareReminders()
            }
            let listID = app.eventKit.defaultReminderListID
            guard !listID.isEmpty else {
                app.flash("No Reminders list available.")
                return
            }
            let calendar = Calendar.current
            let due: Date?
            switch filter {
            case .today:
                due = calendar.startOfDay(for: .now)
            case .upcoming:
                due = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))
            case .inbox, .all:
                due = nil
            }
            do {
                try app.eventKit.createReminder(title: title, listID: listID, due: due)
                draft = ""
                composerFocused = true
            } catch {
                app.flash(error.localizedDescription)
            }
        }
    }

    private func toggle(_ item: ReminderItem) {
        do {
            try app.eventKit.setCompleted(item, completed: !item.isCompleted)
        } catch {
            app.flash(error.localizedDescription)
        }
    }
}

private struct TaskRow: View {
    @Environment(AppModel.self) private var app
    var item: AgendaItem
    var hideTodayDue = false
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(checkTint)
                    .opacity(item.isCompleted ? 0.45 : 1)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isCompleted ? "Mark incomplete" : "Mark complete")
            .accessibilityLabel(item.isCompleted ? "Mark \(title) incomplete" : "Mark \(title) complete")

            Button {
                app.present(.editTask(item))
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .strikethrough(item.isCompleted)
                        .foregroundStyle(item.isCompleted ? .tertiary : .primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    AgendaMarks(item: item)
                    Spacer(minLength: 8)
                    if let dueText, !dueText.isEmpty {
                        Text(dueText)
                            .font(.system(size: 12))
                            .foregroundStyle(overdue ? app.accent(for: .calendar) : Color.secondary)
                            .lineLimit(1)
                            .frame(width: 72, alignment: .trailing)
                    }
                    if let source {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.secondary.opacity(0.45))
                                .frame(width: 6, height: 6)
                            Text(source)
                                .font(CraftFont.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .frame(width: 88, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit task")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? CraftColor.hover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }

    private var title: String { item.displayTitle }

    private var overdue: Bool {
        guard let due = item.due else { return false }
        return TaskDue.isOverdue(due)
    }

    private var checkTint: Color {
        overdue ? app.accent(for: .calendar) : Color.secondary
    }

    private var dueText: String? {
        guard let due = item.due else { return nil }
        return TaskDue.compact(due, hideIfToday: hideTodayDue)
    }

    private var source: String? {
        guard let project = item.project else { return nil }
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled" : name
    }
}

private struct ReminderRow: View {
    @Environment(AppModel.self) private var app
    var item: ReminderItem
    var compact = false
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(checkTint)
                    .opacity(item.isCompleted ? 0.45 : 1)
                    .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isCompleted ? "Mark incomplete" : "Mark complete")
            .accessibilityLabel(item.isCompleted ? "Mark \(title) incomplete" : "Mark \(title) complete")

            Button {
                app.present(.editReminder(item))
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .strikethrough(item.isCompleted)
                        .foregroundStyle(item.isCompleted ? .tertiary : .primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    EventAgendaMarks(kind: .reminder, eventKitID: item.id)
                    if item.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.04))
                            .accessibilityLabel("Flagged")
                    }
                    Spacer(minLength: compact ? 4 : 8)
                    if let dueText, !dueText.isEmpty {
                        Text(dueText)
                            .font(compact ? CraftFont.caption : .system(size: 12))
                            .foregroundStyle(overdue ? app.accent(for: .calendar) : Color.secondary)
                            .lineLimit(1)
                            .frame(width: compact ? nil : 72, alignment: .trailing)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.tint.color)
                            .frame(width: 6, height: 6)
                        if !compact {
                            Text(item.listName)
                                .font(CraftFont.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: compact ? 6 : 88, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit reminder")
        }
        .padding(compact ? 4 : 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? CraftColor.hover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, compact ? 0 : -8)
        .onHover { hovering = $0 }
    }

    private var title: String {
        item.title.isEmpty ? "Untitled" : item.title
    }

    private var overdue: Bool {
        guard let due = item.due else { return false }
        return TaskDue.isOverdue(due)
    }

    private var checkTint: Color {
        overdue ? app.accent(for: .calendar) : item.tint.color
    }

    private var dueText: String? {
        guard let due = item.due else { return nil }
        return TaskDue.compact(due, hideIfToday: compact && !item.dueHasTime, hasTime: item.dueHasTime)
    }
}
