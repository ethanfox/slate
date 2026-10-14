import Foundation
import SwiftData

enum ProjectStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case active
    case paused
    case done

    var id: String { rawValue }

    var label: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .done: "Done"
        }
    }

    var symbol: String {
        switch self {
        case .active: "play.circle"
        case .paused: "pause.circle"
        case .done: "checkmark.circle"
        }
    }
}

enum ThreadKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case direction
    case feature
    case problem
    case experiment
    case topic

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ThreadStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case exploring
    case active
    case paused
    case completed
    case rejected

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var isCurrent: Bool {
        self == .exploring || self == .active
    }
}

enum DecisionStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case active
    case superseded

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum MessageRole: String, Codable, Hashable {
    case user
    case assistant
}

/// Every Space is one of these. What a Space can hold is its capabilities: one that collects
/// records is what used to be an Area, and the code still calls it `Space`.
typealias Space = Project

@Model
final class Project: Identifiable {
    var id: UUID
    var name: String
    var symbol: String
    var summary: String
    var currentDirection: String
    /// One sentence Membrae writes on what the user is doing in this project now. It leads the project's page.
    var brief: String = ""
    var statusRaw: String
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Capabilities, as `SpaceBuiltInKind` raw values. `records` makes this a Space that collects.
    var enabledKindsRaw: String = ""
    /// A `SpaceGradient` name. Empty falls back to one picked from the id.
    var gradientRaw: String = ""
    /// What the agent has learned about how the user talks about this Space: their names for things,
    /// units, standing preferences. The agent writes it; the user can read and fix it in Edit Area.
    var agentNotes: String = ""
    /// The shape of the picture on this Space's cards. Empty is landscape; "portrait" suits covers and posters.
    var cardShapeRaw: String = ""

    @Relationship(deleteRule: .cascade, inverse: \ProjectThread.project)
    var threads: [ProjectThread] = []

    @Relationship(deleteRule: .cascade, inverse: \Note.project)
    var notes: [Note] = []

    /// Library sources linked to this project. A source can be linked to several projects.
    @Relationship(inverse: \SavedSource.projects)
    var sources: [SavedSource] = []

    @Relationship(deleteRule: .cascade, inverse: \Decision.project)
    var decisions: [Decision] = []

    @Relationship(deleteRule: .cascade, inverse: \Conversation.project)
    var conversations: [Conversation] = []

