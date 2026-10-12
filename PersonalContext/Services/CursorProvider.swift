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
    /// The chat this turn belongs to, so its writes can be traced back to it.
    var conversationId = ""
    var codeRoots: [ProjectCodeRoot]
    var includeMembraeTools: Bool
    var includeProjectTools: Bool
    var includeWorkerTool: Bool = false
    var includeFinishRun: Bool = false
    var allowedTools: [String] = []
    var runtime: String
    var cloudRepos: [RunnerCloudRepo]
    var codeSnapshots: [RunnerCodeSnapshot] = []
    var readProvenancePath: String = ""
    var images: [RunnerImage] = []
    var externalTools: [RunnerExternalTool] = []
    var includeMCPImport = false
}

struct RunnerImage: Encodable, Sendable {
    var data: String
    var mimeType: String
}

struct RunnerExternalTool: Encodable, Sendable {
    var name: String
    var description: String
    var parametersJSON: String
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

extension RunnerRequest {
    var reuseKey: String {
        [
            runtime,
            cwd,
            model,
            includeMembraeTools ? "membrae" : "",
            includeProjectTools ? "code" : "",
            includeWorkerTool ? "worker" : "",
            includeFinishRun ? "finish" : "",
            includeMCPImport ? "mcp-import" : "",
            allowedTools.joined(separator: ","),
            externalTools.map(\.name).joined(separator: ","),
            mcpCommand,
            apiKey
        ].joined(separator: "\u{1e}")
    }
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

@MainActor
@Observable
final class CursorConversationBridge {
    let workspace: ChatWorkspace
    var conversation: Conversation {
        get { workspace.conversation }
        set { workspace.conversation = newValue }
    }
    var project: Project? {
        get { workspace.project }
        set { workspace.project = newValue }
    }
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var processInput: FileHandle?
    @ObservationIgnored private var runnerFingerprint = ""
    @ObservationIgnored private var runnerBooted = false
    @ObservationIgnored private var keepRunnerHot = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var readerTask: Task<Void, Never>?
    @ObservationIgnored private var turnEvents: AsyncThrowingStream<RunnerEvent, Error>.Continuation?
    @ObservationIgnored private var activeCodeRoots: [ProjectCodeRoot] = []
    var debugLog: ChatDebugLog { workspace.debugLog }
    var mcp: MembraeMCPClient { workspace.mcp }

    init(workspace: ChatWorkspace) {
        self.workspace = workspace
    }

    convenience init(conversation: Conversation, project: Project?, debugLog: ChatDebugLog? = nil) {
        self.init(workspace: ChatWorkspace(conversation: conversation, project: project, debugLog: debugLog ?? ChatDebugLog()))
    }

    func prepareCodeRoots() async throws -> [ProjectCodeRoot] {
        let store = conversation.modelContext?.container.configurations.first?.url
        let roots = try await ProjectCodeWorkspace.prepare(for: project, storeURL: store)
        activeCodeRoots = roots
        return roots
    }

    func currentCodeRoots() async throws -> [ProjectCodeRoot] {
        let store = conversation.modelContext?.container.configurations.first?.url
        let current = ProjectCodeWorkspace.authorizedRoots(for: project, storeURL: store)
        if !current.isEmpty {
            keepAccess(to: current)
            return current
        }
        return try await prepareCodeRoots()
    }

    func encodedCurrentCodeRoots() async throws -> String {
        try ProjectCodeWorkspace.encodedRoots(try await currentCodeRoots())
    }

    func keepAccess(to roots: [ProjectCodeRoot]) {
        activeCodeRoots = roots
    }

