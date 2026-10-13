import Foundation
import SwiftData

enum SpaceStoreError: LocalizedError, Equatable {
    case emptyKey
    case duplicateKey(String)
    case notAnObjectType
    case notAnEventType
    case recordOutsideSpace
    case invalidScreen([String])
    case unknownLinkTarget(field: String, target: String)
    case brokenLink(field: String, target: String)
    case oneRecordOnly(String)
    case badFormulaPath(field: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyKey: "A type needs a key."
        case .duplicateKey(let key): "This Area already has a type with the key \(key)."
        case .notAnObjectType: "Records can only be made from an object type."
        case .notAnEventType: "Events can only be logged with an event type."
        case .recordOutsideSpace: "An event can only be about records in its own Area."
        case .invalidScreen(let problems): problems.joined(separator: " ")
        case .unknownLinkTarget(let field, let target):
            "\(field) links to \(target), which is not an object type in this Area. Create that type first."
        case .brokenLink(let field, let target):
            "\(field) must hold the id of a record in \(target). Use list_space_records to find it."
        case .oneRecordOnly(let type):
            "\(type) is a settings type and has exactly one record. Use list_space_records to get it, then update_space_record."
        case .badFormulaPath(let field, let reason):
            "\(field) has a formula that does not work: \(reason)"
        }
    }
}

enum SpaceStore {
    // MARK: Spaces

