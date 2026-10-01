import SwiftUI

struct CalendarHero: View {
    var day: Date
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(weekday)
                        .font(CraftFont.display)
                        .foregroundStyle(.primary)
                    Circle()
                        .fill(app.accent(for: .calendar))
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0.height }
                }
                Spacer(minLength: 12)
                Text(dayNumber)
                    .font(.system(size: 34, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Text(monthYear)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
    }

    private var weekday: String {
        day.formatted(.dateTime.weekday(.abbreviated))
    }

    private var dayNumber: String {
        day.formatted(.dateTime.day())
    }

    private var monthYear: String {
        day.formatted(.dateTime.month(.wide).year())
    }
}

struct CalendarWeekStrip: View {
    var weekStart: Date
    var selectedDay: Date
    var days: [Date]
    var tints: [Date: [CalendarTint]]
    var pageDirection: Edge
    var onSelect: (Date) -> Void
    var onPage: (Int) -> Void
    var onToday: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsToday: Bool {
        !Calendar.current.isDateInToday(selectedDay)
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                weekButton("chevron.left", label: "Previous week") { onPage(-1) }
                weekButton("chevron.right", label: "Next week") { onPage(1) }
            }
            ZStack {
                CalendarWeekDays(
                    selectedDay: selectedDay,
                    days: days,
                    tints: tints,
                    onSelect: onSelect
                )
                .id(weekStart)
                .transition(reduceMotion ? .opacity : .push(from: pageDirection))
            }
            .frame(maxWidth: .infinity)
            .frame(height: CalendarLayout.cellHeight)
            .clipped()
            Button("Today", action: onToday)
                .font(CraftFont.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(CraftColor.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(CraftColor.hairline))
                .contentShape(Capsule())
                .buttonStyle(.plain)
                .opacity(showsToday ? 1 : 0)
                .allowsHitTesting(showsToday)
                .accessibilityHidden(!showsToday)
        }
    }

    private func weekButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct CalendarWeekDays: View {
    var selectedDay: Date
    var days: [Date]
    var tints: [Date: [CalendarTint]]
    var onSelect: (Date) -> Void

    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                CalendarWeekCell(
                    day: day,
                    isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDay),
                    tints: tints[day] ?? [],
                    namespace: selection,
                    reduceMotion: reduceMotion,
                    onSelect: { onSelect(day) }
                )
            }
        }
        .animation(reduceMotion ? Motion.quick : Motion.snappy, value: selectedDay)
    }
}

private struct CalendarWeekCell: View {
    var day: Date
    var isSelected: Bool
    var tints: [CalendarTint]
    var namespace: Namespace.ID
    var reduceMotion: Bool
    var onSelect: () -> Void

    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                if isSelected {
                    selectedFill
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hovering ? CraftColor.hover : Color.clear)
                        .animation(Motion.hover, value: hovering)
                }
                VStack(spacing: 2) {
                    Text(weekday)
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                    Text(dayNumber)
                        .font(CraftFont.dayNumber)
                        .foregroundStyle(isToday ? app.accent(for: .calendar) : Color.primary)
                    HStack(spacing: 3) {
                        ForEach(Array(tints.prefix(3).enumerated()), id: \.offset) { _, tint in
                            Circle()
                                .fill(tint.color)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .frame(height: 5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: CalendarLayout.cellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var selectedFill: some View {
        let pill = RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(CraftColor.selection)
        if reduceMotion {
            pill
        } else {
            pill.matchedGeometryEffect(id: "selection", in: namespace)
        }
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(day)
    }

    private var weekday: String {
        day.formatted(.dateTime.weekday(.abbreviated))
    }

    private var dayNumber: String {
        day.formatted(.dateTime.day())
    }
}

struct CalendarNextUpCard: View {
    var event: CalendarEvent
    var now: Date
    var onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(event.tint.color)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    Text(meta)
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        EventAgendaMarks(kind: .event, eventKitID: event.seriesID)
                    }
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering ? CraftColor.selection : CraftColor.elevated)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .help("Edit event")
    }

    private var title: String {
        event.title.isEmpty ? "Untitled" : event.title
    }

    private var meta: String {
        if event.start <= now && event.end > now {
            return "Now · ends in \(CalendarTime.relative(from: now, to: event.end))"
        }
        return "Next up · in \(CalendarTime.relative(from: now, to: event.start))"
    }

    private var detail: String {
        let range = event.timeLabel
        if event.location.isEmpty { return range }
        return "\(range) · \(event.location)"
    }
}