    func prepare(
        userText: String,
        apiKey: String,
        model: String,
        codeRoots: [ProjectCodeRoot],
        includeMembraeTools: Bool = true,
        includeProjectTools: Bool = true,
        resumeSession: Bool = true,
        runtime: WorkerPath = .local,
        history: [TalkMessage] = []
    ) async throws -> (request: RunnerRequest, metadata: ChatTurnMetadata) {
        guard let mcp = Bundle.main.url(forAuxiliaryExecutable: "membrae-mcp") else {
            throw CursorAPIError(status: 0, message: "The Membrae MCP is missing from the app.")
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
        var metadata = ChatTurnMetadata()
        let title: String
        if conversation.title == "New chat" || conversation.title.isEmpty {
            title = conversationTitle(from: userText)
            metadata.title = title
        } else {
            title = conversation.title
        }
        let focused = conversation.thread
        let context = project.map(ContextBuilder.identity(for:)) ?? ""
        let routing = self.workspace.routing(includeMembraeTools: includeMembraeTools)
        if opening {
            metadata.contextSnapshot = context.isEmpty ? routing : context
        }
        let workspace = codeRoots.count == 1
            ? codeRoots[0].path
            : (codeRoots.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path } ?? folder.path)
        let request = RunnerRequest(
            apiKey: apiKey,
            env: ProcessInfo.processInfo.environment,
            agentId: opening ? nil : conversation.externalSessionID,
            name: title,
            text: includeMembraeTools
                ? ContextBuilder.prompt(
                    userText: userText,
                    context: context,
                    opening: opening,
                    focusedThread: focused,
                    transcript: opening ? TalkMessage.conversationTranscript(history) : nil,
                    routing: routing
                )
                : ContextBuilder.codeConsultationPrompt(userText: userText, context: context),
            model: model,
            cwd: workspace,
            mcpCommand: mcp.path,
            conversationId: conversation.id.uuidString,
            codeRoots: codeRoots,
            includeMembraeTools: includeMembraeTools,
            includeProjectTools: includeProjectTools,
            includeWorkerTool: includeMembraeTools && ProjectWorker.isConfigured(on: project),
            runtime: runtime.rawValue,
            cloudRepos: cloudRepositories(),
            codeSnapshots: includeProjectTools && runtime == .local
                ? ProjectCodeWorkspace.remoteSnapshots(for: project, storeURL: store)
                : [],
            externalTools: includeMembraeTools ? await externalMCPTools() + BrowserTools.providerTools() : [],
            includeMCPImport: includeMembraeTools
        )
        return (request, metadata)
    }

    private func externalMCPTools() async -> [RunnerExternalTool] {
        guard let projectID = project?.id else { return [] }
        return await MCPRuntime.shared.definitions(projectID: projectID).map { tool in
            let parameters = tool.providerDefinition["parameters"] as? [String: Any] ?? tool.schema
            let schema = (try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"type":"object","properties":{}}"#
            return RunnerExternalTool(
                name: tool.namespacedName,
                description: tool.providerDefinition["description"] as? String ?? tool.description,
                parametersJSON: schema
            )
        }
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

    func prepareProviderTurn(userText: String, includeMembraeTools: Bool = true) -> (prompt: String, metadata: ChatTurnMetadata) {
        workspace.prepareTurn(userText: userText, includeMembraeTools: includeMembraeTools)
    }

    func run(_ request: RunnerRequest) throws -> AsyncThrowingStream<RunnerEvent, Error> {
        keepRunnerHot = request.includeMembraeTools
        try ensureRunner(request)
        return AsyncThrowingStream { continuation in
            if turnEvents != nil {
                continuation.finish(throwing: CursorAPIError(status: 0, message: "This conversation already has a run."))
                return
            }
            turnEvents = continuation
            do {
                try writeTurn(request)
            } catch {
                turnEvents = nil
                continuation.finish(throwing: error)
            }
        }
    }

    func stop() {
        closeRunner()
    }

    func finished() {
        if keepRunnerHot, process?.isRunning == true {
            bumpIdle()
            return
        }
        closeRunner()
    }

    func replyToHostTool(id: String, text: String? = nil, error: String? = nil) {
        guard let processInput else { return }
        var payload: [String: String] = ["type": "host_tool_result", "id": id]
        if let text { payload["text"] = text }
        if let error { payload["error"] = error }
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        try? processInput.write(contentsOf: data)
    }

    private func ensureRunner(_ request: RunnerRequest) throws {
        let key = request.reuseKey
        if process?.isRunning == true, runnerFingerprint == key, readerTask != nil, processInput != nil {
            idleTask?.cancel()
            idleTask = nil
            ChatTrace.event("runner reuse pid=\(process?.processIdentifier ?? 0)")
            debugLog.add("runner reuse pid=\(process?.processIdentifier ?? 0)")
            return
        }
        closeRunner()
        guard let node = Bundle.main.url(forAuxiliaryExecutable: "membrae-node"),
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
        self.runnerFingerprint = key
        self.runnerBooted = false
        ChatTrace.event("runner started pid=\(process.processIdentifier) resume=\(request.agentId != nil)")
        startReader(output.fileHandleForReading, exits: exits)
    }

    private func writeTurn(_ request: RunnerRequest) throws {
        guard let processInput else {
            throw CursorAPIError(status: 0, message: "The agent runner is not running.")
        }
        let payload: Data
        if runnerBooted {
            payload = try JSONEncoder().encode(RunnerTurnMessage(text: request.text, model: request.model))
        } else {
            runnerBooted = true
            payload = try JSONEncoder().encode(request)
        }
        var line = payload
        line.append(0x0A)
        try processInput.write(contentsOf: line)
    }

    private func startReader(_ reader: FileHandle, exits: AsyncStream<Int32>) {
        readerTask = Task.detached { [weak self] in
            var sawEnd = false
            for await line in PipeLines.stream(reader) {
                guard let event = try? JSONDecoder().decode(RunnerEvent.self, from: Data(line.utf8)) else { continue }
                if event.type == "result" || event.type == "error" { sawEnd = true }
                await self?.deliver(event)
            }
            var status: Int32 = 0
            for await code in exits { status = code }
            await self?.runnerDied(status: status, sawEnd: sawEnd)
        }
    }

    private func deliver(_ event: RunnerEvent) {
        turnEvents?.yield(event)
        if event.type == "result" || event.type == "error" {
            turnEvents?.finish()
            turnEvents = nil
        }
    }

    private func failTurn(_ error: Error) {
        turnEvents?.finish(throwing: error)
        turnEvents = nil
    }

    private func runnerDied(status: Int32, sawEnd: Bool) {
        ChatTrace.event("runner exited status=\(status)")
        if turnEvents != nil, !sawEnd, status != 0, status != 130 {
            failTurn(CursorAPIError(status: 0, message: "The agent stopped unexpectedly (exit \(status))."))
        } else {
            turnEvents?.finish()
            turnEvents = nil
        }
        processInput = nil
        process = nil
        runnerBooted = false
        runnerFingerprint = ""
        readerTask = nil
    }

    private func bumpIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8 * 60))
            guard !Task.isCancelled else { return }
            self?.closeRunner()
        }
    }

    private func closeRunner() {
        idleTask?.cancel()
        idleTask = nil
        turnEvents?.finish()
        turnEvents = nil
        readerTask?.cancel()
        readerTask = nil
        try? processInput?.close()
        processInput = nil
        if let process, process.isRunning {
            ChatTrace.event("runner stop pid=\(process.processIdentifier)")
            process.terminate()
        }
        process = nil
        runnerBooted = false
        runnerFingerprint = ""
        ProjectCodeWorkspace.stopAccessing(activeCodeRoots)
        activeCodeRoots = []
    }

    private struct RunnerTurnMessage: Encodable {
        var type = "turn"
        var text: String
        var model: String
    }
}

