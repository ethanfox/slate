import Foundation

@MainActor
final class MembraeToolGateway: AgentToolGateway {
    private var roots: [ProjectCodeRoot]
    private let includeMembraeTools: Bool
    private let includeProjectTools: Bool
    private let prepareRoots: (() async throws -> [ProjectCodeRoot])?
    private let consult: ((String) async throws -> String)?
    private let mcp: MembraeMCPClient?
    private let indexingRunID: UUID?
    private let storeURL: URL?

    init(
        roots: [ProjectCodeRoot] = [],
        includeMembraeTools: Bool = true,
        includeProjectTools: Bool = true,
        prepareRoots: (() async throws -> [ProjectCodeRoot])? = nil,
        consult: ((String) async throws -> String)? = nil,
        mcp: MembraeMCPClient? = nil,
        indexingRunID: UUID? = nil,
        storeURL: URL? = nil
    ) {
        self.roots = roots
        self.includeMembraeTools = includeMembraeTools
        self.includeProjectTools = includeProjectTools
        self.prepareRoots = prepareRoots
        self.consult = consult
        self.mcp = mcp ?? (includeMembraeTools ? .shared : nil)
        self.indexingRunID = indexingRunID
        self.storeURL = storeURL
    }

    func definitions() async throws -> [[String: Any]] {
        var tools: [[String: Any]] = includeProjectTools ? Self.projectDefinitions : []
        if consult != nil {
            tools.append(Self.consultDefinition)
        }
        if includeMembraeTools, let mcp {
            let listed = try await mcp.toolDefinitions()
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
        case "consult_code":
            guard let consult else {
                throw ProjectWorkspaceError("This project has no Worker. Set one in Project Settings.")
            }
            let brief = (arguments["brief"] as? String) ?? (arguments["question"] as? String) ?? ""
            return try await consult(brief)
        default:
            guard let mcp else {
                throw ProjectWorkspaceError("The Membrae tool service is unavailable.")
            }
            let data = try await mcp.invoke(
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
        if let prepareRoots {
            roots = try await prepareRoots()
            return
        }
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
                    ? "No code is attached to this Membrae project."
                    : "Specify root because this project has several code attachments."
            )
        }
        let base = URL(fileURLWithPath: root.path).standardizedFileURL
        let file = base.appendingPathComponent(path).standardizedFileURL
        guard file.path == base.path || file.path.hasPrefix(base.path + "/") else {
            throw ProjectWorkspaceError("The requested path is outside the attached repository.")
        }
        let data = try Data(contentsOf: file)
        let hash = CodeContentHash.sha256(of: data)
        if let indexingRunID {
            CodeReadProvenance.record(runID: indexingRunID, path: path, hash: hash, storeURL: storeURL)
        }
        let lines = (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
            .components(separatedBy: .newlines)
        let first = max(1, start ?? 1)
        let last = min(lines.count, end ?? first + 249)
        guard first <= last else { return "content_hash \(hash)" }
        let body = lines[(first - 1)..<last]
            .enumerated()
            .map { "\(first + $0.offset): \($0.element)" }
            .joined(separator: "\n")
        return "content_hash \(hash)\n\(body)"
    }

    private func gitLog(rootTitle: String?) throws -> String {
        try jsonString(ProjectCodeWorkspace.gitHistory(for: roots, requested: rootTitle))
    }

    private func allFiles(limit: Int) -> [(root: String, path: String, url: URL)] {
        let ignored = Set([".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm", "xcuserdata"])
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

    private static let consultDefinition: [String: Any] = [
        "type": "function",
        "name": "consult_code",
        "description": "Ask the project's Worker to inspect attached code. Pass a brief. Do not use this for decisions, tracks, or notes — those are Membrae tools.",
        "parameters": [
            "type": "object",
            "properties": [
                "brief": ["type": "string", "description": "What the Worker should inspect in the attached code."]
            ],
            "required": ["brief"]
        ]
    ]

    private static let projectDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "name": "project_list_files",
            "description": "List files in the current Membrae project's attached code. Read-only.",
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
            "description": "Search text in the current Membrae project's attached code. Read-only.",
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
            "description": "Read a line range from a file in the current Membrae project's attached code. Read-only.",
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
            "description": "Read recent commits for the current Membrae project's attached remote repositories. Read-only.",
            "parameters": [
                "type": "object",
                "properties": [
                    "root": ["type": "string", "description": "Optional attachment title."]
                ]
            ]
        ]
    ]

}