    @Relationship(deleteRule: .nullify, inverse: \AgendaItem.project)
    var agendaItems: [AgendaItem] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskCompletion.project)
    var taskCompletions: [TaskCompletion] = []

    @Relationship(deleteRule: .cascade, inverse: \DeletionMark.project)
    var deletionMarks: [DeletionMark] = []

    @Relationship(deleteRule: .cascade, inverse: \CodeAttachment.project)
    var codeAttachments: [CodeAttachment] = []

    @Relationship(deleteRule: .cascade, inverse: \AgentRun.project)
    var runs: [AgentRun] = []

    @Relationship(deleteRule: .cascade, inverse: \TrackTheme.project)
    var themes: [TrackTheme] = []

    var orderedThemes: [TrackTheme] {
        themes.sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    var overviewWidthRaw: String = "twoThirds"
    var overviewLayoutJSON: String = ""
    var workerProviderID: String = ""
    var workerModelID: String = ""
    var workerPath: String = ""
    /// The one track this project is being worked on. It sets what the task board shows and which task is Next.
    var activeTrackID: UUID?

    var activeTrack: ProjectThread? {
        guard let activeTrackID else { return nil }
        return threads.first { $0.id == activeTrackID }
    }

    var status: ProjectStatus {
        get { ProjectStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var rootThreads: [ProjectThread] {
        threads
            .filter { $0.parent == nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var displayName: String {
        name.isEmpty ? "Untitled" : name
    }

    var lastActivity: Date {
        let dates = [updatedAt]
            + notes.map(\.updatedAt)
            + decisions.map(\.createdAt)
            + threads.map(\.updatedAt)
            + conversations.map(\.updatedAt)
            + runs.map(\.updatedAt)
        return dates.max() ?? updatedAt
    }

    /// The most a Space's notes may hold, so they stay cheap to send with every message.
    static let agentNotesLimit = 1500

    /// Spaces that collect records: what the sidebar and the tools call Areas.
    static let collecting = #Predicate<Project> { $0.enabledKindsRaw.contains("records") }

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

    var collects: Bool { enabledKinds.contains(.records) }

    var hasPortraitCards: Bool {
        get { cardShapeRaw == "portrait" }
        set { cardShapeRaw = newValue ? "portrait" : "" }
    }

    init(name: String, symbol: String = "square.grid.2x2", summary: String = "") {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.summary = summary
        self.currentDirection = ""
        self.statusRaw = ProjectStatus.active.rawValue
        self.isPinned = false
        self.createdAt = .now
        self.updatedAt = .now
        self.overviewWidthRaw = "twoThirds"
        self.overviewLayoutJSON = ""
    }

    func touch() {
        updatedAt = .now
    }
}

enum CodeAttachmentKind: String, CaseIterable, Identifiable {
    case folder
    case github
    case gitlab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "Folder"
        case .github: "GitHub"
        case .gitlab: "GitLab"
        }
    }
}

extension CodeAttachment {
    /// Fetched, not walked from the project, so a just-added attachment is seen.
    static func all(on project: Project, in context: ModelContext) -> [CodeAttachment] {
        let id = project.id
        let found = ((try? context.fetch(FetchDescriptor<CodeAttachment>())) ?? []).filter { $0.project?.id == id }
        return found.isEmpty ? project.codeAttachments : found
    }

    static func find(_ id: UUID, in context: ModelContext) -> CodeAttachment? {
        try? context.fetch(FetchDescriptor<CodeAttachment>(predicate: #Predicate { $0.id == id })).first
    }
}

@Model
final class CodeAttachment {
    var id: UUID
    var kindRaw: String
    var title: String
    var locator: String
    var bookmark: Data?
    var defaultBranch: String
    var tokenID: String = ""
    var createdAt: Date

    var project: Project?

    var kind: CodeAttachmentKind {
        get { CodeAttachmentKind(rawValue: kindRaw) ?? .folder }
        set { kindRaw = newValue.rawValue }
    }

    var subtitle: String {
        switch kind {
        case .folder: locator
        case .github, .gitlab: defaultBranch.isEmpty ? locator : "\(locator) · \(defaultBranch)"
        }
    }

    init(kind: CodeAttachmentKind, title: String, locator: String, bookmark: Data? = nil, defaultBranch: String = "", tokenID: String = "", project: Project) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.title = title
        self.locator = locator
        self.bookmark = bookmark
        self.defaultBranch = defaultBranch
        self.tokenID = tokenID
        self.createdAt = .now
        self.project = project
    }
}

@Model
final class ProjectThread {
    var id: UUID
    var kindRaw: String
    var title: String
    var summary: String
    var body: String
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date
    var project: Project?
    var parent: ProjectThread?
    var spaceIDString: String = ""
    /// The group this track is listed under.
    var theme: TrackTheme?

    @Relationship(deleteRule: .cascade, inverse: \ProjectThread.parent)
    var children: [ProjectThread] = []

    @Relationship(deleteRule: .nullify, inverse: \Note.thread)
    var notes: [Note] = []

    @Relationship(deleteRule: .nullify, inverse: \Decision.thread)
    var decisions: [Decision] = []

    @Relationship(deleteRule: .nullify, inverse: \Conversation.thread)
    var conversations: [Conversation] = []

    @Relationship(inverse: \Tag.threads)
    var tags: [Tag] = []

    @Relationship(deleteRule: .nullify, inverse: \AgendaTrackLink.thread)
    var agendaTrackLinks: [AgendaTrackLink] = []

    @Relationship(deleteRule: .cascade, inverse: \TrackStop.thread)
    var stops: [TrackStop] = []

    var orderedStops: [TrackStop] {
        stops.sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    /// Junctions where this track is the first: the one waited on, or the one a merge continues as.
    @Relationship(deleteRule: .cascade, inverse: \TrackJunction.first)
    var junctionsAsFirst: [TrackJunction] = []

    /// Junctions where this track is the second: the one that waits, or the one a merge folds in.
    @Relationship(deleteRule: .cascade, inverse: \TrackJunction.second)
    var junctionsAsSecond: [TrackJunction] = []

    var junctions: [TrackJunction] {
        (junctionsAsFirst + junctionsAsSecond).sorted { $0.createdAt < $1.createdAt }
    }

    var kind: ThreadKind {
        get { ThreadKind(rawValue: kindRaw) ?? .topic }
        set { kindRaw = newValue.rawValue }
    }

    var status: ThreadStatus {
        get { ThreadStatus(rawValue: statusRaw) ?? .exploring }
        set { statusRaw = newValue.rawValue }
    }

    var orderedChildren: [ProjectThread] {
        children.sorted { $0.createdAt < $1.createdAt }
    }

    var deletionTargetIDs: [UUID] {
        [id] + children.flatMap(\.deletionTargetIDs)
    }

    init(title: String, kind: ThreadKind, project: Project, parent: ProjectThread? = nil) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.title = title
        self.summary = ""
        self.body = ""
        self.statusRaw = ThreadStatus.exploring.rawValue
        self.createdAt = .now
        self.updatedAt = .now
        self.project = project
        self.parent = parent
    }

    func contains(_ other: ProjectThread) -> Bool {
        if id == other.id { return true }
        var cursor: ProjectThread? = other.parent
        var guardrail = 0
        while let current = cursor, guardrail < 32 {
            if current.id == id { return true }
            cursor = current.parent
            guardrail += 1
        }
        return false
    }
}

/// A named group of tracks. It holds no work of its own: no tasks, no stops, and it cannot be active.
@Model
final class TrackTheme: Identifiable {
    var id: UUID
    var name: String
    var order: Int
    var createdAt: Date
    var project: Project?

    @Relationship(deleteRule: .nullify, inverse: \ProjectThread.theme)
    var tracks: [ProjectThread] = []

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    init(name: String, order: Int, project: Project) {
        self.id = UUID()
        self.name = name
        self.order = order
        self.createdAt = .now
        self.project = project
    }
}

/// One idea inside a track. A track's stops are in the order they are to be worked on.
@Model
final class TrackStop: Identifiable {
    var id: UUID
    var title: String
    var body: String
    var order: Int
    var isDone: Bool
    var createdAt: Date
    var updatedAt: Date
    var thread: ProjectThread?

    @Relationship(deleteRule: .nullify, inverse: \AgendaItem.stop)
    var tasks: [AgendaItem] = []

    @Relationship(deleteRule: .nullify, inverse: \JunctionRequirement.stop)
    var requirements: [JunctionRequirement] = []

    @Relationship(deleteRule: .nullify, inverse: \TrackJunction.heldStop)
    var heldBy: [TrackJunction] = []

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    init(title: String, body: String = "", order: Int, thread: ProjectThread) {
        self.id = UUID()
        self.title = title
        self.body = body
        self.order = order
        self.isDone = false
        self.createdAt = .now
        self.updatedAt = .now
        self.thread = thread
    }
}

enum JunctionKind: String, CaseIterable, Identifiable {
    case wait
    case merge

    var id: String { rawValue }
}

/// Sits between two tracks. A wait holds the second track until the first has done what the junction requires.
/// A merge lists what has to be reconciled between the two before they become one track.
@Model
final class TrackJunction: Identifiable {
    var id: UUID
    var kindRaw: String
    var createdAt: Date
    var updatedAt: Date
    /// The track waited on, or the track a merge continues as.
    var first: ProjectThread?
    /// The track that waits, or the track a merge folds in.
    var second: ProjectThread?
    /// On a wait, the stop on the second track that cannot start. Nil holds the whole track.
    var heldStop: TrackStop?

    @Relationship(deleteRule: .cascade, inverse: \JunctionRequirement.junction)
    var requirements: [JunctionRequirement] = []

    var kind: JunctionKind {
        get { JunctionKind(rawValue: kindRaw) ?? .wait }
        set { kindRaw = newValue.rawValue }
    }

    var orderedRequirements: [JunctionRequirement] {
        requirements.sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    /// A wait with nothing listed is met when the first track is completed. A merge has to list what it reconciles.
    var isMet: Bool {
        if requirements.isEmpty {
            return kind == .wait && first?.status == .completed
        }
        return requirements.allSatisfy(\.isMet)
    }

    func other(than track: ProjectThread) -> ProjectThread? {
        first?.id == track.id ? second : first
    }

    init(kind: JunctionKind, first: ProjectThread, second: ProjectThread, heldStop: TrackStop? = nil) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.createdAt = .now
        self.updatedAt = .now
        self.first = first
        self.second = second
        self.heldStop = heldStop
    }
}

/// One thing a junction needs. Tied to a stop or a task, it is met when that is done; otherwise it is ticked by hand.
@Model
final class JunctionRequirement: Identifiable {
    var id: UUID
    var text: String
    var order: Int
    var isChecked: Bool
    var createdAt: Date
    var junction: TrackJunction?
    var stop: TrackStop?
    var task: AgendaItem?

    var isMet: Bool {
        if let stop { return stop.isDone }
        if let task { return task.isCompleted }
        return isChecked
    }

    var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return stop?.displayTitle ?? task?.displayTitle ?? "Untitled"
    }

    init(text: String, order: Int, junction: TrackJunction, stop: TrackStop? = nil, task: AgendaItem? = nil) {
        self.id = UUID()
        self.text = text
        self.order = order
        self.isChecked = false
        self.createdAt = .now
        self.junction = junction
        self.stop = stop
        self.task = task
    }
}

/// One change a cleanup would make, in words the user can judge.
struct CleanupChange: Codable, Identifiable, Hashable {
    enum Action: String, Codable {
        case mergeTracks = "merge_tracks"
        case delete
        case retireDecision = "retire_decision"
    }

    var id = UUID()
    var action: Action
    /// track, task, note, or decision.
    var targetType: String
    var targetID: String
    /// For a merge, the track that continues.
    var intoID = ""
    var title: String
    var intoTitle = ""
    var reason: String
    var isAccepted = true
    /// Empty until applied, then "done" or why it could not be done.
    var outcome = ""

    var sentence: String {
        switch action {
        case .mergeTracks: "Merge “\(title)” into “\(intoTitle)”"
        case .delete: "Delete \(targetType) “\(title)”"
        case .retireDecision: "Retire decision “\(title)”"
        }
    }
}

enum CleanupPlanStatus: String {
    case proposed, applied, dismissed
}

/// What Membrae proposes to tidy in one project. Nothing changes until the user applies it.
@Model
final class CleanupPlan: Identifiable {
    var id: UUID
    var projectIDString: String
    var createdAt: Date
    var statusRaw: String
    var summary: String
    var changesJSON: String
    var client: String

    var status: CleanupPlanStatus {
        get { CleanupPlanStatus(rawValue: statusRaw) ?? .proposed }
        set { statusRaw = newValue.rawValue }
    }

    var changes: [CleanupChange] {
        get { SpaceJSON.decode(changesJSON, as: [CleanupChange].self) ?? [] }
        set { changesJSON = SpaceJSON.encode(newValue) }
    }

    init(project: Project, summary: String, changes: [CleanupChange], client: String) {
        self.id = UUID()
        self.projectIDString = project.id.uuidString.lowercased()
        self.createdAt = .now
        self.statusRaw = CleanupPlanStatus.proposed.rawValue
        self.summary = summary
        self.changesJSON = SpaceJSON.encode(changes)
        self.client = client
    }
}

enum SavedSourceKind: String, CaseIterable {
    case link, pdf, file, image

    var symbol: String {
        switch self {
        case .link: "link"
        case .pdf: "doc.richtext"
        case .file: "doc"
        case .image: "photo"
        }
    }

    var label: String {
        switch self {
        case .link: "Link"
        case .pdf: "PDF"
        case .file: "File"
        case .image: "Image"
        }
    }
}

/// Something saved to the Library: a link, a PDF, or an article, with its text kept for search.
@Model
final class SavedSource {
    @Attribute(.unique) var id: UUID
    var url: String = ""
    var title: String = ""
    var summary: String = ""
    /// The readable text of the page or file.
    var text: String = ""
    var kindRaw: String = SavedSourceKind.link.rawValue
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var readAt: Date?
    /// When the app last tried to fetch the text, so a dead link is not fetched forever.
    var fetchedAt: Date?
    var isArchived: Bool = false
    var projects: [Project] = []

    var kind: SavedSourceKind {
        get { SavedSourceKind(rawValue: kindRaw) ?? .link }
        set { kindRaw = newValue.rawValue }
    }

    var host: String {
        guard let host = URL(string: url)?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return host.isEmpty ? "Untitled" : host
    }

    /// The summary, or the start of the text when nothing has summarized it yet.
    var blurb: String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        return [title, summary, url, text].contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    init(url: String, title: String = "", summary: String = "", text: String = "", kind: SavedSourceKind = .link) {
        id = UUID()
        self.url = url
        self.title = title
        self.summary = summary
        self.text = text
        kindRaw = kind.rawValue
    }
}

@Model
final class Note {
    var id: UUID
    var title: String
    var content: String
    var source: String
    var createdAt: Date
    var updatedAt: Date
    var project: Project?
    var thread: ProjectThread?
    var spaceIDString: String = ""

    @Relationship(inverse: \Tag.notes)
    var tags: [Tag] = []

    @Relationship(deleteRule: .nullify, inverse: \AgendaNoteLink.note)
    var agendaNoteLinks: [AgendaNoteLink] = []

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    init(content: String, project: Project, title: String = "", source: String = "", thread: ProjectThread? = nil) {
        self.id = UUID()
        self.title = title
        self.content = content
        self.source = source
        self.createdAt = .now
        self.updatedAt = .now
        self.project = project
        self.thread = thread
    }
}

@Model
final class Decision {
    var id: UUID
    var title: String
    var decision: String
    var rationale: String
    var statusRaw: String
    var supersededByID: UUID?
    var createdAt: Date
    var project: Project?
    var thread: ProjectThread?
    var spaceIDString: String = ""

    @Relationship(inverse: \Tag.decisions)
    var tags: [Tag] = []

    var status: DecisionStatus {
        get { DecisionStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    init(title: String, decision: String, project: Project, rationale: String = "", thread: ProjectThread? = nil) {
        self.id = UUID()
        self.title = title
        self.decision = decision
        self.rationale = rationale
        self.statusRaw = DecisionStatus.active.rawValue
        self.supersededByID = nil
        self.createdAt = .now
        self.project = project
        self.thread = thread
    }
}

enum DeletionTargetKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case note
    case thread = "track"
    case decision
    case conversation

    var id: String { rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "note": self = .note
        case "track", "thread": self = .thread
        case "decision": self = .decision
        case "conversation": self = .conversation
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .note: "Note"
        case .thread: "Track"
        case .decision: "Decision"
        case .conversation: "Chat"
        }
    }
}

@Model
final class DeletionMark {
    var id: UUID
    var targetKindRaw: String
    var targetID: UUID
    var reason: String
    var replacementKindRaw: String
    var replacementID: UUID?
    var createdAt: Date
    var project: Project?

    var targetKind: DeletionTargetKind {
        get { DeletionTargetKind(rawValue: targetKindRaw) ?? .note }
        set { targetKindRaw = newValue.rawValue }
    }

    var replacementKind: DeletionTargetKind? {
        get { DeletionTargetKind(rawValue: replacementKindRaw) }
        set { replacementKindRaw = newValue?.rawValue ?? "" }
    }

    init(
        targetKind: DeletionTargetKind,
        targetID: UUID,
        reason: String,
        project: Project,
        replacementKind: DeletionTargetKind? = nil,
        replacementID: UUID? = nil
    ) {
        self.id = UUID()
        self.targetKindRaw = targetKind.rawValue
        self.targetID = targetID
        self.reason = reason
        self.replacementKindRaw = replacementKind?.rawValue ?? ""
        self.replacementID = replacementID
        self.createdAt = .now
        self.project = project
    }
}

enum DeletionMarks {
    static func existing(for targetID: UUID, in project: Project) -> DeletionMark? {
        project.deletionMarks.first { $0.targetID == targetID }
    }

    static func existing(for targetID: UUID, in context: ModelContext) -> DeletionMark? {
        let id = targetID
        return try? context.fetch(FetchDescriptor<DeletionMark>(predicate: #Predicate { $0.targetID == id })).first
    }

    static func upsert(
        targetKind: DeletionTargetKind,
        targetID: UUID,
        reason: String,
        project: Project,
        replacementKind: DeletionTargetKind?,
        replacementID: UUID?,
        in context: ModelContext
    ) -> DeletionMark {
        if let mark = existing(for: targetID, in: project) {
            mark.reason = reason
            mark.replacementKind = replacementKind
            mark.replacementID = replacementID
            return mark
        }
        let mark = DeletionMark(
            targetKind: targetKind,
            targetID: targetID,
            reason: reason,
            project: project,
            replacementKind: replacementKind,
            replacementID: replacementID
        )
        context.insert(mark)
        return mark
    }

    static func keep(_ mark: DeletionMark, in context: ModelContext) {
        context.delete(mark)
    }

    static func remove(targetingIDs ids: [UUID], in context: ModelContext) {
        guard !ids.isEmpty else { return }
        let marks = (try? context.fetch(FetchDescriptor<DeletionMark>())) ?? []
        for mark in marks where ids.contains(mark.targetID) {
            context.delete(mark)
        }
    }
}

@Model
final class Conversation {
    var id: UUID
    var providerID: String = "cursor"
    @Attribute(originalName: "cursorAgentId") var externalSessionID: String
    var title: String
    @Attribute(originalName: "model") var modelID: String
    var contextSnapshot: String
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    var project: Project?
    var thread: ProjectThread?
    var spaceIDString: String = ""

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []

    @Relationship(deleteRule: .nullify, inverse: \AgentRun.originChat)
    var originatedRuns: [AgentRun] = []

    @Relationship(inverse: \Tag.conversations)
    var tags: [Tag] = []

    var orderedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    init(title: String = "New chat", providerID: String, modelID: String = "", project: Project? = nil) {
        self.id = UUID()
        self.providerID = providerID
        self.externalSessionID = ""
        self.title = title
        self.modelID = modelID
        self.contextSnapshot = ""
        self.isArchived = false
        self.createdAt = .now
        self.updatedAt = .now
        self.project = project
    }
}

@Model
final class ChatMessage {
    var id: UUID
    var roleRaw: String
    var content: String
    @Attribute(originalName: "cursorRunId") var externalRunID: String
    var createdAt: Date
    var conversation: Conversation?

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), role: MessageRole, content: String) {
        self.id = id
        self.roleRaw = role.rawValue
        self.content = content
        self.externalRunID = ""
        self.createdAt = .now
    }
}

enum AgendaKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case reminder
    case event
    case task

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reminder: "Reminder"
        case .event: "Event"
        case .task: "Task"
        }
    }
}

