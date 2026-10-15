import Foundation

/// A coding tool installed on this Mac that Membrae hands work to. It runs with the user's own install and login.
enum LocalAgent: String, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude-code"
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var installURL: URL {
        switch self {
        case .claudeCode: URL(string: "https://claude.com/product/claude-code")!
        case .codex: URL(string: "https://openai.com/codex")!
        }
    }

    /// What the user types in Terminal to sign in.
    var signInCommand: String {
        switch self {
        case .claudeCode: "claude auth login"
        case .codex: "codex login"
        }
    }

    /// Passed to membrae-mcp so a worker sees only the tools its Run allows.
    static let allowedToolsVariable = "MEMBRAE_ALLOWED_TOOLS"
    /// Passed to membrae-mcp so the worker's plan lands on its own Run.
    static let runIDVariable = "MEMBRAE_RUN_ID"

    /// The sandbox container is not the user's home. The tools keep their login in the real one.
    static var home: String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return NSHomeDirectory()
        }
        return String(cString: directory)
    }

    var candidates: [String] {
        switch self {
        case .claudeCode:
            [Self.home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            [
                "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
                Self.home + "/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]
        }
    }

    func locate() -> URL? {
        candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Claude Code opens `/tmp/claude-<uid>` unless told otherwise, which the sandbox refuses.
    static func environment() -> [String: String] {
        let temporary = NSTemporaryDirectory()
        return [
            "HOME": home,
            "USER": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporary,
            "CLAUDE_CODE_TMPDIR": temporary,
            "LANG": "en_US.UTF-8"
        ]
    }
}

struct LocalAgentRequest: Equatable, Sendable {
    var prompt: String
    var directory: String
    /// Lets the worker change files and run commands. Membrae passes this on; the tool enforces it.
    var allowEdits: Bool
    var mcpCommand: String?
    var membraeTools: [String] = []
    var runID: String = ""
    /// Carries on an earlier session with `prompt` as the user's reply, so the worker keeps what it knew.
    var resumeSessionID: String?
}

struct LocalAgentError: LocalizedError, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension LocalAgent {
    func arguments(for request: LocalAgentRequest) -> [String] {
        let tools = request.membraeTools.joined(separator: ",")
        let mcp = request.membraeTools.isEmpty ? nil : request.mcpCommand
        switch self {
        case .claudeCode:
            var arguments = ["-p", request.prompt, "--output-format", "stream-json", "--verbose", "--strict-mcp-config"]
            if let session = request.resumeSessionID, !session.isEmpty {
                arguments += ["--resume", session]
            }
            var allowed: [String] = []
            if request.allowEdits {
                arguments += ["--permission-mode", "acceptEdits"]
                allowed.append("Bash")
            }
            if let mcp {
                let config: [String: Any] = [
                    "mcpServers": [
                        "membrae": [
                            "command": mcp,
                            "args": [String](),
                            "env": [Self.allowedToolsVariable: tools, Self.runIDVariable: request.runID]
                        ]
                    ]
                ]
                if let data = try? JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]) {
                    arguments += ["--mcp-config", String(decoding: data, as: UTF8.self)]
                    allowed.append("mcp__membrae")
                }
            }
            if !allowed.isEmpty {
                arguments += ["--allowedTools", allowed.joined(separator: ",")]
            }
            return arguments
        case .codex:
            // Codex wraps every command in its own sandbox, which cannot start inside Membrae's.
            // With edits allowed that inner sandbox is turned off; Membrae's still applies.
            var arguments = [
                "exec", "--json", "--skip-git-repo-check",
                "-C", request.directory,
                "-s", request.allowEdits ? "danger-full-access" : "read-only"
            ]
            if let mcp {
                arguments += [
                    "-c", "mcp_servers.membrae.command=\(Self.toml(mcp))",
                    "-c", "mcp_servers.membrae.env={\(Self.allowedToolsVariable)=\(Self.toml(tools)),\(Self.runIDVariable)=\(Self.toml(request.runID))}"
                ]
            }
            arguments.append(request.prompt)
            return arguments
        }
    }

    private static func toml(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum LocalAgentEvent: Equatable, Sendable {
    /// What the worker is doing right now, in a few words.
    case activity(String)
    /// One whole message from the worker.
    case text(String)
    /// `refused` names the tools the worker asked for and was not allowed to use.
    case finished(summary: String, refused: [String])
    case failed(String)
    /// The id the worker gave this conversation, for carrying it on later.
    case session(String)
}

extension LocalAgent {
    func events(fromLine line: String) -> [LocalAgentEvent] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = object["type"] as? String
        else { return [] }
        switch self {
        case .claudeCode: return claudeEvents(type: type, object: object)
        case .codex: return codexEvents(type: type, object: object)
        }
    }

    private func claudeEvents(type: String, object: [String: Any]) -> [LocalAgentEvent] {
        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let session = object["session_id"] as? String, !session.isEmpty else {
                return []
            }
            return [.session(session)]
        case "assistant":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : .text(text)
                case "tool_use":
                    return .activity(Self.activity(forTool: block["name"] as? String ?? ""))
                case "thinking":
                    return .activity("Thinking")
                default:
                    return nil
                }
            }
        case "result":
            let text = (object["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if object["is_error"] as? Bool == true {
                let subtype = object["subtype"] as? String ?? "error"
                return [.failed(text.isEmpty ? "\(title) stopped with \(subtype)." : text)]
            }
            let denials = object["permission_denials"] as? [[String: Any]] ?? []
            var refused: [String] = []
            for name in denials.compactMap({ $0["tool_name"] as? String }) where !refused.contains(name) {
                refused.append(name)
            }
            return [.finished(summary: text, refused: refused)]
        default:
            return []
        }
    }

    private func codexEvents(type: String, object: [String: Any]) -> [LocalAgentEvent] {
        switch type {
        case "item.started", "item.completed":
            guard let item = object["item"] as? [String: Any] else { return [] }
            switch item["type"] as? String {
            case "agent_message":
                guard type == "item.completed" else { return [] }
                let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? [] : [.text(text)]
            case "command_execution":
                return type == "item.started" ? [.activity("Running a command")] : []
            case "file_change":
                return [.activity("Editing files")]
            case "mcp_tool_call":
                return type == "item.started" ? [.activity(Self.activity(forTool: item["tool"] as? String ?? ""))] : []
            case "reasoning":
                return [.activity("Thinking")]
            default:
                return []
            }
        case "turn.completed":
            return [.finished(summary: "", refused: [])]
        case "turn.failed":
            let message = (object["error"] as? [String: Any])?["message"] as? String
            return [.failed(message ?? "\(title) could not finish.")]
        case "error":
            return [.failed(object["message"] as? String ?? "\(title) reported an error.")]
        default:
            return []
        }
    }

    static func activity(forTool name: String) -> String {
        let bare = name.split(separator: "__").last.map(String.init) ?? name
        switch bare {
        case "Bash", "BashOutput": return "Running a command"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing files"
        case "Read", "Grep", "Glob", "LS": return "Reading code"
        case "WebSearch", "WebFetch": return "Searching the web"
        case "": return "Working"
        default:
            return name.contains("membrae") ? "Updating Membrae" : "Working"
        }
    }

    /// Says whose limit it was, so a refusal does not read as Membrae failing.
    func refusalNote(_ refused: [String], allowEdits: Bool) -> String {
        guard !refused.isEmpty else { return "" }
        let names = refused.joined(separator: ", ")
        if allowEdits {
            return "\(title) was not allowed to use \(names). That limit comes from \(title)’s own settings on this Mac."
        }
        return "\(title) was not allowed to use \(names). Start the Run again with “Let it edit files and run commands” turned on."
    }
}

