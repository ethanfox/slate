import AppKit
import EventKit
import Foundation
import SwiftUI

struct CalendarTint: Hashable, Sendable, Codable {
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

    init(_ color: Color) {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.deviceRGB) ?? ns.usingColorSpace(.sRGB) else {
            self = .neutral
            return
        }
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    func matches(_ other: CalendarTint) -> Bool {
        abs(red - other.red) < 0.04 && abs(green - other.green) < 0.04 && abs(blue - other.blue) < 0.04
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

struct CalendarEvent: Identifiable, Hashable, Sendable {
    var id: String
    var seriesID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String
    var calendarName: String
    var location: String
    var notes: String
    var url: URL?
    var allowsEditing: Bool
    var tint: CalendarTint

    init(_ event: EKEvent) {
        id = event.calendarItemIdentifier
        seriesID = event.eventIdentifier ?? event.calendarItemIdentifier
        title = event.title ?? ""
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        calendarID = event.calendar.calendarIdentifier
        calendarName = event.calendar.title
        let place = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        location = place.isEmpty ? (event.structuredLocation?.title ?? "") : place
        notes = event.notes ?? ""
        url = event.url
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
    var notes: String
    var url: URL?
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
        notes = reminder.notes ?? ""
        url = reminder.url
        isCompleted = reminder.isCompleted
        allowsEditing = reminder.calendar.allowsContentModifications
        tint = CalendarTint(reminder.calendar.cgColor)
    }
}

struct EventKitList: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var tint: CalendarTint = .neutral
    var sourceID = ""
    var sourceTitle = ""
    var sourceRank = 2
}

struct EventKitSourceGroup: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var rank: Int
    var lists: [EventKitList]
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
    private(set) var visibleCalendars: [EventKitList] = []
    private(set) var visibleReminderLists: [EventKitList] = []
    private(set) var sourceGroups: [EventKitSourceGroup] = []
    private(set) var disabledIDs: Set<String> = []
    private(set) var defaultEventCalendarID = ""
    private(set) var defaultReminderListID = ""
    private var tintOverrides: [String: CalendarTint] = [:]
    private var allEvents: [CalendarEvent] = []
    private var allReminders: [ReminderItem] = []

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
        loadTintOverrides()
        loadDisabledIDs()
        refresh()
    }

    func setTint(id: String, tint: CalendarTint) {
        tintOverrides[id] = tint
        persistTintOverrides()
        if let calendar = store.calendar(withIdentifier: id) {
            calendar.cgColor = tint.cgColor
            try? store.saveCalendar(calendar, commit: true)
        }
        applyOverrides()
    }

    func clearTint(id: String) {
        tintOverrides.removeValue(forKey: id)
        persistTintOverrides()
        refresh()
    }

    func hasTintOverride(id: String) -> Bool {
        tintOverrides[id] != nil
    }

    func isEnabled(id: String) -> Bool {
        !disabledIDs.contains(id)
    }

    func setEnabled(id: String, enabled: Bool) {
        if enabled {
            disabledIDs.remove(id)
        } else {
            disabledIDs.insert(id)
        }
        persistDisabledIDs()
        publishVisible()
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

    @discardableResult
    func createEvent(title: String, start: Date, end: Date, allDay: Bool, calendarID: String, location: String, notes: String) throws -> CalendarEvent {
        let event = EKEvent(eventStore: store)
        apply(event, title: title, start: start, end: end, allDay: allDay, calendarID: calendarID, location: location, notes: notes)
        try store.save(event, span: .thisEvent)
        refreshEvents()
        return CalendarEvent(event)
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

    @discardableResult
    func createReminder(title: String, listID: String, due: Date?, notes: String = "") throws -> ReminderItem {
        let reminder = EKReminder(eventStore: store)
        apply(reminder, title: title, listID: listID, due: due, notes: notes)
        try store.save(reminder, commit: true)
        remindersTask?.cancel()
        remindersTask = Task { await refreshReminders() }
        return ReminderItem(reminder)
    }

    func reminder(id: String) -> ReminderItem? {
        allReminders.first { $0.id == id } ?? reminders.first { $0.id == id }
    }

    func event(seriesID: String) -> CalendarEvent? {
        allEvents.first { $0.seriesID == seriesID } ?? events.first { $0.seriesID == seriesID }
    }

    var knownAgendaIDs: Set<String> {
        Set(allReminders.map(\.id) + reminders.map(\.id) + allEvents.map(\.seriesID) + events.map(\.seriesID))
    }

    func updateReminder(_ item: ReminderItem, title: String, listID: String, due: Date?, notes: String = "") throws {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        apply(reminder, title: title, listID: listID, due: due, notes: notes)
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
            allEvents = []
            events = []
            eventCalendars = []
            visibleCalendars = []
            rebuildGroups()
            return
        }
        let all = store.calendars(for: .event)
        visibleCalendars = listed(all)
        eventCalendars = listed(all.filter(\.allowsContentModifications))
        defaultEventCalendarID = store.defaultCalendarForNewEvents?.calendarIdentifier ?? eventCalendars.first?.id ?? ""

        let calendar = Calendar.current
        let start = calendar.date(byAdding: .month, value: -3, to: calendar.startOfDay(for: .now)) ?? calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .month, value: 6, to: calendar.startOfDay(for: .now)) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        allEvents = store.events(matching: predicate)
            .map { applied($0) }
            .sorted { $0.start < $1.start }
        rebuildGroups()
        publishVisible()
    }

    private func refreshReminders() async {
        guard canReadReminders else {
            allReminders = []
            reminders = []
            reminderLists = []
            visibleReminderLists = []
            rebuildGroups()
            return
        }
        let all = store.calendars(for: .reminder)
        visibleReminderLists = listed(all)
        reminderLists = listed(all.filter(\.allowsContentModifications))
        defaultReminderListID = store.defaultCalendarForNewReminders()?.calendarIdentifier ?? reminderLists.first?.id ?? ""

        let open = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let doneStart = Calendar.current.date(byAdding: .day, value: -14, to: .now)
        let done = store.predicateForCompletedReminders(withCompletionDateStarting: doneStart, ending: nil, calendars: nil)
        let openItems = await fetchReminders(matching: open)
        let doneItems = await fetchReminders(matching: done)
        let items = uniqueReminders(openItems + doneItems)
        guard !Task.isCancelled else { return }
        allReminders = items.map { applied($0) }.sorted(by: Self.sortReminders)
        rebuildGroups()
        publishVisible()
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

    private func apply(_ reminder: EKReminder, title: String, listID: String, due: Date?, notes: String) {
        reminder.title = title
        reminder.notes = notes.isEmpty ? nil : notes
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

    private func applyOverrides() {
        visibleCalendars = remapped(visibleCalendars)
        eventCalendars = remapped(eventCalendars)
        visibleReminderLists = remapped(visibleReminderLists)
        reminderLists = remapped(reminderLists)
        allEvents = allEvents.map { event in
            var event = event
            if let tint = tintOverrides[event.calendarID] { event.tint = tint }
            return event
        }
        allReminders = allReminders.map { reminder in
            var reminder = reminder
            if let tint = tintOverrides[reminder.listID] { reminder.tint = tint }
            return reminder
        }
        rebuildGroups()
        publishVisible()
    }

    private func remapped(_ lists: [EventKitList]) -> [EventKitList] {
        lists.map { list in
            var list = list
            if let tint = tintOverrides[list.id] { list.tint = tint }
            return list
        }
    }

    private func listed(_ calendars: [EKCalendar]) -> [EventKitList] {
        calendars
            .map { calendar in
                EventKitList(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    tint: tint(for: calendar),
                    sourceID: calendar.source.sourceIdentifier,
                    sourceTitle: calendar.source.title.isEmpty ? "Other" : calendar.source.title,
                    sourceRank: Self.sourceRank(calendar.source)
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func rebuildGroups() {
        let items = visibleCalendars + visibleReminderLists
        let grouped = Dictionary(grouping: items, by: \.sourceID)
        sourceGroups = grouped.values.compactMap { lists -> EventKitSourceGroup? in
            guard let first = lists.first else { return nil }
            return EventKitSourceGroup(
                id: first.sourceID,
                title: first.sourceTitle,
                rank: first.sourceRank,
                lists: lists.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            )
        }
        .sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func publishVisible() {
        events = allEvents.filter { !disabledIDs.contains($0.calendarID) }
        reminders = allReminders.filter { !disabledIDs.contains($0.listID) }
    }

    private static func sourceRank(_ source: EKSource) -> Int {
        switch source.sourceType {
        case .calDAV, .mobileMe: 0
        case .exchange: 1
        case .local: 3
        case .subscribed, .birthdays: 4
        default: 2
        }
    }

    private func tint(for calendar: EKCalendar) -> CalendarTint {
        tintOverrides[calendar.calendarIdentifier] ?? CalendarTint(calendar.cgColor)
    }

    private func applied(_ event: EKEvent) -> CalendarEvent {
        var item = CalendarEvent(event)
        if let tint = tintOverrides[item.calendarID] { item.tint = tint }
        return item
    }

    private func applied(_ reminder: ReminderItem) -> ReminderItem {
        var item = reminder
        if let tint = tintOverrides[item.listID] { item.tint = tint }
        return item
    }

    private func loadTintOverrides() {
        guard let data = UserDefaults.standard.data(forKey: Self.tintOverridesKey),
              let stored = try? JSONDecoder().decode([String: CalendarTint].self, from: data)
        else { return }
        tintOverrides = stored
    }

    private func persistTintOverrides() {
        if let data = try? JSONEncoder().encode(tintOverrides) {
            UserDefaults.standard.set(data, forKey: Self.tintOverridesKey)
        }
    }

    private func loadDisabledIDs() {
        guard let stored = UserDefaults.standard.array(forKey: Self.disabledIDsKey) as? [String] else { return }
        disabledIDs = Set(stored)
    }

    private func persistDisabledIDs() {
        UserDefaults.standard.set(Array(disabledIDs), forKey: Self.disabledIDsKey)
    }

    private static let tintOverridesKey = "calendarTintOverrides"
    private static let disabledIDsKey = "calendarDisabledIDs"
}

enum CalendarLink {
    static func meeting(preferred: URL?, texts: [String]) -> URL? {
        if let preferred, isMeeting(preferred) { return preferred }
        let found = texts.flatMap(urls(in:))
        return found.first(where: isMeeting) ?? preferred ?? found.first
    }

    static func maps(for location: String) -> URL? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, urls(in: trimmed).isEmpty else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url)
    }

    static func isMeeting(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("zoom.us")
            || host.contains("zoom.com")
            || host.contains("meet.google.com")
            || host.contains("teams.microsoft.com")
            || host.contains("teams.live.com")
            || host.contains("webex.com")
            || host.contains("gotomeeting.com")
            || host.contains("whereby.com")
    }
}