enum TaskRepeat: String, CaseIterable, Identifiable, Hashable {
    case none
    case daily
    case weekdays
    case weekly
    case monthly
    case yearly
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Never"
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        case .custom: "Custom"
        }
    }

    var advances: Bool {
        self != .none && self != .custom
    }

    static var choices: [TaskRepeat] {
        [.none, .daily, .weekdays, .weekly, .monthly, .yearly]
    }

    static func pickerCases(including current: TaskRepeat) -> [TaskRepeat] {
        current == .custom ? choices + [.custom] : choices
    }

    func nextDue(after date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .none, .custom:
            return date
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        case .weekdays:
            var next = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            while calendar.isDateInWeekend(next) {
                next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
            }
            return next
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
    }
}

enum TaskWorkflowStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case ready
    case inProgress
    case blocked
    case done

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ready: "Ready"
        case .inProgress: "In Progress"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }
}

enum TaskDue {
    static func isOutstanding(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: date) <= calendar.startOfDay(for: now)
    }

    static func isOverdue(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: date) < calendar.startOfDay(for: now)
    }

    static func isDueToday(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, inSameDayAs: now)
    }

    static func isUpcoming(_ date: Date, now: Date = .now, calendar: Calendar = .current, days: Int = 7) -> Bool {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return false }
        let day = calendar.startOfDay(for: date)
        return day > start && day <= end
    }

    static func hasClockTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (parts.hour ?? 0) != 0 || (parts.minute ?? 0) != 0 || (parts.second ?? 0) != 0
    }

    static func label(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Due today" }
        if calendar.isDateInTomorrow(date) { return "Due tomorrow" }
        return "Due \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    static func compact(
        _ date: Date,
        hideIfToday: Bool = false,
        hasTime: Bool = false,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        if isDueToday(date, now: now, calendar: calendar) {
            if hasTime || hasClockTime(date, calendar: calendar) {
                return date.formatted(date: .omitted, time: .shortened)
            }
            return hideIfToday ? "" : "Today"
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dayHeading(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

enum TagSwatch: String, CaseIterable, Identifiable, Hashable {
    case slate
    case terracotta
    case ochre
    case moss
    case sea
    case indigo
    case plum

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slate: "Slate"
        case .terracotta: "Terracotta"
        case .ochre: "Ochre"
        case .moss: "Moss"
        case .sea: "Sea"
        case .indigo: "Indigo"
        case .plum: "Plum"
        }
    }

    var hex: String {
        switch self {
        case .slate: "6B6B6B"
        case .terracotta: "C45C26"
        case .ochre: "C4922A"
        case .moss: "5A7A3A"
        case .sea: "2F6F7A"
        case .indigo: "3D4F8A"
        case .plum: "7A3F6A"
        }
    }

    var inkLightHex: String {
        switch self {
        case .slate: "3D3D3D"
        case .terracotta: "8A3A12"
        case .ochre: "7A5A10"
        case .moss: "3A5224"
        case .sea: "1A4A52"
        case .indigo: "2A3660"
        case .plum: "522044"
        }
    }

    var inkDarkHex: String {
        switch self {
        case .slate: "C8C8C8"
        case .terracotta: "F0B090"
        case .ochre: "F0D080"
        case .moss: "B5D090"
        case .sea: "8FCDD4"
        case .indigo: "A8B4E0"
        case .plum: "E0A8D0"
        }
    }

    static func parse(_ raw: String?) -> TagSwatch? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if trimmed.isEmpty { return nil }
        if let named = TagSwatch(rawValue: trimmed) { return named }
        let hex = trimmed.filter(\.isHexDigit)
        return allCases.first { $0.hex.lowercased() == hex }
    }

    static func resolved(_ raw: String?, fallbackID: UUID? = nil) -> TagSwatch {
        if let parsed = parse(raw) { return parsed }
        guard let fallbackID else { return .slate }
        let colors = Array(allCases)
        let index = abs(fallbackID.uuidString.hashValue) % colors.count
        return colors[index]
    }

    static func nextUnused(among tags: [Tag]) -> TagSwatch {
        let used = Set(tags.map(\.swatch))
        return allCases.first { !used.contains($0) } ?? .slate
    }
}

