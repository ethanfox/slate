import Foundation

@MainActor
final class SlateToolGateway {
    private let mcpCommand: String?
    private var roots: [ProjectCodeRoot]
    private let includeSlateTools: Bool
    private let includeProjectTools: Bool
    private let prepareRoots: (() async throws -> [ProjectCodeRoot])?

    init(
        roots: [ProjectCodeRoot] = [],
        includeSlateTools: Bool = true,
        includeProjectTools: Bool = true,
        prepareRoots: (() async throws -> [ProjectCodeRoot])? = nil
    ) {
        mcpCommand = Bundle.main.url(forAuxiliaryExecutable: "slate-mcp")?.path
        self.roots = roots
        self.includeSlateTools = includeSlateTools
        self.includeProjectTools = includeProjectTools
        self.prepareRoots = prepareRoots
    }

    func definitions() async throws -> [[String: Any]] {
        var tools: [[String: Any]] = includeProjectTools ? Self.projectDefinitions : []
        if includeSlateTools, let mcpCommand {
            let data = try await Self.invokeMCP(
                command: mcpCommand,
                method: "tools/list",
                params: [:]
            )
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let listed = object["tools"] as? [[String: Any]] {
                tools += listed.compactMap { tool in
                    guard let name = tool["name"] as? String else { return nil }
                    return [
                        "type": "function",
                        "name": name,
                        "description": tool["description"] as? String ?? "",
                        "parameters": tool["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]]
                    ]
                }
            }
        }
        return tools
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        if name.hasPrefix("project_") {
            try await ensureRoots()
        }
        switch name {
        case "project_list_files":
            return try listFiles(query: arguments["query"] as? String)
        case "project_search_code":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                throw ProjectWorkspaceError("query is required")
            }
            return try searchCode(query)
        case "project_read_file":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                throw ProjectWorkspaceError("path is required")
            }
            return try readFile(
                rootTitle: arguments["root"] as? String,
                path: path,
                start: arguments["start_line"] as? Int,
                end: arguments["end_line"] as? Int
            )
        case "project_git_log":
            return try gitLog(rootTitle: arguments["root"] as? String)
        default:
            guard let mcpCommand else {
                throw ProjectWorkspaceError("The Slate tool service is unavailable.")
            }
            let data = try await Self.invokeMCP(
                command: mcpCommand,
                method: "tools/call",
                params: ["name": name, "arguments": arguments]
            )
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = object["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty { return text }
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func ensureRoots() async throws {
        guard roots.isEmpty, let prepareRoots else { return }
        roots = try await prepareRoots()
    }

    private func listFiles(query: String?) throws -> String {
        let query = query?.lowercased() ?? ""
        let items = allFiles(limit: 2000)
            .filter { query.isEmpty || $0.path.lowercased().contains(query) }
            .prefix(300)
            .map { ["root": $0.root, "path": $0.path] }
        return try jsonString(Array(items))
    }

    private func searchCode(_ query: String) throws -> String {
        var output: [[String: Any]] = []
        for file in allFiles(limit: 1200) {
            guard output.count < 120,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.intValue <= 1_000_000,
                  let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: .newlines).enumerated()
            where line.localizedCaseInsensitiveContains(query) {
                output.append([
                    "root": file.root,
                    "path": file.path,
                    "line": index + 1,
                    "text": String(line.trimmingCharacters(in: .whitespaces).prefix(400))
                ])
                if output.count >= 120 { break }
            }
        }
        return try jsonString(output)
    }

    private func readFile(rootTitle: String?, path: String, start: Int?, end: Int?) throws -> String {
        let root: ProjectCodeRoot?
        if let rootTitle, !rootTitle.isEmpty {
            root = ProjectCodeRoot.resolve(roots, requested: rootTitle).first
        } else {
            root = roots.count == 1 ? roots[0] : nil
        }
        guard let root else {
            throw ProjectWorkspaceError(
                roots.isEmpty
                    ? "No code is attached to this Slate project."
                    : "Specify root because this project has several code attachments."
            )
        }
        let base = URL(fileURLWithPath: root.path).standardizedFileURL
        let file = base.appendingPathComponent(path).standardizedFileURL
        guard file.path == base.path || file.path.hasPrefix(base.path + "/") else {
            throw ProjectWorkspaceError("The requested path is outside the attached repository.")
        }
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
        let first = max(1, start ?? 1)
        let last = min(lines.count, end ?? first + 249)
        guard first <= last else { return "" }
        return lines[(first - 1)..<last]
            .enumerated()
            .map { "\(first + $0.offset): \($0.element)" }
            .joined(separator: "\n")
    }

    private func gitLog(rootTitle: String?) throws -> String {
        let selected = ProjectCodeRoot.resolve(roots, requested: rootTitle)
        guard !selected.isEmpty else {
            throw ProjectWorkspaceError(
                roots.isEmpty
                    ? "No code is attached to this Slate project."
                    : "Unknown code root. Use one of: \(roots.map(\.title).joined(separator: ", "))."
            )
        }
        var commits: [[String: Any]] = []
        for root in selected {
            let file = URL(fileURLWithPath: root.path).appendingPathComponent(".slate-commits.json")
            guard let data = try? Data(contentsOf: file),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            commits += items.map { item in
                var item = item
                item["root"] = root.title
                return item
            }
        }
        guard !commits.isEmpty else {
            throw ProjectWorkspaceError("Git history is unavailable for this attachment.")
        }
        return try jsonString(commits)
    }

    private func allFiles(limit: Int) -> [(root: String, path: String, url: URL)] {
        let ignored = Set([".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm"])
        var output: [(root: String, path: String, url: URL)] = []
        for root in roots {
            let base = URL(fileURLWithPath: root.path)
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if output.count >= limit { return output }
                if ignored.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                output.append((
                    root: root.title,
                    path: String(url.path.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                    url: url
                ))
            }
        }
        return output
    }

    private func jsonString(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static let projectDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "name": "project_list_files",
            "description": "List files in the current Slate project's attached code. Read-only.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Optional case-insensitive path filter."]
                ]
            ]
        ],
        [
            "type": "function",
            "name": "project_search_code",
            "description": "Search text in the current Slate project's attached code. Read-only.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text to search for."]
                ],
                "required": ["query"]
            ]
        ],
        [
            "type": "function",
            "name": "project_read_file",
            "description": "Read a line range from a file in the current Slate project's attached code. Read-only.",
            "parameters": [
                "type": "object",
                "properties": [
                    "root": ["type": "string", "description": "Attachment title. Required when several roots are attached."],
                    "path": ["type": "string", "description": "Path relative to the selected attachment."],
                    "start_line": ["type": "integer"],
                    "end_line": ["type": "integer"]
                ],
                "required": ["path"]
            ]
        ],
        [
            "type": "function",
            "name": "project_git_log",
            "description": "Read recent commits for the current Slate project's attached remote repositories. Read-only.",
            "parameters": [
                "type": "object",
                "properties": [
                    "root": ["type": "string", "description": "Optional attachment title."]
                ]
            ]
        ]
    ]

    private static func invokeMCP(
        command: String,
        method: String,
        params: [String: Any]
    ) async throws -> Data {
        let requestData = try JSONSerialization.data(withJSONObject: params)
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()

            let initialize: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:],
                    "clientInfo": ["name": "slate-app", "version": "1.0"]
                ]
            ]
            let decodedParams = try JSONSerialization.jsonObject(with: requestData)
            let call: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": method,
                "params": decodedParams
            ]
            for message in [initialize, call] {
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message))
                try input.fileHandleForWriting.write(contentsOf: Data([0x0A]))
            }
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw ProjectWorkspaceError(detail.isEmpty ? "The Slate tool service stopped." : detail)
            }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let lineData = String(line).data(using: .utf8),
                      let response = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      response["id"] as? Int == 2 else { continue }
                if let error = response["error"] as? [String: Any] {
                    throw ProjectWorkspaceError(error["message"] as? String ?? "A Slate tool failed.")
                }
                return try JSONSerialization.data(withJSONObject: response["result"] ?? [:])
            }
            throw ProjectWorkspaceError("The Slate tool service returned no result.")
        }.value
    }
}
