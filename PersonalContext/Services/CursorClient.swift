import Foundation
import os

enum ChatTrace {
    static let logger = Logger(subsystem: "com.ethanfox.PersonalContext", category: "chat")

    private static let lock = NSLock()
    private static let iso = ISO8601DateFormatter()
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/PersonalContext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chat.log")
    }()

    static func event(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[PC-OS chat] \(message)")
        let line = "\(iso.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    static func clip(_ text: String, _ limit: Int = 160) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

struct CursorModel: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var description: String?
}

struct CursorAccount: Decodable, Sendable {
    var apiKeyName: String
    var userEmail: String?
}

struct CursorAgent: Decodable, Sendable {
    var id: String
    var name: String?
    var url: String?
    var latestRunId: String?
}

struct CursorRun: Decodable, Sendable {
    var id: String
    var agentId: String?
    var status: String
    var result: String?
}

enum CursorStreamEvent: Sendable {
    case status(String)
    case assistant(String)
    case thinking(String)
    case tool(String)
    case result(status: String, text: String?)
    case error(String)
    case done
}

struct CursorAPIError: LocalizedError, Sendable {
    var status: Int
    var message: String

    var errorDescription: String? { message }
}

struct CursorClient: Sendable {
    var apiKey: String
    var session: URLSession

    init(apiKey: String, session: URLSession = CursorClient.makeSession()) {
        self.apiKey = apiKey
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func account() async throws -> CursorAccount {
        ChatTrace.event("GET /v1/me")
        return try await send(make(path: "/v1/me", method: "GET"), as: CursorAccount.self)
    }

    func models() async throws -> [CursorModel] {
        ChatTrace.event("GET /v1/models")
        struct Response: Decodable { var items: [CursorModel] }
        return try await send(make(path: "/v1/models", method: "GET"), as: Response.self).items
    }

    func createAgent(name: String, prompt: String, modelID: String) async throws -> (agent: CursorAgent, run: CursorRun) {
        struct Body: Encodable {
            var prompt: PromptText
            var name: String
            var model: ModelSelection?
        }
        struct PromptText: Encodable { var text: String }
        struct ModelSelection: Encodable { var id: String }
        struct Response: Decodable {
            var agent: CursorAgent
            var run: CursorRun
        }
        let body = Body(
            prompt: PromptText(text: prompt),
            name: String(name.prefix(100)),
            model: modelID.isEmpty ? nil : ModelSelection(id: modelID)
        )
        ChatTrace.event("POST /v1/agents name=\(name.prefix(60)) model=\(modelID.isEmpty ? "default" : modelID) promptChars=\(prompt.count)")
        let response = try await send(make(path: "/v1/agents", method: "POST", body: body), as: Response.self)
        ChatTrace.event("created agent=\(response.agent.id) run=\(response.run.id) status=\(response.run.status)")
        return (response.agent, response.run)
    }

    func createRun(agentID: String, prompt: String) async throws -> CursorRun {
        struct Body: Encodable { var prompt: PromptText }
        struct PromptText: Encodable { var text: String }
        struct Response: Decodable { var run: CursorRun }
        let request = make(
            path: "/v1/agents/\(agentID)/runs",
            method: "POST",
            body: Body(prompt: PromptText(text: prompt))
        )
        ChatTrace.event("POST /v1/agents/\(agentID)/runs promptChars=\(prompt.count)")
        let run = try await send(request, as: Response.self).run
        ChatTrace.event("created run=\(run.id) status=\(run.status)")
        return run
    }

    func run(agentID: String, runID: String) async throws -> CursorRun {
        ChatTrace.event("GET /v1/agents/\(agentID)/runs/\(runID)")
        return try await send(make(path: "/v1/agents/\(agentID)/runs/\(runID)", method: "GET"), as: CursorRun.self)
    }

    func waitForRun(agentID: String, runID: String) async throws -> CursorRun {
        var delay: UInt64 = 1_000_000_000
        for attempt in 1...90 {
            try Task.checkCancellation()
            let current = try await run(agentID: agentID, runID: runID)
            ChatTrace.event("poll run=\(runID) status=\(current.status) resultChars=\(current.result?.count ?? 0) attempt=\(attempt)")
            switch current.status.uppercased() {
            case "FINISHED", "ERROR", "CANCELLED", "EXPIRED":
                return current
            default:
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay + 500_000_000, 3_000_000_000)
            }
        }
        throw CursorAPIError(status: 0, message: "The run is still going. Try again in a moment.")
    }

