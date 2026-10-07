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

    var title: String { Self.title(for: name, status: status) }

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
    @ObservationIgnored private var startNewText = false
    let debugLog = ChatDebugLog()

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
        debugLog.add("beginTurn")
    }

    func bindTurn(to userID: UUID) {
        turnUserID = userID
        debugLog.add("bindTurn user=\(userID.uuidString.prefix(8))")
    }

    func prepare(userText: String, apiKey: String) throws -> RunnerRequest {
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

        let opening = conversation.cursorAgentId.isEmpty
        ChatTrace.event("prepare conversation=\(conversation.id) opening=\(opening) agent=\(conversation.cursorAgentId) model=\(conversation.model) project=\(project?.name ?? "none") textChars=\(userText.count)")
        if conversation.title == "New chat" || conversation.title.isEmpty {
            conversation.title = conversationTitle(from: userText)
        }
        let focused = conversation.thread
        let context = project.map { ContextBuilder.package(for: $0, focusedThread: focused) } ?? ""
        if opening {
            conversation.contextSnapshot = context
        }
        conversation.updatedAt = .now
        project?.touch()
        try? conversation.modelContext?.save()
        return RunnerRequest(
            apiKey: apiKey,
            env: ProcessInfo.processInfo.environment,
            agentId: opening ? nil : conversation.cursorAgentId,
            name: conversation.title,
            text: ContextBuilder.prompt(userText: userText, context: context, opening: opening, focusedThread: focused),
            model: conversation.model,
            cwd: folder.path,
            mcpCommand: mcp.path
        )
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
        ChatTrace.event("runner started pid=\(process.processIdentifier) resume=\(request.agentId != nil)")
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
        try input.fileHandleForWriting.close()

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
        guard conversation.cursorAgentId != id else { return }
        ChatTrace.event("agent id=\(id)")
        conversation.cursorAgentId = id
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
        if let incoming { mergeSources(incoming) }
        if next == .running {
            startNewText = true
            waitState = .working
        }
        if let id, let index = toolIndex(id: id) {
            updateTool(at: index, status: next, detail: detail)
            refreshWaitState()
            return
        }
        if next == .running, let index = lastRunningTool(named: name) {
            updateTool(at: index, status: next, detail: detail)
            return
        }
        if next != .running, let index = lastRunningTool(named: name) {
            updateTool(at: index, status: next, detail: detail)
            refreshWaitState()
            return
        }
        if next != .running, case .tool(let tool) = turn.last?.kind, tool.name == name {
            updateTool(at: turn.count - 1, status: next, detail: detail)
            refreshWaitState()
            return
        }
        turn.append(ChatTurnItem(
            id: UUID().uuidString,
            kind: .tool(ChatToolActivity(id: id ?? UUID().uuidString, name: name, status: next, detail: detail))
        ))
        recordChange(name: name, status: next)
        refreshWaitState()
    }

    func stop() {
        markRunning(as: .failed)
        if finishedAt == nil { finishedAt = .now }
        guard let process, process.isRunning else { return }
        ChatTrace.event("runner stop pid=\(process.processIdentifier)")
        process.terminate()
    }

    func finished() {
        if finishedAt == nil { finishedAt = .now }
        process = nil
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

    private func updateTool(at index: Int, status: ChatToolActivity.Status, detail: String = "") {
        guard case .tool(var tool) = turn[index].kind else { return }
        tool.status = status
        if !detail.isEmpty { tool.detail = detail }
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

    private func mergeSources(_ incoming: [RunnerSource]) {
        for raw in incoming {
            let kind = ChatSource.Kind(rawValue: raw.kind ?? "") ?? (raw.url == nil ? .note : .url)
            let id = raw.id?.isEmpty == false ? raw.id! : raw.url ?? raw.title
            let url = raw.url ?? (kind == .url ? nil : ChatObjectLink.href(kind: kind, id: id))
            let source = ChatSource(
                id: id,
                title: raw.title,
                url: url,
                kind: kind,
                pin: raw.pin ?? true
            )
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
            let task = Task { @MainActor in
                defer { bridge.finished() }
                do {
                    bridge.debugLog.add("stream start model=\(model) messages=\(messages.count)")
                    for (index, message) in messages.enumerated() {
                        let text = message.content.compactMap { block -> String? in
                            if case .text(let text) = block { return text }
                            return nil
                        }.joined()
                        bridge.debugLog.add("  msg[\(index)] \(message.role) \(ChatTrace.clip(text, 80))")
                    }
                    guard let apiKey = KeychainStore.read() else {
                        throw CursorAPIError(status: 0, message: "Add a Cursor API key in Settings.")
                    }
                    let request = try bridge.prepare(userText: userText, apiKey: apiKey)
                    bridge.debugLog.add("prepare opening=\(request.agentId == nil) model=\(request.model) promptChars=\(request.text.count)")
                    var emitted = false
                    var agentID: String?
                    var textChars = 0
                    var lastTextLog = Date.distantPast
                    for try await event in try bridge.run(request) {
                        switch event.type {
                        case "agent":
                            agentID = event.agentId
                            bridge.debugLog.add("event agent id=\(event.agentId ?? "")")
                        case "text":
                            if let text = event.text, !text.isEmpty {
                                emitted = true
                                bridge.appendText(text)
                                continuation.yield(.text(text))
                                textChars += text.count
                                let now = Date()
                                if textChars == text.count || now.timeIntervalSince(lastTextLog) > 0.4 {
                                    bridge.debugLog.add("event text +\(text.count) total=\(textChars) \(ChatTrace.clip(text, 80))")
                                    lastTextLog = now
                                }
                                await Task.yield()
                            }
                        case "break":
                            bridge.debugLog.add("event break")
                        case "thinking":
                            bridge.markThinking(event.text)
                        case "status":
                            if let status = event.status { bridge.applyStatus(status) }
                            bridge.debugLog.add("event status \(event.status ?? "")")
                        case "tool":
                            bridge.applyTool(
                                name: event.name ?? "",
                                status: event.status ?? "",
                                id: event.id,
                                detail: event.detail,
                                sources: event.sources
                            )
                            bridge.debugLog.add("event tool \(event.name ?? "") \(event.status ?? "") \(ChatTrace.clip(event.detail ?? "", 80))")
                        case "result":
                            bridge.debugLog.add("event result status=\(event.status ?? "") emitted=\(emitted) textChars=\(textChars)")
                            if !emitted, let text = event.text, !text.isEmpty {
                                emitted = true
                                continuation.yield(.text(text))
                            }
                            if event.status?.lowercased() == "error" {
                                throw CursorAPIError(status: 0, message: event.error ?? "The run failed.")
                            }
                            if let agentID { bridge.agentStarted(agentID) }
                        case "error":
                            bridge.debugLog.add("event error \(event.message ?? "")")
                            throw CursorAPIError(status: 0, message: event.message ?? "The run failed.")
                        default:
                            bridge.debugLog.add("event \(event.type)")
                        }
                    }
                    ChatTrace.event("provider.stream complete emitted=\(emitted)")
                    bridge.debugLog.add("stream complete emitted=\(emitted) textChars=\(textChars) turn=\(bridge.turn.count) wait=\(bridge.waitState)")
                    bridge.completeRunningTools()
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    bridge.failRunningTools()
                    ChatTrace.event("provider.stream error: \(error.localizedDescription)")
                    bridge.debugLog.add("stream error \(error.localizedDescription)")
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
