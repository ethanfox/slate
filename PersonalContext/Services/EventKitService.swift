import AppKit
import EventKit
import Foundation
import SwiftUI

struct CalendarTint: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let neutral = CalendarTint(red: 0.55, green: 0.55, blue: 0.55)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: CGColor?) {
        guard let color,
              let converted = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3
        else {
            self = .neutral
            return
        }
        red = Double(components[0])
        green = Double(components[1])
        blue = Double(components[2])
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

struct CalendarEvent: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String
    var calendarName: String
    var location: String
    var notes: String
    var allowsEditing: Bool
    var tint: CalendarTint

    init(_ event: EKEvent) {
        id = event.calendarItemIdentifier
        title = event.title ?? ""
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        calendarID = event.calendar.calendarIdentifier
        calendarName = event.calendar.title
        let place = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        location = place.isEmpty ? (event.structuredLocation?.title ?? "") : place
        notes = event.notes ?? ""
        allowsEditing = event.calendar.allowsContentModifications
        tint = CalendarTint(event.calendar.cgColor)
    }

    var timeLabel: String {
        if isAllDay { return "All day" }
        let startText = start.formatted(date: .omitted, time: .shortened)
        let endText = end.formatted(date: .omitted, time: .shortened)
        return "\(startText) – \(endText)"
    }

    var displayEnd: Date {
        guard isAllDay else { return end }
        return Calendar.current.date(byAdding: .day, value: -1, to: end) ?? start
    }
}

struct ReminderItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var listID: String
    var listName: String
    var due: Date?
    var isCompleted: Bool
    var allowsEditing: Bool
    var tint: CalendarTint

    init(_ reminder: EKReminder) {
        id = reminder.calendarItemIdentifier
        title = reminder.title ?? ""
        listID = reminder.calendar.calendarIdentifier
        listName = reminder.calendar.title
        if let components = reminder.dueDateComponents {
            due = Calendar.current.date(from: components)
        } else {
            due = nil
        }
        isCompleted = reminder.isCompleted
        allowsEditing = reminder.calendar.allowsContentModifications
        tint = CalendarTint(reminder.calendar.cgColor)
    }
}

struct EventKitList: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var tint: CalendarTint = .neutral
}

@MainActor
@Observable
final class EventKitService {
    private let store = EKEventStore()
    private var observer: (any NSObjectProtocol)?
    private var remindersTask: Task<Void, Never>?

    private(set) var eventsAccess = EKEventStore.authorizationStatus(for: .event)
    private(set) var remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
    private(set) var events: [CalendarEvent] = []
    private(set) var reminders: [ReminderItem] = []
    private(set) var eventCalendars: [EventKitList] = []
    private(set) var reminderLists: [EventKitList] = []
    private(set) var defaultEventCalendarID = ""
    private(set) var defaultReminderListID = ""

