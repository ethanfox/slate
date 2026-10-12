import SwiftData
import SwiftUI

/// Card colors for Spaces. Each runs top to bottom.
enum SpaceGradient: String, CaseIterable, Identifiable, Hashable {
    case matcha
    case zen
    case indigo
    case sand
    case mochi
    case iris
    case tide
    case graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .matcha: "Matcha"
        case .zen: "Zen"
        case .indigo: "Indigo"
        case .sand: "Sand"
        case .mochi: "Mochi"
        case .iris: "Iris"
        case .tide: "Tide"
        case .graphite: "Graphite"
        }
    }

    private var stops: [(String, CGFloat)] {
        switch self {
        case .matcha: [("44744A", 0), ("7C9C7C", 0.52), ("C9D2C2", 1)]
        case .zen: [("CDCED3", 0), ("DDB3A4", 0.42), ("E88A66", 0.78), ("E96F47", 1)]
        case .indigo: [("0A0F24", 0), ("1B2F52", 0.46), ("5C5873", 0.72), ("CBA3A4", 1)]
        case .sand: [("CFD2D8", 0), ("E3CDB2", 0.45), ("EDB06A", 0.82), ("EFA043", 1)]
        case .mochi: [("DE7596", 0), ("EBA9BA", 0.48), ("F6E9DD", 1)]
        case .iris: [("5B62C4", 0), ("8E93D6", 0.5), ("D9D6E6", 1)]
        case .tide: [("1F5E63", 0), ("6FA3A1", 0.52), ("D5DEDA", 1)]
        case .graphite: [("1C1C1E", 0), ("4A4A4F", 0.5), ("B9B4AE", 1)]
        }
    }

    var fill: LinearGradient {
        LinearGradient(
            stops: stops.map { Gradient.Stop(color: Color(hex: $0.0), location: $0.1) },
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The top of the card is dark enough to need white text.
    var hasDarkTop: Bool {
        switch self {
        case .zen, .sand: false
        default: true
        }
    }

    /// A single color that stands for the gradient in lists.
    var accent: Color {
        switch self {
        case .matcha: Color(hex: "5E8A62")
        case .zen: Color(hex: "E8704A")
        case .indigo: Color(hex: "23365C")
        case .sand: Color(hex: "EFA246")
        case .mochi: Color(hex: "DE7596")
        case .iris: Color(hex: "5B62C4")
        case .tide: Color(hex: "1F5E63")
        case .graphite: Color(hex: "4A4A4F")
        }
    }

    static func resolved(_ raw: String, fallbackID: UUID) -> SpaceGradient {
        if let named = SpaceGradient(rawValue: raw) { return named }
        let index = Int(fallbackID.uuid.0) % allCases.count
        return allCases[index]
    }

    /// The first gradient no existing Space uses, then round robin.
    static func next(after used: [String]) -> SpaceGradient {
        allCases.first { !used.contains($0.rawValue) } ?? allCases[used.count % allCases.count]
    }
}

extension Space {
    var gradient: SpaceGradient {
        SpaceGradient.resolved(gradientRaw, fallbackID: id)
    }
}

struct ComingUpItem: Identifiable, Equatable {
    enum Target: Equatable {
        case task(UUID)
        case event(String)
        case record(space: UUID, record: UUID)
    }

    var id: String
    var date: Date
    var hasTime: Bool
    var title: String
    var source: String
    var target: Target

    func dayLabel(now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    var meta: String {
        hasTime ? date.formatted(date: .omitted, time: .shortened) : source
    }
}

enum ComingUp {
    /// Open tasks with a due date, calendar events, and dates on Space records, from today on.
    static func items(
        tasks: [AgendaItem],
        events: [CalendarEvent],
        records: [SpaceRecord],
        spaces: [Space],
        now: Date = .now,
        calendar: Calendar = .current,
        days: Int = 14,
        limit: Int = 6
    ) -> [ComingUpItem] {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }
        var items: [ComingUpItem] = []

        for task in tasks where task.kind == .task && !task.isCompleted {
            guard let due = task.due, due >= start, due < end else { continue }
            items.append(ComingUpItem(
                id: "task-\(task.id.uuidString)",
                date: due,
                hasTime: TaskDue.hasClockTime(due, calendar: calendar),
                title: task.displayTitle,
                source: task.project?.displayName ?? "Task",
                target: .task(task.id)
            ))
        }

        for event in events where event.end > now && event.start < end {
            items.append(ComingUpItem(
                id: "event-\(event.id)",
                date: max(event.start, start),
                hasTime: !event.isAllDay && event.start >= start,
                title: event.title,
                source: event.calendarName,
                target: .event(event.id)
            ))
        }

        for record in records {
            guard let spaceID = record.spaceID else { continue }
            let spaceName = spaces.first { $0.id == spaceID }?.displayName ?? "Space"
            for (field, value) in record.values {
                guard case .date(let date) = value, date >= start, date < end else { continue }
                items.append(ComingUpItem(
                    id: "record-\(record.id.uuidString)-\(field)",
                    date: date,
                    hasTime: TaskDue.hasClockTime(date, calendar: calendar),
                    title: record.displayTitle,
                    source: spaceName,
                    target: .record(space: spaceID, record: record.id)
                ))
            }
        }

        return Array(items.sorted { ($0.date, $0.id) < ($1.date, $1.id) }.prefix(limit))
    }
}

struct YouView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Space.createdAt) private var spaces: [Space]
    @Query private var records: [SpaceRecord]
    @Query(filter: #Predicate<AgendaItem> { $0.kindRaw == "task" && $0.isCompleted == false })
    private var openTasks: [AgendaItem]
    @Query(filter: #Predicate<TitleIndex> { $0.kindRaw == "project" }, sort: \TitleIndex.updatedAt, order: .reverse)
    private var projects: [TitleIndex]
    @State private var pendingDelete: Space?

    private let gutter: CGFloat = 48

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 32) {
                    greeting
                        .padding(.horizontal, gutter)
                    shelf
                    HStack(alignment: .top, spacing: 48) {
                        latelyFeed
                            .frame(maxWidth: .infinity, alignment: .leading)
                        comingUp
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, gutter)
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
        .captureBar()
        .task { await app.eventKit.prepareEvents() }
        .alert(
            "Delete \(pendingDelete?.displayName ?? "this Space")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let space = pendingDelete {
                    try? SpaceStore.delete(space, in: context)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Everything in this Space will be deleted. This can’t be undone.")
        }
    }

    private var greeting: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greetingLine)
                    .font(.system(size: 28, weight: .semibold))
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
                shortcuts
                    .padding(.top, 12)
            }
            Spacer(minLength: 16)
            Button {
                app.navigate(to: .aboutYou)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("About you")
                        .font(CraftFont.body)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(CraftColor.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(CraftColor.hairline))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("What Membrae knows about you")
        }
    }

    private var greetingLine: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let salutation = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? salutation : "\(salutation), \(first)"
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spaces")
                .font(CraftFont.section)
                .foregroundStyle(.secondary)
                .padding(.horizontal, gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(spaces) { space in
                        Button {
                            app.navigate(to: .space(space.id))
                        } label: {
                            SpaceCard(space: space, summary: summary(for: space))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { spaceMenu(space) }
                    }
                    if spaces.isEmpty {
                        Button {
                            app.present(.newSpace)
                        } label: {
                            NewSpaceCard()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, gutter)
                .padding(.bottom, 18)
            }
        }
    }

    @ViewBuilder
    private func spaceMenu(_ space: Space) -> some View {
        Button {
            app.present(.editSpace(space))
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Menu("Color") {
            ForEach(SpaceGradient.allCases) { gradient in
                Button {
                    space.gradientRaw = gradient.rawValue
                    space.touch()
                    try? context.persist()
                } label: {
                    if space.gradient == gradient {
                        Label(gradient.label, systemImage: "checkmark")
                    } else {
                        Text(gradient.label)
                    }
                }
            }
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = space
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func summary(for space: Space) -> SpaceCardSummary {
        let key = SpaceJSON.key(space.id)
        let owned = records.filter { $0.spaceIDString == key }
        let latest = owned.max { $0.updatedAt < $1.updatedAt }
        let line: String
        if let latest {
            line = "\(latest.displayTitle), \(latest.updatedAt.relativeLabel)"
        } else {
            line = space.summary.isEmpty ? "Nothing yet" : space.summary
        }
        return SpaceCardSummary(line: line, count: owned.count, caption: owned.count == 1 ? "record" : "records")
    }

    private var upcoming: [ComingUpItem] {
        ComingUp.items(tasks: openTasks, events: app.eventKit.events, records: records, spaces: spaces)
    }

    private var comingUp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coming up")
                .font(CraftFont.section)
                .foregroundStyle(.secondary)
            let items = upcoming
            if items.isEmpty {
                EmptyLine(text: "Nothing in the next two weeks.")
            } else {
                ForEach(items) { item in
                    Button {
                        open(item)
                    } label: {
                        ComingUpRow(item: item, tint: tint(for: item))
                    }
                    .buttonStyle(.plain)
                    if item.id != items.last?.id {
                        Hairline()
                    }
                }
            }
        }
    }

    private func tint(for item: ComingUpItem) -> Color {
        switch item.target {
        case .task:
            return Color.secondary.opacity(0.6)
        case .event(let id):
            return app.eventKit.events.first { $0.id == id }?.tint.color ?? Color.secondary.opacity(0.6)
        case .record(let spaceID, _):
            return spaces.first { $0.id == spaceID }?.gradient.accent ?? Color.secondary.opacity(0.6)
        }
    }

    private func open(_ item: ComingUpItem) {
        switch item.target {
        case .task(let id):
            if let task = openTasks.first(where: { $0.id == id }) {
                app.open(task)
            }
        case .event:
            app.navigate(to: .calendar)
        case .record(let spaceID, _):
            app.navigate(to: .space(spaceID))
        }
    }

    private var latelyFeed: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lately")
                .font(CraftFont.section)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ActionFeed(empty: "What Membrae files for you will show up here.")
        }
    }

    /// The places that no longer have a sidebar row of their own.
    private var shortcuts: some View {
        HStack(spacing: 6) {
            shortcut("Tasks", "checklist", .tasks)
            shortcut("Calendar", "calendar", .calendar)
            shortcut("Library", "books.vertical", .library)
            shortcut("Chats", "bubble.left.and.bubble.right", .chats)
            shortcut("Runs", "play.circle", .runs)
            shortcut("All projects", "square.stack", .projects)
        }
    }

    private func shortcut(_ title: String, _ symbol: String, _ destination: Destination) -> some View {
        Button {
            app.navigate(to: destination)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(CraftFont.body)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(CraftColor.elevated, in: Capsule())
            .overlay(Capsule().strokeBorder(CraftColor.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent projects")
                .font(CraftFont.section)
                .foregroundStyle(.secondary)
            let recent = Array(projects.prefix(4))
            if recent.isEmpty {
                EmptyLine(text: "Projects you open will appear here.")
            } else {
                ForEach(recent) { project in
                    Button {
                        app.open(project)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: project.symbol.isEmpty ? "folder" : project.symbol)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(project.displayTitle)
                                .font(CraftFont.body)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(project.updatedAt.relativeLabel)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if project.id != recent.last?.id {
                        Hairline()
                    }
                }
            }
        }
    }
}

struct SpaceCardSummary {
    var line: String
    var count: Int
    var caption: String
}

private struct SpaceCard: View {
    var space: Space
    var summary: SpaceCardSummary

    private static let ink = Color(hex: "16151A")

    var body: some View {
        let gradient = space.gradient
        let top: Color = gradient.hasDarkTop ? .white : Self.ink
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(space.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(top)
                        .lineLimit(1)
                    Text(summary.line)
                        .font(.system(size: 12))
                        .foregroundStyle(top.opacity(gradient.hasDarkTop ? 0.72 : 0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: space.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(top)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(summary.count)")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Self.ink)
                Text(summary.caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Self.ink.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 212, height: 236, alignment: .topLeading)
        .background(gradient.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct NewSpaceCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 18))
            Text("New Space")
                .font(CraftFont.body)
        }
        .foregroundStyle(.secondary)
        .frame(width: 212, height: 236)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CraftColor.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ComingUpRow: View {
    var item: ComingUpItem
    var tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(item.dayLabel())
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 3, height: 18)
            Text(item.title)
                .font(CraftFont.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.meta)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: 40)
        .contentShape(Rectangle())
    }
}
