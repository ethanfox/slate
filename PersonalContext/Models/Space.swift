import Foundation
import SwiftData

enum SpaceFieldKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case text
    case richText
    case number
    case boolean
    case date
    case choice
    case image
    case quantity
    case group

    var id: String { rawValue }
}

struct SpaceOption: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

/// `id` is permanent. Renaming changes `name` only, so stored values keep resolving.
struct SpaceField: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var kind: SpaceFieldKind
    /// Choice only.
    var options: [SpaceOption]
    /// Group only: the columns of each row. Groups do not nest.
    var fields: [SpaceField]
    /// Group only: rows are numbered steps rather than a loose list.
    var isOrdered: Bool
    /// Hidden, not erased. Values stay on the records.
    var isRemoved: Bool

    init(
        id: String,
        name: String,
        kind: SpaceFieldKind,
        options: [SpaceOption] = [],
        fields: [SpaceField] = [],
        isOrdered: Bool = false,
        isRemoved: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.options = options
        self.fields = fields
        self.isOrdered = isOrdered
        self.isRemoved = isRemoved
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(SpaceFieldKind.self, forKey: .kind)
        options = try container.decodeIfPresent([SpaceOption].self, forKey: .options) ?? []
        fields = try container.decodeIfPresent([SpaceField].self, forKey: .fields) ?? []
        isOrdered = try container.decodeIfPresent(Bool.self, forKey: .isOrdered) ?? false
        isRemoved = try container.decodeIfPresent(Bool.self, forKey: .isRemoved) ?? false
    }
}

struct SpaceQuantity: Codable, Hashable {
    var amount: Double
    var unit: String
    /// False for amounts like "a pinch" that stay put when servings change.
    var scales: Bool

    init(amount: Double, unit: String, scales: Bool = true) {
        self.amount = amount
        self.unit = unit
        self.scales = scales
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try container.decode(Double.self, forKey: .amount)
        unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? ""
        scales = try container.decodeIfPresent(Bool.self, forKey: .scales) ?? true
    }
}

/// One stored value. Persisted as a single-key object, e.g. `{"number": 2}`.
enum SpaceValue: Codable, Hashable {
    /// Text, rich text, a choice's option id, or an image's asset id.
    case text(String)
    case number(Double)
    case boolean(Bool)
    case date(Date)
    case quantity(SpaceQuantity)
    /// Group rows, each keyed by the group's field ids.
    case rows([[String: SpaceValue]])

    private enum CodingKeys: String, CodingKey {
        case text, number, boolean, date, quantity, rows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(value)
        } else if let value = try container.decodeIfPresent(Double.self, forKey: .number) {
            self = .number(value)
        } else if let value = try container.decodeIfPresent(Bool.self, forKey: .boolean) {
            self = .boolean(value)
        } else if let value = try container.decodeIfPresent(Date.self, forKey: .date) {
            self = .date(value)
        } else if let value = try container.decodeIfPresent(SpaceQuantity.self, forKey: .quantity) {
            self = .quantity(value)
        } else if let value = try container.decodeIfPresent([[String: SpaceValue]].self, forKey: .rows) {
            self = .rows(value)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown Space value.")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value): try container.encode(value, forKey: .text)
        case .number(let value): try container.encode(value, forKey: .number)
        case .boolean(let value): try container.encode(value, forKey: .boolean)
        case .date(let value): try container.encode(value, forKey: .date)
        case .quantity(let value): try container.encode(value, forKey: .quantity)
        case .rows(let value): try container.encode(value, forKey: .rows)
        }
    }
}

enum SpaceSchemaError: LocalizedError, Equatable {
    case emptyFieldID
    case emptyFieldName(String)
    case duplicateFieldID(String)
    case duplicateOptionID(field: String, option: String)
    case nestedGroup(String)
    case kindChanged(String)
    case unknownField(String)
    case wrongValue(field: String, expected: SpaceFieldKind)
    case unknownOption(field: String, option: String)

    var errorDescription: String? {
        switch self {
        case .emptyFieldID: "Every field needs an id."
        case .emptyFieldName(let id): "Field \(id) needs a name."
        case .duplicateFieldID(let id): "Field id \(id) is used more than once."
        case .duplicateOptionID(let field, let option): "\(field) lists option \(option) more than once."
        case .nestedGroup(let field): "\(field) is a group inside a group. Groups do not nest."
        case .kindChanged(let field): "\(field) already holds values of another kind. Add a new field instead."
        case .unknownField(let id): "There is no field \(id) on this type."
        case .wrongValue(let field, let expected): "\(field) expects a \(expected.rawValue) value."
        case .unknownOption(let field, let option): "\(field) has no option \(option)."
        }
    }
}

