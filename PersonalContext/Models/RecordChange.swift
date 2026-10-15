import Foundation
import SwiftData

/// What kind of record a change row points at.
enum ChangeKind: String, CaseIterable {
    case space, track, stop, theme, junction, requirement
    case note, decision, chat, message
    case task, taskTrackLink = "task_track_link", taskNoteLink = "task_note_link", completion, dependency
    case asset, assetReference = "asset_reference", tag, deletionMark = "deletion_mark", code, run
    case type, record, event, fact, action, source, pin, widget, cleanup

    var label: String {
        switch self {
        case .space: "Space"
        case .track: "track"
        case .stop: "stop"
        case .theme: "theme"
        case .junction: "junction"
        case .requirement: "junction requirement"
        case .note: "note"
        case .decision: "decision"
        case .chat: "chat"
        case .message: "chat message"
        case .task: "task"
        case .taskTrackLink: "task track link"
        case .taskNoteLink: "task note link"
        case .completion: "task completion"
        case .dependency: "task dependency"
        case .asset: "file"
        case .assetReference: "file reference"
        case .tag: "tag"
        case .deletionMark: "deletion mark"
        case .code: "code attachment"
        case .run: "Run"
        case .type: "type"
        case .record: "record"
        case .event: "event"
        case .fact: "fact"
        case .action: "agent action"
        case .source: "source"
        case .pin: "pin"
        case .widget: "widget"
        case .cleanup: "cleanup plan"
        }
    }
}

/// One row per record that has ever changed on this device. A later change to the same record moves
/// its row to a new sequence; a deletion keeps the row as a tombstone. Sync walks rows with a sequence
/// greater than where it last got to, reads the live record for each, and uploads it or its deletion.
@Model
final class RecordChange {
    @Attribute(.unique) var targetIDString: String
    var kindRaw: String
    /// The Space the record is in, so a per-Space sync switch can filter. Empty for records outside any Space.
    var spaceIDString: String
    var isDeletion: Bool
    /// Rises with every change on the device. Two rows never share one.
    var sequence: Int
    var changedAt: Date
    /// Who wrote: app, membrae for the in-app agent, or the name of the MCP client.
    var origin: String

    var kind: ChangeKind? { ChangeKind(rawValue: kindRaw) }
    var targetID: UUID? { UUID(uuidString: targetIDString) }
    var spaceID: UUID? { UUID(uuidString: spaceIDString) }

    /// The change in plain words: Wrote note, Deleted track.
    var sentence: String {
        let noun = kind?.label ?? kindRaw
        return (isDeletion ? "Deleted " : "Wrote ") + noun
    }

    init(kind: ChangeKind, targetID: UUID, spaceID: UUID?, isDeletion: Bool, sequence: Int, changedAt: Date, origin: String) {
        self.targetIDString = SpaceJSON.key(targetID)
        self.kindRaw = kind.rawValue
        self.spaceIDString = spaceID.map(SpaceJSON.key) ?? ""
        self.isDeletion = isDeletion
        self.sequence = sequence
        self.changedAt = changedAt
        self.origin = origin
    }
}

/// A model whose changes are recorded. Every model in the schema adopts it except the title index
/// and the change record itself; a test asserts that over `Store.models`.
protocol ChangeTracked: PersistentModel {
    static var changeKind: ChangeKind { get }
    var changeID: UUID { get }
    /// The Space the record is in. Nil for records that belong to no Space.
    var changeSpaceID: UUID? { get }
    /// Records the store removes with this one, so their rows are marked deleted whether or not
    /// SwiftData has cascaded before the save.
    var changeDependents: [any ChangeTracked] { get }
}

extension ChangeTracked {
    var changeDependents: [any ChangeTracked] { [] }
}

/// Records what a save is about to write, in rows the sync at a later stop walks.
enum ChangeLog {
    /// Who this process writes as. The app says app; the MCP helper says mcp until its client names itself.
    static var origin = "app"
    /// Off while changes that arrived from Cloudflare are applied, so they are not sent back.
    static var isRecording = true

    /// Runs `body` with the writer named `client`. An empty name keeps the current one.
    static func recording<T>(as client: String, _ body: () throws -> T) rethrows -> T {
        let previous = origin
        if !client.isEmpty { origin = client }
        defer { origin = previous }
        return try body()
    }

    static func withoutRecording<T>(_ body: () throws -> T) rethrows -> T {
        let previous = isRecording
        isRecording = false
        defer { isRecording = previous }
        return try body()
    }

    private struct Pending {
        var kind: ChangeKind
        var spaceID: UUID?
        var isDeletion: Bool
    }

