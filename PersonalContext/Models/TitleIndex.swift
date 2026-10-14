import Foundation
import SwiftData

enum TitleIndexKind: String, CaseIterable, Identifiable, Hashable {
    case project
    case track
    case note
    case decision
    case chat
    case task
    case run

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .project: "square.stack"
        case .track: "arrow.triangle.branch"
        case .note: "note.text"
        case .decision: "checkmark.seal"
        case .chat: "bubble.left"
        case .task: "checklist"
        case .run: "play.circle"
        }
    }
}

@Model
final class TitleIndex {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var title: String
    var owner: String
    var projectIDString: String
    var parentIDString: String
    var updatedAt: Date
    var createdAt: Date
    var statusRaw: String
    var detailRaw: String
    var symbol: String
    var isArchived: Bool
    var isPinned: Bool
    var isBusy: Bool
    var isMarked: Bool

    var kind: TitleIndexKind {
        get { TitleIndexKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }

    var projectID: UUID? {
        get { UUID(uuidString: projectIDString) }
        set { projectIDString = newValue?.uuidString.lowercased() ?? "" }
    }

    var parentID: UUID? {
        get { UUID(uuidString: parentIDString) }
        set { parentIDString = newValue?.uuidString.lowercased() ?? "" }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch kind {
        case .chat: return "New chat"
        case .run: return "New run"
        default: return "Untitled"
        }
    }

    var projectStatus: ProjectStatus {
        ProjectStatus(rawValue: statusRaw) ?? .active
    }

    var threadKind: ThreadKind {
        ThreadKind(rawValue: detailRaw) ?? .topic
    }

    var threadStatus: ThreadStatus {
        ThreadStatus(rawValue: statusRaw) ?? .exploring
    }

    var decisionStatus: DecisionStatus {
        DecisionStatus(rawValue: statusRaw) ?? .active
    }

    var runStatus: RunStatus {
        RunStatus(rawValue: statusRaw) ?? .queued
    }

    var taskStatus: TaskWorkflowStatus {
        TaskWorkflowStatus(rawValue: statusRaw) ?? .ready
    }

    init(
        id: UUID,
        kind: TitleIndexKind,
        title: String,
        owner: String = "",
        projectID: UUID? = nil,
        parentID: UUID? = nil,
        updatedAt: Date,
        createdAt: Date,
        statusRaw: String = "",
        detailRaw: String = "",
        symbol: String = "",
        isArchived: Bool = false,
        isPinned: Bool = false,
        isBusy: Bool = false,
        isMarked: Bool = false
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.title = title
        self.owner = owner
        self.projectIDString = projectID?.uuidString.lowercased() ?? ""
        self.parentIDString = parentID?.uuidString.lowercased() ?? ""
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.statusRaw = statusRaw
        self.detailRaw = detailRaw
        self.symbol = symbol
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.isBusy = isBusy
        self.isMarked = isMarked
    }
}

struct TrackNode: Identifiable {
    var id: UUID
    var title: String
    var kind: ThreadKind
    var status: ThreadStatus
    var createdAt: Date
    var children: [TrackNode]
}

// MARK: - Action log

enum AgentActionVerb: String {
    case added, changed, completed, logged, flagged, tagged, untagged, removed
}

/// Who made a write: the client that connected, and the chat it came from when the app knows it.
struct ActionOrigin: Sendable {
    var client = ""
    var conversationID = ""
}

/// One write an agent made. The feed reads these, and the app takes a write back from one.
@Model
final class AgentAction {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var tool: String
    var verbRaw: String
    /// A `TitleIndexKind` raw value, or space, record, tag, code, completion.
    var kindRaw: String
    var targetIDString: String
    var title: String
    /// What the verb needs beyond the title: a tag's name, an event type, a reason.
    var detail: String
    var projectIDString: String
    var spaceIDString: String
    var client: String
    var conversationIDString: String
    /// The changed fields as they were before the write, for taking it back.
    var beforeJSON: String
    var undoneAt: Date?

    init(
        tool: String,
        verb: AgentActionVerb,
        kind: String,
        targetID: String,
        title: String,
        detail: String = "",
        projectID: String = "",
        spaceID: String = "",
        origin: ActionOrigin = ActionOrigin(),
        beforeJSON: String = ""
    ) {
        id = UUID()
        createdAt = .now
        self.tool = tool
        verbRaw = verb.rawValue
        kindRaw = kind
        targetIDString = targetID.lowercased()
        self.title = title
        self.detail = detail
        projectIDString = projectID.lowercased()
        spaceIDString = spaceID.lowercased()
        client = origin.client
        conversationIDString = origin.conversationID.lowercased()
        self.beforeJSON = beforeJSON
    }

    var verb: AgentActionVerb { AgentActionVerb(rawValue: verbRaw) ?? .changed }
    var targetID: UUID? { UUID(uuidString: targetIDString) }
    var projectID: UUID? { UUID(uuidString: projectIDString) }
    var spaceID: UUID? { UUID(uuidString: spaceIDString) }
    var indexKind: TitleIndexKind? { TitleIndexKind(rawValue: kindRaw) }