    func cancel(agentID: String, runID: String) async throws {
        let request = make(path: "/v1/agents/\(agentID)/runs/\(runID)/cancel", method: "POST")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    func stream(agentID: String, runID: String) -> AsyncThrowingStream<CursorStreamEvent, Error> {
        let request = make(
            path: "/v1/agents/\(agentID)/runs/\(runID)/stream",
            method: "GET",
            accept: "text/event-stream"
        )
        let session = session
        ChatTrace.event("GET stream /v1/agents/\(agentID)/runs/\(runID)/stream")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse {
                        ChatTrace.event("stream HTTP \(http.statusCode)")
                    }
                    try Self.validateStream(response)
                    var name = "message"
                    var dataLines: [String] = []
                    func flush() {
                        let payload = dataLines.joined(separator: "\n")
                        dataLines = []
                        let eventName = name
                        name = "message"
                        guard !payload.isEmpty else { return }
                        let events = Self.parseAll(name: eventName, data: payload)
                        if events.isEmpty {
                            ChatTrace.event("sse unparsed name=\(eventName) data=\(ChatTrace.clip(payload, 240))")
                            return
                        }
                        for event in events {
                            ChatTrace.event("sse \(Self.summarize(event))")
                            continuation.yield(event)
                        }
                    }
                    for try await line in bytes.lines {
                        let cleaned = line.hasSuffix("\r") ? String(line.dropLast()) : line
                        if cleaned.isEmpty {
                            flush()
                            continue
                        }
                        if cleaned.hasPrefix(":") { continue }
                        if cleaned.hasPrefix("id:") {
                            if !dataLines.isEmpty { flush() }
                            continue
                        }
                        if cleaned.hasPrefix("event:") {
                            if !dataLines.isEmpty { flush() }
                            name = Self.field(cleaned, prefix: "event:")
                        } else if cleaned.hasPrefix("data:") {
                            dataLines.append(Self.field(cleaned, prefix: "data:"))
                        }
                    }
                    flush()
                    ChatTrace.event("stream finished")
                    continuation.finish()
                } catch {
                    ChatTrace.event("stream failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func validateStream(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw CursorAPIError(status: http.statusCode, message: message(for: http.statusCode, data: Data()))
        }
    }

    private static func parseAll(name: String, data: String) -> [CursorStreamEvent] {
        if (try? JSONSerialization.jsonObject(with: Data(data.utf8))) != nil,
           let event = parse(name: name, data: data) {
            return [event]
        }
        var events: [CursorStreamEvent] = []
        for line in data.split(whereSeparator: \.isNewline) {
            let piece = line.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty, let event = parse(name: inferName(piece, fallback: name), data: piece) else { continue }
            events.append(event)
        }
        return events
    }

    private static func inferName(_ data: String, fallback: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            return fallback
        }
        if json["code"] != nil { return "error" }
        if json["text"] != nil, json["runId"] != nil { return "result" }
        if json["text"] != nil { return "assistant" }
        if json["status"] != nil { return "status" }
        if json.isEmpty { return "done" }
        return fallback
    }

    private static func parse(name: String, data: String) -> CursorStreamEvent? {
        guard let raw = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return name == "done" ? .done : nil
        }
        switch name {
        case "status":
            return .status(json["status"] as? String ?? "")
        case "assistant":
            return .assistant(json["text"] as? String ?? "")
        case "thinking":
            return .thinking(json["text"] as? String ?? "")
        case "tool_call":
            let tool = json["name"] as? String ?? "tool"
            let status = json["status"] as? String ?? ""
            return .tool(status == "completed" ? "Finished \(tool)" : "Using \(tool)")
        case "result":
            return .result(status: json["status"] as? String ?? "", text: json["text"] as? String)
        case "error":
            return .error(json["message"] as? String ?? json["code"] as? String ?? "The stream failed.")
        case "done":
            return .done
        case "heartbeat", "interaction_update":
            return nil
        default:
            return nil
        }
    }

    private static func field(_ line: String, prefix: String) -> String {
        var value = line.dropFirst(prefix.count)
        if value.first == " " { value = value.dropFirst() }
        return String(value)
    }

    private func make(path: String, method: String, accept: String = "application/json") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.cursor.com\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    private func make<Body: Encodable>(path: String, method: String, body: Body) -> URLRequest {
        var request = make(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let path = request.url?.path ?? "?"
        let method = request.httpMethod ?? "?"
        ChatTrace.event("http \(method) \(path) start")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        ChatTrace.event("http \(method) \(path) status=\(status) bytes=\(data.count)")
        do {
            try validate(response, data: data)
        } catch {
            ChatTrace.event("http \(method) \(path) rejected: \(error.localizedDescription) body=\(ChatTrace.clip(String(data: data, encoding: .utf8) ?? "", 400))")
            throw error
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            ChatTrace.event("http \(method) \(path) decode failed as \(T.self): \(error) body=\(ChatTrace.clip(String(data: data, encoding: .utf8) ?? "", 400))")
            throw CursorAPIError(status: status, message: "Cursor returned a response this app couldn't read.")
        }
    }

    private static func summarize(_ event: CursorStreamEvent) -> String {
        switch event {
        case .status(let status):
            return "status=\(status)"
        case .assistant(let text):
            return "assistant chars=\(text.count)"
        case .thinking(let text):
            return "thinking chars=\(text.count)"
        case .tool(let name):
            return "tool=\(name)"
        case .result(let status, let text):
            return "result status=\(status) chars=\(text?.count ?? 0)"
        case .error(let message):
            return "error=\(message)"
        case .done:
            return "done"
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw CursorAPIError(status: http.statusCode, message: Self.message(for: http.statusCode, data: data))
        }
    }

    private static func message(for status: Int, data: Data) -> String {
        if status == 401 { return "Cursor rejected the API key." }
        if status == 409 { return "This conversation already has a run in progress." }
        if status == 429 { return "Cursor is rate limiting requests. Wait a moment and try again." }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String, !message.isEmpty { return message }
            if let error = json["error"] as? String, !error.isEmpty { return error }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
                return message
            }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count < 280 {
            return text
        }
        return "Cursor request failed (\(status))."
    }
}