    /// Runs at the top of `persist()`, before the title index, so it sees only the records themselves.
    /// Deleted wins when a record is in both lists. Existing rows are fetched in one query.
    static func record(in context: ModelContext) {
        guard isRecording else { return }
        var pending: [String: Pending] = [:]
        var deletedSpaces: [String] = []
        for model in context.deletedModelsArray {
            guard let tracked = model as? any ChangeTracked else { continue }
            note(tracked, deleted: true, into: &pending)
            if let space = tracked as? Project {
                deletedSpaces.append(SpaceJSON.key(space.id))
            }
        }
        for model in context.insertedModelsArray + context.changedModelsArray {
            guard let tracked = model as? any ChangeTracked else { continue }
            note(tracked, deleted: false, into: &pending)
        }
        write(pending, deletedSpaces: deletedSpaces, in: context)
    }

    /// Moves the rows of `records` to new sequences, as if each had just been written. Used when a
    /// Space is turned on for sync, so everything already in it is sent.
    static func touch(_ records: [any ChangeTracked], in context: ModelContext) {
        var pending: [String: Pending] = [:]
        for record in records {
            note(record, deleted: false, into: &pending)
        }
        write(pending, deletedSpaces: [], in: context)
    }

    private static func write(_ pending: [String: Pending], deletedSpaces: [String], in context: ModelContext) {
        guard !pending.isEmpty || !deletedSpaces.isEmpty else { return }

        let now = Date.now
        var sequence = latestSequence(in: context)
        let keys = pending.keys.sorted()
        var existing: [String: RecordChange] = [:]
        for row in rows(for: keys, in: context) {
            existing[row.targetIDString] = row
        }
        for key in keys {
            guard let change = pending[key] else { continue }
            sequence += 1
            if let row = existing[key] {
                row.kindRaw = change.kind.rawValue
                if let spaceID = change.spaceID { row.spaceIDString = SpaceJSON.key(spaceID) }
                row.isDeletion = change.isDeletion
                row.sequence = sequence
                row.changedAt = now
                row.origin = origin
            } else if let id = UUID(uuidString: key) {
                context.insert(RecordChange(
                    kind: change.kind,
                    targetID: id,
                    spaceID: change.spaceID,
                    isDeletion: change.isDeletion,
                    sequence: sequence,
                    changedAt: now,
                    origin: origin
                ))
            }
        }
        for spaceKey in deletedSpaces {
            for row in rows(inSpace: spaceKey, in: context) where !row.isDeletion {
                sequence += 1
                row.isDeletion = true
                row.sequence = sequence
                row.changedAt = now
                row.origin = origin
            }
        }
    }

    private static func note(_ tracked: any ChangeTracked, deleted: Bool, into pending: inout [String: Pending]) {
        let key = SpaceJSON.key(tracked.changeID)
        if let already = pending[key] {
            guard deleted, !already.isDeletion else { return }
        }
        pending[key] = Pending(kind: type(of: tracked).changeKind, spaceID: tracked.changeSpaceID, isDeletion: deleted)
        guard deleted else { return }
        for dependent in tracked.changeDependents {
            note(dependent, deleted: true, into: &pending)
        }
    }

    // MARK: Reading

