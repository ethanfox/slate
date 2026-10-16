import Foundation
import SwiftData

enum RunLiveEvent {
    case wait(String)
    case text(String)
    case citation(url: String, title: String)
}

@MainActor
final class RunCursorProcess {
    private var process: Process?
    private var processInput: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var events: AsyncThrowingStream<RunnerEvent, Error>.Continuation?

    func start(_ request: RunnerRequest) throws -> AsyncThrowingStream<RunnerEvent, Error> {
        stop()
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
            if data.isEmpty { handle.readabilityHandler = nil }
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
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: payload)
        return AsyncThrowingStream { continuation in
            self.events = continuation
            self.readerTask = Task.detached { [weak self] in
                var sawEnd = false
                for await line in PipeLines.stream(output.fileHandleForReading) {
                    guard let event = try? JSONDecoder().decode(RunnerEvent.self, from: Data(line.utf8)) else { continue }
                    if event.type == "result" || event.type == "error" { sawEnd = true }
                    await self?.yield(event)
                }
                var status: Int32 = 0
                for await code in exits { status = code }
                await self?.died(status: status, sawEnd: sawEnd)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
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

    func stop() {
        events?.finish()
        events = nil
        readerTask?.cancel()
        readerTask = nil
        try? processInput?.close()
        processInput = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func yield(_ event: RunnerEvent) {
        events?.yield(event)
        if event.type == "result" || event.type == "error" {
            events?.finish()
            events = nil
        }
    }

    private func fail(_ error: Error) {
        events?.finish(throwing: error)
        events = nil
    }

    private func died(status: Int32, sawEnd: Bool) {
        if events != nil, !sawEnd, status != 0, status != 130 {
            fail(CursorAPIError(status: 0, message: "The agent stopped unexpectedly (exit \(status))."))
        } else {
            events?.finish()
            events = nil
        }
        processInput = nil
        process = nil
        readerTask = nil
    }
}

enum RunChatGPT {
    static func stream(
        instructions: String,
        userText: String,
        model: String,
        gateway: RunGateway
    ) -> AsyncThrowingStream<RunLiveEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var coalescer = StreamTextCoalescer()
                    let tools = try await gateway.definitions()
                    try await AgentRuntime.run(
                        instructions: instructions,
                        input: [["role": "user", "content": userText]],
                        tools: tools,
                        maxRounds: ChatGPTProvider.maxToolRounds,
                        transport: ChatGPTTransport(model: model),
                        gateway: gateway,
                        onEvent: { event in
                            switch event {
                            case .text(let delta):
                                if let chunk = coalescer.push(delta) {
                                    continuation.yield(.text(chunk))
                                }
                            case .thinking:
                                continuation.yield(.wait(ChatWaitState.thinking.label))
                            case .callStarted(let call), .callFinished(let call, _):
                                continuation.yield(.wait(RunWaitLabel.forTool(call.name)))
                            }
                        }
                    )
                    if let leftover = coalescer.take() {
                        continuation.yield(.text(leftover))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
            }
        }
    }
}

/// The chat agent's way to open the New Run form. The user checks it and starts the Run; the agent never does.
@MainActor
enum RunFormTool {
    static let name = "start_run"
    static weak var app: AppModel?

    static let definition: [String: Any] = [
        "type": "function",
        "name": name,
        "description": "Open the New Run form for the user, filled in, so they can check it and start it. Call this when the user asks to run something, to have work done in the background, or to send work to Claude Code or Codex. It does not start the Run. Afterwards tell the user the form is open; do not say the Run has started.",
        "parameters": [
            "type": "object",
            "properties": [
                "brief": [
                    "type": "string",
                    "description": "What the Run should do, written so the worker can act on it without this conversation."
                ],
                "worker": [
                    "type": "string",
                    "enum": ["membrae", LocalAgent.claudeCode.rawValue, LocalAgent.codex.rawValue],
                    "description": "Who does the work. membrae is the built-in agent. Use claude-code or codex only when the user names one or the work is changing code."
                ],
                "space_id": [
                    "type": "string",
                    "description": "The Space the Run belongs to, when the conversation is not already in one."
                ]
            ] as [String: Any],
            "required": ["brief"]
        ] as [String: Any]
    ]

    static var providerTool: RunnerExternalTool {
        let parameters = definition["parameters"] as? [String: Any] ?? [:]
        let schema = (try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"type":"object","properties":{}}"#
        return RunnerExternalTool(
            name: name,
            description: definition["description"] as? String ?? "",
            parametersJSON: schema
        )
    }

