import Foundation
import SwiftData

enum RunOrigin: String, Codable, CaseIterable, Identifiable, Hashable {
    case workspace
    case project
    case task
    case chat

    var id: String { rawValue }
}

enum RunStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case queued
    case running
    case waiting
    case succeeded
    case failed
    case cancelled

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var isActive: Bool {
        self == .queued || self == .running || self == .waiting
    }

    var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .cancelled
    }
}

enum RunEventKind: String, Codable, Hashable {
    case queued
    case running
    case waiting
    case succeeded
    case failed
    case cancelled
    case quit
}

struct RunEvent: Codable, Identifiable, Hashable {
    var id: UUID
    var at: Date
    var kind: RunEventKind
    var detail: String

    init(id: UUID = UUID(), at: Date = .now, kind: RunEventKind, detail: String = "") {
        self.id = id
        self.at = at
        self.kind = kind
        self.detail = detail
    }
}

enum RunLinkKind: String, Codable, Hashable {
    case link
    case document
    case file
    case pullRequest
}

struct RunResultLink: Codable, Identifiable, Hashable {
    var id: UUID
    var label: String
    var url: String
    var kindRaw: String

    var kind: RunLinkKind {
        RunLinkKind(rawValue: kindRaw) ?? .link
    }

    init(id: UUID = UUID(), label: String, url: String, kind: RunLinkKind) {
        self.id = id
        self.label = label
        self.url = url
        self.kindRaw = kind.rawValue
    }
}

struct NewRunDraft: Equatable {
    var brief: String
    var projectID: UUID?
    var taskID: UUID?
    var originChatID: UUID?
    var origin: RunOrigin
    var providerID: String
    var modelID: String
    var pathRaw: String
    var repositoryLocators: [String]
    var retryOfID: UUID?

    static func blank(
        origin: RunOrigin,
        projectID: UUID? = nil,
        taskID: UUID? = nil,
        originChatID: UUID? = nil,
        brief: String = "",
        providerID: String,
        modelID: String,
        pathRaw: String = "local",
        retryOfID: UUID? = nil
    ) -> NewRunDraft {
        NewRunDraft(
            brief: brief,
            projectID: projectID,
            taskID: projectID == nil ? nil : taskID,
            originChatID: originChatID,
            origin: origin,
            providerID: providerID,
            modelID: modelID,
            pathRaw: pathRaw,
            repositoryLocators: [],
            retryOfID: retryOfID
        )
    }
}

@Model
final class AgentRun {
    var id: UUID
    var originRaw: String
    var statusRaw: String
    var title: String
    var titleSnapshot: String
    var brief: String
    var providerID: String
    var modelID: String
    var pathRaw: String
    var adapterID: String
    var externalID: String
    var externalURL: String
    var resultSummary: String
    var resultLinksJSON: String
    var repositoryLocatorsJSON: String
    var branch: String
    var statusDetail: String
    var adapterStateJSON: String
    var historyJSON: String
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var updatedAt: Date

    var project: Project?
    var task: AgendaItem?
    var originChat: Conversation?
    var retryOf: AgentRun?

    var origin: RunOrigin {
        get { RunOrigin(rawValue: originRaw) ?? .workspace }
        set { originRaw = newValue.rawValue }
    }

    var status: RunStatus {
        get { RunStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New run" : trimmed
    }

    var history: [RunEvent] {
        get { Self.decode(historyJSON, as: [RunEvent].self) ?? [] }
        set { historyJSON = Self.encode(newValue) }
    }

    var resultLinks: [RunResultLink] {
        get { Self.decode(resultLinksJSON, as: [RunResultLink].self) ?? [] }
        set { resultLinksJSON = Self.encode(newValue) }
    }

    var repositoryLocators: [String] {
        get { Self.decode(repositoryLocatorsJSON, as: [String].self) ?? [] }
        set { repositoryLocatorsJSON = Self.encode(newValue) }
    }

    var path: String { pathRaw }

    init(
        brief: String,
        origin: RunOrigin,
        providerID: String,
        modelID: String,
        pathRaw: String = "local",
        project: Project? = nil,
        task: AgendaItem? = nil,
        originChat: Conversation? = nil,
        retryOf: AgentRun? = nil
    ) {
        self.id = UUID()
        self.originRaw = origin.rawValue
        self.statusRaw = RunStatus.queued.rawValue
        self.title = AgentRun.title(from: brief)
        self.titleSnapshot = task?.displayTitle ?? ""
        self.brief = brief
        self.providerID = providerID
        self.modelID = modelID
        self.pathRaw = pathRaw
        self.adapterID = ""
        self.externalID = ""
        self.externalURL = ""
        self.resultSummary = ""
        self.resultLinksJSON = "[]"
        self.repositoryLocatorsJSON = "[]"
        self.branch = ""
        self.statusDetail = ""
        self.adapterStateJSON = ""
        self.historyJSON = "[]"
        self.createdAt = .now
        self.updatedAt = .now
        self.project = project
        self.task = task
        self.originChat = originChat
        self.retryOf = retryOf
    }

    func append(_ kind: RunEventKind, detail: String = "", at: Date = .now) {
        var events = history
        events.append(RunEvent(at: at, kind: kind, detail: detail))
        history = events
        updatedAt = at
    }

    func touch() {
        updatedAt = .now
    }

    static func title(from brief: String) -> String {
        let line = brief
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        if line.count <= 80 { return line }
        return String(line.prefix(80))
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
