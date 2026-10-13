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
    /// Points at one record of another type in the same Space.
    case link
    /// A number worked out from other fields by a formula. Never typed, never stored.
    case calc
    /// How often something is meant to happen: every day, some times a week, or on set weekdays.
    case schedule
    /// Several of the field's options at once.
    case tags
    /// A web address.
    case url
    /// An amount of money, in the field's currency.
    case money
    /// A length of time, held in minutes.
    case duration
    /// A time of day, held as minutes after midnight.
    case time
    /// A first and last day.
    case dateRange
    /// One to five stars.
    case rating
    /// Any file, kept in the file store like an image.
    case file

    var id: String { rawValue }

    /// Holds a number that formulas and totals can use.
    var isNumeric: Bool {
        [.number, .quantity, .calc, .money, .duration, .rating].contains(self)
    }
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
    /// Link only: the key of the type its records come from.
    var target: String
    /// Calc only. See `SpaceFormula`.
    var formula: String
    /// Money only: a currency code such as USD. Empty uses the Mac's own.
    var unit: String
    /// What a new record starts with, as text: a number, an option id, true, or today for a date.
    var initial: String

    init(
        id: String,
        name: String,
        kind: SpaceFieldKind,
        options: [SpaceOption] = [],
        fields: [SpaceField] = [],
        isOrdered: Bool = false,
        isRemoved: Bool = false,
        target: String = "",
        formula: String = "",
        unit: String = "",
        initial: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.options = options
        self.fields = fields
        self.isOrdered = isOrdered
        self.isRemoved = isRemoved
        self.target = target
        self.formula = formula
        self.unit = unit
        self.initial = initial
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
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        formula = try container.decodeIfPresent(String.self, forKey: .formula) ?? ""
        unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? ""
        initial = try container.decodeIfPresent(String.self, forKey: .initial) ?? ""
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
    /// Text, rich text, a choice's option id, an image's asset id, or a link's record id.
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
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown Area value.")
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
    case linkNeedsTarget(String)
    case targetChanged(String)
    case badFormula(field: String, reason: String)
    case computed(String)
    case notAColumn(field: String, kind: SpaceFieldKind)

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
        case .linkNeedsTarget(let field): "\(field) is a link and needs a target: the key of the type it points at."
        case .targetChanged(let field): "\(field) already links to another type. Add a new field instead."
        case .badFormula(let field, let reason): "\(field) has a formula that does not work: \(reason)"
        case .computed(let field): "\(field) is worked out automatically and cannot be set."
        case .notAColumn(let field, let kind): "\(field) is a \(kind.rawValue) field, which cannot be a column inside a group. Put it on the record itself."
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
        for field in liveFields {
            if field.kind == .calc {
                try checkFormula(of: field, beside: liveFields)
            }
            for column in field.fields where column.kind == .calc && !column.isRemoved {
                try checkFormula(of: column, beside: field.fields.filter { !$0.isRemoved })
            }
        }
    }

    private func checkFormula(of field: SpaceField, beside siblings: [SpaceField]) throws {
        guard let formula = SpaceFormula(field.formula) else {
            throw SpaceSchemaError.badFormula(field: field.name, reason: "it could not be read. \(SpaceFormula.grammar)")
        }
        if let reason = formula.problem(beside: siblings, schema: self) {
            throw SpaceSchemaError.badFormula(field: field.name, reason: reason)
        }
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
            if field.kind == .link, field.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SpaceSchemaError.linkNeedsTarget(field.name)
            }
            if insideGroup, [.tags, .dateRange, .file, .schedule, .richText].contains(field.kind) {
                throw SpaceSchemaError.notAColumn(field: field.name, kind: field.kind)
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
            case (.calc, _):
                throw SpaceSchemaError.computed(field.name)
            case (.schedule, .text(let raw)):
                guard SpaceSchedule(raw) != nil else {
                    throw SpaceSchemaError.wrongValue(field: field.name, expected: field.kind)
                }
            case (.tags, .text(let raw)):
                for option in SpaceTags.ids(raw) where !field.options.contains(where: { $0.id == option }) {
                    throw SpaceSchemaError.unknownOption(field: field.name, option: option)
                }
            case (.dateRange, .text(let raw)):
                guard SpaceDateRange(raw) != nil else {
                    throw SpaceSchemaError.wrongValue(field: field.name, expected: field.kind)
                }
            case (.rating, .number(let stars)):
                guard (0...5).contains(stars) else {
                    throw SpaceSchemaError.wrongValue(field: field.name, expected: field.kind)
                }
            case (.url, .text), (.file, .text), (.money, .number), (.duration, .number), (.time, .number):
                break
            case (.text, .text), (.richText, .text), (.image, .text), (.link, .text),
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
                guard field.kind != .link || previous.target == field.target else {
                    throw SpaceSchemaError.targetChanged(field.name)
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

/// Card gradient names, in the order new Spaces take them. The colors live with the views.
enum SpaceGradientName {
    static let all = ["matcha", "zen", "indigo", "sand", "mochi", "iris", "tide", "graphite"]

    /// The first name no existing Space uses, then round robin.
    static func next(after used: [String]) -> String {
        all.first { !used.contains($0) } ?? all[used.count % all.count]
    }
}

enum SpaceTypeRole: String, Codable, CaseIterable, Identifiable, Hashable {
    /// A durable thing: a recipe, a habit.
    case object
    /// A logged occurrence about one or more records: cooked, checked in.
    case event
    /// One record for the whole Space: targets, preferences.
    case settings

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
    /// What the agent has learned about how the user talks about this Area: their names for things,
    /// units, standing preferences. The agent writes it; the user can read and fix it in Edit Area.
    var agentNotes: String = ""
    /// The shape of the picture on this Area's cards. Empty is landscape; "portrait" suits covers and posters.
    var cardShapeRaw: String = ""
    var createdAt: Date
    var updatedAt: Date

    /// The most an Area's notes may hold, so they stay cheap to send with every message.
    static let agentNotesLimit = 1500

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

    var hasPortraitCards: Bool {
        get { cardShapeRaw == "portrait" }
        set { cardShapeRaw = newValue ? "portrait" : "" }
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
    /// The field ids the user chose to show on this type's cards, as JSON. Empty means the app picks.
    var cardFieldsJSON: String = ""
    var createdAt: Date
    var updatedAt: Date

    var spaceID: UUID? { UUID(uuidString: spaceIDString) }

    /// The most fields a card shows under the name.
    static let cardFieldLimit = 5

    /// The fields the user chose for cards. Nil means the app picks; an empty list means none,
    /// so the card is only the picture and the name.
    var cardFields: [String]? {
        get { cardFieldsJSON.isEmpty ? nil : SpaceJSON.decode(cardFieldsJSON, as: [String].self) }
        set { cardFieldsJSON = newValue.map { SpaceJSON.encode($0) } ?? "" }
    }

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
    /// Put away without being deleted. Hidden from screens unless archived records are shown.
    var isArchived: Bool = false
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
    /// The outside assistant that said this about the user, such as ChatGPT. Empty for Membrae's own.
    var origin: String
    var createdAt: Date
    var updatedAt: Date

    var source: PersonalFactSource {
        get { PersonalFactSource(rawValue: sourceRaw) ?? .user }
        set { sourceRaw = newValue.rawValue }
    }

    var sourceChatID: UUID? { UUID(uuidString: sourceChatIDString) }

    init(text: String, category: String = "", source: PersonalFactSource = .user, sourceChatID: UUID? = nil, origin: String = "") {
        self.id = UUID()
        self.text = text
        self.category = category
        self.sourceRaw = source.rawValue
        self.sourceChatIDString = sourceChatID.map(SpaceJSON.key) ?? ""
        self.origin = origin
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
            case (.image, .text(let raw)), (.file, .text(let raw)):
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

    /// Every link a set of values holds, including link columns inside groups.
    func links(in values: [String: SpaceValue]) -> [(field: SpaceField, recordID: String)] {
        Self.links(in: values, fields: fields)
    }

    private static func links(in values: [String: SpaceValue], fields: [SpaceField]) -> [(field: SpaceField, recordID: String)] {
        var found: [(field: SpaceField, recordID: String)] = []
        for field in fields {
            switch (field.kind, values[field.id]) {
            case (.link, .text(let id)):
                found.append((field, id))
            case (.group, .rows(let rows)):
                for row in rows {
                    found += links(in: row, fields: field.fields)
                }
            default:
                break
            }
        }
        return found
    }

    var linkFields: [SpaceField] {
        fields.flatMap { $0.kind == .group ? $0.fields : [$0] }.filter { $0.kind == .link }
    }

    /// `values` without any link to `recordID`. Nil when nothing pointed at it.
    func removingLinks(to recordID: String, from values: [String: SpaceValue]) -> [String: SpaceValue]? {
        var result = values
        var changed = false
        for field in fields {
            switch (field.kind, values[field.id]) {
            case (.link, .text(recordID)):
                result[field.id] = nil
                changed = true
            case (.group, .rows(let rows)):
                let links = field.fields.filter { $0.kind == .link }.map(\.id)
                let cleaned = rows.map { row in row.filter { !(links.contains($0.key) && $0.value == .text(recordID)) } }
                if cleaned != rows {
                    result[field.id] = .rows(cleaned.filter { !$0.isEmpty })
                    changed = true
                }
            default:
                break
            }
        }
        return changed ? result : nil
    }

    /// `titles` maps record ids to names, for link fields.
    func display(_ value: SpaceValue, for field: SpaceField, titles: [String: String] = [:]) -> String {
        switch value {
        case .text(let text):
            if field.kind == .choice {
                return field.options.first { $0.id == text }?.name ?? text
            }
            if field.kind == .link {
                return titles[text] ?? "Missing record"
            }
            if field.kind == .schedule {
                return SpaceSchedule(text)?.label ?? text
            }
            if field.kind == .tags {
                return SpaceTags.ids(text).map { id in field.options.first { $0.id == id }?.name ?? id }.joined(separator: ", ")
            }
            if field.kind == .dateRange {
                return SpaceDateRange(text)?.label ?? text
            }
            if field.kind == .url {
                return URL(string: text)?.host?.replacingOccurrences(of: "www.", with: "") ?? text
            }
            // An image or file value is an asset id, which is not worth reading.
            return field.kind == .image || field.kind == .file ? "" : text
        case .number(let number):
            switch field.kind {
            case .money:
                let code = field.unit.isEmpty ? (Locale.current.currency?.identifier ?? "USD") : field.unit.uppercased()
                return number.formatted(.currency(code: code).precision(.fractionLength(0...2)))
            case .duration:
                return SpaceClock.duration(number)
            case .time:
                return SpaceClock.timeOfDay(number)
            case .rating:
                let stars = Int(number.rounded())
                return String(repeating: "★", count: max(0, min(stars, 5))) + String(repeating: "☆", count: max(0, 5 - stars))
            default:
                return number.formatted(.number.precision(.fractionLength(0...2)))
            }
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
        ]),
        TypeDraft(key: "cooked", name: "Cooked", role: .event, fields: [
            SpaceField(id: "servings", name: "Servings", kind: .number),
            SpaceField(id: "note", name: "Note", kind: .text)
        ])
    ])

    static let habits = SpaceTemplate(id: "habits", name: "Habits", types: [
        TypeDraft(key: "habit", name: "Habits", role: .object, fields: [
            SpaceField(id: "target", name: "Target", kind: .text),
            SpaceField(id: "schedule", name: "How often", kind: .schedule),
            SpaceField(id: "started", name: "Started", kind: .date),
            SpaceField(id: "active", name: "Active", kind: .boolean),
            SpaceField(id: "notes", name: "Notes", kind: .richText)
        ]),
        TypeDraft(key: "check-in", name: "Check-in", role: .event, fields: [
            SpaceField(id: "minutes", name: "Minutes", kind: .number),
            SpaceField(id: "note", name: "Note", kind: .text)
        ])
    ])

    static let all = [empty, recipes, habits]
}


/// The arithmetic behind a calc field or a progress bar.
///
/// Terms: a number, a field id beside the formula, `settingsKey.field` (a field of a settings type),
/// and `sum(group.column)`. A formula stays inside its own record: it cannot read a linked record,
/// so a value that comes from one is copied into the row when the row is added.
/// Operators: + - * / and parentheses. Ids may hold hyphens, so put spaces around a minus.
indirect enum SpaceFormula: Equatable {
    case number(Double)
    case field(String)
    case path(String, String)
    case sum(String, String)
    case binary(Character, SpaceFormula, SpaceFormula)

    static let grammar = "Use numbers, field ids, settingsKey.field, sum(group.column), + - * / and parentheses, with spaces around a minus."

    static let noLinkedReads = "is a link, and a formula cannot read the record it points at. Give the row its own number field and copy the value into it when the row is added."

    init?(_ raw: String) {
        var parser = Parser(raw)
        guard let parsed = parser.expression(), parser.atEnd else { return nil }
        self = parsed
    }

    private struct Parser {
        private var tokens: [String] = []
        private var index = 0

        init(_ raw: String) {
            let characters = Array(raw)
            var position = 0
            func isWord(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "_" }
            while position < characters.count {
                let character = characters[position]
                if character.isWhitespace {
                    position += 1
                } else if isWord(character) {
                    var word = ""
                    while position < characters.count {
                        let next = characters[position]
                        let joinsWord = (next == "-" || next == ".") && position + 1 < characters.count
                            && isWord(characters[position + 1]) && !word.isEmpty
                        guard isWord(next) || joinsWord else { break }
                        word.append(next)
                        position += 1
                    }
                    tokens.append(word)
                } else {
                    tokens.append(String(character))
                    position += 1
                }
            }
        }

        var atEnd: Bool { index == tokens.count }

        private mutating func take(_ token: String) -> Bool {
            guard index < tokens.count, tokens[index] == token else { return false }
            index += 1
            return true
        }

        mutating func expression() -> SpaceFormula? {
            guard var left = product() else { return nil }
            while index < tokens.count, tokens[index] == "+" || tokens[index] == "-" {
                let op = Character(tokens[index])
                index += 1
                guard let right = product() else { return nil }
                left = .binary(op, left, right)
            }
            return left
        }

        private mutating func product() -> SpaceFormula? {
            guard var left = term() else { return nil }
            while index < tokens.count, tokens[index] == "*" || tokens[index] == "/" {
                let op = Character(tokens[index])
                index += 1
                guard let right = term() else { return nil }
                left = .binary(op, left, right)
            }
            return left
        }

        private mutating func term() -> SpaceFormula? {
            guard index < tokens.count else { return nil }
            if take("(") {
                guard let inner = expression(), take(")") else { return nil }
                return inner
            }
            let token = tokens[index]
            index += 1
            if token == "sum" {
                guard take("("), index < tokens.count else { return nil }
                let parts = tokens[index].split(separator: ".").map(String.init)
                index += 1
                guard parts.count == 2, take(")") else { return nil }
                return .sum(parts[0], parts[1])
            }
            if let number = Double(token) { return .number(number) }
            guard let first = token.first, first.isLetter || first == "_" else { return nil }
            let parts = token.split(separator: ".").map(String.init)
            switch parts.count {
            case 1: return .field(parts[0])
            case 2: return .path(parts[0], parts[1])
            default: return nil
            }
        }
    }


    /// What is wrong with the formula as far as one type can tell. Fields of settings types are
    /// checked by the store, which can see them.
    func problem(beside siblings: [SpaceField], schema: SpaceSchema) -> String? {
        switch self {
        case .number:
            return nil
        case .field(let id):
            guard let field = siblings.first(where: { $0.id == id }) ?? schema.liveFields.first(where: { $0.id == id }) else {
                return "there is no field \(id)."
            }
            return field.kind.isNumeric ? nil : "\(field.name) is not a number."
        case .path(let head, _):
            let link = siblings.first { $0.id == head && $0.kind == .link && !$0.isRemoved }
                ?? schema.liveFields.first { $0.id == head && $0.kind == .link }
            return link.map { "\($0.name) \(Self.noLinkedReads)" }
        case .sum(let group, let column):
            guard let field = schema.liveFields.first(where: { $0.id == group }), field.kind == .group else {
                return "\(group) is not a group."
            }
            guard let found = field.fields.first(where: { $0.id == column && !$0.isRemoved }) else {
                return "\(field.name) has no column \(column)."
            }
            return found.kind.isNumeric ? nil : "\(found.name) is not a number."
        case .binary(_, let left, let right):
            return left.problem(beside: siblings, schema: schema) ?? right.problem(beside: siblings, schema: schema)
        }
    }

    /// Every `a.b` the formula reads.
    var paths: [(String, String)] {
        switch self {
        case .path(let head, let field): [(head, field)]
        case .binary(_, let left, let right): left.paths + right.paths
        default: []
        }
    }
}

/// Where a formula finds the settings it reads.
protocol SpaceFormulaSource {
    /// The one record of a settings type, by the type's key.
    func settings(_ typeKey: String) -> (schema: SpaceSchema, values: [String: SpaceValue])?
}

extension SpaceSchema {
    /// `values` with every calc field filled in, including calc columns inside groups.
    func resolved(_ values: [String: SpaceValue], source: SpaceFormulaSource?) -> [String: SpaceValue] {
        var result = values
        for field in liveFields {
            switch field.kind {
            case .calc:
                result[field.id] = number(of: field, in: values, top: values, source: source, depth: 0).map(SpaceValue.number)
            case .group:
                let columns = field.fields.filter { $0.kind == .calc && !$0.isRemoved }
                guard !columns.isEmpty, case .rows(let rows) = values[field.id] else { continue }
                result[field.id] = .rows(rows.map { row in
                    var filled = row
                    for column in columns {
                        filled[column.id] = evaluate(column, siblings: field.fields, row: row, top: values, source: source, depth: 0)
                            .map(SpaceValue.number)
                    }
                    return filled
                })
            default:
                break
            }
        }
        return result
    }

    /// One formula against a record, for components such as a progress bar.
    func value(of formula: SpaceFormula, in values: [String: SpaceValue], source: SpaceFormulaSource?) -> Double? {
        evaluate(formula, siblings: liveFields, row: values, top: values, source: source, depth: 0)
    }

    private func number(
        of field: SpaceField,
        in row: [String: SpaceValue],
        top: [String: SpaceValue],
        source: SpaceFormulaSource?,
        depth: Int
    ) -> Double? {
        evaluate(field, siblings: liveFields, row: row, top: top, source: source, depth: depth)
    }

    private func evaluate(
        _ field: SpaceField,
        siblings: [SpaceField],
        row: [String: SpaceValue],
        top: [String: SpaceValue],
        source: SpaceFormulaSource?,
        depth: Int
    ) -> Double? {
        guard let formula = SpaceFormula(field.formula) else { return nil }
        return evaluate(formula, siblings: siblings, row: row, top: top, source: source, depth: depth)
    }

    /// Nil when something the formula needs is missing, so a blank shows rather than a wrong number.
    private func evaluate(
        _ formula: SpaceFormula,
        siblings: [SpaceField],
        row: [String: SpaceValue],
        top: [String: SpaceValue],
        source: SpaceFormulaSource?,
        depth: Int
    ) -> Double? {
        guard depth < 8 else { return nil }
        switch formula {
        case .number(let number):
            return number
        case .field(let id):
            if let field = siblings.first(where: { $0.id == id && !$0.isRemoved }) {
                return plain(field, siblings: siblings, row: row, top: top, source: source, depth: depth)
            }
            guard let field = liveFields.first(where: { $0.id == id }) else { return nil }
            return plain(field, siblings: liveFields, row: top, top: top, source: source, depth: depth)
        case .path(let head, let fieldID):
            guard let found = source?.settings(head) else { return nil }
            return found.schema.evaluate(
                .field(fieldID), siblings: found.schema.liveFields, row: found.values, top: found.values, source: source, depth: depth + 1
            )
        case .sum(let groupID, let columnID):
            guard let group = liveFields.first(where: { $0.id == groupID }), case .rows(let rows) = top[groupID] else { return 0 }
            return rows.reduce(0) { total, each in
                total + (evaluate(.field(columnID), siblings: group.fields, row: each, top: top, source: source, depth: depth + 1) ?? 0)
            }
        case .binary(let op, let left, let right):
            guard let a = evaluate(left, siblings: siblings, row: row, top: top, source: source, depth: depth),
                  let b = evaluate(right, siblings: siblings, row: row, top: top, source: source, depth: depth) else { return nil }
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            default: return b == 0 ? nil : a / b
            }
        }
    }

    private func plain(
        _ field: SpaceField,
        siblings: [SpaceField],
        row: [String: SpaceValue],
        top: [String: SpaceValue],
        source: SpaceFormulaSource?,
        depth: Int
    ) -> Double? {
        if field.kind == .calc {
            return evaluate(field, siblings: siblings, row: row, top: top, source: source, depth: depth + 1)
        }
        switch row[field.id] {
        case .number(let number): return number
        case .quantity(let quantity): return quantity.amount
        default: return nil
        }
    }

    /// Every formula on the type: calc fields and calc columns.
    var formulas: [(field: SpaceField, siblings: [SpaceField], formula: SpaceFormula)] {
        var found: [(field: SpaceField, siblings: [SpaceField], formula: SpaceFormula)] = []
        for field in liveFields {
            if field.kind == .calc, let formula = SpaceFormula(field.formula) {
                found.append((field, liveFields, formula))
            }
            for column in field.fields where column.kind == .calc && !column.isRemoved {
                if let formula = SpaceFormula(column.formula) {
                    found.append((column, field.fields, formula))
                }
            }
        }
        return found
    }
}


/// How often a record is meant to be logged. Stored as text: `daily`, `weekly:3`, or `days:mon,wed,fri`.
struct SpaceSchedule: Equatable {
    enum Rule: Equatable {
        case daily
        /// Any days, this many times in a calendar week.
        case perWeek(Int)
        /// Calendar weekday numbers, 1 for Sunday.
        case weekdays(Set<Int>)
    }

    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    var rule: Rule

    init(_ rule: Rule) {
        self.rule = rule
    }

    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == "daily" {
            rule = .daily
        } else if text.hasPrefix("weekly:"), let times = Int(text.dropFirst(7)), (1...7).contains(times) {
            rule = times == 7 ? .daily : .perWeek(times)
        } else if text.hasPrefix("days:") {
            let days = text.dropFirst(5).split(separator: ",").map { String($0.prefix(3)) }
            let numbers = days.compactMap { Self.dayNames.firstIndex(of: $0).map { $0 + 1 } }
            guard !numbers.isEmpty, numbers.count == days.count else { return nil }
            rule = numbers.count == 7 ? .daily : .weekdays(Set(numbers))
        } else {
            return nil
        }
    }

    var raw: String {
        switch rule {
        case .daily: "daily"
        case .perWeek(let times): "weekly:\(times)"
        case .weekdays(let days): "days:" + days.sorted().map { Self.dayNames[$0 - 1] }.joined(separator: ",")
        }
    }

    var label: String {
        switch rule {
        case .daily: "Every day"
        case .perWeek(let times): times == 1 ? "Once a week" : "\(times) times a week"
        case .weekdays(let days): days.sorted().map { Self.dayNames[$0 - 1].capitalized }.joined(separator: ", ")
        }
    }

    /// Whether `day` is one it is meant to happen on. A times-a-week rule is open every day.
    func isDue(on day: Date, calendar: Calendar = .current) -> Bool {
        if case .weekdays(let days) = rule {
            return days.contains(calendar.component(.weekday, from: day))
        }
        return true
    }
}


