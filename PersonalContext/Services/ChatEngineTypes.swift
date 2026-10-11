import Foundation
import SwiftData

/// Composer payload: text and ordered attachment references.
struct ChatSubmission: Equatable, Sendable {
    var text: String
    var attachments: [ChatAttachmentRef] = []

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasContent: Bool {
        !trimmedText.isEmpty || !attachments.isEmpty
    }
}

enum TalkRole: String, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct TalkToolCall: Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

enum TalkContent: Equatable, Sendable {
    case text(String)
    case attachment(ChatAttachmentRef)
}

/// Provider-facing history. Distinct from the persisted SwiftData `ChatMessage`.
struct TalkMessage: Identifiable, Sendable {
    var id: UUID
    var role: TalkRole
    var content: [TalkContent]
    var toolCallID: String?
    var toolCalls: [TalkToolCall]?

    init(
        id: UUID = UUID(),
        role: TalkRole,
        content: [TalkContent],
        toolCallID: String? = nil,
        toolCalls: [TalkToolCall]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    init(id: UUID = UUID(), role: TalkRole, text: String) {
        self.init(id: id, role: role, content: [.text(text)])
    }

    var text: String {
        content.compactMap { part in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n")
    }

    var attachments: [ChatAttachmentRef] {
        content.compactMap { part in
            if case .attachment(let attachment) = part { return attachment }
            return nil
        }
    }

    static func conversationTranscript(_ messages: [TalkMessage]) -> String? {
        var prior = messages
        if prior.last?.role == .user {
            prior.removeLast()
        }
        let lines = prior.compactMap { message -> String? in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user: return "User: \(text)"
            case .assistant: return "Assistant: \(text)"
            default: return nil
            }
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n\n")
    }
}

enum ChatStreamEvent: Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case wait(ChatWaitState)
    case status(String)
    case tool(name: String, status: String, id: String?, detail: String?, sources: [ChatSource])
    case sources([ChatSource])
    case metadata(ChatTurnMetadata)
    case completeRunningTools
    case failRunningTools
    case done
}

protocol ChatProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var zeroResponseMessage: String { get }

    func stream(
        messages: [TalkMessage],
        model: String,
        options: ChatTurnOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error>

    @MainActor
    func attach(conversation: Conversation, project: Project?)
}

extension ChatProvider {
    @MainActor
    func attach(conversation: Conversation, project: Project?) {}
}

enum ChatEngineError: LocalizedError, Equatable {
    case emptySubmission

    var errorDescription: String? {
        "Type a message or attach a file."
    }
}

enum ChatEntry: Identifiable {
    case userMessage(User)
    case aiMessage(Assistant)
    case activity(Activity)

    var id: String {
        switch self {
        case .userMessage(let user): "user-\(user.id)"
        case .aiMessage(let assistant): "ai-\(assistant.id)"
        case .activity(let activity): "activity-\(activity.id)"
        }
    }

    struct User: Identifiable, Equatable {
        var id: UUID
        var text: String
        var attachments: [ChatAttachmentRef] = []
        var isCancelled = false
        var isFailed = false
    }

    struct Assistant: Identifiable, Equatable {
        var id: UUID
        var text: String
        var isStreaming: Bool
        var items: [ChatTurnItem] = []
        var sources: [ChatSource] = []
        var thinking: String = ""
        var waitState: ChatWaitState = .starting
        var startedAt: Date? = nil
        var finishedAt: Date? = nil

        var tools: [ChatToolActivity] {
            items.compactMap { item in
                if case .tool(let tool) = item.kind { return tool }
                return nil
            }
        }

        var work: ChatWork {
            ChatWork(seconds: workedSeconds, thinking: thinking, tools: tools)
        }

        var workedSeconds: Int {
            guard let startedAt else { return 0 }
            return max(0, Int((finishedAt ?? .now).timeIntervalSince(startedAt).rounded()))
        }

        var hasTextItems: Bool {
            items.contains { item in
                if case .text = item.kind { return true }
                return false
            }
        }

        var displayText: String {
            let fromItems = items.compactMap { item -> String? in
                if case .text(let text) = item.kind { return text }
                return nil
            }.joined(separator: "\n\n")
            return fromItems.isEmpty ? ChatTranscript.unpack(text).text : fromItems
        }
    }

    struct Activity: Identifiable, Equatable {
        var id: UUID
        var text: String
        var isError = false
    }

