import Foundation
import SwiftData

/// One stored value as it travels to and from Cloudflare. Dates and ids travel as text.
enum SyncValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var text: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// What a record points at: one id for a to-one relationship, ids for a to-many.
enum SyncLink: Codable, Equatable {
    case one(String)
    case many([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let ids = try? container.decode([String].self) {
            self = .many(ids)
        } else {
            self = .one(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .one(let id): try container.encode(id)
        case .many(let ids): try container.encode(ids)
        }
    }
}

/// One record as it travels between the Mac and the user's database in Cloudflare.
struct SyncRecord: Codable, Equatable {
    var kind: String
    var id: String
    var spaceID: String
    var isDeleted: Bool
    /// The device's sequence on the way up; the database's on the way down.
    var sequence: Int
    var changedAt: Date
    var origin: String
    var fields: [String: SyncValue]
    var links: [String: SyncLink]

    enum CodingKeys: String, CodingKey {
        case kind, id, sequence, origin, fields, links
        case spaceID = "space_id"
        case isDeleted = "deleted"
        case changedAt = "changed_at"
    }

    var targetID: UUID? { UUID(uuidString: id) }
    var changeKind: ChangeKind? { ChangeKind(rawValue: kind) }
}

/// What happened to one record that came down from Cloudflare.
enum SyncApplyOutcome: Equatable {
    case applied
    case deleted
    /// Left alone: the edit on this Mac is later and has not been sent yet.
    case keptLocal
    case skipped(String)
}

/// Turns tracked records into `SyncRecord`s and back, reading the schema so every model is covered
/// without a hand-written encoder each.
enum SyncCodec {
    static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let json: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dates.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = dates.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(raw)"))
            }
            return date
        }
        return decoder
    }()

    // MARK: Encoding

    /// The record a change row points at, as it is now. Nil when the record is gone and the row is not a deletion.
    static func record(for change: RecordChange, in context: ModelContext) -> SyncRecord? {
        guard let kind = change.kind, let id = change.targetID else { return nil }
        if change.isDeletion {
            return SyncRecord(
                kind: kind.rawValue, id: change.targetIDString, spaceID: change.spaceIDString, isDeleted: true,
                sequence: change.sequence, changedAt: change.changedAt, origin: change.origin, fields: [:], links: [:]
            )
        }
        guard let model = kind.find(id, in: context) else { return nil }
        return record(model, sequence: change.sequence, changedAt: change.changedAt, origin: change.origin)
    }

    static func record(_ model: any ChangeTracked, sequence: Int = 0, changedAt: Date = .now, origin: String = ChangeLog.origin) -> SyncRecord {
        var fields: [String: SyncValue] = [:]
        var links: [String: SyncLink] = [:]
        if let entity = entity(of: model) {
            let paths = keyPaths(of: model)
            for attribute in entity.attributes {
                guard let keyPath = paths[attribute.name] else { continue }
                fields[attribute.name] = value(read(model, keyPath))
            }
            for relationship in entity.relationships {
                guard let keyPath = relationship.keypath, let raw = read(model, keyPath) else { continue }
                if let one = raw as? any ChangeTracked {
                    links[relationship.name] = .one(SpaceJSON.key(one.changeID))
                } else if let many = raw as? [Any] {
                    let ids = many.compactMap { ($0 as? any ChangeTracked).map { SpaceJSON.key($0.changeID) } }
                    if !ids.isEmpty { links[relationship.name] = .many(ids) }
                }
            }
        }
        return SyncRecord(
            kind: type(of: model).changeKind.rawValue,
            id: SpaceJSON.key(model.changeID),
            spaceID: model.changeSpaceID.map(SpaceJSON.key) ?? "",
            isDeleted: false,
            sequence: sequence,
            changedAt: changedAt,
            origin: origin,
            fields: fields,
            links: links
        )
    }

    static func entity(of model: any PersistentModel) -> Schema.Entity? {
        Store.schema.entitiesByName[String(describing: type(of: model))]
    }

    private static var keyPathCache: [String: [String: AnyKeyPath]] = [:]

    /// The key path of every stored property, by name. The schema's attributes carry no key path,
    /// but the model's own metadata does, under `name` and `keypath`.
    static func keyPaths(of model: any PersistentModel) -> [String: AnyKeyPath] {
        let entityName = String(describing: type(of: model))
        if let cached = keyPathCache[entityName] { return cached }
        var paths: [String: AnyKeyPath] = [:]
        for property in type(of: model).schemaMetadata {
            var name: String?
            var keyPath: AnyKeyPath?
            for child in Mirror(reflecting: property).children {
                if child.label == "name" { name = child.value as? String }
                if child.label == "keypath" { keyPath = child.value as? AnyKeyPath }
            }
            if let name, let keyPath { paths[name] = keyPath }
        }
        keyPathCache[entityName] = paths
        return paths
    }

    private static func read<M: PersistentModel>(_ model: M, _ keyPath: AnyKeyPath) -> Any? {
        model[keyPath: keyPath]
    }

    /// Unwraps optionals, so a nil at any depth is `.null`.
    static func value(_ raw: Any?) -> SyncValue {
        guard let raw else { return .null }
        let mirror = Mirror(reflecting: raw)
        if mirror.displayStyle == .optional {
            guard let inner = mirror.children.first?.value else { return .null }
            return value(inner)
        }
        switch raw {
        case let text as String: return .string(text)
        case let flag as Bool: return .bool(flag)
        case let number as Int: return .int(number)
        case let number as Double: return .double(number)
        case let date as Date: return .string(dates.string(from: date))
        case let id as UUID: return .string(SpaceJSON.key(id))
        case let data as Data: return .string(data.base64EncodedString())
        default: return .string(String(describing: raw))
        }
    }

    // MARK: Applying

    /// Applies one record that came down. `unsentAfter` is the last sequence already pushed: a local
    /// change above it has not reached Cloudflare, and keeps if it is later than what came down.
    static func apply(_ record: SyncRecord, unsentAfter pushed: Int, in context: ModelContext) -> SyncApplyOutcome {
        guard let kind = record.changeKind else { return .skipped("Unknown kind \(record.kind)") }
        guard let id = record.targetID else { return .skipped("Bad id \(record.id)") }
        if let local = ChangeLog.row(for: id, in: context), local.sequence > pushed, local.changedAt > record.changedAt {
            return .keptLocal
        }
        let existing = kind.find(id, in: context)
        if record.isDeleted {
            guard let existing else { return .skipped("Already gone") }
            context.delete(existing)
            return .deleted
        }
        let model: any ChangeTracked
        if let existing {
            model = existing
        } else {
            guard let made = kind.make(id: id, record: record, in: context) else {
                return .skipped("Cannot create a \(kind.label) from sync yet")
            }
            context.insert(made)
            model = made
        }
        guard let entity = entity(of: model) else { return .skipped("No schema for \(record.kind)") }
        let paths = keyPaths(of: model)
        for attribute in entity.attributes {
            guard let keyPath = paths[attribute.name], let incoming = record.fields[attribute.name] else { continue }
            assign(model, keyPath, incoming, as: attribute.valueType)
        }
        for relationship in entity.relationships where relationship.isToOneRelationship {
            guard let keyPath = relationship.keypath, case .one(let targetKey)? = record.links[relationship.name],
                  let targetID = UUID(uuidString: targetKey),
                  let targetKind = ChangeKind.of(entityName: relationship.destination),
                  let target = targetKind.find(targetID, in: context) else { continue }
            link(model, keyPath, to: target)
        }
        return .applied
    }

    private static func assign(_ model: any PersistentModel, _ keyPath: AnyKeyPath, _ value: SyncValue, as type: Any.Type) {
        func open<M: PersistentModel>(_ model: M) {
            if let path = keyPath as? ReferenceWritableKeyPath<M, String>, case .string(let text) = value {
                model[keyPath: path] = text
            } else if let path = keyPath as? ReferenceWritableKeyPath<M, String?> {
                model[keyPath: path] = value.text
            } else if let path = keyPath as? ReferenceWritableKeyPath<M, Bool>, case .bool(let flag) = value {
                model[keyPath: path] = flag
            } else if let path = keyPath as? ReferenceWritableKeyPath<M, Int>, let number = int(value) {
                model[keyPath: path] = number
            } else if let path = keyPath as? ReferenceWritableKeyPath<M, Double>, let number = double(value) {
                model[keyPath: path] = number
            } else if let path = keyPath as? ReferenceWritableKeyPath<M, Date>, let date = value.text.flatMap(dates.date) {
                model[keyPath: path] = date
            } else if let path = keyPath as? ReferenceWritableKeyPath<M, Date?> {
                model[keyPath: path] = value.text.flatMap(dates.date)
            } else if let path = keyPath as? ReferenceWritableKeyPath<M, UUID>, let id = value.text.flatMap(UUID.init) {
                model[keyPath: path] = id
            } else if let path = keyPath as? ReferenceWritableKeyPath<M, UUID?> {
                model[keyPath: path] = value.text.flatMap(UUID.init)
            } else if let path = keyPath as? ReferenceWritableKeyPath<M, Data?> {
                model[keyPath: path] = value.text.flatMap { Data(base64Encoded: $0) }
            }
        }
        open(model)
    }

    private static func int(_ value: SyncValue) -> Int? {
        switch value {
        case .int(let number): number
        case .double(let number): Int(number)
        default: nil
        }
    }

    private static func double(_ value: SyncValue) -> Double? {
        switch value {
        case .int(let number): Double(number)
        case .double(let number): number
        default: nil
        }
    }

    private static func link(_ model: any PersistentModel, _ keyPath: AnyKeyPath, to target: any PersistentModel) {
        func open<M: PersistentModel, T: PersistentModel>(_ model: M, _ target: T) {
            if let path = keyPath as? ReferenceWritableKeyPath<M, T?> {
                model[keyPath: path] = target
            }
        }
        open(model, target)
    }
}