struct LocalAgentStatus: Equatable, Sendable {
    var path: String?
    var signedIn = false
    var account = ""

    var isReady: Bool { path != nil && signedIn }
}

extension LocalAgent {
    func status() async -> LocalAgentStatus {
        guard let executable = locate() else { return LocalAgentStatus() }
        var status = LocalAgentStatus(path: executable.path)
        switch self {
        case .claudeCode:
            let result = await LocalAgentShell.capture(executable, ["auth", "status"])
            let object = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any]
            status.signedIn = object?["loggedIn"] as? Bool ?? false
            let email = object?["email"] as? String ?? ""
            let plan = (object?["subscriptionType"] as? String ?? "").capitalized
            status.account = [email, plan].filter { !$0.isEmpty }.joined(separator: " · ")
        case .codex:
            let result = await LocalAgentShell.capture(executable, ["login", "status"])
            let line = result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            status.signedIn = result.status == 0 && line.hasPrefix("Logged in")
            status.account = line.replacingOccurrences(of: "Logged in using ", with: "")
        }
        return status
    }

    /// Sends one harmless request and returns the reply.
    @MainActor
    func test() async throws -> String {
        guard let executable = locate() else {
            throw LocalAgentError("\(title) is not installed on this Mac.")
        }
        let process = LocalAgentProcess()
        defer { process.stop() }
        let request = LocalAgentRequest(
            prompt: "Reply with the single word OK.",
            directory: NSTemporaryDirectory(),
            allowEdits: false
        )
        var reply = ""
        for try await event in try process.start(self, executable: executable, request: request) {
            switch event {
            case .text(let text): reply = text
            case .finished(let summary, _): if !summary.isEmpty { reply = summary }
            case .failed(let message): throw LocalAgentError(message)
            case .activity, .session: break
            }
        }
        guard !reply.isEmpty else { throw LocalAgentError("\(title) did not answer.") }
        return reply
    }
}