    var messageID: UUID? {
        switch self {
        case .userMessage(let user): user.id
        case .aiMessage(let assistant): assistant.id
        case .activity: nil
        }
    }
}

enum ChatWaitState: Equatable, Sendable {
    case starting, thinking, working, writing

    var label: String {
        switch self {
        case .starting: "Starting"
        case .thinking: "Thinking"
        case .working: "Working"
        case .writing: "Writing"
        }
    }

    init?(status: String) {
        switch status.uppercased() {
        case "CREATING": self = .starting
        case "RUNNING": self = .thinking
        default: return nil
        }
    }
}

struct ChatTurnItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text(String)
        case tool(ChatToolActivity)
    }

    var id: String
    var kind: Kind
}

struct ChatTurnMetadata: Equatable, Sendable {
    var externalSessionID: String? = nil
    var title: String? = nil
    var contextSnapshot: String? = nil

    var hasContent: Bool {
        externalSessionID != nil || title != nil || contextSnapshot != nil
    }
}

struct ChatWork: Equatable, Codable, Sendable {
    var seconds: Int
    var thinking: String
    var tools: [ChatToolActivity]

    var hasContent: Bool {
        seconds > 0 || !thinking.isEmpty || !tools.isEmpty
    }
}

enum ChatPersistedState: String, Codable, Sendable {
    case completed, failed, cancelled
}

enum ChatTranscript {
    private static let start = "\n\n<!--membrae:"
    private static let end = "-->"

    struct Payload: Codable {
        var sources: [ChatSource] = []
        var work: ChatWork?
        var state: ChatPersistedState?
        var activity: Bool?
    }

    struct Unpacked: Equatable {
        var text: String
        var sources: [ChatSource]
        var work: ChatWork?
        var state: ChatPersistedState?
        var isActivity: Bool
    }

    static func pack(
        text: String,
        sources: [ChatSource] = [],
        work: ChatWork? = nil,
        state: ChatPersistedState? = nil,
        isActivity: Bool = false
    ) -> String {
        let existing = unpack(text)
        let nextSources = sources.isEmpty ? existing.sources : sources
        let nextWork = work?.hasContent == true ? work : existing.work
        let nextState = state ?? existing.state
        let nextActivity = isActivity || existing.isActivity
        let persistState = nextState == .completed ? nil : nextState
        guard persistState != nil || nextActivity || !nextSources.isEmpty || nextWork?.hasContent == true,
              let data = try? JSONEncoder().encode(
                Payload(sources: nextSources, work: nextWork, state: persistState, activity: nextActivity ? true : nil)
              ),
              let json = String(data: data, encoding: .utf8)
        else { return existing.text }
        return existing.text + start + json + end
    }

    static func unpack(_ raw: String) -> Unpacked {
        guard let start = raw.range(of: start, options: .backwards),
              let end = raw.range(of: end, range: start.upperBound..<raw.endIndex)
        else {
            return Unpacked(text: raw, sources: [], work: nil, state: nil, isActivity: false)
        }
        let json = String(raw[start.upperBound..<end.lowerBound])
        let payload = (try? JSONDecoder().decode(Payload.self, from: Data(json.utf8))) ?? Payload()
        return Unpacked(
            text: String(raw[..<start.lowerBound]),
            sources: payload.sources,
            work: payload.work,
            state: payload.state,
            isActivity: payload.activity == true
        )
    }
}

/// Canonical in-memory assistant turn. Session applies provider events here.
struct ChatTurnState: Equatable, Sendable {
    var items: [ChatTurnItem] = []
    var sources: [ChatSource] = []
    var thinking = ""
    var waitState: ChatWaitState = .starting
    var startedAt: Date?
    var finishedAt: Date?
    var startNewText = false
    var userID: UUID?

    var tools: [ChatToolActivity] {
        items.compactMap { item in
            if case .tool(let tool) = item.kind { return tool }
            return nil
        }
    }