enum TaggableKind: String, CaseIterable {
    case note
    case track
    case decision
    case conversation
    case task
}

@Model
final class Tag {
    var id: UUID
    var name: String
    var symbol: String
    var colorRaw: String?
    var createdAt: Date

    var threads: [ProjectThread] = []
    var notes: [Note] = []
    var decisions: [Decision] = []
    var conversations: [Conversation] = []
    var agendaItems: [AgendaItem] = []

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    var swatch: TagSwatch {
        get { TagSwatch.resolved(colorRaw, fallbackID: id) }
        set { colorRaw = newValue.rawValue }
    }

    init(name: String, symbol: String = "tag", color: TagSwatch = .slate) {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.colorRaw = color.rawValue
        self.createdAt = .now
    }
}

@Model
final class AgendaItem {
    var id: UUID
    var kindRaw: String
    var eventKitID: String
    var title: String
    var due: Date?
    var isCompleted: Bool = false
    var notes: String = ""
    var repeatRaw: String = "none"
    var projectIsInherited: Bool
    var createdAt: Date
    var updatedAt: Date
    var workflowStatusRaw: String = TaskWorkflowStatus.ready.rawValue
    var isNext: Bool = false
    var blockedReason: String = ""
    var project: Project?
    var spaceIDString: String = ""
    /// The stop this task sits on, on one of its tracks.
    var stop: TrackStop?

