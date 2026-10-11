import Foundation
import SwiftData

enum SpaceStoreError: LocalizedError, Equatable {
    case emptyKey
    case duplicateKey(String)
    case notAnObjectType
    case notAnEventType
    case recordOutsideSpace
    case invalidScreen([String])

    var errorDescription: String? {
        switch self {
        case .emptyKey: "A type needs a key."
        case .duplicateKey(let key): "This Space already has a type with the key \(key)."
        case .notAnObjectType: "Records can only be made from an object type."
        case .notAnEventType: "Events can only be logged with an event type."
        case .recordOutsideSpace: "An event can only be about records in its own Space."
        case .invalidScreen(let problems): problems.joined(separator: " ")
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

    /// Delete means delete: the Space, its types, records, events, and every built-in record it owns.
    static func delete(_ space: Space, in context: ModelContext) throws {
        let key = SpaceJSON.key(space.id)
        events(in: space, context: context).forEach(context.delete)
        fetch(#Predicate<SpaceScreen> { $0.spaceIDString == key }, in: context).forEach(context.delete)
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
        let type = SpaceType(spaceID: space.id, key: trimmed, name: name, role: role, schema: schema, origin: origin)
        context.insert(type)
        space.touch()
        try context.save()
        return type
    }

    /// Types first, then screens, because a screen can name any event type in the Space.
    static func apply(_ template: SpaceTemplate, to space: Space, in context: ModelContext) throws {
        var made: [(SpaceTemplate.TypeDraft, SpaceType)] = []
        for draft in template.types {
            let type = try defineType(
                in: space,
                key: draft.key,
                name: draft.name,
                role: draft.role,
                schema: SpaceSchema(fields: draft.fields),
                context: context
            )
            made.append((draft, type))
        }
        for (draft, type) in made {
            if !draft.collection.isEmpty {
                try setScreen(SpaceScreenDefinition(draft.collection), for: type, kind: .collection, in: context)
            }
            if !draft.detail.isEmpty {
                try setScreen(SpaceScreenDefinition(draft.detail), for: type, kind: .detail, in: context)
            }
        }
    }

    // MARK: Screens

    static func screen(for type: SpaceType, kind: SpaceScreenKind, in context: ModelContext) -> SpaceScreen? {
        let key = SpaceJSON.key(type.id)
        let raw = kind.rawValue
        let descriptor = FetchDescriptor<SpaceScreen>(predicate: #Predicate { $0.typeIDString == key && $0.kindRaw == raw })
        return try? context.fetch(descriptor).first
    }

    static func eventKeys(in spaceIDString: String, context: ModelContext) -> Set<String> {
        let role = SpaceTypeRole.event.rawValue
        let descriptor = FetchDescriptor<SpaceType>(predicate: #Predicate { $0.spaceIDString == spaceIDString && $0.roleRaw == role })
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.key))
    }

    /// Stores a screen only if every component and binding checks out. `byAgent` also records it as
    /// the version Reset returns to.
    @discardableResult
    static func setScreen(
        _ definition: SpaceScreenDefinition,
        for type: SpaceType,
        kind: SpaceScreenKind,
        byAgent: Bool = false,
        in context: ModelContext
    ) throws -> SpaceScreen {
        let problems = SpaceScreenCatalog.problems(
            in: definition,
            kind: kind,
            schema: type.schema,
            eventKeys: eventKeys(in: type.spaceIDString, context: context)
        )
        guard problems.isEmpty else { throw SpaceStoreError.invalidScreen(problems) }
        let screen = screen(for: type, kind: kind, in: context) ?? {
            let created = SpaceScreen(type: type, kind: kind, definition: definition)
            context.insert(created)
            return created
        }()
        screen.definition = definition
        if byAgent { screen.agentJSON = screen.definitionJSON }
        screen.updatedAt = .now
        try context.save()
        return screen
    }

    /// Back to the last version an agent wrote. With none, the screen is removed and the plain view shows.
    static func resetScreen(_ screen: SpaceScreen, in context: ModelContext) throws {
        if screen.agentJSON.isEmpty {
            context.delete(screen)
        } else {
            screen.definitionJSON = screen.agentJSON
            screen.updatedAt = .now
        }
        try context.save()
    }

    /// Replace a type's schema without losing stored values. See `SpaceSchema.replacing`.
    static func reviseSchema(of type: SpaceType, to schema: SpaceSchema, in context: ModelContext) throws {
        let merged = try schema.replacing(type.schema)
        guard merged != type.schema else { return }
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
        fetch(#Predicate<SpaceScreen> { $0.typeIDString == key }, in: context).forEach(context.delete)
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
        guard type.role == .object else { throw SpaceStoreError.notAnObjectType }
        try type.schema.validate(values)
        let record = SpaceRecord(type: type, title: title, values: values)
        context.insert(record)
        try context.save()
        syncImages(of: record, schema: type.schema, in: context)
        return record
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
        let event = SpaceEvent(type: type, occurredAt: occurredAt, values: values, recordIDs: records.map(\.id))
        context.insert(event)
        try context.save()
        return event
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
            sourceChatID: sourceChatID
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