    var text: String {
        items.compactMap { item in
            if case .text(let text) = item.kind { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    var workedSeconds: Int {
        guard let startedAt else { return 0 }
        return max(0, Int((finishedAt ?? .now).timeIntervalSince(startedAt).rounded()))
    }

    var work: ChatWork {
        ChatWork(seconds: workedSeconds, thinking: thinking, tools: tools)
    }

    mutating func begin(userID: UUID?) {
        items = []
        sources = []
        thinking = ""
        self.userID = userID
        waitState = .starting
        startedAt = .now
        finishedAt = nil
        startNewText = false
    }

    var joinedText: String {
        items.compactMap { item -> String? in
            if case .text(let text) = item.kind { return text }
            return nil
        }.joined()
    }

    mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        waitState = .writing
        if let index = lastTextIndex, case .text(let existing) = items[index].kind {
            if text == existing || existing.hasPrefix(text) { return }
            if text.hasPrefix(existing) {
                items[index].kind = .text(text)
                startNewText = false
                return
            }
        }
        if !startNewText, case .text(let existing) = items.last?.kind {
            items[items.count - 1].kind = .text(existing + text)
        } else {
            startNewText = false
            items.append(ChatTurnItem(id: UUID().uuidString, kind: .text(text)))
        }
    }

    mutating func appendContinuation(_ text: String) {
        guard !text.isEmpty else { return }
        waitState = .writing
        startNewText = false
        if let index = lastTextIndex, case .text(let existing) = items[index].kind {
            items[index].kind = .text(existing + text)
            return
        }
        items.append(ChatTurnItem(id: UUID().uuidString, kind: .text(text)))
    }

    private var lastTextIndex: Int? {
        items.lastIndex { item in
            if case .text = item.kind { return true }
            return false
        }
    }

    mutating func markThinking(_ text: String? = nil) {
        if let text, !text.isEmpty { thinking += text }
        if tools.contains(where: { $0.status == .running }) { return }
        waitState = .thinking
    }

    mutating func applyStatus(_ status: String) {
        switch status.uppercased() {
        case "CREATING":
            waitState = .starting
        case "RUNNING":
            if waitState == .starting { waitState = .thinking }
        default:
            break
        }
    }

    mutating func applyTool(
        name: String,
        status: String,
        id: String? = nil,
        detail: String? = nil,
        sources incoming: [ChatSource] = []
    ) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let next = ChatToolActivity.Status(event: status)
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mergeSources(incoming)
        if next == .running {
            startNewText = true
            waitState = .working
        }
        let toolID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedID = (toolID?.isEmpty == false) ? toolID : nil
        if let matchedID, let index = toolIndex(id: matchedID),
           case .tool(let existing) = items[index].kind, existing.name == name {
            updateTool(at: index, status: next, detail: detail, sources: incoming)
            refreshWaitState()
            return
        }
        if next == .running, matchedID == nil, let index = lastRunningTool(named: name) {
            updateTool(at: index, status: next, detail: detail, sources: incoming)
            return
        }
        if next != .running, let index = lastRunningTool(named: name) {
            updateTool(at: index, status: next, detail: detail, sources: incoming)
            refreshWaitState()
            return
        }
        items.append(ChatTurnItem(
            id: UUID().uuidString,
            kind: .tool(ChatToolActivity(
                id: matchedID ?? UUID().uuidString,
                name: name,
                status: next,
                detail: detail,
                sources: incoming
            ))
        ))
        refreshWaitState()
    }

    mutating func mergeSources(_ incoming: [ChatSource]) {
        for source in incoming {
            if let index = sources.firstIndex(where: { $0.isSame(as: source) }) {
                if source.pin { sources[index].pin = true }
                if UUID(uuidString: source.id) != nil, UUID(uuidString: sources[index].id) == nil {
                    sources[index].id = source.id
                }
                if sources[index].title.count < source.title.count { sources[index].title = source.title }
                if sources[index].url == nil { sources[index].url = source.url }
            } else {
                sources.append(source)
            }
        }
    }

    mutating func completeRunningTools() {
        markRunning(as: .succeeded)
    }

    mutating func failRunningTools() {
        markRunning(as: .failed)
    }

    mutating func finish() {
        if finishedAt == nil { finishedAt = .now }
    }

    mutating func apply(_ assistant: ChatEntry.Assistant) {
        items = assistant.items
        sources = assistant.sources
        thinking = assistant.thinking
        waitState = assistant.waitState
        startedAt = assistant.startedAt
        finishedAt = assistant.finishedAt
    }

    func published(onto assistant: ChatEntry.Assistant, text: String, streaming: Bool) -> ChatEntry.Assistant {
        var next = assistant
        next.text = text
        next.isStreaming = streaming
        next.items = items
        next.sources = sources
        next.thinking = thinking
        next.waitState = waitState
        next.startedAt = startedAt
        next.finishedAt = finishedAt
        return next
    }

    private mutating func markRunning(as status: ChatToolActivity.Status) {
        for index in items.indices {
            guard case .tool(var tool) = items[index].kind, tool.status == .running else { continue }
            tool.status = status
            items[index].kind = .tool(tool)
        }
    }

    private func toolIndex(id: String) -> Int? {
        items.firstIndex { item in
            if case .tool(let tool) = item.kind { return tool.id == id }
            return false
        }
    }

    private func lastRunningTool(named name: String) -> Int? {
        items.lastIndex { item in
            if case .tool(let tool) = item.kind { return tool.name == name && tool.status == .running }
            return false
        }
    }

    private mutating func updateTool(
        at index: Int,
        status: ChatToolActivity.Status,
        detail: String = "",
        sources: [ChatSource] = []
    ) {
        guard case .tool(var tool) = items[index].kind else { return }
        tool.status = status
        if !detail.isEmpty { tool.detail = detail }
        if !sources.isEmpty { tool.sources = sources }
        items[index].kind = .tool(tool)
    }

    private mutating func refreshWaitState() {
        if tools.contains(where: { $0.status == .running }) {
            waitState = .working
        } else if waitState == .working {
            waitState = .thinking
        }
    }

}

struct ChatToolActivity: Identifiable, Equatable, Codable, Sendable {
    enum Status: String, Equatable, Codable, Sendable {
        case running, succeeded, failed

