import Foundation
import SwiftData

enum SpaceScreenKind: String, Codable, CaseIterable, Identifiable, Hashable {
    /// Browsing every record of a type.
    case collection
    /// One record.
    case detail

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

/// A calculation named in a component setting, written `name` or `name:eventKey`.
struct SpaceCalcRequest: Hashable {
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

        var needsEvent: Bool { self != .records }
        var collectionOnly: Bool { self == .today || self == .records }
    }

    var name: Name
    var eventKey: String

    init?(_ raw: String) {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let name = Name(rawValue: first) else { return nil }
        self.name = name
        self.eventKey = parts.count > 1 ? parts[1] : ""
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
    var screens: Set<SpaceScreenKind>
    var props: [SpacePropSpec] = []
    var takesChildren = false
}

enum SpaceScreenCatalog {
    private static let singles: [SpaceFieldKind] = [.text, .number, .boolean, .date, .choice, .quantity]
    private static let both: Set<SpaceScreenKind> = [.collection, .detail]

    static let components: [SpaceComponentSpec] = [
        SpaceComponentSpec(
            name: "section",
            summary: "A heading over a group of components.",
            screens: both,
            props: [SpacePropSpec(name: "title", kind: .text, required: true, note: "The heading.")],
            takesChildren: true
        ),
        SpaceComponentSpec(
            name: "columns",
            summary: "Places its children side by side.",
            screens: both,
            props: [SpacePropSpec(name: "leading", kind: .number, note: "Fixed width of the first column in points.")],
            takesChildren: true
        ),
        SpaceComponentSpec(
            name: "search",
            summary: "A search box and filter chips over the records below it.",
            screens: [.collection],
            props: [SpacePropSpec(name: "filters", kind: .fields([.choice]), note: "Choice fields to offer as chips.")]
        ),
        SpaceComponentSpec(
            name: "cards",
            summary: "The records as a grid of cards.",
            screens: [.collection],
            props: [
                SpacePropSpec(name: "image", kind: .field([.image]), note: "Image field shown at the top of each card."),
                SpacePropSpec(name: "subtitle", kind: .fields(singles), note: "Fields shown under each name.")
            ]
        ),
        SpaceComponentSpec(
            name: "rows",
            summary: "The records as a list, with an optional one-tap action.",
            screens: [.collection],
            props: [
                SpacePropSpec(name: "subtitle", kind: .fields(singles), note: "Fields shown under each name."),
                SpacePropSpec(name: "action", kind: .event, note: "Event to log or undo for today with one tap."),
                SpacePropSpec(name: "week", kind: .event, note: "Event to show as seven day dots."),
                SpacePropSpec(name: "trail", kind: .calc, note: "A calculation shown at the end of each row.")
            ]
        ),
        SpaceComponentSpec(
            name: "header",
            summary: "The record's name, a few fields, and its main action.",
            screens: [.detail],
            props: [
                SpacePropSpec(name: "image", kind: .field([.image]), note: "Image field shown beside the name."),
                SpacePropSpec(name: "fields", kind: .fields(singles), note: "Fields shown under the name."),
                SpacePropSpec(name: "action", kind: .event, note: "Event the main button logs."),
                SpacePropSpec(name: "actionLabel", kind: .text, note: "The button's label.")
            ]
        ),
        SpaceComponentSpec(
            name: "fields",
            summary: "Chosen fields with their labels.",
            screens: [.detail],
            props: [SpacePropSpec(name: "fields", kind: .fields(singles + [.richText]), required: true, note: "Fields to show.")]
        ),
        SpaceComponentSpec(
            name: "stepper",
            summary: "Plus and minus on a number, to try another amount without saving it.",
            screens: [.detail],
            props: [
                SpacePropSpec(name: "field", kind: .field([.number]), required: true, note: "The number field."),
                SpacePropSpec(name: "label", kind: .text, note: "Text before the control.")
            ]
        ),
        SpaceComponentSpec(
            name: "checklist",
            summary: "Rows of a group with tick boxes. Quantities can scale with a stepper.",
            screens: [.detail],
            props: [
                SpacePropSpec(name: "rows", kind: .field([.group]), required: true, note: "The group field."),
                SpacePropSpec(name: "scaleBy", kind: .field([.number]), note: "Number field whose stepper scales the quantities.")
            ]
        ),
        SpaceComponentSpec(
            name: "steps",
            summary: "Rows of a group as numbered steps.",
            screens: [.detail],
            props: [SpacePropSpec(name: "rows", kind: .field([.group]), required: true, note: "The group field.")]
        ),
        SpaceComponentSpec(
            name: "timeline",
            summary: "Logged events, newest first.",
            screens: both,
            props: [SpacePropSpec(name: "events", kind: .event, required: true, note: "The event type.")]
        ),
        SpaceComponentSpec(
            name: "calendar",
            summary: "A month grid marking the days an event was logged.",
            screens: [.detail],
            props: [SpacePropSpec(name: "events", kind: .event, required: true, note: "The event type.")]
        ),
        SpaceComponentSpec(
            name: "metric",
            summary: "One calculated number with a label.",
            screens: both,
            props: [
                SpacePropSpec(name: "value", kind: .calc, required: true, note: "count, latest, streak, best or week, then :eventKey. In a collection also today:eventKey and records."),
                SpacePropSpec(name: "label", kind: .text, required: true, note: "Text under the number.")
            ]
        ),
        SpaceComponentSpec(
            name: "action",
            summary: "A button that logs an event about the record.",
            screens: [.detail],
            props: [
                SpacePropSpec(name: "event", kind: .event, required: true, note: "The event type."),
                SpacePropSpec(name: "label", kind: .text, required: true, note: "The button's label.")
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
        eventKeys: Set<String>
    ) -> [String] {
        var problems: [String] = []
        for component in definition.components {
            check(component, kind: kind, schema: schema, eventKeys: eventKeys, into: &problems)
        }
        return problems
    }

    private static func check(
        _ component: SpaceComponent,
        kind: SpaceScreenKind,
        schema: SpaceSchema,
        eventKeys: Set<String>,
        into problems: inout [String]
    ) {
        guard let spec = spec(component.kind) else {
            problems.append("There is no component called \(component.kind).")
            return
        }
        if !spec.screens.contains(kind) {
            problems.append("\(spec.name) cannot be used on a \(kind.rawValue) screen.")
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
                    problems.append("\(spec.name).\(prop.name) must name an event type in this Space.")
                    continue
                }
            case .calc:
                guard case .text(let raw) = component.props[prop.name], let request = SpaceCalcRequest(raw) else {
                    problems.append("\(spec.name).\(prop.name) is not a calculation.")
                    continue
                }
                if request.name.collectionOnly, kind != .collection {
                    problems.append("\(request.name.rawValue) only works on a collection screen.")
                }
                if request.name.needsEvent, !eventKeys.contains(request.eventKey) {
                    problems.append("\(spec.name).\(prop.name) must name an event type, like \(request.name.rawValue):eventKey.")
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
        for child in component.children {
            check(child, kind: kind, schema: schema, eventKeys: eventKeys, into: &problems)
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
