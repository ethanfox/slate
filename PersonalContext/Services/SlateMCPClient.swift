import Foundation

/// One slate-mcp process for ChatGPT. Tool schemas are listed once and reused.
actor SlateMCPClient {
    static let shared = SlateMCPClient()

    private let command: String?
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var cachedTools: [[String: Any]]?
    private var idleTask: Task<Void, Never>?
    private var listProvider: (() async throws -> [[String: Any]])?
    private(set) var listCalls = 0

    init(command: String? = Bundle.main.url(forAuxiliaryExecutable: "slate-mcp")?.path) {
        self.command = command
    }

    func toolDefinitions() async throws -> [[String: Any]] {
        if let cachedTools { return cachedTools }
        if let listProvider {
            listCalls += 1
            let listed = try await listProvider()
            cachedTools = listed
            return listed
        }
        ChatTrace.event("mcp tools/list")
        listCalls += 1
        let data = try await request("tools/list", params: [:])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listed = object["tools"] as? [[String: Any]] else {
            throw ProjectWorkspaceError("The Slate tool service returned no tools.")
        }
        cachedTools = listed
        return listed
    }

    func invoke(method: String, params: [String: Any]) async throws -> Data {
        try await request(method, params: params)
    }

    func useListProvider(_ provider: @escaping () async throws -> [[String: Any]]) {
        listProvider = provider
        cachedTools = nil
        listCalls = 0
    }

    func stop() {
        idleTask?.cancel()
        idleTask = nil
        failPending(ProjectWorkspaceError("The Slate tool service stopped."))
        stdin = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        buffer = Data()
        nextID = 1
    }

    private func request(_ method: String, params: [String: Any]) async throws -> Data {
        try await ensureProcess()
        bumpIdle()
        return try await send(method, params: params)
    }

    private func ensureProcess() async throws {
        if process?.isRunning == true { return }
        guard let command else {
            throw ProjectWorkspaceError("The Slate tool service is unavailable.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
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
            ChatTrace.event("mcp stderr: \(ChatTrace.clip(String(decoding: data, as: UTF8.self), 400))")
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processExited() }
        }
        try process.run()
        self.process = process
        self.stdin = input.fileHandleForWriting
        ChatTrace.event("mcp started pid=\(process.processIdentifier)")
        _ = try await send("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "slate-app", "version": "1.0"]
        ])
    }

    private func send(_ method: String, params: [String: Any]) async throws -> Data {
        guard let stdin else {
            throw ProjectWorkspaceError("The Slate tool service is unavailable.")
        }
        let id = nextID
        nextID += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdin.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func ingest(_ data: Data) {
        if data.isEmpty {
            processExited()
            return
        }
        buffer.append(data)
        while let line = popLine() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = Self.jsonID(object["id"]),
                  let continuation = pending.removeValue(forKey: id) else { continue }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: ProjectWorkspaceError(error["message"] as? String ?? "A Slate tool failed."))
            } else {
                let result = object["result"] ?? [:]
                do {
                    continuation.resume(returning: try JSONSerialization.data(withJSONObject: result))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
        failPending(ProjectWorkspaceError("The Slate tool service stopped."))
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    private func bumpIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8 * 60))
            guard !Task.isCancelled else { return }
            await self?.sleepProcess()
        }
    }

    private static func jsonID(_ value: Any?) -> Int? {
        if let id = value as? Int { return id }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func sleepProcess() {
        ChatTrace.event("mcp idle stop")
        if let process, process.isRunning {
            process.terminate()
        }
        stdin = nil
        process = nil
        buffer = Data()
        nextID = 1
    }
}