struct SpaceSchema: Codable, Equatable {
    var fields: [SpaceField]

    init(fields: [SpaceField] = []) {
        self.fields = fields
    }

    var liveFields: [SpaceField] {
        fields.filter { !$0.isRemoved }
    }

    func field(_ id: String) -> SpaceField? {
        fields.first { $0.id == id }
    }

    func validate() throws {
        try Self.validate(fields, insideGroup: false)
    }

    private static func validate(_ fields: [SpaceField], insideGroup: Bool) throws {
        var seen: Set<String> = []
        for field in fields {
            guard !field.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpaceSchemaError.emptyFieldID
            }
            guard !field.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpaceSchemaError.emptyFieldName(field.id)
            }
            guard seen.insert(field.id).inserted else {
                throw SpaceSchemaError.duplicateFieldID(field.id)
            }
            var options: Set<String> = []
            for option in field.options where !options.insert(option.id).inserted {
                throw SpaceSchemaError.duplicateOptionID(field: field.name, option: option.id)
            }
            if field.kind == .group {
                guard !insideGroup else { throw SpaceSchemaError.nestedGroup(field.name) }
                try validate(field.fields, insideGroup: true)
            }
        }
    }

    /// Values for removed fields are still accepted: removal hides, it does not erase.
    func validate(_ values: [String: SpaceValue]) throws {
        try Self.validate(values, against: fields)
    }

    private static func validate(_ values: [String: SpaceValue], against fields: [SpaceField]) throws {
        for (id, value) in values {
            guard let field = fields.first(where: { $0.id == id }) else {
                throw SpaceSchemaError.unknownField(id)
            }
            switch (field.kind, value) {
            case (.text, .text), (.richText, .text), (.image, .text),
                 (.number, .number), (.boolean, .boolean), (.date, .date), (.quantity, .quantity):
                break
            case (.choice, .text(let option)):
                guard field.options.contains(where: { $0.id == option }) else {
                    throw SpaceSchemaError.unknownOption(field: field.name, option: option)
                }
            case (.group, .rows(let rows)):
                for row in rows {
                    try validate(row, against: field.fields)
                }
            default:
                throw SpaceSchemaError.wrongValue(field: field.name, expected: field.kind)
            }
        }
    }

    /// The schema to store when `self` replaces `old` on a type that may already have records.
    /// A field cannot change kind. A field left out is kept as removed so its values survive.
    func replacing(_ old: SpaceSchema) throws -> SpaceSchema {
        try validate()
        return SpaceSchema(fields: try Self.merge(fields, over: old.fields))
    }

    private static func merge(_ new: [SpaceField], over old: [SpaceField]) throws -> [SpaceField] {
        var merged: [SpaceField] = []
        for var field in new {
            if let previous = old.first(where: { $0.id == field.id }) {
                guard previous.kind == field.kind else {
                    throw SpaceSchemaError.kindChanged(field.name)
                }
                if field.kind == .group {
                    field.fields = try merge(field.fields, over: previous.fields)
                }
            }
            merged.append(field)
        }
        for var previous in old where !new.contains(where: { $0.id == previous.id }) {
            previous.isRemoved = true
            merged.append(previous)
        }
        return merged
    }
}

enum SpaceJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
        guard let data = raw.data(using: .utf8), !raw.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func key(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

/// Built-in Membrae types a Space can turn on or off.
enum SpaceBuiltInKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case track
    case note
    case decision
    case task
    case chat
    case run

    var id: String { rawValue }
}

enum SpaceTypeRole: String, Codable, CaseIterable, Identifiable, Hashable {
    /// A durable thing: a recipe, a habit.
    case object
    /// A logged occurrence about one or more records: cooked, checked in.
    case event

    var id: String { rawValue }
}

enum SpaceTypeOrigin: String, Codable, CaseIterable, Identifiable, Hashable {
    case user
    case agent
    case copy

    var id: String { rawValue }
}

@Model
final class Space {
    var id: UUID
    var name: String
    var symbol: String
    var summary: String
    var enabledKindsRaw: String
    /// A `SpaceGradient` name. Empty falls back to one picked from the id.
    var gradientRaw: String = ""
    var createdAt: Date
    var updatedAt: Date

