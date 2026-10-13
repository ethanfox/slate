import Foundation
import SwiftData

enum SpaceScreenKind: String, Codable, CaseIterable, Identifiable, Hashable {
    /// Browsing every record of a type.
    case collection
    /// One record.
    case detail
    /// A small card about the whole type. See `AreaWidgetDefinition`.
    case widget

    var id: String { rawValue }
}

enum SpaceProp: Codable, Hashable {
    case text(String)
    case number(Double)
    case flag(Bool)
    case list([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .flag(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else {
            self = .list(try container.decode([String].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .flag(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        }
    }
}

/// One placed component. In JSON its settings sit beside `component`:
/// `{"component": "checklist", "rows": "ingredients", "scaleBy": "servings"}`.
struct SpaceComponent: Codable, Hashable {
    var kind: String
    var props: [String: SpaceProp]
    var children: [SpaceComponent]

    init(_ kind: String, _ props: [String: SpaceProp] = [:], children: [SpaceComponent] = []) {
        self.kind = kind
        self.props = props
        self.children = children
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        kind = try container.decode(String.self, forKey: Key("component"))
        children = try container.decodeIfPresent([SpaceComponent].self, forKey: Key("children")) ?? []
        var props: [String: SpaceProp] = [:]
        for key in container.allKeys where key.stringValue != "component" && key.stringValue != "children" {
            props[key.stringValue] = try container.decode(SpaceProp.self, forKey: key)
        }
        self.props = props
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(kind, forKey: Key("component"))
        for (name, value) in props {
            try container.encode(value, forKey: Key(name))
        }
        if !children.isEmpty {
            try container.encode(children, forKey: Key("children"))
        }
    }

    /// A text setting, with an optional `field:` or `event:` prefix removed.
    func text(_ name: String) -> String? {
        guard case .text(let raw) = props[name] else { return nil }
        return Self.reference(raw)
    }

    /// A list setting. A single text counts as a list of one.
    func list(_ name: String) -> [String] {
        switch props[name] {
        case .list(let values): values.map(Self.reference)
        case .text(let value): [Self.reference(value)]
        default: []
        }
    }

    func number(_ name: String) -> Double? {
        if case .number(let value) = props[name] { return value }
        return nil
    }

    static func reference(_ raw: String) -> String {
        for prefix in ["field:", "event:"] where raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        return raw
    }
}

struct SpaceScreenDefinition: Codable, Hashable {
    var components: [SpaceComponent]

    init(_ components: [SpaceComponent] = []) {
        self.components = components
    }
}

/// A calculation named in a component setting.
/// Written `name`, `name:eventKey`, or for logged values `name:eventKey.field:period`.
struct SpaceCalcRequest: Hashable {
    /// How far back a calculation over logged values looks.
    enum Period: String, CaseIterable {
        case today
        /// The last seven days, today included.
        case week
        /// The last thirty days.
        case month
        /// The last 365 days.
        case year
        case all

        func start(now: Date = .now, calendar: Calendar = .current) -> Date? {
            let today = calendar.startOfDay(for: now)
            switch self {
            case .today: return today
            case .week: return calendar.date(byAdding: .day, value: -6, to: today)
            case .month: return calendar.date(byAdding: .day, value: -29, to: today)
            case .year: return calendar.date(byAdding: .day, value: -364, to: today)
            case .all: return nil
            }
        }
    }

    enum Name: String, CaseIterable {
        /// How many events.
        case count
        /// When the newest event happened.
        case latest
        /// Days in a row with an event, ending today or yesterday.
        case streak
        /// The longest run of days with an event.
        case best
        /// Events in the last seven days.
        case week
        /// Collection only: how many records have an event today, out of all.
        case today
        /// Collection only: how many records.
        case records
        /// A logged number added up over a period.
        case sum
        /// The average of a logged number over a period.
        case avg
        /// The smallest logged number in a period.
        case min
        /// The largest logged number in a period.
        case max
        /// How much a logged number has moved since the period began.
        case change
        /// The most recent reading of a logged number, such as today's weight.
        case last
        /// Where the record stands against its schedule: 2 of 3 this week, or done today.
        case pace

        var needsEvent: Bool { self != .records }
        var collectionOnly: Bool { self == .today || self == .records }
        /// Works on a logged number, so it needs `eventKey.field`.
        var needsField: Bool { [.sum, .avg, .min, .max, .change, .last].contains(self) }
        /// Gives a number a progress bar can use.
        var isNumber: Bool { needsField || self == .count || self == .week }
    }

    var name: Name
    var eventKey: String
    /// The logged number: a field of the event itself. A value that comes from the record the event
    /// is about is copied into the event when it is logged.
    var field = ""
    var period = Period.all

    init?(_ raw: String) {
        let parts = raw.split(separator: ":").map(String.init)
        guard let first = parts.first, let name = Name(rawValue: first), parts.count <= 3 else { return nil }
        self.name = name
        let path = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        self.eventKey = path.first ?? ""
        switch path.count {
        case 0, 1: break
        case 2: field = path[1]
        default: return nil
        }
        if parts.count == 3 {
            guard let period = Period(rawValue: parts[2]) else { return nil }
            self.period = period
        }
        if name.needsField, field.isEmpty { return nil }
    }
}

enum SpaceCalc {
    static func days(_ dates: [Date], calendar: Calendar = .current) -> Set<Date> {
        Set(dates.map { calendar.startOfDay(for: $0) })
    }

    /// Days in a row with an event. A streak survives until a full day is missed.
    static func streak(_ dates: [Date], now: Date = .now, calendar: Calendar = .current) -> Int {
        let marked = days(dates, calendar: calendar)
        var cursor = calendar.startOfDay(for: now)
        if !marked.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var length = 0
        while marked.contains(cursor) {
            length += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return length
    }

    /// A streak in the schedule's own terms: scheduled days hit in a row, or weeks that met their count.
    /// The current day or week does not break a streak until it is over.
    static func streak(_ dates: [Date], schedule: SpaceSchedule, now: Date = .now, calendar: Calendar = .current) -> String {
        let marked = days(dates, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        switch schedule.rule {
        case .daily:
            return daysLabel(streak(dates, now: now, calendar: calendar))
        case .weekdays:
            var length = 0
            var cursor = today
            for _ in 0..<3660 {
                if schedule.isDue(on: cursor, calendar: calendar) {
                    if marked.contains(cursor) {
                        length += 1
                    } else if cursor != today {
                        break
                    }
                }
                guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
            }
            return daysLabel(length)
        case .perWeek(let times):
            guard var week = calendar.dateInterval(of: .weekOfYear, for: today) else { return weeksLabel(0) }
            var length = 0
            for index in 0..<520 {
                let count = marked.filter { week.contains($0) }.count
                if count >= times {
                    length += 1
                } else if index != 0 {
                    break
                }
                guard let earlier = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start),
                      let previous = calendar.dateInterval(of: .weekOfYear, for: earlier) else { break }
                week = previous
            }
            return weeksLabel(length)
        }
    }

    static func pace(_ dates: [Date], schedule: SpaceSchedule?, now: Date = .now, calendar: Calendar = .current) -> String {
        let marked = days(dates, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        if case .perWeek(let times) = schedule?.rule, let week = calendar.dateInterval(of: .weekOfYear, for: today) {
            return "\(marked.filter { week.contains($0) }.count) of \(times) this week"
        }
        if marked.contains(today) { return "Done today" }
        return schedule?.isDue(on: today, calendar: calendar) == false ? "Not due today" : "Due today"
    }

    static func weeksLabel(_ count: Int) -> String {
        count == 1 ? "1 week" : "\(count) weeks"
    }

    static func best(_ dates: [Date], calendar: Calendar = .current) -> Int {
        let ordered = days(dates, calendar: calendar).sorted()
        var best = 0
        var run = 0
        var previous: Date?
        for day in ordered {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }

    static func week(_ dates: [Date], now: Date = .now, calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return 0 }
        return dates.filter { $0 >= start && $0 < end }.count
    }

    /// One number from logged values. `values` are in time order, oldest first, with their dates.
    static func number(
        _ name: SpaceCalcRequest.Name,
        _ values: [(date: Date, value: Double)],
        period: SpaceCalcRequest.Period,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Double? {
        let start = period.start(now: now, calendar: calendar)
        let inside = values.filter { start == nil || $0.date >= start! }
        switch name {
        case .sum:
            return inside.reduce(0) { $0 + $1.value }
        case .avg:
            return inside.isEmpty ? nil : inside.reduce(0) { $0 + $1.value } / Double(inside.count)
        case .min:
            return inside.map(\.value).min()
        case .max:
            return inside.map(\.value).max()
        case .last:
            return inside.last?.value
        case .change:
            guard let last = inside.last else { return nil }
            let before = values.last { start != nil && $0.date < start! } ?? inside.first
            return before.map { last.value - $0.value }
        default:
            return nil
        }
    }

    static func label(_ number: Double, signed: Bool = false) -> String {
        let text = number.formatted(.number.precision(.fractionLength(0...1)))
        return signed && number > 0 ? "+\(text)" : text
    }

    static func dayLabel(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date else { return "Never" }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let distance = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch distance {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return date.formatted(.dateTime.weekday(.wide))
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    static func daysLabel(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }
}

/// What one setting on a component may hold.
enum SpacePropKind: Hashable {
    case field([SpaceFieldKind])
    case fields([SpaceFieldKind])
    case event
    case calc
    /// Arithmetic over the record's fields. See `SpaceFormula`.
    case formula
    case text
    case number
}

struct SpacePropSpec: Hashable {
    var name: String
    var kind: SpacePropKind
    var required = false
    var note: String
}

/// A component's declaration: where it can go and what it accepts.
/// The app validates screens against these, and an agent reads them as its catalog.
struct SpaceComponentSpec: Hashable {
    var name: String
    var summary: String
    var props: [SpacePropSpec] = []
    var takesChildren = false
}

enum SpaceScreenCatalog {
    private static let singles: [SpaceFieldKind] = [.text, .number, .boolean, .date, .choice, .quantity, .link, .calc, .schedule, .tags, .url, .money, .duration, .time, .dateRange, .rating, .file]
    private static let sortNote = "A field id, title, or updated. Put - in front for largest or newest first, such as -rating."
    static let components: [SpaceComponentSpec] = [
        SpaceComponentSpec(
            name: "chart",
            summary: "Logged events over time: a line for a logged number such as weight, or bars for how much happened each day.",
            props: [
                SpacePropSpec(name: "events", kind: .event, required: true, note: "The event type."),
                SpacePropSpec(name: "field", kind: .text, note: "A number field of the event. Left out, the chart counts events."),
                SpacePropSpec(name: "period", kind: .text, note: "week, month, year or all. Defaults to month."),
                SpacePropSpec(name: "style", kind: .text, note: "line or bar. Lines suit a measurement, bars a daily amount.")
            ]
        ),
        SpaceComponentSpec(
            name: "progress",
            summary: "A bar showing a number against a target, such as calories against a daily goal.",
            props: [
                SpacePropSpec(name: "value", kind: .formula, required: true, note: "A field id or formula for the number so far, or a calculation over logs such as sum:eaten.calories:today."),
                SpacePropSpec(name: "target", kind: .formula, required: true, note: "A number, field id or formula for the target, such as goals.calories."),
                SpacePropSpec(name: "label", kind: .text, note: "What is being measured."),
                SpacePropSpec(name: "unit", kind: .text, note: "Shown after the numbers, such as g or kcal.")
            ]
        ),
        SpaceComponentSpec(
            name: "metric",
            summary: "One calculated number with a label.",
            props: [
                SpacePropSpec(name: "value", kind: .calc, required: true, note: "count, latest, streak, best, week or pace, then :eventKey. latest is when the newest entry was logged, not its value. For logged numbers: last (the most recent reading), sum, avg, min, max or change, then :eventKey.field:period. In a collection also today:eventKey and records."),
                SpacePropSpec(name: "label", kind: .text, required: true, note: "Text under the number.")
            ]
        ),
        SpaceComponentSpec(
            name: "label",
            summary: "A short line of plain text, such as a caption over a number.",
            props: [
                SpacePropSpec(name: "text", kind: .text, required: true, note: "What it says.")
            ]
        ),
        SpaceComponentSpec(
            name: "list",
            summary: "The first few records by name, such as what is coming up next.",
            props: [
                SpacePropSpec(name: "sort", kind: .text, note: sortNote),
                SpacePropSpec(name: "subtitle", kind: .field(singles), note: "One field shown beside each name.")
            ]
        )
    ]

    static func spec(_ name: String) -> SpaceComponentSpec? {
        components.first { $0.name == name }
    }

    /// Every reason this screen cannot be shown. Empty means it is valid.
    static func problems(
        in definition: SpaceScreenDefinition,
        kind: SpaceScreenKind,
        schema: SpaceSchema,
        eventKeys: Set<String>,
        events: [String: SpaceSchema] = [:]
    ) -> [String] {
        var problems: [String] = []
        for component in definition.components {
            check(component, kind: kind, schema: schema, eventKeys: eventKeys, events: events, into: &problems)
        }
        return problems
    }

    private static func check(
        _ component: SpaceComponent,
        kind: SpaceScreenKind,
        schema: SpaceSchema,
        eventKeys: Set<String>,
        events: [String: SpaceSchema],
        into problems: inout [String]
    ) {
        guard let spec = spec(component.kind) else {
            problems.append("There is no component called \(component.kind).")
            return
        }
        if !spec.takesChildren, !component.children.isEmpty {
            problems.append("\(spec.name) does not take children.")
        }
        for name in component.props.keys where !spec.props.contains(where: { $0.name == name }) {
            problems.append("\(spec.name) has no setting called \(name).")
        }
        for prop in spec.props {
            guard component.props[prop.name] != nil else {
                if prop.required {
                    problems.append("\(spec.name) needs \(prop.name).")
                }
                continue
            }
            switch prop.kind {
            case .field(let kinds):
                guard let id = component.text(prop.name) else {
                    problems.append("\(spec.name).\(prop.name) must name one field.")
                    continue
                }
                checkField(id, kinds: kinds, owner: "\(spec.name).\(prop.name)", schema: schema, into: &problems)
            case .fields(let kinds):
                let ids = component.list(prop.name)
                if ids.isEmpty {
                    problems.append("\(spec.name).\(prop.name) must name at least one field.")
                }
                for id in ids {
                    checkField(id, kinds: kinds, owner: "\(spec.name).\(prop.name)", schema: schema, into: &problems)
                }
            case .event:
                guard let key = component.text(prop.name), eventKeys.contains(key) else {
                    problems.append("\(spec.name).\(prop.name) must name an event type in this Area.")
                    continue
                }
            case .calc:
                guard case .text(let raw) = component.props[prop.name], let request = SpaceCalcRequest(raw) else {
                    problems.append("\(spec.name).\(prop.name) is not a calculation.")
                    continue
                }
                if request.name.collectionOnly, kind == .detail {
                    problems.append("\(request.name.rawValue) only works on a collection screen.")
                }
                checkCalc(request, owner: "\(spec.name).\(prop.name)", schema: schema, eventKeys: eventKeys, events: events, into: &problems)
            case .formula:
                let raw = component.text(prop.name) ?? component.number(prop.name).map { "\($0)" }
                if let raw, raw.contains(":") {
                    guard let request = SpaceCalcRequest(raw), request.name.isNumber else {
                        problems.append("\(spec.name).\(prop.name) is not a calculation that gives a number.")
                        continue
                    }
                    checkCalc(request, owner: "\(spec.name).\(prop.name)", schema: schema, eventKeys: eventKeys, events: events, into: &problems)
                    continue
                }
                guard let raw, let formula = SpaceFormula(raw) else {
                    problems.append("\(spec.name).\(prop.name) is not a formula. \(SpaceFormula.grammar)")
                    continue
                }
                if let reason = formula.problem(beside: schema.liveFields, schema: schema) {
                    problems.append("\(spec.name).\(prop.name): \(reason)")
                }
            case .text:
                if component.text(prop.name) == nil {
                    problems.append("\(spec.name).\(prop.name) must be text.")
                }
            case .number:
                if component.number(prop.name) == nil {
                    problems.append("\(spec.name).\(prop.name) must be a number.")
                }
            }
        }
        if component.kind == "checklist", let saves = component.text("saves"), let rows = component.text("rows") {
            let column = schema.field(rows)?.fields.first { $0.id == saves && !$0.isRemoved }
            if column?.kind != .boolean {
                problems.append("checklist.saves must name a yes/no column of \(rows).")
            }
        }
        if component.kind == "chart" {
            if let period = component.text("period"), SpaceCalcRequest.Period(rawValue: period) == nil {
                problems.append("chart.period must be week, month, year or all.")
            }
            if let style = component.text("style"), style != "line", style != "bar" {
                problems.append("chart.style must be line or bar.")
            }
            if let eventKey = component.text("events"), let field = component.text("field") {
                if let request = SpaceCalcRequest("sum:\(eventKey).\(field)") {
                    checkCalc(request, owner: "chart.field", schema: schema, eventKeys: eventKeys, events: events, into: &problems)
                } else {
                    problems.append("chart.field must be the id of a number field of the event.")
                }
            }
        }
        for sortable in ["cards", "rows", "board", "sheet"] where component.kind == sortable {
            if let sort = component.text("sort") {
                let id = sort.hasPrefix("-") ? String(sort.dropFirst()) : sort
                if id != "title", id != "updated", schema.liveFields.first(where: { $0.id == id }) == nil {
                    problems.append("\(sortable).sort names a field that does not exist: \(id).")
                }
            }
        }
        for child in component.children {
            check(child, kind: kind, schema: schema, eventKeys: eventKeys, events: events, into: &problems)
        }
    }

    private static func checkCalc(
        _ request: SpaceCalcRequest,
        owner: String,
        schema: SpaceSchema,
        eventKeys: Set<String>,
        events: [String: SpaceSchema],
        into problems: inout [String]
    ) {
        if request.name.needsEvent, !eventKeys.contains(request.eventKey) {
            problems.append("\(owner) must name an event type, like \(request.name.rawValue):eventKey.")
            return
        }
        guard request.name.needsField else { return }
        // Without the event's fields to hand there is nothing more to check.
        guard let holder = events[request.eventKey] else { return }
        guard let field = holder.liveFields.first(where: { $0.id == request.field }), field.kind.isNumeric else {
            problems.append("\(owner) needs a number field, and the event \(request.eventKey) has no number field \(request.field).")
            return
        }
    }

    private static func checkField(
        _ id: String,
        kinds: [SpaceFieldKind],
        owner: String,
        schema: SpaceSchema,
        into problems: inout [String]
    ) {
        guard let field = schema.field(id), !field.isRemoved else {
            problems.append("\(owner) names a field that does not exist: \(id).")
            return
        }
        if !kinds.contains(field.kind) {
            problems.append("\(owner) cannot show \(field.name), which is a \(field.kind.rawValue) field.")
        }
    }
}

/// A stored screen for one type. `agentJSON` is the last version an agent wrote, kept for Reset.
@Model
final class SpaceScreen {
    var id: UUID
    var spaceIDString: String
    var typeIDString: String
    var kindRaw: String
    var definitionJSON: String
    var agentJSON: String
    var updatedAt: Date

    var kind: SpaceScreenKind {
        get { SpaceScreenKind(rawValue: kindRaw) ?? .collection }
        set { kindRaw = newValue.rawValue }
    }

    var definition: SpaceScreenDefinition {
        get { SpaceJSON.decode(definitionJSON, as: SpaceScreenDefinition.self) ?? SpaceScreenDefinition() }
        set { definitionJSON = SpaceJSON.encode(newValue) }
    }

    init(type: SpaceType, kind: SpaceScreenKind, definition: SpaceScreenDefinition) {
        self.id = UUID()
        self.spaceIDString = type.spaceIDString
        self.typeIDString = SpaceJSON.key(type.id)
        self.kindRaw = kind.rawValue
        self.definitionJSON = SpaceJSON.encode(definition)
        self.agentJSON = ""
        self.updatedAt = .now
    }
}


// MARK: Widgets

/// How big a widget is, in grid cells. Every widget is one of these three.
enum AreaWidgetSize: String, Codable, CaseIterable, Identifiable, Hashable {
    case small = "1x1"
    case wide = "2x1"
    case large = "2x2"

    var id: String { rawValue }

    /// How many rows of blocks fit.
    var maxRows: Int {
        switch self {
        case .small, .wide: 2
        case .large: 4
        }
    }

    /// How many blocks fit side by side.
    var maxAcross: Int {
        self == .small ? 1 : 2
    }
}

/// A widget is rows of blocks. The definition says which blocks sit in which row and in what order;
/// the app sets the padding, the spacing, and the type sizes.
struct AreaWidgetDefinition: Codable, Hashable {
    var rows: [[SpaceComponent]]

    init(rows: [[SpaceComponent]] = []) {
        self.rows = rows
    }
}

enum AreaWidgetCatalog {
    /// The blocks a widget can be built from.
    static var blocks: [SpaceComponentSpec] { SpaceScreenCatalog.components }

    /// Every reason this widget cannot be shown. Empty means it is valid.
    static func problems(
        in definition: AreaWidgetDefinition,
        size: AreaWidgetSize,
        schema: SpaceSchema,
        eventKeys: Set<String>,
        events: [String: SpaceSchema] = [:]
    ) -> [String] {
        var problems: [String] = []
        if definition.rows.isEmpty {
            problems.append("A widget needs at least one row with a block in it.")
        }
        if definition.rows.count > size.maxRows {
            problems.append("A \(size.rawValue) widget fits \(size.maxRows) rows, and this has \(definition.rows.count).")
        }
        for (index, row) in definition.rows.enumerated() {
            if row.isEmpty {
                problems.append("Row \(index + 1) is empty.")
            }
            if row.count > size.maxAcross {
                problems.append("A \(size.rawValue) widget fits \(size.maxAcross) across, and row \(index + 1) has \(row.count).")
            }
            if size == .small, row.contains(where: { $0.kind == "list" }) {
                problems.append("A list does not fit a 1x1 widget. Use 2x1 or 2x2.")
            }
        }
        return problems + SpaceScreenCatalog.problems(
            in: SpaceScreenDefinition(definition.rows.flatMap { $0 }),
            kind: .widget,
            schema: schema,
            eventKeys: eventKeys,
            events: events
        )
    }
}

/// A small card an agent builds for one type in an Area. It keeps its definition and reads live data,
/// so it is the same widget every time it is shown.
@Model
final class AreaWidget {
    var id: UUID
    var spaceIDString: String
    var typeIDString: String
    var name: String
    var sizeRaw: String
    var definitionJSON: String
    /// The user chose to keep it on the You page.
    var isOnYou: Bool = false
    var createdAt: Date
    var updatedAt: Date

    var size: AreaWidgetSize {
        get { AreaWidgetSize(rawValue: sizeRaw) ?? .small }
        set { sizeRaw = newValue.rawValue }
    }

    var definition: AreaWidgetDefinition {
        get { SpaceJSON.decode(definitionJSON, as: AreaWidgetDefinition.self) ?? AreaWidgetDefinition() }
        set { definitionJSON = SpaceJSON.encode(newValue) }
    }

    var typeID: UUID? { UUID(uuidString: typeIDString) }
    var spaceID: UUID? { UUID(uuidString: spaceIDString) }

    init(type: SpaceType, name: String, size: AreaWidgetSize, definition: AreaWidgetDefinition) {
        self.id = UUID()
        self.spaceIDString = type.spaceIDString
        self.typeIDString = SpaceJSON.key(type.id)
        self.name = name
        self.sizeRaw = size.rawValue
        self.definitionJSON = SpaceJSON.encode(definition)
        self.createdAt = .now
        self.updatedAt = .now
    }
}