    static func open(arguments: [String: Any], projectID: UUID?, conversationID: UUID?) throws -> String {
        guard let app else { throw LocalAgentError("The New Run form is not available.") }
        let brief = (arguments["brief"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { throw LocalAgentError("brief is required") }
        let context = app.container.mainContext
        let named = ((arguments["space_id"] as? String) ?? (arguments["project_id"] as? String)).flatMap(UUID.init(uuidString:))
        let project = (projectID ?? named).flatMap { TitleIndexStore.project($0, in: context) }
        let defaults = app.runDefaults(for: project)
        var draft = NewRunDraft.blank(
            origin: .chat,
            projectID: project?.id,
            originChatID: conversationID,
            brief: brief,
            providerID: defaults.provider,
            modelID: defaults.model,
            pathRaw: defaults.path
        )
        if let agent = (arguments["worker"] as? String).flatMap(LocalAgent.init(rawValue:)) {
            guard app.isConnected(agent) else {
                throw LocalAgentError("\(agent.title) is not connected. The user can connect it in Settings under AI Providers.")
            }
            draft.providerID = agent.rawValue
            draft.modelID = ""
        }
        if let project {
            let attachments = ProjectCodeWorkspace.attachments(on: project)
            if attachments.count == 1, let only = attachments.first {
                draft.repositoryLocators = [only.locator.isEmpty ? only.title : only.locator]
            }
        }
        app.present(.newRun(draft))
        return "The New Run form is open for the user to check and start. The Run has not started."
    }
}

enum RunWaitLabel {
    static func forTool(_ name: String) -> String {
        switch name {
        case "webSearch", "browser_search": return "Searching the web"
        case "webFetch": return "Fetching a page"
        case let name where name.hasPrefix("browser_"): return "Browsing"
        case "create_note", "update_note": return "Writing a note"
        case RunToolPolicy.finishRun: return ChatWaitState.writing.label
        default:
            return ChatToolActivity.title(for: name, status: .running)
        }
    }

    static func forCursor(_ event: RunnerEvent) -> String? {
        if event.type == "tool", let name = event.name {
            return forTool(name)
        }
        switch event.type {
        case "status" where event.status?.uppercased() == "CREATING":
            return ChatWaitState.starting.label
        case "thinking":
            return ChatWaitState.thinking.label
        case "text":
            return ChatWaitState.writing.label
        default:
            return nil
        }
    }
}

enum RunPrompt {
    static func closeInstruction(hasProject: Bool) -> String {
        if hasProject {
            return "Do the job with the tools you have. Call finish_run with a short summary when you are done. If you cannot do what was asked, for example because it needs code changed and you cannot change code, call finish_run with outcome could_not and the reason; do not describe work you could not do as done. If you were given an assigned task and you finished it, mark it done with complete_task; if you did not finish it, leave it as it is. You can browse the public web with the browser_* tools. Prefer snapshots, cite source URLs, and do not bypass CAPTCHAs."
        }
        return "Do the job. Call finish_run with a short summary when you are done. If you cannot do what was asked, call finish_run with outcome could_not and the reason. You are in no Space; pass a space_id from list_spaces to file anything. You can browse the public web with the browser_* tools. Prefer snapshots, cite source URLs, and do not bypass CAPTCHAs."
    }

    static let stepsInstruction = "For a job with more than two or three parts, call set_run_steps before you start with your plan as short steps, and call it again each time you finish one, sending the whole list with that step marked done. The user watches the list to see how far along you are. Skip it for a job that is one step."

    /// For a coding tool on this Mac. It has no finish_run; its last message is the summary.
    static func localAgent(
        brief: String,
        project: Project?,
        directory: String?,
        allowEdits: Bool,
        hasMembrae: Bool,
        task: AgendaItem? = nil
    ) -> String {
        var lines: [String] = []
        if let project {
            lines.append(ContextBuilder.identity(for: project))
        }
        lines.append(assigned(task))
        if hasMembrae {
            lines.append("The membrae tools read and write this Space’s decisions, tracks, notes, tasks, and records in Membrae. Read what governs the work before you start. If you were given an assigned task and you finished it, mark it done with complete_task; if you did not finish it, leave it as it is.")
        }
        if allowEdits, let directory {
            lines.append("You are working in \(directory). Make the changes the brief asks for. If it is a git repository, commit what you change with a clear message. Do not push.")
        } else if allowEdits {
            lines.append("No code is attached to this run.")
        } else {
            lines.append("Do not change files. Report what you find, with file paths and line numbers.")
        }
        if hasMembrae { lines.append(stepsInstruction) }
        lines.append("Finish with a short summary of what you did.")
        lines.append(brief)
        return lines.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The first turn of a session on a track. The worker keeps this across turns through its own session.
    static func session(
        brief: String,
        track: ProjectThread?,
        project: Project?,
        directory: String?,
        extraDirectories: [String] = [],
        allowEdits: Bool,
        hasMembrae: Bool,
        branch: String? = nil
    ) -> String {
        var lines: [String] = []
        if let project {
            lines.append(ContextBuilder.identity(for: project))
        }
        lines.append("You are in a session on one track, and it lasts. You and the user take turns: you work, then say in a few lines what you did and what you suggest next, and stop. The user answers and you carry on with everything you knew. When you need a decision from them, ask and stop. The stops are a list, not a queue: work the stop the user points at, and the one you were on when they say nothing.")
        if let track {
            lines.append(ContextBuilder.focusedTrack(for: track))
        }
        if hasMembrae {
            lines.append("The membrae tools read and write this Space’s decisions, tracks, notes, tasks, and records. When you finish a stop, call mark_stop with its id. Work you leave for later goes in a task on its stop, with create_task and stop_id. Record what was decided with create_decision on the track. Each of your messages lists the stops as they stand now.")
        }
        if allowEdits, let directory {
            var line = "You are working in \(directory)."
            if !extraDirectories.isEmpty {
                line += " You may also read and write in: \(extraDirectories.joined(separator: ", "))."
            }
            if let branch {
                lines.append(line + " " + branchRule(branch))
            } else {
                lines.append(line + " Make the changes the work asks for. If it is a git repository, commit what you change with a clear message before you say what you did, so the user can relaunch the app and see it. Do not push.")
            }
        } else if allowEdits {
            lines.append("No code is attached to this session.")
        } else {
            lines.append("Do not change files. Report what you find, with file paths and line numbers.")
        }
        lines.append(brief)
        return lines.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A later turn of a session: the user's message, with the stops as they stand so the worker need not look.
    static func sessionTurn(
        message: String,
        track: ProjectThread?,
        extraDirectories: [String] = [],
        directory: String? = nil,
        branch: String? = nil
    ) -> String {
        var message = message
        if let directory, let branch {
            message += "\n\nYou are working in \(directory). " + branchRule(branch)
        }
        if !extraDirectories.isEmpty {
            message += "\n\nFolders you may work in besides the one you started in: \(extraDirectories.joined(separator: ", "))."
        }
        guard let track else { return message }
        let stops = track.orderedStops
        guard !stops.isEmpty else { return message }
        let list = stops.enumerated().map { index, stop in
            "\(index + 1). \(stop.isDone ? "done" : "open") · \(stop.displayTitle) (id \(stop.id.uuidString))"
        }
        return message + "\n\nStops now:\n" + list.joined(separator: "\n")
    }

    /// How a worker treats the track's branch: its own, pushed by Membrae, merged by the user.
    static func branchRule(_ branch: String) -> String {
        "This is the track's own checkout, on branch \(branch). Make the changes the work asks for and commit them with a clear message before you say what you did. Stay on this branch; do not push, merge, rebase, or switch branches. Membrae pushes the branch after each turn, and the user brings it into main from the Tracks view."
    }

    /// The task a Run was started from. The prompt may add to it or stand in for it.
    static func assigned(_ task: AgendaItem?) -> String {
        guard let task else { return "" }
        var text = "Assigned task: \(task.displayTitle) (id \(task.id.uuidString))."
        let comment = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty {
            text += "\nTask comment: \(comment)"
        }
        return text
    }

    /// Lets the prompt send the work to another Space by naming it.
    static func otherSpaces(besides space: Space?, in context: ModelContext?) -> String {
        guard let context else { return "" }
        let all = (try? context.fetch(FetchDescriptor<Space>(sortBy: [SortDescriptor(\.name)]))) ?? []
        let others = all.filter { $0.id != space?.id && $0.status != .done }.prefix(60)
        guard !others.isEmpty else { return "" }
        let list = others.map { "- \($0.name) (id \($0.id.uuidString))" }.joined(separator: "\n")
        let lead = space == nil
            ? "File what you make in the Space the prompt names, passing that Space’s id as space_id."
            : "If the prompt names another Space, do the notes and tasks work there, passing that Space’s id as space_id."
        return "\(lead)\n\(list)"
    }

    static func body(brief: String, project: Project?, run: AgentRun? = nil) -> String {
        let parts = [
            project.map(ContextBuilder.identity(for:)) ?? "",
            assigned(run?.task),
            otherSpaces(besides: project, in: run?.modelContext),
            closeInstruction(hasProject: project != nil),
            stepsInstruction,
            brief
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