    var enabledKinds: Set<SpaceBuiltInKind> {
        get {
            Set(enabledKindsRaw.split(separator: ",").compactMap { SpaceBuiltInKind(rawValue: String($0)) })
        }
        set {
            enabledKindsRaw = SpaceBuiltInKind.allCases
                .filter(newValue.contains)
                .map(\.rawValue)
                .joined(separator: ",")
        }
    }

    var displayName: String {
        name.isEmpty ? "Untitled" : name
    }

    init(name: String, symbol: String = "square.grid.2x2", summary: String = "") {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.summary = summary
        self.enabledKindsRaw = ""
        self.createdAt = .now
        self.updatedAt = .now
    }

    func touch() {
        updatedAt = .now
    }
}

/// A Space-local type definition. Ownership lives on string ID columns, not SwiftData relationships.
@Model
final class SpaceType {
    var id: UUID
    var spaceIDString: String
    var key: String
    var name: String
    var roleRaw: String
    var schemaJSON: String
    var schemaVersion: Int
    var originRaw: String
    var createdAt: Date
    var updatedAt: Date

    var spaceID: UUID? { UUID(uuidString: spaceIDString) }

    var role: SpaceTypeRole {
        get { SpaceTypeRole(rawValue: roleRaw) ?? .object }
        set { roleRaw = newValue.rawValue }
    }

    var origin: SpaceTypeOrigin {
        get { SpaceTypeOrigin(rawValue: originRaw) ?? .user }
        set { originRaw = newValue.rawValue }
    }

    var schema: SpaceSchema {
        get { SpaceJSON.decode(schemaJSON, as: SpaceSchema.self) ?? SpaceSchema() }
        set { schemaJSON = SpaceJSON.encode(newValue) }
    }

    init(
        spaceID: UUID,
        key: String,
        name: String,
        role: SpaceTypeRole,
        schema: SpaceSchema,
        origin: SpaceTypeOrigin
    ) {
        self.id = UUID()
        self.spaceIDString = SpaceJSON.key(spaceID)
        self.key = key
        self.name = name
        self.roleRaw = role.rawValue
        self.schemaJSON = SpaceJSON.encode(schema)
        self.schemaVersion = 1
        self.originRaw = origin.rawValue
        self.createdAt = .now
        self.updatedAt = .now
    }
}

@Model
final class SpaceRecord {
    var id: UUID
    var spaceIDString: String
    var typeIDString: String
    var title: String
    var valuesJSON: String
    var createdAt: Date
    var updatedAt: Date

    var spaceID: UUID? { UUID(uuidString: spaceIDString) }
    var typeID: UUID? { UUID(uuidString: typeIDString) }

    var values: [String: SpaceValue] {
        get { SpaceJSON.decode(valuesJSON, as: [String: SpaceValue].self) ?? [:] }
        set { valuesJSON = SpaceJSON.encode(newValue) }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    init(type: SpaceType, title: String, values: [String: SpaceValue]) {
        self.id = UUID()
        self.spaceIDString = type.spaceIDString
        self.typeIDString = SpaceJSON.key(type.id)
        self.title = title
        self.valuesJSON = SpaceJSON.encode(values)
        self.createdAt = .now
        self.updatedAt = .now
    }
}

/// A logged occurrence. One event can be about several records.
@Model
final class SpaceEvent {
    var id: UUID
    var spaceIDString: String
    var typeIDString: String
    var occurredAt: Date
    var valuesJSON: String
    var recordIDsRaw: String
    var createdAt: Date

    var spaceID: UUID? { UUID(uuidString: spaceIDString) }
    var typeID: UUID? { UUID(uuidString: typeIDString) }

    var values: [String: SpaceValue] {
        get { SpaceJSON.decode(valuesJSON, as: [String: SpaceValue].self) ?? [:] }
        set { valuesJSON = SpaceJSON.encode(newValue) }
    }

    var recordIDs: [UUID] {
        get { recordIDsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
        set { recordIDsRaw = newValue.map(SpaceJSON.key).joined(separator: ",") }
    }

    init(type: SpaceType, occurredAt: Date, values: [String: SpaceValue], recordIDs: [UUID]) {
        self.id = UUID()
        self.spaceIDString = type.spaceIDString
        self.typeIDString = SpaceJSON.key(type.id)
        self.occurredAt = occurredAt
        self.valuesJSON = SpaceJSON.encode(values)
        self.recordIDsRaw = recordIDs.map(SpaceJSON.key).joined(separator: ",")
        self.createdAt = .now
    }
}

enum PersonalFactSource: String, Codable, CaseIterable, Identifiable, Hashable {
    case user
    case agent