        init(event: String) {
            switch event.lowercased() {
            case "running", "in_progress", "pending", "started": self = .running
            case "error", "failed", "cancelled", "canceled": self = .failed
            default: self = .succeeded
            }
        }
    }

    var id: String
    var name: String
    var status: Status
    var detail: String = ""
    var sources: [ChatSource] = []

    var title: String { Self.title(for: name, status: status) }

    var displayTitle: String {
        if let url = pageURL { return Self.compactPageURL(url) }
        return title
    }

    var pageURL: URL? {
        guard namesAWebPage else { return nil }
        if let raw = sources.first(where: { $0.kind == .url })?.url, let url = Self.httpURL(from: raw) {
            return url
        }
        return Self.httpURL(from: detail)
    }

    var showsDetail: Bool {
        !detail.isEmpty && pageURL == nil
    }

    func destination(from extras: [ChatSource] = []) -> ChatSource? {
        if sources.count == 1 { return sources[0] }
        if let first = sources.first, opensRecord { return first }
        if let match = extras.first(where: matches) { return match }
        return inferredDestination
    }

    var isCursorSource: Bool {
        name == "ask_cursor" || name.contains("cursor")
    }

    var symbol: String {
        if isCursorSource { return "chevron.left.forwardslash.chevron.right" }
        if name.hasPrefix("browser_") { return "globe" }
        switch name {
        case "webSearch": return "globe"
        case "webFetch": return "safari"
        default: break
        }
        if name.contains("note") { return "eyeglasses" }
        if name.hasPrefix("list_") || name.hasPrefix("get_") { return "doc.text.magnifyingglass" }
        if name.hasPrefix("create_") { return "plus" }
        if name.hasPrefix("update_") { return "pencil" }
        return "wrench.and.screwdriver"
    }

