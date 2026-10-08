import AIChatCore
import Foundation
import Observation

struct RunnerRequest: Encodable, Sendable {
    var apiKey: String
    var env: [String: String]
    var agentId: String?
    var name: String
    var text: String
    var model: String
    var cwd: String
    var mcpCommand: String
    var codeRoots: [ProjectCodeRoot]
    var includeSlateTools: Bool
    var includeProjectTools: Bool
    var includeWorkerTool: Bool = false
    var runtime: String
    var cloudRepos: [RunnerCloudRepo]
    var codeSnapshots: [RunnerCodeSnapshot] = []
}

struct RunnerCodeSnapshot: Encodable, Sendable {
    var title: String
    var locator: String
    var kind: String
    var branch: String
    var token: String?
    var path: String
    var archiveURL: String?
    var commitsURL: String?
}

struct RunnerCloudRepo: Encodable, Sendable {
    var url: String
    var startingRef: String?
}

struct RunnerSource: Decodable, Sendable {
    var id: String?
    var title: String
    var url: String?
    var kind: String?
    var pin: Bool?
}

struct RunnerEvent: Decodable, Sendable {
    var type: String
    var agentId: String?
    var text: String?
    var name: String?
    var status: String?
    var error: String?
    var message: String?
    var id: String?
    var detail: String?
    var sources: [RunnerSource]?
}

enum ChatWaitState: Equatable {
    case starting, thinking, working, writing

    var label: String {
        switch self {
        case .starting: "Starting"
        case .thinking: "Thinking"
        case .working: "Working"
        case .writing: "Writing"
        }
    }
}

struct ChatTurnItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case text(String)
        case tool(ChatToolActivity)
    }

    var id: String
    var kind: Kind
}