    var id: String { rawValue }
}

/// One durable thing Membrae knows about the user. Shown on About you, not on You.
@Model
final class PersonalFact {
    var id: UUID
    var text: String
    var category: String
    var sourceRaw: String
    /// The chat an agent-written fact came from.
    var sourceChatIDString: String
    var createdAt: Date
    var updatedAt: Date

    var source: PersonalFactSource {
        get { PersonalFactSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }

    var sourceChatID: UUID? { UUID(uuidString: sourceChatIDString) }

    init(text: String, category: String = "", source: PersonalFactSource = .user, sourceChatID: UUID? = nil) {
        self.id = UUID()
        self.text = text
        self.category = category
        self.sourceRaw = source.rawValue
        self.sourceChatIDString = sourceChatID.map(SpaceJSON.key) ?? ""
        self.createdAt = .now
        self.updatedAt = .now
    }
}

/// A built-in record that belongs to a Project or to a Space, never both.
/// Move one into a Space with `SpaceStore.move`, which clears the project.
protocol SpaceOwnable: AnyObject {
    var project: Project? { get set }
    var spaceIDString: String { get set }
}

extension SpaceOwnable {
    var spaceID: UUID? { UUID(uuidString: spaceIDString) }
}

extension ProjectThread: SpaceOwnable {}
extension Note: SpaceOwnable {}
extension Decision: SpaceOwnable {}
extension Conversation: SpaceOwnable {}
extension AgendaItem: SpaceOwnable {}
extension AgentRun: SpaceOwnable {}

extension SpaceSchema {
    /// Text for lists and the plain detail view.
    /// Asset ids held by image fields, including image columns inside groups.
    func imageAssetIDs(in values: [String: SpaceValue]) -> [UUID] {
        Self.imageAssetIDs(in: values, fields: fields)
    }

    private static func imageAssetIDs(in values: [String: SpaceValue], fields: [SpaceField]) -> [UUID] {
        var ids: [UUID] = []
        for field in fields {
            switch (field.kind, values[field.id]) {
            case (.image, .text(let raw)):
                if let id = UUID(uuidString: raw) { ids.append(id) }
            case (.group, .rows(let rows)):
                for row in rows {
                    ids += imageAssetIDs(in: row, fields: field.fields)
                }
            default:
                break
            }
        }
        return ids
    }

    func display(_ value: SpaceValue, for field: SpaceField) -> String {
        switch value {
        case .text(let text):
            if field.kind == .choice {
                return field.options.first { $0.id == text }?.name ?? text
            }
            // An image value is an asset id, which is not worth reading.
            return field.kind == .image ? "" : text
        case .number(let number):
            return number.formatted(.number.precision(.fractionLength(0...2)))
        case .boolean(let flag):
            return flag ? "Yes" : "No"
        case .date(let date):
            return date.formatted(date: .abbreviated, time: .omitted)
        case .quantity(let quantity):
            let amount = quantity.amount.formatted(.number.precision(.fractionLength(0...2)))
            return quantity.unit.isEmpty ? amount : "\(amount) \(quantity.unit)"
        case .rows(let rows):
            return rows.count == 1 ? "1 row" : "\(rows.count) rows"
        }
    }
}

/// A starting set of types for a new Space. Plain data built from the same field kinds an agent uses.
struct SpaceTemplate: Identifiable, Hashable {
    struct TypeDraft: Hashable {
        var key: String
        var name: String
        var role: SpaceTypeRole
        var fields: [SpaceField]
        var collection: [SpaceComponent] = []
        var detail: [SpaceComponent] = []
    }

    var id: String
    var name: String
    var types: [TypeDraft]

    static let empty = SpaceTemplate(id: "empty", name: "Empty", types: [])