struct CursorChatProvider: ChatProvider {
    let id = "cursor"
    let name = "Cursor"
    let bridge: CursorConversationBridge
    var includeMembraeTools = true
    var includeProjectTools = true
    var resumeConversation = true
    var runtime: WorkerPath = .local

    var zeroResponseMessage: String { "Cursor didn’t return a reply." }

    func attach(conversation: Conversation, project: Project?) {
        bridge.workspace.attach(conversation: conversation, project: project)
    }

    func stream(
        messages: [TalkMessage],
        model: String,
        options: ChatTurnOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let extracted = AttachmentPrep.labelledExtraction(in: options.attachments)
        let rawUser = messages.last(where: { $0.role == .user })?.text ?? ""
        let userText = [rawUser, extracted].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let images = options.attachments.compactMap { item -> RunnerImage? in
            guard case .nativeImage = item.route else { return nil }
            return RunnerImage(data: item.data.base64EncodedString(), mimeType: item.ref.mimeType)
        }
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
                        continuation.yield(.text(text))
                        current.painted(text.count, applyMs: Date().timeIntervalSince(applyStart) * 1000)
                        bridge.debugLog.pace = current
                        if current.paintEvents == 1 {
                            bridge.debugLog.add("pace \(current.logLine)")
                        }
                        return current
                    }
                }

                func emitTool(name: String, status: String, id: String?, detail: String?, sources: [RunnerSource]? = nil) {
                    continuation.yield(.tool(
                        name: name,
                        status: status,
                        id: id,
                        detail: detail,
                        sources: ChatSource.make(from: sources)
                    ))
                }
                func flushText() async {
                    if let leftover = coalescer.take() {
                        await emitText(leftover)
                    }
                }
                do {
                    let prepared = try await prepareCursorTurn(
                        bridge: bridge,
                        userText: userText,
                        model: model,
                        messages: messages,
                        images: images,
                        includeMembraeTools: includeMembraeTools,
                        includeProjectTools: includeProjectTools,
                        resumeConversation: resumeConversation,
                        runtime: runtime
                    )
                    let request = prepared.0
                    continuation.yield(.metadata(prepared.1))
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
                            if let text = event.text {
                                continuation.yield(.reasoning(text))
                            }
                        case "status":
                            if let status = event.status {
                                continuation.yield(.status(status))
                            }
                            await MainActor.run {
                                bridge.debugLog.add("event status \(event.status ?? "")")
                            }
                        case "host_tool":
                            await flushText()
                            let toolID = event.id ?? UUID().uuidString
                            let toolName = event.name ?? "consult_code"
                            let brief = event.text ?? event.detail ?? ""
                            emitTool(name: toolName, status: "running", id: toolID, detail: hostToolDetail(name: toolName, brief: brief))
                            await MainActor.run {
                                bridge.debugLog.add("event host_tool \(toolName) \(ChatTrace.clip(brief, 80))")
                            }
                            do {
                                let output: String
                                if toolName == "resolve_project_code_roots" {
                                    output = try await bridge.encodedCurrentCodeRoots()
                                } else if BrowserTools.isBrowser(toolName) {
                                    output = try await BrowserRuntime.shared.execute(
                                        name: toolName,
                                        arguments: jsonObject(brief),
                                        context: BrowserCallContext(projectID: bridge.project?.id)
                                    )
                                } else if toolName == MCPToolName.importServers || MCPToolName.isExternal(toolName) {
                                    output = try await MCPRuntime.shared.execute(
                                        name: toolName,
                                        arguments: jsonObject(brief),
                                        projectID: bridge.project?.id
                                    )
                                } else {
                                    output = try await ProjectWorker.consult(
                                        brief: brief,
                                        reportingTo: bridge.workspace,
                                        options: options
                                    ) { name, status, id, detail in
                                        continuation.yield(.tool(
                                            name: name,
                                            status: status,
                                            id: id,
                                            detail: detail,
                                            sources: []
                                        ))
                                    }
                                }
                                emitTool(name: toolName, status: "completed", id: toolID, detail: hostToolDetail(name: toolName, brief: brief, result: output))
                                await MainActor.run { bridge.replyToHostTool(id: toolID, text: output) }
                            } catch {
                                emitTool(
                                    name: toolName,
                                    status: "error",
                                    id: toolID,
                                    detail: error.localizedDescription
                                )
                                await MainActor.run {
                                    bridge.replyToHostTool(id: toolID, error: error.localizedDescription)
                                }
                            }
                        case "tool":
                            await flushText()
                            emitTool(
                                name: event.name ?? "",
                                status: event.status ?? "",
                                id: event.id,
                                detail: event.detail,
                                sources: event.sources
                            )
                            await MainActor.run {
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
                                continuation.yield(.metadata(ChatTurnMetadata(externalSessionID: agentID)))
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
                        bridge.debugLog.add("stream complete emitted=\(emitted) textChars=\(textChars)")
                        if emitted {
                            bridge.finished()
                        } else {
                            bridge.stop()
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    await MainActor.run {
                        ChatTrace.event("provider.stream error: \(error.localizedDescription)")
                        bridge.debugLog.add("stream error \(error.localizedDescription)")
                        bridge.stop()
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
}

@MainActor
private func prepareCursorTurn(
    bridge: CursorConversationBridge,
    userText: String,
    model: String,
    messages: [TalkMessage],
    images: [RunnerImage],
    includeMembraeTools: Bool,
    includeProjectTools: Bool,
    resumeConversation: Bool,
    runtime: WorkerPath
) async throws -> (RunnerRequest, ChatTurnMetadata) {
    bridge.debugLog.add("stream start model=\(model) messages=\(messages.count)")
    for (index, message) in messages.enumerated() {
        bridge.debugLog.add("  msg[\(index)] \(message.role) \(ChatTrace.clip(message.text, 80))")
    }
    guard let apiKey = KeychainStore.read(.cursorAPIKey) else {
        throw CursorAPIError(status: 0, message: "Add a Cursor API key in Settings.")
    }
    let roots = runtime == .local && includeProjectTools
        ? ProjectCodeWorkspace.localRoots(for: bridge.project)
        : []
    bridge.keepAccess(to: roots)
    let prepared = try await bridge.prepare(
        userText: userText.isEmpty ? " " : userText,
        apiKey: apiKey,
        model: model,
        codeRoots: roots,
        includeMembraeTools: includeMembraeTools,
        includeProjectTools: includeProjectTools,
        resumeSession: resumeConversation,
        runtime: runtime,
        history: messages
    )
    var request = prepared.request
    request.images = images
    bridge.debugLog.add("prepare opening=\(request.agentId == nil) model=\(request.model) promptChars=\(request.text.count) images=\(images.count)")
    return (request, prepared.metadata)
}

private func jsonObject(_ text: String) -> [String: Any] {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

private func hostToolDetail(name: String, brief: String, result: String? = nil) -> String {
    var arguments = jsonObject(brief)
    if arguments.isEmpty, URL(string: brief)?.scheme?.hasPrefix("http") == true {
        arguments = ["url": brief]
    }
    let detail = ChatToolActivity.detail(for: name, arguments: arguments, result: result)
    return detail.isEmpty ? clip(brief, 80) : detail
}
