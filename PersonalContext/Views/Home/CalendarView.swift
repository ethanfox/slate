import EventKit
import SwiftUI

struct CalendarView: View {
    @Environment(AppModel.self) private var app
    @State private var showPreviousDays = false
    @State private var showNextMonths = false
    @State private var expandedMonths: Set<Date> = []

    var body: some View {
        ScrollView {
            PageBody {
                content
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
        .task {
            await app.eventKit.prepareEvents()
            await app.eventKit.prepareReminders()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.eventKit.eventsAccess {
        case .fullAccess:
            agenda
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

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !previousDays.isEmpty {
                revealButton(
                    showPreviousDays ? "Hide previous days" : "Show previous days",
                    symbol: "clock"
                ) {
                    showPreviousDays.toggle()
                }

                if showPreviousDays {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(previousDays, id: \.self) { day in
                            sideDay(day)
                        }
                    }
                }
            }

            ForEach(weekDays, id: \.self) { day in
                if calendar.isDateInToday(day) {
                    todayCard
                } else {
                    sideDay(day)
                }
            }

            if !monthGroups.isEmpty {
                revealButton(
                    showNextMonths ? "Hide next months" : "Show next months",
                    symbol: "calendar"
                ) {
                    showNextMonths.toggle()
                }

                if showNextMonths {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(monthGroups) { month in
                            monthRow(month)
                        }
                    }
                }
            }
        }
    }

    private var todayCard: some View {
        let day = today
        let entries = items(on: day)
        return HStack(alignment: .top, spacing: 24) {
            DayLabel(day: day)
                .frame(width: 88, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if entries.isEmpty {
                    EmptyLine(text: "Nothing today.")
                } else {
                    ForEach(entries) { entry in
                        dayEntry(entry)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sideDay(_ day: Date) -> some View {
        let entries = items(on: day)
        return HStack(alignment: .top, spacing: 16) {
            DatePlate {
                DayLabel(day: day)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    dayEntry(entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        }
    }

    private func monthRow(_ month: MonthGroup) -> some View {
        let visible = expandedMonths.contains(month.id) ? month.items : Array(month.items.prefix(8))
        let hidden = month.items.count - visible.count
        return HStack(alignment: .top, spacing: 16) {
            DatePlate {
                if let first = month.rangeFirst, let last = month.rangeLast, first != last {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(first.formatted(.dateTime.month(.abbreviated).day()))
                        Text(last.formatted(.dateTime.month(.abbreviated).day()))
                            .foregroundStyle(.secondary)
                    }
                    .font(CraftFont.section)
                } else {
                    Text(month.title)
                        .font(CraftFont.section)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(visible) { item in
                    monthLine(item)
                }
                if hidden > 0 {
                    Button("Show \(hidden) more") {
                        expandedMonths.insert(month.id)
                    }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func dayEntry(_ entry: DayItem) -> some View {
        switch entry {
        case .event(let event):
            eventLine(event)
        case .reminder(let reminder):
            reminderLine(reminder)
        }
    }

    private func eventLine(_ event: CalendarEvent) -> some View {
        Button {
            app.editingEvent = event
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(weekEventTitle(event))
                    .font(CraftFont.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !event.location.isEmpty {
                    Text(event.location)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit event")
    }

    private func reminderLine(_ item: ReminderItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                toggle(item)
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isCompleted ? "Mark incomplete" : "Mark complete")

            Button {
                app.editingReminder = item
            } label: {
                HStack(spacing: 8) {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(CraftFont.body)
                        .strikethrough(item.isCompleted)
                        .foregroundStyle(item.isCompleted ? .tertiary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(item.listName)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit reminder")
        }
        .padding(.vertical, 5)
    }

    private func monthLine(_ item: MonthItem) -> some View {
        Button {
            switch item.kind {
            case .event(let event):
                app.editingEvent = event
            case .reminder(let reminder):
                app.editingReminder = reminder
            }
        } label: {
            Text("\(item.day.formatted(.dateTime.day(.twoDigits))) · \(item.title)")
                .font(CraftFont.body)
                .foregroundStyle(item.tint.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func revealButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(CraftColor.elevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var calendar: Calendar { .current }

    private var today: Date {
        calendar.startOfDay(for: .now)
    }

    private var weekEnd: Date {
        let weekday = calendar.component(.weekday, from: today)
        let daysToEnd = (calendar.firstWeekday + 6 - weekday + 7) % 7
        return calendar.date(byAdding: .day, value: daysToEnd, to: today) ?? today
    }

    private var previousDays: [Date] {
        days(from: calendar.date(byAdding: .day, value: -7, to: today) ?? today, through: calendar.date(byAdding: .day, value: -1, to: today) ?? today)
    }

    private var weekDays: [Date] {
        days(from: today, through: weekEnd)
    }

    private var monthGroups: [MonthGroup] {
        guard let afterWeek = calendar.date(byAdding: .day, value: 1, to: weekEnd),
              let horizon = calendar.date(byAdding: .month, value: 4, to: today)
        else { return [] }
        let items = days(from: afterWeek, through: horizon).flatMap { day -> [MonthItem] in
            items(on: day, includeUndated: false).map { entry in
                switch entry {
                case .event(let event):
                    MonthItem(id: "e-\(event.id)-\(day.timeIntervalSince1970)", day: day, title: event.title.isEmpty ? "Untitled" : event.title, tint: event.tint, kind: .event(event))
                case .reminder(let reminder):
                    MonthItem(id: "r-\(reminder.id)-\(day.timeIntervalSince1970)", day: day, title: reminder.title.isEmpty ? "Untitled" : reminder.title, tint: reminder.tint, kind: .reminder(reminder))
                }
            }
        }
        let grouped = Dictionary(grouping: items) { calendar.dateInterval(of: .month, for: $0.day)?.start ?? $0.day }
        return grouped.keys.sorted().compactMap { start -> MonthGroup? in
            guard let monthItems = grouped[start], !monthItems.isEmpty else { return nil }
            let sorted = monthItems.sorted { lhs, rhs in
                if lhs.day != rhs.day { return lhs.day < rhs.day }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            let isCurrentMonth = calendar.isDate(start, equalTo: today, toGranularity: .month)
            return MonthGroup(
                id: start,
                title: start.formatted(.dateTime.month(.wide)),
                items: sorted,
                rangeFirst: isCurrentMonth ? sorted.first?.day : nil,
                rangeLast: isCurrentMonth ? sorted.last?.day : nil
            )
        }
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
        return reminders + events
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

    private func weekEventTitle(_ event: CalendarEvent) -> String {
        let name = event.title.isEmpty ? "Untitled" : event.title
        if event.isAllDay { return name }
        return "\(event.start.formatted(date: .omitted, time: .shortened)) · \(name)"
    }

    private func toggle(_ item: ReminderItem) {
        do {
            try app.eventKit.setCompleted(item, completed: !item.isCompleted)
        } catch {
            app.flash(error.localizedDescription)
        }
    }
}

private struct DatePlate<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 100, alignment: .topLeading)
            .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DayLabel: View {
    var day: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.month(.abbreviated).day()))
                .font(CraftFont.section)
            if Calendar.current.isDateInToday(day) {
                Text("Today")
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
            } else if Calendar.current.isDateInTomorrow(day) {
                Text("Tomorrow")
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
            }
            Text(day.formatted(.dateTime.weekday(.wide)))
                .font(CraftFont.body)
                .foregroundStyle(.tertiary)
        }
    }
}

private enum DayItem: Identifiable {
    case event(CalendarEvent)
    case reminder(ReminderItem)

    var id: String {
        switch self {
        case .event(let event): "e-\(event.id)"
        case .reminder(let reminder): "r-\(reminder.id)"
        }
    }
}

private struct MonthGroup: Identifiable {
    var id: Date
    var title: String
    var items: [MonthItem]
    var rangeFirst: Date?
    var rangeLast: Date?
}

private struct MonthItem: Identifiable {
    var id: String
    var day: Date
    var title: String
    var tint: CalendarTint
    var kind: Kind

    enum Kind {
        case event(CalendarEvent)
        case reminder(ReminderItem)
    }
}