    static func title(for tool: String, status: Status) -> String {
        if let parsed = MCPToolName.parse(tool) {
            let action = parsed.original.replacingOccurrences(of: "_", with: " ")
            let server = MCPDisplay.connectionNames[parsed.connectionID] ?? "MCP"
            switch status {
            case .running: return "\(server) · \(action)"
            case .succeeded: return "\(server) · \(action)"
            case .failed: return "\(server) couldn’t run \(action)"
            }
        }
        if tool == MCPToolName.importServers {
            switch status {
            case .running: return "Adding MCP connections"
            case .succeeded: return "Added MCP connections"
            case .failed: return "Couldn’t add MCP connections"
            }
        }
        if tool.hasPrefix("browser_") {
            switch tool {
            case "browser_search":
                return status == .running ? "Searching the web" : status == .failed ? "Couldn’t search the web" : "Searched the web"
            case "browser_navigate", "browser_open":
                return status == .running ? "Opening a page" : status == .failed ? "Couldn’t open the page" : "Opened a page"
            case "browser_snapshot", "browser_read":
                return status == .running ? "Reading the page" : status == .failed ? "Couldn’t read the page" : "Read the page"
            default:
                return status == .running ? "Browsing" : status == .failed ? "Browsing failed" : "Browsed"
            }
        }
        switch tool {
        case "webSearch":
            return status == .running ? "Searching the web" : status == .failed ? "Couldn’t search the web" : "Searched the web"
        case "webFetch":
            return status == .running ? "Fetching a page" : status == .failed ? "Couldn’t fetch a page" : "Fetched a page"
        case "mcp":
            return status == .running ? "Using a tool" : status == .failed ? "A tool failed" : "Used a tool"
        case "project_search_code":
            return status == .running ? "Searching code" : status == .failed ? "Couldn’t search code" : "Searched code"
        case "project_read_file":
            return status == .running ? "Reading file" : status == .failed ? "Couldn’t read file" : "Read file"
        case "project_list_files":
            return status == .running ? "Listing files" : status == .failed ? "Couldn’t list files" : "Listed files"
        case "project_git_log":
            return status == .running ? "Reading git history" : status == .failed ? "Couldn’t read git history" : "Read git history"
        case "consult_code":
            return status == .running ? "Asking the Worker" : status == .failed ? "The Worker failed" : "Asked the Worker"
        default:
            break
        }
        let verbs: [(prefix: String, running: String, done: String, fail: String)] = [
            ("list_", "Listing", "Listed", "list"),
            ("get_", "Reading", "Read", "read"),
            ("create_", "Adding", "Added", "add"),
            ("update_", "Updating", "Updated", "update")
        ]
        for verb in verbs {
            guard let range = tool.range(of: verb.prefix) else { continue }
            let noun = tool[range.upperBound...]
                .replacingOccurrences(of: "_", with: " ")
                .localizedCapitalized
            switch status {
            case .running: return "\(verb.running) \(noun)"
            case .succeeded: return "\(verb.done) \(noun)"
            case .failed: return "Couldn’t \(verb.fail) \(noun.lowercased())"
            }
        }
        let readable = tool
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        switch status {
        case .running, .succeeded: return readable.localizedCapitalized
        case .failed: return "Couldn’t run \(readable.lowercased())"
        }
    }

    private var opensRecord: Bool {
        name.hasPrefix("create_") || name.hasPrefix("update_") || name.hasPrefix("get_")
    }

    private var inferredKind: ChatSource.Kind? {
        if name.contains("decision") { return .decision }
        if name.contains("thread") || name.contains("track") { return .thread }
        if name.contains("note") { return .note }
        if name.contains("project") { return .project }
        return nil
    }

    private var namesAWebPage: Bool {
        if name == "webFetch" || name == "WebFetch" { return true }
        return name.hasPrefix("browser_") && name != "browser_search" && name != "browser_sessions"
    }

    private var inferredDestination: ChatSource? {
        if let url = pageURL {
            return ChatSource(
                id: url.absoluteString,
                title: Self.compactPageURL(url),
                url: url.absoluteString,
                kind: .url,
                pin: false
            )
        }
        guard status == .succeeded, opensRecord, let kind = inferredKind, !detail.isEmpty else { return nil }
        return ChatSource(id: detail, title: detail, url: nil, kind: kind, pin: false)
    }

    private func matches(_ source: ChatSource) -> Bool {
        guard opensRecord, source.kind == inferredKind, !detail.isEmpty else { return false }
        return source.title == detail
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, detail, sources
    }

    init(id: String, name: String, status: Status, detail: String = "", sources: [ChatSource] = []) {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(Status.self, forKey: .status)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        sources = try container.decodeIfPresent([ChatSource].self, forKey: .sources) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encode(detail, forKey: .detail)
        if !sources.isEmpty {
            try container.encode(sources, forKey: .sources)
        }
    }

    static func detail(for name: String, arguments: [String: Any] = [:], result: String? = nil) -> String {
        let fields = stringFields(arguments)
        switch name {
        case "project_read_file":
            return fileDetail(merging(fields, from: result, keys: ["root", "path"]))
        case "project_search_code":
            return clip(fields["query"] ?? "", 80)
        case "project_list_files":
            if let query = fields["query"], !query.isEmpty { return clip(query, 80) }
            return fileListDetail(result)
        case "project_git_log":
            return fields["root"] ?? ""
        case "consult_code":
            return clip(fields["brief"] ?? fields["question"] ?? "", 80)
        case "webSearch", "browser_search":
            return clip(fields["query"] ?? fields["search"] ?? fields["q"] ?? "", 80)
        case "webFetch", "WebFetch", "browser_navigate", "browser_open":
            return pageURLString(arguments: arguments, result: result) ?? ""
        default:
            break
        }
        if name.hasPrefix("browser_"), let url = pageURLString(arguments: arguments, result: result) {
            return url
        }
        if let title = fields["title"] ?? fields["name"], !title.isEmpty {
            return clip(title, 80)
        }
        if name.contains("note"), let content = fields["content"], !content.isEmpty {
            return clip(content, 80)
        }
        let titles = titles(from: result).prefix(3)
        if !titles.isEmpty { return titles.joined(separator: " · ") }
        return ""
    }