enum LocalAgentShell {
    static func capture(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval = 20
    ) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = LocalAgent.environment()
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let output = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                return (Int32(-1), error.localizedDescription)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

/// Keeps the end of a worker's error output for the message shown when it dies.
private final class LocalAgentErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ more: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(more)
        if data.count > 4000 { data.removeFirst(data.count - 4000) }
    }

    var lastLine: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

@MainActor
final class LocalAgentProcess {
    private var process: Process?
    private var relay: WorkerRelay.Handle?

    func start(
        _ agent: LocalAgent,
        executable: URL,
        request: LocalAgentRequest
    ) throws -> AsyncThrowingStream<LocalAgentEvent, Error> {
        stop()
        if BrowserSupport.helperAppURL != nil {
            return startRelayed(agent, executable: executable, request: request)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = agent.arguments(for: request)
        process.environment = LocalAgent.environment()
        process.currentDirectoryURL = URL(fileURLWithPath: request.directory, isDirectory: true)
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let tail = LocalAgentErrorTail()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                tail.append(data)
            }
        }
        let exits = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        self.process = process
        return AsyncThrowingStream { continuation in
            let reader = Task.detached {
                var ended = false
                for await line in PipeLines.stream(output.fileHandleForReading) {
                    for event in agent.events(fromLine: line) {
                        switch event {
                        case .finished, .failed: ended = true
                        case .activity, .text, .session: break
                        }
                        continuation.yield(event)
                    }
                }
                var status: Int32 = 0
                for await code in exits { status = code }
                if !ended, status != 0, status != 15 {
                    let detail = tail.lastLine
                    let message = "\(agent.title) stopped before finishing (exit \(status))."
                    continuation.finish(throwing: LocalAgentError(detail.isEmpty ? message : "\(message) \(detail)"))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { [weak self] _ in
                reader.cancel()
                Task { @MainActor in self?.stop() }
            }
        }
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        relay?.stop()
        relay = nil
    }

    /// The tool runs outside Membrae's sandbox, started by Launch Services through the helper app, so it can
    /// write to the user's repository. Its output comes back through files the relay tails.
    private func startRelayed(
        _ agent: LocalAgent,
        executable: URL,
        request: LocalAgentRequest
    ) -> AsyncThrowingStream<LocalAgentEvent, Error> {
        // Outside the sandbox the tool's own temporary folder is fine; only the app's needed pointing elsewhere.
        var environment = LocalAgent.environment()
        environment.removeValue(forKey: "TMPDIR")
        environment.removeValue(forKey: "CLAUDE_CODE_TMPDIR")
        let ticket = WorkerRelay.Ticket(
            id: UUID().uuidString,
            executable: executable.path,
            arguments: agent.arguments(for: request),
            environment: environment,
            directory: request.directory
        )
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                do {
                    let handle = try await WorkerRelay.launch(ticket) { line in
                        continuation.yield(.activity(line))
                    }
                    self?.relay = handle
                    var ended = false
                    for await line in handle.lines {
                        try Task.checkCancellation()
                        for event in agent.events(fromLine: line) {
                            switch event {
                            case .finished, .failed: ended = true
                            case .activity, .text, .session: break
                            }
                            continuation.yield(event)
                        }
                    }
                    let status = await handle.exitStatus()
                    if status == WorkerRelay.neverStarted {
                        continuation.finish(throwing: LocalAgentError("The worker helper did not start. The lines above say how far it got."))
                        return
                    }
                    if !ended, status != 0, status != 15 {
                        let detail = WorkerRelay.lastErrorLine(for: ticket.id)
                        let message = "\(agent.title) stopped before finishing (exit \(status))."
                        continuation.finish(throwing: LocalAgentError(detail.isEmpty ? message : "\(message) \(detail)"))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                Task { @MainActor in self?.stop() }
            }
        }
    }
}
