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