    static func all(in context: ModelContext) -> [Space] {
        let descriptor = FetchDescriptor<Space>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    static func space(_ id: UUID, in context: ModelContext) -> Space? {
        let descriptor = FetchDescriptor<Space>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    static func create(
        named name: String,
        symbol: String = "square.grid.2x2",
        summary: String = "",
        gradient: String = "",
        in context: ModelContext
    ) throws -> Space {
        let space = Space(name: name, symbol: symbol, summary: summary)
        space.gradientRaw = gradient
        context.insert(space)
        try context.save()
        return space
    }

    /// Rename, re-icon, recolor, or re-describe. Nil leaves a value as it is.
    static func update(
        _ space: Space,
        name: String? = nil,
        symbol: String? = nil,
        summary: String? = nil,
        gradient: String? = nil,
        in context: ModelContext
    ) throws {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { space.name = name }
        if let symbol, !symbol.isEmpty { space.symbol = symbol }
        if let summary { space.summary = summary }
        if let gradient, SpaceGradientName.all.contains(gradient) { space.gradientRaw = gradient }
        space.touch()
        try context.save()
    }

    /// Delete means delete: the Space, its types, records, events, and every built-in record it owns.
    static func delete(_ space: Space, in context: ModelContext) throws {
        let key = SpaceJSON.key(space.id)
        events(in: space, context: context).forEach(context.delete)
        fetch(#Predicate<AreaWidget> { $0.spaceIDString == key }, in: context).forEach(context.delete)
        releaseImages(of: records(in: space, context: context), in: context)
        records(in: space, context: context).forEach(context.delete)
        types(in: space, context: context).forEach(context.delete)
        fetch(#Predicate<ProjectThread> { $0.spaceIDString == key }, in: context).forEach(context.delete)
        fetch(#Predicate<Note> { $0.spaceIDString == key }, in: context).forEach(context.delete)
        fetch(#Predicate<Decision> { $0.spaceIDString == key }, in: context).forEach(context.delete)
        fetch(#Predicate<Conversation> { $0.spaceIDString == key }, in: context).forEach(context.delete)
        fetch(#Predicate<AgendaItem> { $0.spaceIDString == key }, in: context).forEach(context.delete)
        fetch(#Predicate<AgentRun> { $0.spaceIDString == key }, in: context).forEach(context.delete)
        context.delete(space)
        try context.save()
    }

    // MARK: Built-in records

    /// A record belongs to a Project or to a Space, never both.
    static func move<Item: SpaceOwnable>(_ item: Item, to space: Space, in context: ModelContext) throws {
        item.project = nil
        item.spaceIDString = SpaceJSON.key(space.id)
        space.touch()
        try context.save()
    }

    static func tracks(in space: Space, context: ModelContext) -> [ProjectThread] {
        let key = SpaceJSON.key(space.id)
        return fetch(#Predicate<ProjectThread> { $0.spaceIDString == key }, in: context)
    }

    static func notes(in space: Space, context: ModelContext) -> [Note] {
        let key = SpaceJSON.key(space.id)
        return fetch(#Predicate<Note> { $0.spaceIDString == key }, in: context)
    }

    static func decisions(in space: Space, context: ModelContext) -> [Decision] {
        let key = SpaceJSON.key(space.id)
        return fetch(#Predicate<Decision> { $0.spaceIDString == key }, in: context)
    }

    static func conversations(in space: Space, context: ModelContext) -> [Conversation] {
        let key = SpaceJSON.key(space.id)
        return fetch(#Predicate<Conversation> { $0.spaceIDString == key }, in: context)
    }

    static func agendaItems(in space: Space, context: ModelContext) -> [AgendaItem] {
        let key = SpaceJSON.key(space.id)
        return fetch(#Predicate<AgendaItem> { $0.spaceIDString == key }, in: context)
    }

    static func runs(in space: Space, context: ModelContext) -> [AgentRun] {
        let key = SpaceJSON.key(space.id)
        return fetch(#Predicate<AgentRun> { $0.spaceIDString == key }, in: context)
    }

    // MARK: Types

    static func types(in space: Space, context: ModelContext) -> [SpaceType] {
        let key = SpaceJSON.key(space.id)
        let descriptor = FetchDescriptor<SpaceType>(
            predicate: #Predicate { $0.spaceIDString == key },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func type(_ id: UUID, in context: ModelContext) -> SpaceType? {
        let descriptor = FetchDescriptor<SpaceType>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    static func defineType(
        in space: Space,
        key: String,
        name: String,
        role: SpaceTypeRole = .object,
        schema: SpaceSchema,
        origin: SpaceTypeOrigin = .user,
        context: ModelContext
    ) throws -> SpaceType {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpaceStoreError.emptyKey }
        guard !types(in: space, context: context).contains(where: { $0.key == trimmed }) else {
            throw SpaceStoreError.duplicateKey(trimmed)
        }
        try schema.validate()
        try checkLinkTargets(of: schema, ownKey: trimmed, spaceKey: SpaceJSON.key(space.id), in: context)
        try checkFormulaPaths(of: schema, ownKey: trimmed, spaceKey: SpaceJSON.key(space.id), in: context)
        let type = SpaceType(spaceID: space.id, key: trimmed, name: name, role: role, schema: schema, origin: origin)
        context.insert(type)
        space.touch()
        try context.save()
        return type
    }

    static func apply(_ template: SpaceTemplate, to space: Space, in context: ModelContext) throws {
        for draft in template.types {
            try defineType(
                in: space,
                key: draft.key,
                name: draft.name,
                role: draft.role,
                schema: SpaceSchema(fields: draft.fields),
                context: context
            )
        }
    }

    static func eventSchemas(in spaceIDString: String, context: ModelContext) -> [String: SpaceSchema] {
        let role = SpaceTypeRole.event.rawValue
        let descriptor = FetchDescriptor<SpaceType>(predicate: #Predicate { $0.spaceIDString == spaceIDString && $0.roleRaw == role })
        return Dictionary(((try? context.fetch(descriptor)) ?? []).map { ($0.key, $0.schema) }) { first, _ in first }
    }

    static func eventKeys(in spaceIDString: String, context: ModelContext) -> Set<String> {
        let role = SpaceTypeRole.event.rawValue
        let descriptor = FetchDescriptor<SpaceType>(predicate: #Predicate { $0.spaceIDString == spaceIDString && $0.roleRaw == role })
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.key))
    }

    // MARK: Widgets

    static func widgets(in space: Space, context: ModelContext) -> [AreaWidget] {
        let key = SpaceJSON.key(space.id)
        let descriptor = FetchDescriptor<AreaWidget>(
            predicate: #Predicate { $0.spaceIDString == key },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func widget(_ id: UUID, in context: ModelContext) -> AreaWidget? {
        try? context.fetch(FetchDescriptor<AreaWidget>(predicate: #Predicate { $0.id == id })).first
    }

    /// Makes a widget, or replaces one when `existing` is given. Nothing is saved unless every block checks out.
    @discardableResult
    static func setWidget(
        _ definition: AreaWidgetDefinition,
        for type: SpaceType,
        name: String,
        size: AreaWidgetSize,
        replacing existing: AreaWidget? = nil,
        in context: ModelContext
    ) throws -> AreaWidget {
        let problems = AreaWidgetCatalog.problems(
            in: definition,
            size: size,
            schema: type.schema,
            eventKeys: eventKeys(in: type.spaceIDString, context: context),
            events: eventSchemas(in: type.spaceIDString, context: context)
        )
        guard problems.isEmpty else { throw SpaceStoreError.invalidScreen(problems) }
        let widget = existing ?? {
            let created = AreaWidget(type: type, name: name, size: size, definition: definition)
            context.insert(created)
            return created
        }()
        widget.typeIDString = SpaceJSON.key(type.id)
        widget.name = name
        widget.size = size
        widget.definition = definition
        widget.updatedAt = .now
        try context.save()
        return widget
    }

    static func delete(_ widget: AreaWidget, in context: ModelContext) throws {
        context.delete(widget)
        try context.save()
    }

    /// Replace a type's schema without losing stored values. See `SpaceSchema.replacing`.
    static func reviseSchema(of type: SpaceType, to schema: SpaceSchema, in context: ModelContext) throws {
        let merged = try schema.replacing(type.schema)
        guard merged != type.schema else { return }
        try checkLinkTargets(of: schema, ownKey: type.key, spaceKey: type.spaceIDString, in: context)
        try checkFormulaPaths(of: schema, ownKey: type.key, spaceKey: type.spaceIDString, in: context)
        type.schema = merged
        type.schemaVersion += 1
        type.updatedAt = .now
        try context.save()
    }

    /// An independent definition in the other Space. Records are not copied.
    @discardableResult
    static func copyType(_ type: SpaceType, to space: Space, in context: ModelContext) throws -> SpaceType {
        try defineType(
            in: space,
            key: type.key,
            name: type.name,
            role: type.role,
            schema: SpaceSchema(fields: type.schema.liveFields),
            origin: .copy,
            context: context
        )
    }

    static func deleteType(_ type: SpaceType, in context: ModelContext) throws {
        let key = SpaceJSON.key(type.id)
        let ownedEvents = FetchDescriptor<SpaceEvent>(predicate: #Predicate { $0.typeIDString == key })
        ((try? context.fetch(ownedEvents)) ?? []).forEach(context.delete)
        releaseImages(of: records(of: type, in: context), in: context)
        for record in records(of: type, in: context) {
            unlink(record, in: context)
            context.delete(record)
        }
        context.delete(type)
        try context.save()
    }

    // MARK: Records

    static func records(in space: Space, context: ModelContext) -> [SpaceRecord] {
        let key = SpaceJSON.key(space.id)
        return fetch(#Predicate<SpaceRecord> { $0.spaceIDString == key }, in: context)
    }

    static func records(of type: SpaceType, in context: ModelContext) -> [SpaceRecord] {
        let key = SpaceJSON.key(type.id)
        let descriptor = FetchDescriptor<SpaceRecord>(
            predicate: #Predicate { $0.typeIDString == key },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func record(_ id: UUID, in context: ModelContext) -> SpaceRecord? {
        let descriptor = FetchDescriptor<SpaceRecord>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    static func createRecord(
        of type: SpaceType,
        title: String,
        values: [String: SpaceValue] = [:],
        in context: ModelContext
    ) throws -> SpaceRecord {
        if type.role == .settings { throw SpaceStoreError.oneRecordOnly(type.name) }
        guard type.role == .object else { throw SpaceStoreError.notAnObjectType }
        try type.schema.validate(values)
        try checkLinks(in: values, schema: type.schema, spaceKey: type.spaceIDString, in: context)
        let record = SpaceRecord(type: type, title: title, values: values)
        context.insert(record)
        try context.save()
        syncImages(of: record, schema: type.schema, in: context)
        return record
    }

    /// A second record with the same values, named as a copy.
    @discardableResult
    static func duplicate(_ record: SpaceRecord, in context: ModelContext) throws -> SpaceRecord {
        guard let typeID = record.typeID, let type = type(typeID, in: context), type.role == .object else {
            throw SpaceStoreError.notAnObjectType
        }
        let copy = SpaceRecord(type: type, title: "\(record.displayTitle) copy", values: record.values)
        context.insert(copy)
        try context.save()
        syncImages(of: copy, schema: type.schema, in: context)
        return copy
    }

    /// Archiving hides a record without losing it or its history.
    static func setArchived(_ archived: Bool, on record: SpaceRecord, in context: ModelContext) throws {
        record.isArchived = archived
        record.updatedAt = .now
        try context.save()
    }

    /// The one record of a settings type, made the first time it is asked for.
    @discardableResult
    static func settingsRecord(of type: SpaceType, in context: ModelContext) throws -> SpaceRecord {
        guard type.role == .settings else { throw SpaceStoreError.notAnObjectType }
        if let existing = records(of: type, in: context).first { return existing }
        let record = SpaceRecord(type: type, title: type.name, values: [:])
        context.insert(record)
        try context.save()
        return record
    }

    /// Everything formulas in one Space can reach: its records, by id and by settings type.
    static func lookup(spaceKey: String, in context: ModelContext) -> SpaceLookup {
        SpaceLookup(
            spaceKey: spaceKey,
            records: fetch(#Predicate<SpaceRecord> { $0.spaceIDString == spaceKey }, in: context),
            types: fetch(#Predicate<SpaceType> { $0.spaceIDString == spaceKey }, in: context)
        )
    }

    /// `values` are merged over what the record holds. Pass `title` to rename it.
    static func update(
        _ record: SpaceRecord,
        title: String? = nil,
        values: [String: SpaceValue] = [:],
        in context: ModelContext
    ) throws {
        if !values.isEmpty, let typeID = record.typeID, let type = type(typeID, in: context) {
            try type.schema.validate(values)
            try checkLinks(in: values, schema: type.schema, spaceKey: type.spaceIDString, in: context)
        }
        if let title { record.title = title }
        if !values.isEmpty {
            record.values = record.values.merging(values) { _, new in new }
        }
        record.updatedAt = .now
        try context.save()
        if let typeID = record.typeID, let type = type(typeID, in: context) {
            syncImages(of: record, schema: type.schema, in: context)
        }
    }

    /// What a form saves: `values` replaces every visible field, so a cleared field loses its value.
    /// Values of removed fields are kept, because removal hides them without erasing.
    static func replaceValues(
        of record: SpaceRecord,
        title: String,
        values: [String: SpaceValue],
        in context: ModelContext
    ) throws {
        var kept: [String: SpaceValue] = [:]
        let schema = record.typeID.flatMap { type($0, in: context) }?.schema
        if let schema {
            try schema.validate(values)
            try checkLinks(in: values, schema: schema, spaceKey: record.spaceIDString, in: context)
            kept = record.values.filter { schema.field($0.key)?.isRemoved == true }
        }
        record.title = title
        record.values = kept.merging(values) { _, new in new }
        record.updatedAt = .now
        try context.save()
        if let schema {
            syncImages(of: record, schema: schema, in: context)
        }
    }

    /// The file store keeps an image for as long as some record points at it. This makes the
    /// record's claims match the asset ids its image fields hold right now.
    private static func syncImages(of record: SpaceRecord, schema: SpaceSchema, in context: ModelContext) {
        try? FileStore.default(context: context).replace(
            assetIDs: schema.imageAssetIDs(in: record.values),
            ownerKind: .spaceRecord,
            ownerID: record.id
        )
    }

    private static func releaseImages(of records: [SpaceRecord], in context: ModelContext) {
        let store = FileStore.default(context: context)
        for record in records {
            try? store.release(ownerKind: .spaceRecord, ownerID: record.id)
        }
    }

    /// Events that mention the record are kept, minus that link.
    static func delete(_ record: SpaceRecord, in context: ModelContext) throws {
        releaseImages(of: [record], in: context)
        unlink(record, in: context)
        context.delete(record)
        try context.save()
    }

    private static func unlink(_ record: SpaceRecord, in context: ModelContext) {
        for event in events(about: record, in: context) {
            event.recordIDs = event.recordIDs.filter { $0 != record.id }
        }
        // Records that linked to it lose that link, so nothing points at a record that is gone.
        let space = record.spaceIDString
        let key = SpaceJSON.key(record.id)
        let pointing = fetch(#Predicate<SpaceRecord> { $0.spaceIDString == space && $0.valuesJSON.contains(key) }, in: context)
        for other in pointing where other.id != record.id {
            guard let schema = other.typeID.flatMap({ type($0, in: context) })?.schema,
                  let cleaned = schema.removingLinks(to: key, from: other.values) else { continue }
            other.values = cleaned
        }
    }

    // MARK: Links

    /// A link field must name an object type that exists in the same Space. A type may link to itself.
    private static func checkLinkTargets(of schema: SpaceSchema, ownKey: String, spaceKey: String, in context: ModelContext) throws {
        let links = schema.linkFields.filter { !$0.isRemoved }
        guard !links.isEmpty else { return }
        let role = SpaceTypeRole.object.rawValue
        let known = Set(fetch(#Predicate<SpaceType> { $0.spaceIDString == spaceKey && $0.roleRaw == role }, in: context).map(\.key))
        for field in links where field.target != ownKey && !known.contains(field.target) {
            throw SpaceStoreError.unknownLinkTarget(field: field.name, target: field.target)
        }
    }

    /// A formula that reads `a.b` needs `a` to be a settings type, and `b` a number there.
    private static func checkFormulaPaths(of schema: SpaceSchema, ownKey: String, spaceKey: String, in context: ModelContext) throws {
        let formulas = schema.formulas
        guard formulas.contains(where: { !$0.formula.paths.isEmpty }) else { return }
        let types = fetch(#Predicate<SpaceType> { $0.spaceIDString == spaceKey }, in: context)
        for entry in formulas {
            for (head, fieldID) in entry.formula.paths {
                let targetSchema: SpaceSchema?
                let targetName: String
                if head == ownKey {
                    targetSchema = schema
                    targetName = head
                } else if let settings = types.first(where: { $0.key == head && $0.role == .settings }) {
                    targetSchema = settings.schema
                    targetName = settings.name
                } else {
                    throw SpaceStoreError.badFormulaPath(
                        field: entry.field.name,
                        reason: "\(head) is not a settings type in this Area."
                    )
                }
                guard let found = targetSchema?.liveFields.first(where: { $0.id == fieldID }), found.kind.isNumeric else {
                    throw SpaceStoreError.badFormulaPath(
                        field: entry.field.name,
                        reason: "\(targetName) has no number field \(fieldID)."
                    )
                }
            }
        }
    }

    /// Every link must hold the id of a record that exists, in this Space, of the type the field points at.
    private static func checkLinks(in values: [String: SpaceValue], schema: SpaceSchema, spaceKey: String, in context: ModelContext) throws {
        let links = schema.links(in: values)
        guard !links.isEmpty else { return }
        let types = fetch(#Predicate<SpaceType> { $0.spaceIDString == spaceKey }, in: context)
        for link in links {
            let target = types.first { $0.key == link.field.target }
            guard let target,
                  let id = UUID(uuidString: link.recordID),
                  let record = record(id, in: context),
                  record.spaceIDString == spaceKey,
                  record.typeIDString == SpaceJSON.key(target.id) else {
                throw SpaceStoreError.brokenLink(field: link.field.name, target: target?.name ?? link.field.target)
            }
        }
    }

    // MARK: Events

    static func events(in space: Space, context: ModelContext) -> [SpaceEvent] {
        let key = SpaceJSON.key(space.id)
        let descriptor = FetchDescriptor<SpaceEvent>(
            predicate: #Predicate { $0.spaceIDString == key },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Newest first.
    static func events(about record: SpaceRecord, in context: ModelContext) -> [SpaceEvent] {
        let space = record.spaceIDString
        let key = SpaceJSON.key(record.id)
        let descriptor = FetchDescriptor<SpaceEvent>(
            predicate: #Predicate { $0.spaceIDString == space && $0.recordIDsRaw.contains(key) },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    static func logEvent(
        of type: SpaceType,
        at occurredAt: Date = .now,
        values: [String: SpaceValue] = [:],
        about records: [SpaceRecord],
        in context: ModelContext
    ) throws -> SpaceEvent {
        guard type.role == .event else { throw SpaceStoreError.notAnEventType }
        guard records.allSatisfy({ $0.spaceIDString == type.spaceIDString }) else {
            throw SpaceStoreError.recordOutsideSpace
        }
        try type.schema.validate(values)
        try checkLinks(in: values, schema: type.schema, spaceKey: type.spaceIDString, in: context)
        let event = SpaceEvent(type: type, occurredAt: occurredAt, values: values, recordIDs: records.map(\.id))
        context.insert(event)
        try context.save()
        return event
    }

    /// Change when a logged event happened or what it recorded. Nil leaves a part as it is.
    static func update(
        _ event: SpaceEvent,
        at occurredAt: Date? = nil,
        values: [String: SpaceValue]? = nil,
        in context: ModelContext
    ) throws {
        if let values {
            if let typeID = event.typeID, let type = type(typeID, in: context) {
                try type.schema.validate(values)
                try checkLinks(in: values, schema: type.schema, spaceKey: type.spaceIDString, in: context)
            }
            event.values = values
        }
        if let occurredAt { event.occurredAt = occurredAt }
        try context.save()
    }

    static func event(_ id: UUID, in context: ModelContext) -> SpaceEvent? {
        let descriptor = FetchDescriptor<SpaceEvent>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    static func delete(_ event: SpaceEvent, in context: ModelContext) throws {
        context.delete(event)
        try context.save()
    }

    private static func fetch<Model: PersistentModel>(
        _ predicate: Predicate<Model>,
        in context: ModelContext
    ) -> [Model] {
        (try? context.fetch(FetchDescriptor<Model>(predicate: predicate))) ?? []
    }
}

/// Records of one Space, ready for formulas and for showing links by name.
final class SpaceLookup: SpaceFormulaSource {
    private let records: [String: SpaceRecord]
    private let schemas: [String: SpaceSchema]
    private let settingsTypeIDs: [String: String]
    private var decoded: [String: [String: SpaceValue]] = [:]
    private var filled: [String: [String: SpaceValue]] = [:]
    let titles: [String: String]

    init(spaceKey: String, records: [SpaceRecord], types: [SpaceType]) {
        var byID: [String: SpaceRecord] = [:]
        var titles: [String: String] = [:]
        for record in records where record.spaceIDString == spaceKey {
            let key = SpaceJSON.key(record.id)
            byID[key] = record
            titles[key] = record.displayTitle
        }
        var schemas: [String: SpaceSchema] = [:]
        var settings: [String: String] = [:]
        for type in types where type.spaceIDString == spaceKey {
            let key = SpaceJSON.key(type.id)
            schemas[key] = type.schema
            if type.role == .settings { settings[type.key] = key }
        }
        self.records = byID
        self.titles = titles
        self.schemas = schemas
        self.settingsTypeIDs = settings
    }

    func record(_ recordID: String) -> SpaceRecord? {
        records[recordID]
    }


    private func stored(_ key: String, _ record: SpaceRecord) -> [String: SpaceValue] {
        if let values = decoded[key] { return values }
        let values = record.values
        decoded[key] = values
        return values
    }

    func settings(_ typeKey: String) -> (schema: SpaceSchema, values: [String: SpaceValue])? {
        guard let typeID = settingsTypeIDs[typeKey], let schema = schemas[typeID] else { return nil }
        guard let found = records.first(where: { $0.value.typeIDString == typeID }) else { return (schema, [:]) }
        return (schema, stored(found.key, found.value))
    }

    /// A record's values with its calc fields worked out.
    func resolved(_ record: SpaceRecord) -> [String: SpaceValue] {
        let key = SpaceJSON.key(record.id)
        if let values = filled[key] { return values }
        let values = stored(key, record)
        let result = schemas[record.typeIDString]?.resolved(values, source: self) ?? values
        filled[key] = result
        return result
    }
}

enum FactStore {
    /// Oldest first, so the list reads in the order things were learned.
    static func all(in context: ModelContext) -> [PersonalFact] {
        let descriptor = FetchDescriptor<PersonalFact>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Returns nil for blank text. The same sentence is not stored twice.
    @discardableResult
    static func add(
        _ text: String,
        category: String = "",
        source: PersonalFactSource = .user,
        sourceChatID: UUID? = nil,
        origin: String = "",
        in context: ModelContext
    ) throws -> PersonalFact? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = all(in: context).first(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let fact = PersonalFact(
            text: trimmed,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source,
            sourceChatID: sourceChatID,
            origin: origin
        )
        context.insert(fact)
        try context.save()
        return fact
    }

    static func delete(_ fact: PersonalFact, in context: ModelContext) throws {
        context.delete(fact)
        try context.save()
    }
}
