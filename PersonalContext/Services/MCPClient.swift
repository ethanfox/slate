import Foundation

protocol MCPSessioning: Sendable {
    func listTools() async throws -> [MCPDiscoveredTool]
    func call(name: String, arguments: [String: Any]) async throws -> Data
    func close() async
}

protocol MCPSessionFactory: Sendable {
    func open(_ connection: MCPResolvedConnection) async throws -> any MCPSessioning
}

struct MCPLiveSessionFactory: MCPSessionFactory {
    static let shared = MCPLiveSessionFactory()

    func open(_ connection: MCPResolvedConnection) async throws -> any MCPSessioning {
        switch connection.record.transport {
        case .stdio:
            return try await MCPStdioSession.open(connection)
        case .http:
            return try await MCPHTTPSession.open(connection)
        }
    }
}

actor MCPStdioSession: MCPSessioning {
    private var process: Process?
    private var stdin: FileHandle?
    private var bookmarks: [URL] = []
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var listChanged: (@Sendable () -> Void)?

    static func open(_ connection: MCPResolvedConnection) async throws -> MCPStdioSession {
        let session = MCPStdioSession()
        try await session.start(connection)
        return session
    }

    func onListChanged(_ handler: @escaping @Sendable () -> Void) {
        listChanged = handler
    }

    func listTools() async throws -> [MCPDiscoveredTool] {
        try await MCPProtocol.listTools(send: request)
    }

    func call(name: String, arguments: [String: Any]) async throws -> Data {
        try await request("tools/call", params: ["name": name, "arguments": arguments])
    }

    func close() async {
        failPending(MCPConnectionError("The MCP server disconnected."))
        stdin = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        buffer = Data()
        nextID = 1
        for url in bookmarks {
            url.stopAccessingSecurityScopedResource()
        }
        bookmarks = []
    }

    private func start(_ connection: MCPResolvedConnection) async throws {
        let record = connection.record
        let executable = URL(fileURLWithPath: record.command).standardizedFileURL
        var accessed: [URL] = []
        if let bookmark = record.executableBookmark {
            accessed.append(contentsOf: Self.startBookmark(bookmark))
        }
        if let bookmark = record.workingDirectoryBookmark {
            accessed.append(contentsOf: Self.startBookmark(bookmark))
        }
        bookmarks = accessed
        let process = Process()
        process.executableURL = executable
        process.arguments = record.arguments
        if !record.workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: record.workingDirectory, isDirectory: true)
        }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in connection.environment {
            environment[key] = value
        }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.ingest(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            ChatTrace.event("mcp-client stderr: \(ChatTrace.clip(String(decoding: data, as: UTF8.self), 400))")
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processExited() }
        }
        do {
            try process.run()
        } catch {
            await close()
            throw MCPConnectionError("Couldn’t start \(record.name): \(error.localizedDescription)")
        }
        self.process = process
        self.stdin = input.fileHandleForWriting
        do {
            try await MCPProtocol.initialize(send: request, notify: notify, clientName: "membrae-app")
        } catch {
            await close()
            throw error
        }
    }

    private func request(_ method: String, params: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        guard let stdin else {
            throw MCPConnectionError("The MCP server is disconnected.")
        }
        let id = nextID
        nextID += 1
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if !params.isEmpty {
            message["params"] = params
        }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdin.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: MCPConnectionError("Couldn’t write to the MCP server."))
            }
        }
    }

    private func notify(_ method: String, params: [String: Any]) async throws {
        guard let stdin else { return }
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if !params.isEmpty {
            message["params"] = params
        }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func ingest(_ data: Data) {
        if data.isEmpty {
            processExited()
            return
        }
        buffer.append(data)
        while let line = popLine() {
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        if let id = Self.jsonID(object["id"]), let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: MCPConnectionError(error["message"] as? String ?? "The MCP server returned an error."))
            } else {
                let result = object["result"] ?? [:]
                do {
                    continuation.resume(returning: try JSONSerialization.data(withJSONObject: result))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            return
        }
        if let method = object["method"] as? String, method.contains("list_changed") {
            listChanged?()
        }
    }

    private func popLine() -> String? {
        guard let index = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<index)
        buffer.removeSubrange(buffer.startIndex...index)
        return String(data: line, encoding: .utf8)
    }

    private func processExited() {
        if let process, process.isRunning { return }
        stdin = nil
        process = nil
        failPending(MCPConnectionError("The MCP server stopped."))
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    private static func jsonID(_ value: Any?) -> Int? {
        if let id = value as? Int { return id }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func startBookmark(_ data: Data) -> [URL] {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return [] }
        _ = url.startAccessingSecurityScopedResource()
        return [url]
    }
}