    static func count(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<RecordChange>())) ?? 0
    }

    /// The newest change first.
    static var latestDescriptor: FetchDescriptor<RecordChange> {
        var descriptor = FetchDescriptor<RecordChange>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func latest(in context: ModelContext) -> RecordChange? {
        (try? context.fetch(latestDescriptor))?.first
    }

    static func latestSequence(in context: ModelContext) -> Int {
        latest(in: context)?.sequence ?? 0
    }

    /// Rows with a sequence greater than `sequence`, oldest first: what sync has not sent yet.
    static func changes(after sequence: Int, in context: ModelContext) -> [RecordChange] {
        let descriptor = FetchDescriptor<RecordChange>(
            predicate: #Predicate { $0.sequence > sequence },
            sortBy: [SortDescriptor(\.sequence)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func row(for id: UUID, in context: ModelContext) -> RecordChange? {
        rows(for: [SpaceJSON.key(id)], in: context).first
    }

    /// Every tracked record in a Space, of every kind.
    static func records(inSpace spaceID: UUID, in context: ModelContext) -> [any ChangeTracked] {
        var found: [any ChangeTracked] = []
        for model in Store.models where model is any ChangeTracked.Type {
            found += fetchAll(model, in: context).compactMap { $0 as? any ChangeTracked }.filter { $0.changeSpaceID == spaceID }
        }
        return found
    }

    private static func fetchAll<T: PersistentModel>(_: T.Type, in context: ModelContext) -> [any PersistentModel] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private static func rows(for keys: [String], in context: ModelContext) -> [RecordChange] {
        guard !keys.isEmpty else { return [] }
        let descriptor = FetchDescriptor<RecordChange>(predicate: #Predicate { keys.contains($0.targetIDString) })
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func rows(inSpace key: String, in context: ModelContext) -> [RecordChange] {
        let descriptor = FetchDescriptor<RecordChange>(predicate: #Predicate { $0.spaceIDString == key })
        return (try? context.fetch(descriptor)) ?? []
    }
}

// MARK: - Conformances

extension Project: ChangeTracked {
    static var changeKind: ChangeKind { .space }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { id }
    var changeDependents: [any ChangeTracked] {
        threads + notes + decisions + conversations + taskCompletions + deletionMarks + codeAttachments + runs + themes
    }
}

extension ProjectThread: ChangeTracked {
    static var changeKind: ChangeKind { .track }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { project?.id }
    var changeDependents: [any ChangeTracked] { children + stops + junctionsAsFirst + junctionsAsSecond }
}

extension TrackStop: ChangeTracked {
    static var changeKind: ChangeKind { .stop }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { thread?.project?.id }
}

extension TrackTheme: ChangeTracked {
    static var changeKind: ChangeKind { .theme }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { project?.id }
}

extension TrackJunction: ChangeTracked {
    static var changeKind: ChangeKind { .junction }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { first?.project?.id ?? second?.project?.id }
    var changeDependents: [any ChangeTracked] { requirements }
}

extension JunctionRequirement: ChangeTracked {
    static var changeKind: ChangeKind { .requirement }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { junction?.changeSpaceID }
}

extension Note: ChangeTracked {
    static var changeKind: ChangeKind { .note }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { project?.id }
}

extension Decision: ChangeTracked {
    static var changeKind: ChangeKind { .decision }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { project?.id }
}

extension Conversation: ChangeTracked {
    static var changeKind: ChangeKind { .chat }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { project?.id }
    var changeDependents: [any ChangeTracked] { messages }
}

extension ChatMessage: ChangeTracked {
    static var changeKind: ChangeKind { .message }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { conversation?.project?.id }
}

extension StoredAsset: ChangeTracked {
    static var changeKind: ChangeKind { .asset }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { nil }
}

extension AssetReference: ChangeTracked {
    static var changeKind: ChangeKind { .assetReference }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { nil }
}

extension Tag: ChangeTracked {
    static var changeKind: ChangeKind { .tag }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { nil }
}

extension AgendaItem: ChangeTracked {
    static var changeKind: ChangeKind { .task }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { project?.id }
    var changeDependents: [any ChangeTracked] { trackLinks + noteLinks + blockerLinks + blockingLinks }
}

extension AgendaTrackLink: ChangeTracked {
    static var changeKind: ChangeKind { .taskTrackLink }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { item?.project?.id }
}

extension AgendaNoteLink: ChangeTracked {
    static var changeKind: ChangeKind { .taskNoteLink }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { item?.project?.id }
}

extension TaskCompletion: ChangeTracked {
    static var changeKind: ChangeKind { .completion }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { project?.id }
}

extension TaskDependency: ChangeTracked {
    static var changeKind: ChangeKind { .dependency }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { blockedTask?.project?.id }
}

extension DeletionMark: ChangeTracked {
    static var changeKind: ChangeKind { .deletionMark }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { project?.id }
}

extension CodeAttachment: ChangeTracked {
    static var changeKind: ChangeKind { .code }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { project?.id }
}

extension AgentRun: ChangeTracked {
    static var changeKind: ChangeKind { .run }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { project?.id }
}

extension SpaceType: ChangeTracked {
    static var changeKind: ChangeKind { .type }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { spaceID }
}

extension SpaceRecord: ChangeTracked {
    static var changeKind: ChangeKind { .record }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { spaceID }
}

extension SpaceEvent: ChangeTracked {
    static var changeKind: ChangeKind { .event }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { spaceID }
}

extension PersonalFact: ChangeTracked {
    static var changeKind: ChangeKind { .fact }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { nil }
}

extension AgentAction: ChangeTracked {
    static var changeKind: ChangeKind { .action }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { spaceID }
}

extension SavedSource: ChangeTracked {
    static var changeKind: ChangeKind { .source }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { nil }
}

extension Pin: ChangeTracked {
    static var changeKind: ChangeKind { .pin }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { nil }
}

extension AreaWidget: ChangeTracked {
    static var changeKind: ChangeKind { .widget }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { spaceID }
}

extension CleanupPlan: ChangeTracked {
    static var changeKind: ChangeKind { .cleanup }
    var changeID: UUID { id }
    var changeSpaceID: UUID? { UUID(uuidString: projectIDString) }
}