    @Relationship(deleteRule: .nullify, inverse: \JunctionRequirement.task)
    var junctionRequirements: [JunctionRequirement] = []

    @Relationship(inverse: \Tag.agendaItems)
    var tags: [Tag] = []

    @Relationship(deleteRule: .cascade, inverse: \AgendaTrackLink.item)
    var trackLinks: [AgendaTrackLink] = []

    @Relationship(deleteRule: .cascade, inverse: \AgendaNoteLink.item)
    var noteLinks: [AgendaNoteLink] = []

    @Relationship(deleteRule: .nullify, inverse: \TaskCompletion.parentTask)
    var completions: [TaskCompletion] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskDependency.blockedTask)
    var blockerLinks: [TaskDependency] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskDependency.blockingTask)
    var blockingLinks: [TaskDependency] = []

    @Relationship(deleteRule: .nullify, inverse: \AgentRun.task)
    var agentRuns: [AgentRun] = []

    var kind: AgendaKind {
        get { AgendaKind(rawValue: kindRaw) ?? .reminder }
        set { kindRaw = newValue.rawValue }
    }

    var repeatRule: TaskRepeat {
        get { TaskRepeat(rawValue: repeatRaw) ?? .none }
        set { repeatRaw = newValue == .custom ? TaskRepeat.none.rawValue : newValue.rawValue }
    }

    var workflowStatus: TaskWorkflowStatus {
        if isCompleted { return .done }
        return TaskWorkflowStatus(rawValue: workflowStatusRaw) ?? .ready
    }

    var unresolvedBlockers: [AgendaItem] {
        blockerLinks.compactMap(\.blockingTask).filter { !$0.isCompleted }
    }

    var canBeNext: Bool {
        guard kind == .task, let project, project.status == .active else { return false }
        let status = workflowStatus
        return status == .ready || status == .inProgress
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    var liveNotes: [Note] {
        noteLinks.compactMap(\.note)
    }

    var liveTracks: [ProjectThread] {
        trackLinks.compactMap(\.thread)
    }

    init(kind: AgendaKind, eventKitID: String, title: String) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.eventKitID = eventKitID
        self.title = title
        self.due = nil
        self.isCompleted = false
        self.notes = ""
        self.repeatRaw = TaskRepeat.none.rawValue
        self.projectIsInherited = false
        self.workflowStatusRaw = TaskWorkflowStatus.ready.rawValue
        self.isNext = false
        self.blockedReason = ""
        self.createdAt = .now
        self.updatedAt = .now
    }

    func touch() {
        updatedAt = .now
    }
}