/// Several option ids held as one comma-separated text value.
enum SpaceTags {
    static func ids(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func raw(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }
}

/// A first and last day, held as text: `2026-10-11/2026-10-14`.
struct SpaceDateRange: Equatable {
    var start: Date
    var end: Date

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    init(start: Date, end: Date) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    init?(_ raw: String) {
        let parts = raw.split(separator: "/").map(String.init)
        let formatter = Self.formatter()
        guard parts.count == 2, let start = formatter.date(from: parts[0]), let end = formatter.date(from: parts[1]) else { return nil }
        self.init(start: start, end: end)
    }

    var raw: String {
        let formatter = Self.formatter()
        return "\(formatter.string(from: start))/\(formatter.string(from: end))"
    }

    var label: String {
        let first = start.formatted(.dateTime.month(.abbreviated).day())
        let last = end.formatted(.dateTime.month(.abbreviated).day().year())
        return Calendar.current.isDate(start, inSameDayAs: end) ? last : "\(first) to \(last)"
    }
}

enum SpaceClock {
    /// Minutes as `1h 30m`.
    static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let hours = total / 60
        let rest = total % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// Minutes after midnight as the Mac writes a time.
    static func timeOfDay(_ minutes: Double) -> String {
        date(minutes).formatted(date: .omitted, time: .shortened)
    }