struct ChatToolActivity: Identifiable, Equatable, Codable {
    enum Status: String, Equatable, Codable {
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
        switch tool {
        case "webSearch":
            return status == .running ? "Searching the web" : status == .failed ? "Couldn’t search the web" : "Searched the web"
        case "webFetch":
            return status == .running ? "Fetching a page" : status == .failed ? "Couldn’t fetch a page" : "Fetched a page"
        case "mcp":
            return status == .running ? "Using a tool" : status == .failed ? "A tool failed" : "Used a tool"
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
            let noun = tool[range.upperBound...].replacingOccurrences(of: "_", with: " ")
            switch status {
            case .running: return "\(verb.running) \(noun)"
            case .succeeded: return "\(verb.done) \(noun)"
            case .failed: return "Couldn’t \(verb.fail) \(noun)"
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
        if name.contains("thread") { return .thread }
        if name.contains("note") { return .note }
        if name.contains("project") { return .project }
        return nil
    }

    private var inferredDestination: ChatSource? {
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
}

@MainActor
@Observable
final class CursorConversationBridge {
    var conversation: Conversation
    var project: Project?
    private(set) var changes: [String] = []
    private(set) var turn: [ChatTurnItem] = []
    private(set) var waitState: ChatWaitState = .starting
    private(set) var sources: [ChatSource] = []
    private(set) var thinkingText = ""
    private(set) var turnUserID: UUID?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var processInput: FileHandle?
    @ObservationIgnored private var activeCodeRoots: [ProjectCodeRoot] = []
    @ObservationIgnored private var startNewText = false
    let debugLog = ChatDebugLog()
    let mcp = SlateMCPClient.shared

    var workedSeconds: Int {
        guard let startedAt else { return 0 }
        return max(0, Int((finishedAt ?? .now).timeIntervalSince(startedAt).rounded()))
    }

    var work: ChatWork {
        ChatWork(seconds: workedSeconds, thinking: thinkingText, tools: tools)
    }

    var tools: [ChatToolActivity] {
        turn.compactMap { item in
            if case .tool(let tool) = item.kind { return tool }
            return nil
        }
    }

    var turnText: String {
        turn.compactMap { item in
            if case .text(let text) = item.kind { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    init(conversation: Conversation, project: Project?) {
        self.conversation = conversation
        self.project = project
    }

    func beginTurn() {
        changes = []
        turn = []
        sources = []
        thinkingText = ""
        turnUserID = nil
        waitState = .starting
        startedAt = .now
        finishedAt = nil
        startNewText = false
        debugLog.pace = StreamPace()
        debugLog.add("beginTurn")
    }

    func bindTurn(to userID: UUID) {
        turnUserID = userID
        debugLog.add("bindTurn user=\(userID.uuidString.prefix(8))")
    }

    func prepareCodeRoots() async throws -> [ProjectCodeRoot] {
        let store = conversation.modelContext?.container.configurations.first?.url
        let roots = try await ProjectCodeWorkspace.prepare(for: project, storeURL: store)
        activeCodeRoots = roots
        return roots
    }

    func keepAccess(to roots: [ProjectCodeRoot]) {
        activeCodeRoots = roots
    }

    func prepare(
        userText: String,
        apiKey: String,
        model: String,
        codeRoots: [ProjectCodeRoot],
        includeSlateTools: Bool = true,
        includeProjectTools: Bool = true,
        resumeSession: Bool = true,
        runtime: WorkerPath = .local
    ) throws -> RunnerRequest {
        guard let mcp = Bundle.main.url(forAuxiliaryExecutable: "slate-mcp") else {
            throw CursorAPIError(status: 0, message: "The Slate MCP is missing from the app.")
        }
        guard conversation.modelContext != nil else {
            throw CursorAPIError(status: 0, message: "Chat lost its place in the knowledge base. Send again.")
        }
        guard let store = conversation.modelContext?.container.configurations.first?.url else {
            throw CursorAPIError(status: 0, message: "Couldn’t find the knowledge base on disk.")
        }
        let folder = store.deletingLastPathComponent().appendingPathComponent("Agent", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let opening = !resumeSession || conversation.externalSessionID.isEmpty
        ChatTrace.event("prepare conversation=\(conversation.id) opening=\(opening) agent=\(conversation.externalSessionID) model=\(conversation.modelID) project=\(project?.name ?? "none") roots=\(codeRoots.count) textChars=\(userText.count)")
        if conversation.title == "New chat" || conversation.title.isEmpty {
            conversation.title = conversationTitle(from: userText)
        }
        let focused = conversation.thread
        let context = project.map(ContextBuilder.identity(for:)) ?? ""
        if opening {
            conversation.contextSnapshot = context
        }
        conversation.updatedAt = .now
        project?.touch()
        try? conversation.modelContext?.save()
        let workspace = codeRoots.count == 1
            ? codeRoots[0].path
            : (codeRoots.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path } ?? folder.path)
        return RunnerRequest(
            apiKey: apiKey,
            env: ProcessInfo.processInfo.environment,
            agentId: opening ? nil : conversation.externalSessionID,
            name: conversation.title,
            text: includeSlateTools
                ? ContextBuilder.prompt(userText: userText, context: context, opening: opening, focusedThread: focused)
                : ContextBuilder.codeConsultationPrompt(userText: userText, context: context),
            model: model,
            cwd: workspace,
            mcpCommand: mcp.path,
            codeRoots: codeRoots,
            includeSlateTools: includeSlateTools,
            includeProjectTools: includeProjectTools,
            includeWorkerTool: includeSlateTools && ProjectWorker.isConfigured(on: project),
            runtime: runtime.rawValue,
            cloudRepos: cloudRepositories(),
            codeSnapshots: includeProjectTools && runtime == .local
                ? ProjectCodeWorkspace.remoteSnapshots(for: project, storeURL: store)
                : []
        )
    }

    private func cloudRepositories() -> [RunnerCloudRepo] {
        guard let project else { return [] }
        return ProjectCodeWorkspace.attachments(on: project).compactMap { attachment in
            let url: String
            switch attachment.kind {
            case .folder:
                return nil
            case .github:
                url = GitHubRemote.url(forLocator: attachment.locator) + ".git"
            case .gitlab:
                return nil
            }
            return RunnerCloudRepo(
                url: url,
                startingRef: attachment.defaultBranch.isEmpty ? nil : attachment.defaultBranch
            )
        }
    }

    func prepareProviderTurn(userText: String, includeSlateTools: Bool = true) -> String {
        if conversation.title == "New chat" || conversation.title.isEmpty {
            conversation.title = conversationTitle(from: userText)
        }
        let opening = conversation.contextSnapshot.isEmpty
        let context = project.map(ContextBuilder.identity(for:)) ?? ""
        if opening {
            conversation.contextSnapshot = context
        }
        conversation.updatedAt = .now
        project?.touch()
        try? conversation.modelContext?.save()
        if includeSlateTools {
            return ContextBuilder.prompt(
                userText: "",
                context: context,
                opening: opening,
                focusedThread: conversation.thread
            )
        }
        return ContextBuilder.codeConsultationPrompt(userText: "", context: context)
    }

    func run(_ request: RunnerRequest) throws -> AsyncThrowingStream<RunnerEvent, Error> {
        guard let node = Bundle.main.url(forAuxiliaryExecutable: "slate-node"),
              let runner = Bundle.main.url(forResource: "runner", withExtension: "mjs", subdirectory: "runner") else {
            throw CursorAPIError(status: 0, message: "The agent runner is missing from the app.")
        }
        let process = Process()
        process.executableURL = node
        process.arguments = [runner.path]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            ChatTrace.event("runner stderr: \(ChatTrace.clip(String(decoding: data, as: UTF8.self), 8000))")
        }
        let exits = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        self.process = process
        self.processInput = input.fileHandleForWriting
        ChatTrace.event("runner started pid=\(process.processIdentifier) resume=\(request.agentId != nil)")
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: payload)

        let reader = output.fileHandleForReading
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    var sawEnd = false
                    for try await line in reader.bytes.lines {
                        guard let event = try? JSONDecoder().decode(RunnerEvent.self, from: Data(line.utf8)) else { continue }
                        if event.type == "result" || event.type == "error" { sawEnd = true }
                        continuation.yield(event)
                    }
                    var status: Int32 = 0
                    for await code in exits { status = code }
                    ChatTrace.event("runner exited status=\(status)")
                    if !sawEnd, status != 0, status != 130 {
                        throw CursorAPIError(status: 0, message: "The agent stopped unexpectedly (exit \(status)).")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func agentStarted(_ id: String) {
        guard conversation.modelContext != nil else { return }
        guard conversation.externalSessionID != id else { return }
        ChatTrace.event("agent id=\(id)")
        conversation.externalSessionID = id
        try? conversation.modelContext?.save()
    }

    func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        waitState = .writing
        var items = turn
        if !startNewText, case .text(let existing) = items.last?.kind {
            items[items.count - 1].kind = .text(existing + text)
        } else {
            startNewText = false
            items.append(ChatTurnItem(id: UUID().uuidString, kind: .text(text)))
        }
        turn = items
    }

    func markThinking(_ text: String? = nil) {
        if let text, !text.isEmpty { thinkingText += text }
        if tools.contains(where: { $0.status == .running }) { return }
        waitState = .thinking
    }

    func applyStatus(_ status: String) {
        switch status.uppercased() {
        case "CREATING": waitState = .starting
        case "RUNNING":
            if waitState == .starting { waitState = .thinking }
        case "ERROR", "CANCELLED", "CANCELED", "EXPIRED":
            break
        default:
            break
        }
    }

    func beginTextSegment() {
        startNewText = true
    }

    func applyTool(name: String, status: String, id: String? = nil, detail: String? = nil, sources incoming: [RunnerSource]? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let next = ChatToolActivity.Status(event: status)
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ChatTrace.event("tool \(name) status=\(status)")
        let attached = incoming.map(chatSources(from:)) ?? []
        if let incoming { mergeSources(incoming) }
        if next == .running {
            startNewText = true
            waitState = .working
        }
        if let id, let index = toolIndex(id: id) {
            updateTool(at: index, status: next, detail: detail, sources: attached)
            refreshWaitState()
            return
        }
        if next == .running, let index = lastRunningTool(named: name) {
            updateTool(at: index, status: next, detail: detail, sources: attached)
            return
        }
        if next != .running, let index = lastRunningTool(named: name) {
            updateTool(at: index, status: next, detail: detail, sources: attached)
            refreshWaitState()
            return
        }
        if next != .running, case .tool(let tool) = turn.last?.kind, tool.name == name {
            updateTool(at: turn.count - 1, status: next, detail: detail, sources: attached)
            refreshWaitState()
            return
        }
        turn.append(ChatTurnItem(
            id: UUID().uuidString,
            kind: .tool(ChatToolActivity(id: id ?? UUID().uuidString, name: name, status: next, detail: detail, sources: attached))
        ))
        recordChange(name: name, status: next)
        refreshWaitState()
    }

    func stop() {
        markRunning(as: .failed)
        if finishedAt == nil { finishedAt = .now }
        closeProcessInput()
        guard let process, process.isRunning else { return }
        ChatTrace.event("runner stop pid=\(process.processIdentifier)")
        process.terminate()
    }

    func finished() {
        if finishedAt == nil { finishedAt = .now }
        closeProcessInput()
        process = nil
        ProjectCodeWorkspace.stopAccessing(activeCodeRoots)
        activeCodeRoots = []
    }

    func replyToHostTool(id: String, text: String? = nil, error: String? = nil) {
        guard let processInput else { return }
        var payload: [String: String] = ["id": id]
        if let text { payload["text"] = text }
        if let error { payload["error"] = error }
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        try? processInput.write(contentsOf: data)
    }

    private func closeProcessInput() {
        try? processInput?.close()
        processInput = nil
    }

    func completeRunningTools() {
        markRunning(as: .succeeded)
    }

    func failRunningTools() {
        markRunning(as: .failed)
    }

    private func markRunning(as status: ChatToolActivity.Status) {
        for index in turn.indices {
            guard case .tool(var tool) = turn[index].kind, tool.status == .running else { continue }
            tool.status = status
            turn[index].kind = .tool(tool)
            recordChange(name: tool.name, status: status)
        }
    }

    private func toolIndex(id: String) -> Int? {
        turn.firstIndex { item in
            if case .tool(let tool) = item.kind { return tool.id == id }
            return false
        }
    }

    private func lastRunningTool(named name: String) -> Int? {
        turn.lastIndex { item in
            if case .tool(let tool) = item.kind { return tool.name == name && tool.status == .running }
            return false
        }
    }

    private func updateTool(
        at index: Int,
        status: ChatToolActivity.Status,
        detail: String = "",
        sources: [ChatSource] = []
    ) {
        guard case .tool(var tool) = turn[index].kind else { return }
        tool.status = status
        if !detail.isEmpty { tool.detail = detail }
        if !sources.isEmpty { tool.sources = sources }
        turn[index].kind = .tool(tool)
        recordChange(name: tool.name, status: status)
    }

    private func refreshWaitState() {
        if tools.contains(where: { $0.status == .running }) {
            waitState = .working
        } else if waitState == .working {
            waitState = .thinking
        }
    }

    private func chatSources(from incoming: [RunnerSource]) -> [ChatSource] {
        incoming.map { raw in
            let kind = ChatSource.Kind(rawValue: raw.kind ?? "") ?? (raw.url == nil ? .note : .url)
            let id = raw.id?.isEmpty == false ? raw.id! : raw.url ?? raw.title
            let url = raw.url ?? (kind == .url ? nil : ChatObjectLink.href(kind: kind, id: id))
            return ChatSource(
                id: id,
                title: raw.title,
                url: url,
                kind: kind,
                pin: raw.pin ?? true
            )
        }
    }

    private func mergeSources(_ incoming: [RunnerSource]) {
        for source in chatSources(from: incoming) {
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

    private func recordChange(name: String, status: ChatToolActivity.Status) {
        guard status != .running else { return }
        guard name.hasPrefix("create_") || name.hasPrefix("update_") else { return }
        let label = ChatToolActivity.title(for: name, status: status)
        if !changes.contains(label) { changes.append(label) }
    }
}

struct CursorChatProvider: ChatProvider {
    let id = "cursor"
    let name = "Cursor"
    let bridge: CursorConversationBridge
    var includeSlateTools = true
    var includeProjectTools = true
    var resumeConversation = true
    var runtime: WorkerPath = .local

    var zeroResponseMessage: String { "Cursor didn’t return a reply." }

    func stream(
        messages: [AIChatCore.ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let userText = messages.last(where: { $0.role == .user })?.content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n") ?? ""
        let bridge = bridge

        ChatTrace.event("provider.stream model=\(model) messages=\(messages.count) userChars=\(userText.count)")
        return AsyncThrowingStream { continuation in
            let task = Task {
                var coalescer = StreamTextCoalescer()
                var pace = await MainActor.run { bridge.debugLog.pace ?? StreamPace() }
                func emitText(_ text: String) async {
                    let snapshot = pace
                    pace = await MainActor.run {
                        var current = snapshot
                        let applyStart = Date()
                        bridge.appendText(text)
                        continuation.yield(.text(text))
                        current.painted(text.count, applyMs: Date().timeIntervalSince(applyStart) * 1000)
                        bridge.debugLog.pace = current
                        if current.paintEvents == 1 {
                            bridge.debugLog.add("pace \(current.logLine)")
                        }
                        return current
                    }
                }
                func flushText() async {
                    if let leftover = coalescer.take() {
                        await emitText(leftover)
                    }
                }
                do {
                    let request = try await MainActor.run {
                        bridge.debugLog.add("stream start model=\(model) messages=\(messages.count)")
                        for (index, message) in messages.enumerated() {
                            let text = message.content.compactMap { block -> String? in
                                if case .text(let text) = block { return text }
                                return nil
                            }.joined()
                            bridge.debugLog.add("  msg[\(index)] \(message.role) \(ChatTrace.clip(text, 80))")
                        }
                        guard let apiKey = KeychainStore.read(.cursorAPIKey) else {
                            throw CursorAPIError(status: 0, message: "Add a Cursor API key in Settings.")
                        }
                        let roots = runtime == .local && includeProjectTools
                            ? ProjectCodeWorkspace.localRoots(for: bridge.project)
                            : []
                        bridge.keepAccess(to: roots)
                        let request = try bridge.prepare(
                            userText: userText,
                            apiKey: apiKey,
                            model: model,
                            codeRoots: roots,
                            includeSlateTools: includeSlateTools,
                            includeProjectTools: includeProjectTools,
                            resumeSession: resumeConversation,
                            runtime: runtime
                        )
                        bridge.debugLog.add("prepare opening=\(request.agentId == nil) model=\(request.model) promptChars=\(request.text.count)")
                        return request
                    }
                    pace.markPrepared()
                    await MainActor.run { bridge.debugLog.pace = pace }
                    var emitted = false
                    var agentID: String?
                    var textChars = 0
                    var lastTextLog = Date.distantPast
                    let events = try await MainActor.run { try bridge.run(request) }
                    for try await event in events {
                        switch event.type {
                        case "agent":
                            agentID = event.agentId
                            await MainActor.run { bridge.debugLog.add("event agent id=\(event.agentId ?? "")") }
                        case "text":
                            if let text = event.text, !text.isEmpty {
                                emitted = true
                                textChars += text.count
                                pace.inbound(text.count)
                                if let chunk = coalescer.push(text) {
                                    await emitText(chunk)
                                }
                                let now = Date()
                                if textChars == text.count || now.timeIntervalSince(lastTextLog) > 0.4 {
                                    await MainActor.run {
                                        bridge.debugLog.add("event text +\(text.count) total=\(textChars) \(ChatTrace.clip(text, 80))")
                                    }
                                    lastTextLog = now
                                }
                            }
                        case "break":
                            await flushText()
                            await MainActor.run { bridge.debugLog.add("event break") }
                        case "thinking":
                            await MainActor.run { bridge.markThinking(event.text) }
                        case "status":
                            await MainActor.run {
                                if let status = event.status { bridge.applyStatus(status) }
                                bridge.debugLog.add("event status \(event.status ?? "")")
                            }
                        case "host_tool":
                            await flushText()
                            let toolID = event.id ?? UUID().uuidString
                            let toolName = event.name ?? "consult_code"
                            let brief = event.text ?? event.detail ?? ""
                            await MainActor.run {
                                bridge.applyTool(name: toolName, status: "running", id: toolID)
                                bridge.debugLog.add("event host_tool \(toolName) \(ChatTrace.clip(brief, 80))")
                            }
                            do {
                                let output = try await ProjectWorker.consult(
                                    brief: brief,
                                    reportingTo: bridge,
                                    options: options
                                )
                                await MainActor.run {
                                    bridge.applyTool(name: toolName, status: "completed", id: toolID)
                                    bridge.replyToHostTool(id: toolID, text: output)
                                }
                            } catch {
                                await MainActor.run {
                                    bridge.applyTool(
                                        name: toolName,
                                        status: "error",
                                        id: toolID,
                                        detail: error.localizedDescription
                                    )
                                    bridge.replyToHostTool(id: toolID, error: error.localizedDescription)
                                }
                            }
                        case "tool":
                            await flushText()
                            await MainActor.run {
                                bridge.applyTool(
                                    name: event.name ?? "",
                                    status: event.status ?? "",
                                    id: event.id,
                                    detail: event.detail,
                                    sources: event.sources
                                )
                                bridge.debugLog.add("event tool \(event.name ?? "") \(event.status ?? "") \(ChatTrace.clip(event.detail ?? "", 80))")
                            }
                        case "result":
                            await flushText()
                            await MainActor.run {
                                bridge.debugLog.add("event result status=\(event.status ?? "") emitted=\(emitted) textChars=\(textChars)")
                            }
                            if !emitted, let text = event.text, !text.isEmpty {
                                emitted = true
                                await emitText(text)
                            }
                            if event.status?.lowercased() == "error" {
                                throw CursorAPIError(status: 0, message: event.error ?? "The run failed.")
                            }
                            if resumeConversation, let agentID {
                                await MainActor.run { bridge.agentStarted(agentID) }
                            }
                        case "error":
                            await MainActor.run { bridge.debugLog.add("event error \(event.message ?? "")") }
                            throw CursorAPIError(status: 0, message: event.message ?? "The run failed.")
                        default:
                            await MainActor.run { bridge.debugLog.add("event \(event.type)") }
                        }
                    }
                    await flushText()
                    ChatTrace.event("provider.stream complete emitted=\(emitted)")
                    await MainActor.run {
                        bridge.debugLog.pace = pace
                        bridge.debugLog.add("pace done \(pace.logLine)")
                        bridge.debugLog.add("stream complete emitted=\(emitted) textChars=\(textChars) turn=\(bridge.turn.count) wait=\(bridge.waitState)")
                        bridge.completeRunningTools()
                        bridge.finished()
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    await MainActor.run {
                        bridge.failRunningTools()
                        ChatTrace.event("provider.stream error: \(error.localizedDescription)")
                        bridge.debugLog.add("stream error \(error.localizedDescription)")
                        bridge.finished()
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { @MainActor in bridge.stop() }
            }
        }
    }

    func complete(
        messages: [AIChatCore.ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult {
        throw CursorAPIError(status: 0, message: "Cursor conversations stream only.")
    }
}