@Model
final class AgendaTrackLink {
    var id: UUID
    var threadID: UUID
    var isInherited: Bool
    var inheritedFromNoteID: UUID?
    var thread: ProjectThread?
    var item: AgendaItem?

    init(thread: ProjectThread, inherited: Bool, fromNoteID: UUID? = nil) {
        self.id = UUID()
        self.threadID = thread.id
        self.isInherited = inherited
        self.inheritedFromNoteID = fromNoteID
        self.thread = thread
    }
}

@Model
final class AgendaNoteLink {
    var id: UUID
    var noteID: UUID
    var note: Note?
    var item: AgendaItem?

    init(note: Note) {
        self.id = UUID()
        self.noteID = note.id
        self.note = note
    }
}

@Model
final class TaskCompletion {
    var id: UUID
    var createdAt: Date
    var completedAt: Date
    var occurredDue: Date?
    var titleSnapshot: String
    var project: Project?
    var parentTask: AgendaItem?

    init(parent: AgendaItem, completedAt: Date = .now, occurredDue: Date?) {
        self.id = UUID()
        self.createdAt = .now
        self.completedAt = completedAt
        self.occurredDue = occurredDue
        self.titleSnapshot = parent.displayTitle
        self.project = parent.project
        self.parentTask = parent
    }
}

@Model
final class TaskDependency {
    var id: UUID
    var createdAt: Date
    var blockedTask: AgendaItem?
    var blockingTask: AgendaItem?

    init(blocked: AgendaItem, blocking: AgendaItem) {
        self.id = UUID()
        self.createdAt = .now
        self.blockedTask = blocked
        self.blockingTask = blocking
    }
}