    static func date(_ minutes: Double) -> Date {
        Calendar.current.startOfDay(for: .now).addingTimeInterval(minutes * 60)
    }

    static func minutes(_ date: Date) -> Double {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}

extension SpaceSchema {
    /// What a new record starts with, from each field's `initial`. Anything unreadable is skipped.
    func defaults(now: Date = .now) -> [String: SpaceValue] {
        var values: [String: SpaceValue] = [:]
        for field in liveFields where !field.initial.isEmpty {
            let raw = field.initial
            switch field.kind {
            case .text, .richText, .url:
                values[field.id] = .text(raw)
            case .number, .money, .duration, .time, .rating:
                if let number = Double(raw) { values[field.id] = .number(number) }
            case .boolean:
                values[field.id] = .boolean(raw.lowercased() == "true")
            case .date:
                if raw.lowercased() == "today" { values[field.id] = .date(Calendar.current.startOfDay(for: now)) }
            case .choice:
                if field.options.contains(where: { $0.id == raw }) { values[field.id] = .text(raw) }
            case .tags:
                let ids = SpaceTags.ids(raw).filter { id in field.options.contains { $0.id == id } }
                if !ids.isEmpty { values[field.id] = .text(SpaceTags.raw(ids)) }
            case .schedule:
                if let schedule = SpaceSchedule(raw) { values[field.id] = .text(schedule.raw) }
            default:
                break
            }
        }
        return values
    }
}