    static func compactPageURL(_ url: URL) -> String {
        let host = (url.host() ?? "").replacingOccurrences(of: "www.", with: "")
        guard !host.isEmpty else { return clip(url.absoluteString, 80) }
        var path = url.path
        if path == "/" { path = "" }
        while path.hasSuffix("/") { path.removeLast() }
        return clip(host + path, 80)
    }

    private static func pageURLString(arguments: [String: Any], result: String?) -> String? {
        if let url = BrowserPermissions.firstURL(in: arguments) { return url }
        return firstHTTPURL(in: result)
    }

    private static func httpURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    private static func firstHTTPURL(in result: String?) -> String? {
        guard let result else { return nil }
        for line in result.split(whereSeparator: \.isNewline).prefix(24) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard let range = text.range(of: "https://") ?? text.range(of: "http://") else { continue }
            var raw = String(text[range.lowerBound...])
            if let end = raw.firstIndex(where: { $0.isWhitespace || $0 == ")" || $0 == "]" }) {
                raw = String(raw[..<end])
            }
            raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;\""))
            if httpURL(from: raw) != nil { return raw }
        }
        return nil
    }

    private static func fileDetail(_ fields: [String: String]) -> String {
        guard let path = fields["path"], !path.isEmpty else { return "" }
        var parts: [String] = []
        if let root = fields["root"], !root.isEmpty { parts.append(root) }
        parts.append(path)
        if let start = fields["start_line"], !start.isEmpty {
            if let end = fields["end_line"], !end.isEmpty, end != start {
                parts.append("\(start)–\(end)")
            } else {
                parts.append(start)
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func fileListDetail(_ result: String?) -> String {
        guard let items = jsonObject(result) as? [[String: Any]], !items.isEmpty else { return "" }
        var seen = Set<String>()
        var roots: [String] = []
        for item in items {
            guard let root = text(item["root"]), seen.insert(root).inserted else { continue }
            roots.append(root)
        }
        let label = items.count == 1 ? "1 file" : "\(items.count) files"
        if roots.count == 1 { return "\(roots[0]) · \(label)" }
        return label
    }

    private static func titles(from result: String?) -> [String] {
        guard let object = jsonObject(result) else { return [] }
        return titles(fromJSON: object)
            .filter { UUID(uuidString: $0) == nil }
            .map { clip($0, 80) }
    }

    private static func titles(fromJSON value: Any) -> [String] {
        if let items = value as? [Any] {
            return items.flatMap(titles(fromJSON:))
        }
        guard let object = value as? [String: Any] else { return [] }
        if let title = text(object["title"]) ?? text(object["name"]) {
            return [title]
        }
        return object.values.flatMap(titles(fromJSON:))
    }

    private static func merging(_ fields: [String: String], from result: String?, keys: [String]) -> [String: String] {
        var next = fields
        guard let object = jsonObject(result) as? [String: Any] else { return next }
        for key in keys where next[key] == nil {
            if let value = text(object[key]) { next[key] = value }
        }
        return next
    }

    private static func stringFields(_ arguments: [String: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: arguments.compactMap { key, value in
            text(value).map { (key, $0) }
        })
    }

    private static func jsonObject(_ result: String?) -> Any? {
        guard let result else { return nil }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.stringValue
        }
        return nil
    }
}

extension ChatSource {
    init(runner raw: RunnerSource) {
        let kind = Kind(rawValue: raw.kind ?? "") ?? (raw.url == nil ? .note : .url)
        let id = raw.id?.isEmpty == false ? raw.id! : raw.url ?? raw.title
        let url = raw.url ?? (kind == .url ? nil : ChatObjectLink.href(kind: kind, id: id))
        self.init(id: id, title: raw.title, url: url, kind: kind, pin: raw.pin ?? true)
    }

    static func make(from incoming: [RunnerSource]?) -> [ChatSource] {
        incoming?.map(ChatSource.init(runner:)) ?? []
    }
}