    var canReadEvents: Bool { eventsAccess == .fullAccess }
    var canWriteEvents: Bool { eventsAccess == .fullAccess || eventsAccess == .writeOnly }
    var canReadReminders: Bool { remindersAccess == .fullAccess }
    var canWriteReminders: Bool { remindersAccess == .fullAccess || remindersAccess == .writeOnly }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refresh()
    }

    func prepareEvents() async {
        syncAccess()
        if eventsAccess == .notDetermined || eventsAccess == .writeOnly {
            await requestEventsAccess()
        } else {
            refreshEvents()
        }
    }

    func prepareReminders() async {
        syncAccess()
        if remindersAccess == .notDetermined || remindersAccess == .writeOnly {
            await requestRemindersAccess()
        } else {
            await refreshReminders()
        }
    }

    func requestEventsAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {}
        syncAccess()
        refreshEvents()
    }

    func requestRemindersAccess() async {
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {}
        syncAccess()
        await refreshReminders()
    }

    func refresh() {
        syncAccess()
        refreshEvents()
        remindersTask?.cancel()
        remindersTask = Task { await refreshReminders() }
    }

    func createEvent(title: String, start: Date, end: Date, allDay: Bool, calendarID: String, location: String, notes: String) throws {
        let event = EKEvent(eventStore: store)
        apply(event, title: title, start: start, end: end, allDay: allDay, calendarID: calendarID, location: location, notes: notes)
        try store.save(event, span: .thisEvent)
    }

    func updateEvent(_ item: CalendarEvent, title: String, start: Date, end: Date, allDay: Bool, calendarID: String, location: String, notes: String) throws {
        guard let event = store.calendarItem(withIdentifier: item.id) as? EKEvent else { return }
        apply(event, title: title, start: start, end: end, allDay: allDay, calendarID: calendarID, location: location, notes: notes)
        try store.save(event, span: .thisEvent)
    }

    func deleteEvent(_ item: CalendarEvent) throws {
        guard let event = store.calendarItem(withIdentifier: item.id) as? EKEvent else { return }
        try store.remove(event, span: .thisEvent)
    }

    func createReminder(title: String, listID: String, due: Date?) throws {
        let reminder = EKReminder(eventStore: store)
        apply(reminder, title: title, listID: listID, due: due)
        try store.save(reminder, commit: true)
    }

    func updateReminder(_ item: ReminderItem, title: String, listID: String, due: Date?) throws {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        apply(reminder, title: title, listID: listID, due: due)
        try store.save(reminder, commit: true)
    }

    func deleteReminder(_ item: ReminderItem) throws {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    func setCompleted(_ item: ReminderItem, completed: Bool) throws {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
    }

    func openSettings(for entity: EKEntityType) {
        let query = entity == .event ? "Privacy_Calendars" : "Privacy_Reminders"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(query)") else { return }
        NSWorkspace.shared.open(url)
    }

    func statusLabel(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: "Allowed"
        case .writeOnly: "Write only"
        case .denied, .restricted: "Not allowed"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }

    private func syncAccess() {
        eventsAccess = EKEventStore.authorizationStatus(for: .event)
        remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
    }

    private func refreshEvents() {
        guard canReadEvents else {
            events = []
            eventCalendars = []
            return
        }
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        eventCalendars = writable
            .map { EventKitList(id: $0.calendarIdentifier, title: $0.title, tint: CalendarTint($0.cgColor)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        defaultEventCalendarID = store.defaultCalendarForNewEvents?.calendarIdentifier ?? eventCalendars.first?.id ?? ""

        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: .now)) ?? calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .month, value: 4, to: calendar.startOfDay(for: .now)) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .map(CalendarEvent.init)
            .sorted { $0.start < $1.start }
    }

    private func refreshReminders() async {
        guard canReadReminders else {
            reminders = []
            reminderLists = []
            return
        }
        reminderLists = store.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .map { EventKitList(id: $0.calendarIdentifier, title: $0.title, tint: CalendarTint($0.cgColor)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        defaultReminderListID = store.defaultCalendarForNewReminders()?.calendarIdentifier ?? reminderLists.first?.id ?? ""

        let open = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let doneStart = Calendar.current.date(byAdding: .day, value: -14, to: .now)
        let done = store.predicateForCompletedReminders(withCompletionDateStarting: doneStart, ending: nil, calendars: nil)
        let openItems = await fetchReminders(matching: open)
        let doneItems = await fetchReminders(matching: done)
        let items = uniqueReminders(openItems + doneItems)
        guard !Task.isCancelled else { return }
        reminders = items.sorted(by: Self.sortReminders)
    }

    private func apply(
        _ event: EKEvent,
        title: String,
        start: Date,
        end: Date,
        allDay: Bool,
        calendarID: String,
        location: String,
        notes: String
    ) {
        event.title = title
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        event.calendar = store.calendar(withIdentifier: calendarID) ?? event.calendar ?? store.defaultCalendarForNewEvents
        if allDay {
            let calendar = Calendar.current
            let startDay = calendar.startOfDay(for: start)
            let endDay = calendar.startOfDay(for: max(start, end))
            event.startDate = startDay
            event.endDate = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            event.isAllDay = true
        } else {
            event.startDate = start
            event.endDate = max(end, start)
            event.isAllDay = false
        }
    }

    private func apply(_ reminder: EKReminder, title: String, listID: String, due: Date?) {
        reminder.title = title
        reminder.calendar = store.calendar(withIdentifier: listID) ?? reminder.calendar ?? store.defaultCalendarForNewReminders()
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
        } else {
            reminder.dueDateComponents = nil
        }
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [ReminderItem] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(ReminderItem.init))
            }
        }
    }

    private func uniqueReminders(_ items: [ReminderItem]) -> [ReminderItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func sortReminders(_ lhs: ReminderItem, _ rhs: ReminderItem) -> Bool {
        if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
        switch (lhs.due, rhs.due) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
