import EventKit
import SwiftData
import SwiftUI

struct CalendarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<AgendaItem> { $0.kindRaw == "task" })
    private var slateTasks: [AgendaItem]
    @Query private var completions: [TaskCompletion]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var weekStart = CalendarView.startOfWeek(containing: .now)
    @State private var pageDirection = Edge.trailing
    @State private var didScrollToNow = false
    @FocusState private var keysFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                PageBody {
                    content(proxy: proxy)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focusEffectDisabled()
            .focused($keysFocused)
            .onKeyPress(.leftArrow) { handleArrow(-1) }
            .onKeyPress(.rightArrow) { handleArrow(1) }
            .onAppear { keysFocused = true }
            .background {
                Button("Today", action: goToToday)
                    .keyboardShortcut("t", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .task {
            await app.eventKit.prepareEvents()
            await app.eventKit.prepareReminders()
        }
    }

    @ViewBuilder
    private func content(proxy: ScrollViewProxy) -> some View {
        switch app.eventKit.eventsAccess {
        case .fullAccess:
            agenda(proxy: proxy)
        case .notDetermined, .writeOnly:
            EventKitAccessLine(
                text: "Slate needs Calendar access to show your events.",
                actionTitle: "Allow Calendar Access"
            ) {
                Task { await app.eventKit.requestEventsAccess() }
            }
        case .denied, .restricted:
            EventKitAccessLine(
                text: "Calendar access is off. Enable it in System Settings.",
                actionTitle: "Open Settings"
            ) {
                app.eventKit.openSettings(for: .event)
            }
        @unknown default:
            EventKitAccessLine(
                text: "Calendar access is off. Enable it in System Settings.",
                actionTitle: "Open Settings"
            ) {
                app.eventKit.openSettings(for: .event)
            }
        }
    }

    private func agenda(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            CalendarHero(day: selectedDay)
            CalendarWeekStrip(
                weekStart: weekStart,
                selectedDay: selectedDay,
                days: weekDays,
                tints: tintsByDay,
                pageDirection: pageDirection,
                onSelect: selectDay,
                onPage: pageWeek,
                onToday: goToToday
            )
            if calendar.isDateInToday(selectedDay) {
                TimelineView(.everyMinute) { context in
                    dayBody(now: context.date, proxy: proxy)
                }
            } else {
                dayBody(now: .now, proxy: proxy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func dayBody(now: Date, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if let event = nextUp(now: now) {
                CalendarNextUpCard(event: event, now: now) {
                    app.present(.editEvent(event))
                }
            }
            if !selectedAllDay.isEmpty || !selectedReminders.isEmpty || !selectedTasks.isEmpty || !selectedCompletions.isEmpty {
                CalendarAllDaySection(
                    events: selectedAllDay,
                    reminders: selectedReminders,
                    tasks: selectedTasks,
                    completions: selectedCompletions,
                    onOpenEvent: { app.present(.editEvent($0)) },
                    onOpenReminder: { app.present(.editReminder($0)) },
                    onOpenTask: { app.present(.editTask($0)) },
                    onToggleReminder: toggle,
                    onToggleTask: { AgendaStore.toggleComplete($0, in: context) },
                    onToggleCompletion: { completion in
                        do { try TaskStore.undoLatestCompletion(completion, in: context) }
                        catch { app.flash(error.localizedDescription) }
                    }
                )
            }
            if !selectedTimed.isEmpty {
                CalendarTimeline(
                    day: selectedDay,
                    events: selectedTimed,
                    now: now,
                    isToday: calendar.isDateInToday(selectedDay),
                    scrollProxy: proxy,
                    shouldScrollToNow: !didScrollToNow && calendar.isDateInToday(selectedDay),
                    onScrolledToNow: { didScrollToNow = true },
                    onOpen: { app.present(.editEvent($0)) }
                )
            } else if selectedAllDay.isEmpty && selectedReminders.isEmpty && selectedTasks.isEmpty && selectedCompletions.isEmpty {
                EmptyLine(text: "Nothing scheduled.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = Motion.quick }
    }

    private var calendar: Calendar { .current }

    private var weekDays: [Date] {
        guard let end = calendar.date(byAdding: .day, value: 6, to: weekStart) else { return [weekStart] }
        return days(from: weekStart, through: end)
    }

    private var selectedItems: [DayItem] {
        items(on: selectedDay)
    }

    private var selectedReminders: [ReminderItem] {
        selectedItems.compactMap {
            if case .reminder(let item) = $0 { return item }
            return nil
        }
    }

    private var selectedTasks: [AgendaItem] {
        selectedItems.compactMap {
            if case .task(let item) = $0 { return item }
            return nil
        }
    }

    private var selectedCompletions: [TaskCompletion] {
        selectedItems.compactMap {
            if case .completion(let item) = $0 { return item }
            return nil
        }
    }

    private var selectedAllDay: [CalendarEvent] {
        selectedItems.compactMap {
            if case .event(let event) = $0, event.isAllDay { return event }
            return nil
        }
    }

    private var selectedTimed: [CalendarEvent] {
        selectedItems.compactMap {
            if case .event(let event) = $0, !event.isAllDay { return event }
            return nil
        }
    }

    private var tintsByDay: [Date: [CalendarTint]] {
        var result: [Date: [CalendarTint]] = [:]
        for day in weekDays {
            var seen = Set<String>()
            var tints: [CalendarTint] = []
            for event in app.eventKit.events where eventFalls(event, on: day) {
                if seen.insert(event.calendarID).inserted {
                    tints.append(event.tint)
                    if tints.count == 3 { break }
                }
            }
            result[day] = tints
        }
        return result
    }

    private func items(on day: Date, includeUndated: Bool? = nil) -> [DayItem] {
        let undated = includeUndated ?? calendar.isDateInToday(day)
        let events = app.eventKit.events
            .filter { eventFalls($0, on: day) }
            .sorted { $0.start < $1.start }
            .map(DayItem.event)
        let reminders = app.eventKit.reminders
            .filter { reminder in
                if reminder.isCompleted { return false }
                if let due = reminder.due {
                    return calendar.isDate(due, inSameDayAs: day)
                }
                return undated
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map(DayItem.reminder)
        let tasks = slateTasks
            .filter { task in
                if task.isCompleted { return false }
                if let due = task.due {
                    return calendar.isDate(due, inSameDayAs: day)
                }
                return undated
            }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
            .map(DayItem.task)
        let done = completions
            .filter { calendar.isDate($0.completedAt, inSameDayAs: day) }
            .sorted { $0.completedAt > $1.completedAt }
            .map(DayItem.completion)
        return reminders + tasks + done + events
    }

    private func eventFalls(_ event: CalendarEvent, on day: Date) -> Bool {
        let start = calendar.startOfDay(for: event.start)
        let end = calendar.startOfDay(for: event.displayEnd)
        return day >= start && day <= end
    }

    private func days(from start: Date, through end: Date) -> [Date] {
        var dates: [Date] = []
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last {
            dates.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return dates
    }

    private func nextUp(now: Date) -> CalendarEvent? {
        guard calendar.isDateInToday(selectedDay) else { return nil }
        let inProgress = selectedTimed
            .filter { $0.start <= now && $0.end > now }
            .sorted { $0.start < $1.start }
        if let current = inProgress.first { return current }
        return selectedTimed
            .filter { $0.start > now }
            .sorted { $0.start < $1.start }
            .first
    }

    private func handleArrow(_ delta: Int) -> KeyPress.Result {
        if app.modal != nil { return .ignored }
        guard let day = calendar.date(byAdding: .day, value: delta, to: selectedDay) else { return .handled }
        move(to: day)
        return .handled
    }

    private func goToToday() {
        if app.modal != nil { return }
        move(to: calendar.startOfDay(for: .now))
    }

    private func selectDay(_ day: Date) {
        move(to: day)
    }

    private func pageWeek(_ weeks: Int) {
        guard let day = calendar.date(byAdding: .day, value: weeks * 7, to: selectedDay) else { return }
        pageDirection = weeks > 0 ? .trailing : .leading
        let start = Self.startOfWeek(containing: day)
        withAnimation(reduceMotion ? Motion.quick : Motion.smooth) {
            weekStart = start
            selectedDay = calendar.startOfDay(for: day)
        }
        keysFocused = true
    }

    private func move(to day: Date) {
        let day = calendar.startOfDay(for: day)
        guard day != selectedDay else { return }
        let start = Self.startOfWeek(containing: day)
        if start != weekStart {
            pageDirection = day > selectedDay ? .trailing : .leading
            withAnimation(reduceMotion ? Motion.quick : Motion.smooth) {
                weekStart = start
                selectedDay = day
            }
        } else {
            withAnimation(reduceMotion ? Motion.quick : Motion.snappy) {
                selectedDay = day
            }
        }
        keysFocused = true
    }

    private func toggle(_ item: ReminderItem) {
        do {
            try app.eventKit.setCompleted(item, completed: !item.isCompleted)
        } catch {
            app.flash(error.localizedDescription)
        }
    }

    static func startOfWeek(containing date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let delta = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -delta, to: day) ?? day
    }
}

private enum DayItem: Identifiable {
    case event(CalendarEvent)
    case reminder(ReminderItem)
    case task(AgendaItem)
    case completion(TaskCompletion)

    var id: String {
        switch self {
        case .event(let event): "e-\(event.id)"
        case .reminder(let reminder): "r-\(reminder.id)"
        case .task(let task): "t-\(task.id.uuidString)"
        case .completion(let completion): "c-\(completion.id.uuidString)"
        }
    }
}