struct CalendarAllDaySection: View {
    var events: [CalendarEvent]
    var reminders: [ReminderItem]
    var onOpenEvent: (CalendarEvent) -> Void
    var onOpenReminder: (ReminderItem) -> Void
    var onToggle: (ReminderItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All day")
                .font(CraftFont.section)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(events) { event in
                    CalendarAllDayRow(event: event) { onOpenEvent(event) }
                }
                ForEach(reminders) { item in
                    CalendarReminderRow(item: item, onToggle: { onToggle(item) }) {
                        onOpenReminder(item)
                    }
                }
            }
        }
    }
}

private struct CalendarAllDayRow: View {
    var event: CalendarEvent
    var onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(event.tint.color)
                    .frame(width: 3, height: 16)
                Text(event.title.isEmpty ? "Untitled" : event.title)
                    .font(CraftFont.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                EventAgendaMarks(kind: .event, eventKitID: event.seriesID)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? CraftColor.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .help("Edit event")
    }
}

private struct CalendarReminderRow: View {
    var item: ReminderItem
    var onToggle: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isCompleted ? "Mark incomplete" : "Mark complete")

            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(CraftFont.body)
                        .strikethrough(item.isCompleted)
                        .foregroundStyle(item.isCompleted ? .tertiary : .primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    EventAgendaMarks(kind: .reminder, eventKitID: item.id)
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
}

struct CalendarTimeline: View {
    var day: Date
    var events: [CalendarEvent]
    var now: Date
    var isToday: Bool
    var scrollProxy: ScrollViewProxy
    var shouldScrollToNow: Bool
    var onScrolledToNow: () -> Void
    var onOpen: (CalendarEvent) -> Void

    var body: some View {
        let bounds = CalendarLayout.hourBounds(events: events, on: day)
        let placed = CalendarLayout.place(events, on: day, firstHour: bounds.first)
        let hours = Array(bounds.first...bounds.last)
        let height = CGFloat(hours.count) * CalendarLayout.hourHeight

        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(hours, id: \.self) { hour in
                    Text(CalendarTime.hourLabel(hour))
                        .font(CraftFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: CalendarLayout.hourLabelWidth, alignment: .leading)
                        .frame(height: CalendarLayout.hourHeight, alignment: .top)
                }
            }
            Color.clear
                .frame(width: CalendarLayout.hourLabelGap)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(hours, id: \.self) { hour in
                        CraftColor.hairline
                            .frame(height: 1)
                            .offset(y: CGFloat(hour - bounds.first) * CalendarLayout.hourHeight)
                    }
                    ForEach(placed) { item in
                        CalendarEventBlock(
                            event: item.event,
                            height: item.height,
                            onOpen: { onOpen(item.event) }
                        )
                        .frame(width: item.width(in: geo.size.width), height: item.height, alignment: .topLeading)
                        .offset(x: item.x(in: geo.size.width), y: item.y)
                    }
                    if isToday, CalendarLayout.contains(now, firstHour: bounds.first, lastHour: bounds.last) {
                        CalendarNowLine()
                            .offset(y: CalendarLayout.offset(for: now, firstHour: bounds.first) - 3.5)
                    }
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(CalendarNowAnchor.id)
                        .offset(y: CalendarLayout.nowAnchorY(now: now, firstHour: bounds.first, lastHour: bounds.last))
                }
            }
            .frame(height: height)
        }
        .onAppear {
            guard shouldScrollToNow, CalendarLayout.contains(now, firstHour: bounds.first, lastHour: bounds.last) else { return }
            onScrolledToNow()
            DispatchQueue.main.async {
                scrollProxy.scrollTo(CalendarNowAnchor.id, anchor: .top)
            }
        }
    }
}

private struct CalendarNowLine: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(app.accent(for: .calendar))
                .frame(width: 7, height: 7)
                .offset(x: -3.5)
            Rectangle()
                .fill(app.accent(for: .calendar))
                .frame(height: 1)
        }
        .frame(height: 7)
        .allowsHitTesting(false)
    }
}

private struct CalendarEventBlock: View {
    var event: CalendarEvent
    var height: CGFloat
    var onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title.isEmpty ? "Untitled" : event.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    EventAgendaMarks(kind: .event, eventKitID: event.seriesID)
                }
                if height >= CalendarLayout.timeLabelThreshold {
                    Text(event.timeLabel)
                        .font(CraftFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(event.tint.color.opacity(hovering ? 0.18 : 0.12))
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(event.tint.color)
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .help("Edit event")
    }
}

private enum CalendarNowAnchor {
    static let id = "calendar-now-anchor"
}

private enum CalendarLayout {
    static let hourHeight: CGFloat = 48
    static let hourLabelWidth: CGFloat = 44
    static let hourLabelGap: CGFloat = 8
    static let cellHeight: CGFloat = 56
    static let minBlockHeight: CGFloat = 22
    static let timeLabelThreshold: CGFloat = 40
    static let overlapGap: CGFloat = 4
    static let defaultFirstHour = 8
    static let defaultLastHour = 20