    /// Whether the app can take this write back. A later change to the same record can still block it.
    var canUndo: Bool {
        guard undoneAt == nil else { return false }
        switch verb {
        case .added: return ["task", "note", "decision", "track", "record", "source"].contains(kindRaw)
        case .changed, .completed, .logged: return !beforeJSON.isEmpty
        case .removed: return !beforeJSON.isEmpty
        default: return false
        }
    }

    var symbol: String {
        if let indexKind { return indexKind.symbol }
        switch kindRaw {
        case "space": return "square.grid.2x2"
        case "record": return "doc"
        case "source": return "books.vertical"
        case "tag": return "tag"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "circle"
        }
    }

    /// The write in plain words, such as: Added task “Buy flour”.
    var sentence: String {
        let noun = kindRaw == "chat" ? "chat" : kindRaw
        let name = title.isEmpty ? noun : "\(noun) “\(title)”"
        switch verb {
        case .added:
            if kindRaw == "source" { return "Saved \(title.isEmpty ? "a source" : "“\(title)”") to the Library" }
            return "Added \(name)"
        case .changed:
            if tool == "merge_tracks", !detail.isEmpty { return "Merged track “\(detail)” into “\(title)”" }
            if kindRaw == "space", !detail.isEmpty { return "Set up \(detail) in \(title.isEmpty ? "a Space" : title)" }
            return "Changed \(name)"
        case .completed: return "Completed \(name)"
        case .logged: return "Logged \(detail.isEmpty ? "an entry" : detail) on “\(title)”"
        case .flagged: return "Flagged \(name) for deletion"
        case .tagged: return "Tagged \(name)\(detail.isEmpty ? "" : " with \(detail)")"
        case .untagged: return "Removed tag\(detail.isEmpty ? "" : " \(detail)") from \(name)"
        case .removed: return title.isEmpty ? "Removed a \(noun)" : "Deleted \(name)"
        }
    }
}

/// What a pin can point at. A project keeps its own pinned flag.
enum PinKind: String, CaseIterable {
    case track, note, decision, chat, task, run, space, record

    init?(_ kind: TitleIndexKind) {
        guard kind != .project else { return nil }
        self.init(rawValue: kind.rawValue)
    }
}

/// Something the user pinned so it stays within reach in the sidebar.
@Model
final class Pin {
    @Attribute(.unique) var id: UUID
    var kindRaw: String = ""
    var targetIDString: String = ""
    var createdAt: Date = Date.now

    init(kind: PinKind, targetID: UUID) {
        id = UUID()
        kindRaw = kind.rawValue
        targetIDString = targetID.uuidString.lowercased()
    }

    var kind: PinKind? { PinKind(rawValue: kindRaw) }
    var targetID: UUID? { UUID(uuidString: targetIDString) }
}

enum PinStore {
    /// Every pin, oldest first.
    static func all(in context: ModelContext) -> [Pin] {
        (try? context.fetch(FetchDescriptor<Pin>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    static func toggle(_ kind: PinKind, _ id: UUID, in context: ModelContext) {
        let key = id.uuidString.lowercased()
        let existing = (try? context.fetch(FetchDescriptor<Pin>(predicate: #Predicate { $0.targetIDString == key }))) ?? []
        if existing.isEmpty {
            context.insert(Pin(kind: kind, targetID: id))
        } else {
            existing.forEach(context.delete)
        }
    }

    /// Moves in the pins an older build kept in preferences, which held ids with no kind.
    static func adopt(_ ids: [String], in context: ModelContext) {
        let known = Set(all(in: context).map(\.targetIDString))
        var made = Date.now.addingTimeInterval(-Double(ids.count))
        for key in ids where !known.contains(key) {
            guard let id = UUID(uuidString: key),
                  let row = try? context.fetch(FetchDescriptor<TitleIndex>(predicate: #Predicate { $0.id == id })).first,
                  let kind = PinKind(row.kind) else { continue }
            let pin = Pin(kind: kind, targetID: id)
            pin.createdAt = made
            made = made.addingTimeInterval(1)
            context.insert(pin)
        }
    }
}

enum AgentActionStore {
    static let limit = 2000

    static func recent(in context: ModelContext, projectID: UUID? = nil, count: Int = 10) -> [AgentAction] {
        var descriptor = FetchDescriptor<AgentAction>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let key = projectID?.uuidString.lowercased() {
            descriptor.predicate = #Predicate { $0.projectIDString == key }
        }
        descriptor.fetchLimit = count
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Drops the oldest entries once the log passes its limit.
    static func trim(in context: ModelContext) {
        guard let total = try? context.fetchCount(FetchDescriptor<AgentAction>()), total > limit else { return }
        var oldest = FetchDescriptor<AgentAction>(sortBy: [SortDescriptor(\.createdAt)])
        oldest.fetchLimit = total - limit + 200
        for action in (try? context.fetch(oldest)) ?? [] {
            context.delete(action)
        }
    }
}