actor MCPHTTPSession: MCPSessioning {
    private var url: URL
    private var headers: [String: String]
    private var sessionID: String?
    private var nextID = 1
    private let session: URLSession
    private var closed = false

    static func open(_ connection: MCPResolvedConnection) async throws -> MCPHTTPSession {
        guard let url = URL(string: connection.record.url) else {
            throw MCPConnectionError("Enter a valid server URL.")
        }
        let client = MCPHTTPSession(url: url, headers: connection.headers)
        try await client.initialize()
        return client
    }

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration)
    }

    func listTools() async throws -> [MCPDiscoveredTool] {
        try await MCPProtocol.listTools(send: request)
    }

    func call(name: String, arguments: [String: Any]) async throws -> Data {
        try await request("tools/call", params: ["name": name, "arguments": arguments])
    }

    func close() async {
        closed = true
        session.invalidateAndCancel()
    }

    private func initialize() async throws {
        try await MCPProtocol.initialize(send: request, notify: notify, clientName: "membrae-app")
    }

    private func request(_ method: String, params: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw MCPConnectionError("The MCP server is disconnected.") }
        let id = nextID
        nextID += 1
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if !params.isEmpty {
            message["params"] = params
        }
        return try await post(message)
    }

    private func notify(_ method: String, params: [String: Any]) async throws {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if !params.isEmpty {
            message["params"] = params
        }
        _ = try? await post(message)
    }

    private func post(_ message: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionID, !sessionID.isEmpty {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if let incoming = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !incoming.isEmpty {
                sessionID = incoming
            }
            if !(200...299).contains(http.statusCode) {
                let text = String(decoding: data, as: UTF8.self)
                throw MCPConnectionError(Self.httpError(status: http.statusCode, body: text))
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("text/event-stream") {
                return try Self.result(fromSSE: data)
            }
        }
        return try Self.result(fromJSON: data)
    }

    private static func result(fromJSON data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConnectionError("The MCP server returned invalid JSON.")
        }
        if let error = object["error"] as? [String: Any] {
            throw MCPConnectionError(error["message"] as? String ?? "The MCP server returned an error.")
        }
        let result = object["result"] ?? [:]
        return try JSONSerialization.data(withJSONObject: result)
    }

    private static func result(fromSSE data: Data) throws -> Data {
        let text = String(decoding: data, as: UTF8.self)
        var payload = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data:") {
                let value = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { payload = value }
            }
        }
        guard let encoded = payload.data(using: .utf8) else {
            throw MCPConnectionError("The MCP server sent an empty stream.")
        }
        return try result(fromJSON: encoded)
    }

    private static func httpError(status: Int, body: String) -> String {
        if status == 401 || status == 403 {
            return "Authentication failed (\(status)). Check the connection headers."
        }
        if !body.isEmpty {
            return ChatTrace.clip(body, 240)
        }
        return "The MCP server returned \(status)."
    }
}

enum MCPProtocol {
    static func initialize(
        send: (String, [String: Any]) async throws -> Data,
        notify: (String, [String: Any]) async throws -> Void,
        clientName: String
    ) async throws {
        _ = try await send("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": clientName, "version": "1.0"]
        ])
        try await notify("notifications/initialized", [:])
    }

    static func listTools(
        send: (String, [String: Any]) async throws -> Data
    ) async throws -> [MCPDiscoveredTool] {
        var tools: [MCPDiscoveredTool] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let data = try await send("tools/list", params)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPConnectionError("The MCP server returned no tools.")
            }
            let listed = object["tools"] as? [[String: Any]] ?? []
            tools.append(contentsOf: listed.compactMap(MCPDiscoveredTool.parse))
            cursor = object["nextCursor"] as? String
            if cursor?.isEmpty == true { cursor = nil }
        } while cursor != nil
        return tools
    }
}

extension MCPDiscoveredTool {
    static func parse(_ tool: [String: Any]) -> MCPDiscoveredTool? {
        guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
        let annotations = tool["annotations"] as? [String: Any]
        return MCPDiscoveredTool(
            name: name,
            description: tool["description"] as? String ?? "",
            inputSchema: JSONHash.make(tool["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]]),
            readOnlyHint: annotations?["readOnlyHint"] as? Bool,
            destructiveHint: annotations?["destructiveHint"] as? Bool
        )
    }
}

enum JSONHash {
    static func make(_ object: [String: Any]) -> [String: AnyHashable] {
        object.reduce(into: [:]) { result, item in
            if let value = hashable(item.value) {
                result[item.key] = value
            }
        }
    }

    static func hashable(_ value: Any) -> AnyHashable? {
        if let value = value as? AnyHashable { return value }
        if let object = value as? [String: Any] { return make(object) }
        if let array = value as? [Any] { return array.compactMap(hashable) }
        return nil
    }
}