    static func hourBounds(events: [CalendarEvent], on day: Date, calendar: Calendar = .current) -> (first: Int, last: Int) {
        var first = defaultFirstHour
        var last = defaultLastHour
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        for event in events {
            let start = max(event.start, dayStart)
            let end = min(event.end, dayEnd)
            guard start < end else { continue }
            first = min(first, calendar.component(.hour, from: start))
            if end >= dayEnd {
                last = max(last, 23)
                continue
            }
            let endHour = calendar.component(.hour, from: end)
            let leftover = calendar.component(.minute, from: end) > 0 || calendar.component(.second, from: end) > 0
            if leftover {
                last = max(last, min(23, endHour))
            } else {
                last = max(last, max(0, endHour - 1))
            }
        }
        first = min(max(0, first), 23)
        last = min(max(first, last), 23)
        return (first, last)
    }

    static func place(_ events: [CalendarEvent], on day: Date, firstHour: Int, calendar: Calendar = .current) -> [PlacedEvent] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let spans = events.compactMap { event -> (event: CalendarEvent, start: Date, end: Date)? in
            let start = max(event.start, dayStart)
            let end = min(event.end, dayEnd)
            guard start < end else { return nil }
            return (event, start, end)
        }
        .sorted { $0.start < $1.start }

        var clusters: [[(event: CalendarEvent, start: Date, end: Date)]] = []
        var current: [(event: CalendarEvent, start: Date, end: Date)] = []
        var clusterEnd = Date.distantPast
        for span in spans {
            if current.isEmpty || span.start < clusterEnd {
                current.append(span)
                clusterEnd = max(clusterEnd, span.end)
            } else {
                clusters.append(current)
                current = [span]
                clusterEnd = span.end
            }
        }
        if !current.isEmpty { clusters.append(current) }

        var result: [PlacedEvent] = []
        for cluster in clusters {
            var columnEnds: [Date] = []
            var columns: [Int] = []
            for span in cluster {
                if let index = columnEnds.firstIndex(where: { $0 <= span.start }) {
                    columnEnds[index] = span.end
                    columns.append(index)
                } else {
                    columnEnds.append(span.end)
                    columns.append(columnEnds.count - 1)
                }
            }
            let count = max(columnEnds.count, 1)
            for (span, column) in zip(cluster, columns) {
                result.append(
                    PlacedEvent(
                        event: span.event,
                        start: span.start,
                        end: span.end,
                        column: column,
                        columns: count,
                        firstHour: firstHour
                    )
                )
            }
        }
        return result
    }

    static func offset(for date: Date, firstHour: Int, calendar: Calendar = .current) -> CGFloat {
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date) - firstHour * 60
        return CGFloat(minutes) / 60 * hourHeight
    }

    static func contains(_ date: Date, firstHour: Int, lastHour: Int, calendar: Calendar = .current) -> Bool {
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return minutes >= firstHour * 60 && minutes < (lastHour + 1) * 60
    }

    static func nowAnchorY(now: Date, firstHour: Int, lastHour: Int, calendar: Calendar = .current) -> CGFloat {
        let target = now.addingTimeInterval(-1.5 * 3600)
        let minutes = calendar.component(.hour, from: target) * 60 + calendar.component(.minute, from: target)
        let start = firstHour * 60
        let end = (lastHour + 1) * 60
        let clamped = min(max(minutes, start), end)
        return CGFloat(clamped - start) / 60 * hourHeight
    }
}

private struct PlacedEvent: Identifiable {
    var event: CalendarEvent
    var start: Date
    var end: Date
    var column: Int
    var columns: Int
    var firstHour: Int

    var id: String { event.id }

    var y: CGFloat {
        CalendarLayout.offset(for: start, firstHour: firstHour)
    }

    var height: CGFloat {
        max(CalendarLayout.minBlockHeight, CGFloat(end.timeIntervalSince(start) / 3600) * CalendarLayout.hourHeight)
    }

    func width(in area: CGFloat) -> CGFloat {
        let gaps = CalendarLayout.overlapGap * CGFloat(max(columns - 1, 0))
        return (area - gaps) / CGFloat(columns)
    }

    func x(in area: CGFloat) -> CGFloat {
        let width = width(in: area)
        return CGFloat(column) * (width + CalendarLayout.overlapGap)
    }
}

private enum CalendarTime {
    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(Date.FormatStyle().hour(.defaultDigits(amPM: .abbreviated)))
    }

    static func relative(from now: Date, to date: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remain = minutes % 60
        if remain == 0 {
            return "\(hours) hr"
        }
        return "\(hours) hr \(remain) min"
    }
}