    static let recipes = SpaceTemplate(id: "recipes", name: "Recipes", types: [
        TypeDraft(key: "recipe", name: "Recipes", role: .object, fields: [
            SpaceField(id: "photo", name: "Photo", kind: .image),
            SpaceField(id: "course", name: "Course", kind: .choice, options: [
                SpaceOption(id: "main", name: "Main"),
                SpaceOption(id: "side", name: "Side"),
                SpaceOption(id: "bread", name: "Bread"),
                SpaceOption(id: "dessert", name: "Dessert")
            ]),
            SpaceField(id: "servings", name: "Servings", kind: .number),
            SpaceField(id: "time", name: "Time", kind: .text),
            SpaceField(id: "source", name: "Source", kind: .text),
            SpaceField(id: "ingredients", name: "Ingredients", kind: .group, fields: [
                SpaceField(id: "amount", name: "Amount", kind: .quantity),
                SpaceField(id: "item", name: "Item", kind: .text)
            ]),
            SpaceField(id: "method", name: "Method", kind: .group, fields: [
                SpaceField(id: "step", name: "Step", kind: .text)
            ], isOrdered: true),
            SpaceField(id: "notes", name: "Notes", kind: .richText)
        ], collection: [
            SpaceComponent("search", ["filters": .list(["course"])]),
            SpaceComponent("cards", ["image": .text("photo"), "subtitle": .list(["time", "course"])])
        ], detail: [
            SpaceComponent("header", [
                "image": .text("photo"),
                "fields": .list(["time", "course", "source"]),
                "action": .text("cooked"),
                "actionLabel": .text("Log cooked")
            ]),
            SpaceComponent("columns", ["leading": .number(300)], children: [
                SpaceComponent("section", ["title": .text("Ingredients")], children: [
                    SpaceComponent("stepper", ["field": .text("servings"), "label": .text("Serves")]),
                    SpaceComponent("checklist", ["rows": .text("ingredients"), "scaleBy": .text("servings")])
                ]),
                SpaceComponent("section", ["title": .text("Method")], children: [
                    SpaceComponent("steps", ["rows": .text("method")])
                ])
            ]),
            SpaceComponent("fields", ["fields": .list(["notes"])]),
            SpaceComponent("section", ["title": .text("History")], children: [
                SpaceComponent("columns", ["leading": .number(300)], children: [
                    SpaceComponent("columns", children: [
                        SpaceComponent("metric", ["value": .text("count:cooked"), "label": .text("times cooked")]),
                        SpaceComponent("metric", ["value": .text("latest:cooked"), "label": .text("last cooked")])
                    ]),
                    SpaceComponent("timeline", ["events": .text("cooked")])
                ])
            ])
        ]),
        TypeDraft(key: "cooked", name: "Cooked", role: .event, fields: [
            SpaceField(id: "servings", name: "Servings", kind: .number),
            SpaceField(id: "note", name: "Note", kind: .text)
        ])
    ])

    static let habits = SpaceTemplate(id: "habits", name: "Habits", types: [
        TypeDraft(key: "habit", name: "Habits", role: .object, fields: [
            SpaceField(id: "target", name: "Target", kind: .text),
            SpaceField(id: "started", name: "Started", kind: .date),
            SpaceField(id: "active", name: "Active", kind: .boolean),
            SpaceField(id: "notes", name: "Notes", kind: .richText)
        ], collection: [
            SpaceComponent("columns", children: [
                SpaceComponent("metric", ["value": .text("today:check-in"), "label": .text("done today")]),
                SpaceComponent("metric", ["value": .text("week:check-in"), "label": .text("check-ins this week")]),
                SpaceComponent("metric", ["value": .text("records"), "label": .text("habits")])
            ]),
            SpaceComponent("section", ["title": .text("Today")], children: [
                SpaceComponent("rows", [
                    "subtitle": .list(["target"]),
                    "action": .text("check-in"),
                    "week": .text("check-in"),
                    "trail": .text("streak:check-in")
                ])
            ])
        ], detail: [
            SpaceComponent("header", [
                "fields": .list(["target", "started"]),
                "action": .text("check-in"),
                "actionLabel": .text("Check in")
            ]),
            SpaceComponent("columns", ["leading": .number(364)], children: [
                SpaceComponent("calendar", ["events": .text("check-in")]),
                SpaceComponent("section", ["title": .text("Progress")], children: [
                    SpaceComponent("columns", children: [
                        SpaceComponent("metric", ["value": .text("streak:check-in"), "label": .text("current streak")]),
                        SpaceComponent("metric", ["value": .text("best:check-in"), "label": .text("best streak")])
                    ]),
                    SpaceComponent("columns", children: [
                        SpaceComponent("metric", ["value": .text("week:check-in"), "label": .text("this week")]),
                        SpaceComponent("metric", ["value": .text("count:check-in"), "label": .text("check-ins in all")])
                    ])
                ])
            ]),
            SpaceComponent("fields", ["fields": .list(["notes"])]),
            SpaceComponent("section", ["title": .text("History")], children: [
                SpaceComponent("timeline", ["events": .text("check-in")])
            ])
        ]),
        TypeDraft(key: "check-in", name: "Check-in", role: .event, fields: [
            SpaceField(id: "minutes", name: "Minutes", kind: .number),
            SpaceField(id: "note", name: "Note", kind: .text)
        ])
    ])

    static let all = [empty, recipes, habits]
}