extension ChangeKind {
    /// The kind whose model is named `entityName` in the schema.
    static func of(entityName: String) -> ChangeKind? {
        for model in Store.models where String(describing: model) == entityName {
            return (model as? any ChangeTracked.Type)?.changeKind
        }
        return nil
    }

    /// The live record with this id, of this kind.
    func find(_ id: UUID, in context: ModelContext) -> (any ChangeTracked)? {
        switch self {
        case .space: first(#Predicate<Project> { $0.id == id }, in: context)
        case .track: first(#Predicate<ProjectThread> { $0.id == id }, in: context)
        case .stop: first(#Predicate<TrackStop> { $0.id == id }, in: context)
        case .theme: first(#Predicate<TrackTheme> { $0.id == id }, in: context)
        case .junction: first(#Predicate<TrackJunction> { $0.id == id }, in: context)
        case .requirement: first(#Predicate<JunctionRequirement> { $0.id == id }, in: context)
        case .note: first(#Predicate<Note> { $0.id == id }, in: context)
        case .decision: first(#Predicate<Decision> { $0.id == id }, in: context)
        case .chat: first(#Predicate<Conversation> { $0.id == id }, in: context)
        case .message: first(#Predicate<ChatMessage> { $0.id == id }, in: context)
        case .task: first(#Predicate<AgendaItem> { $0.id == id }, in: context)
        case .taskTrackLink: first(#Predicate<AgendaTrackLink> { $0.id == id }, in: context)
        case .taskNoteLink: first(#Predicate<AgendaNoteLink> { $0.id == id }, in: context)
        case .completion: first(#Predicate<TaskCompletion> { $0.id == id }, in: context)
        case .dependency: first(#Predicate<TaskDependency> { $0.id == id }, in: context)
        case .asset: first(#Predicate<StoredAsset> { $0.id == id }, in: context)
        case .assetReference: first(#Predicate<AssetReference> { $0.id == id }, in: context)
        case .tag: first(#Predicate<Tag> { $0.id == id }, in: context)
        case .deletionMark: first(#Predicate<DeletionMark> { $0.id == id }, in: context)
        case .code: first(#Predicate<CodeAttachment> { $0.id == id }, in: context)
        case .run: first(#Predicate<AgentRun> { $0.id == id }, in: context)
        case .type: first(#Predicate<SpaceType> { $0.id == id }, in: context)
        case .record: first(#Predicate<SpaceRecord> { $0.id == id }, in: context)
        case .event: first(#Predicate<SpaceEvent> { $0.id == id }, in: context)
        case .fact: first(#Predicate<PersonalFact> { $0.id == id }, in: context)
        case .action: first(#Predicate<AgentAction> { $0.id == id }, in: context)
        case .source: first(#Predicate<SavedSource> { $0.id == id }, in: context)
        case .pin: first(#Predicate<Pin> { $0.id == id }, in: context)
        case .widget: first(#Predicate<AreaWidget> { $0.id == id }, in: context)
        case .cleanup: first(#Predicate<CleanupPlan> { $0.id == id }, in: context)
        }
    }

    private func first<T: PersistentModel>(_ predicate: Predicate<T>, in context: ModelContext) -> (any ChangeTracked)? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first as? any ChangeTracked
    }

    /// A new record of this kind with `id`, its fields still to be filled from `record`. Nil for kinds
    /// nothing in Cloudflare creates: junctions, files, deletion marks, code, agent actions, cleanup plans.
    func make(id: UUID, record: SyncRecord, in context: ModelContext) -> (any ChangeTracked)? {
        func linked(_ name: String, _ kind: ChangeKind) -> (any ChangeTracked)? {
            guard case .one(let key)? = record.links[name], let target = UUID(uuidString: key) else { return nil }
            return kind.find(target, in: context)
        }
        func space() -> Project? { linked("project", .space) as? Project }
        let placeholderType = SpaceType(spaceID: UUID(), key: "", name: "", role: .object, schema: SpaceSchema(), origin: .user)
        let made: (any ChangeTracked)?
        switch self {
        case .space:
            made = Project(name: "")
        case .track:
            guard let space = space() else { return nil }
            made = ProjectThread(title: "", kind: .topic, project: space, parent: linked("parent", .track) as? ProjectThread)
        case .stop:
            guard let thread = linked("thread", .track) as? ProjectThread else { return nil }
            made = TrackStop(title: "", order: 0, thread: thread)
        case .theme:
            guard let space = space() else { return nil }
            made = TrackTheme(name: "", order: 0, project: space)
        case .note:
            guard let space = space() else { return nil }
            made = Note(content: "", project: space)
        case .decision:
            guard let space = space() else { return nil }
            made = Decision(title: "", decision: "", project: space)
        case .chat:
            made = Conversation(providerID: "", project: space())
        case .message:
            guard let conversation = linked("conversation", .chat) as? Conversation else { return nil }
            let message = ChatMessage(id: id, role: .user, content: "")
            message.conversation = conversation
            made = message
        case .task:
            made = AgendaItem(kind: .task, eventKitID: "", title: "")
        case .taskTrackLink:
            guard let thread = linked("thread", .track) as? ProjectThread else { return nil }
            made = AgendaTrackLink(thread: thread, inherited: false)
        case .taskNoteLink:
            guard let note = linked("note", .note) as? Note else { return nil }
            made = AgendaNoteLink(note: note)
        case .completion:
            guard let task = linked("parentTask", .task) as? AgendaItem else { return nil }
            made = TaskCompletion(parent: task, occurredDue: nil)
        case .dependency:
            guard let blocked = linked("blockedTask", .task) as? AgendaItem,
                  let blocking = linked("blockingTask", .task) as? AgendaItem else { return nil }
            made = TaskDependency(blocked: blocked, blocking: blocking)
        case .tag:
            made = Tag(name: "")
        case .run:
            made = AgentRun(brief: "", origin: .workspace, providerID: "", modelID: "", project: space())
        case .type:
            made = SpaceType(spaceID: UUID(), key: "", name: "", role: .object, schema: SpaceSchema(), origin: .user)
        case .record:
            made = SpaceRecord(type: placeholderType, title: "", values: [:])
        case .event:
            made = SpaceEvent(type: placeholderType, occurredAt: .now, values: [:], recordIDs: [])
        case .fact:
            made = PersonalFact(text: "")
        case .source:
            made = SavedSource(url: "")
        case .pin:
            made = Pin(kind: .note, targetID: id)
        case .widget:
            made = AreaWidget(type: placeholderType, name: "", size: .small, definition: AreaWidgetDefinition())
        case .junction, .requirement, .asset, .assetReference, .deletionMark, .code, .action, .cleanup:
            made = nil
        }
        return made
    }
}
