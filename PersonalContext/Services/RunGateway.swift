import Foundation

@MainActor
final class RunGateway {
    let policy: RunToolPolicy
    private let inner: SlateToolGateway
    private(set) var journal: [RunResultLink] = []
    private(set) var finishSummary: String?
    private(set) var finishLinks: [RunResultLink] = []

    init(policy: RunToolPolicy, inner: SlateToolGateway) {
        self.policy = policy
        self.inner = inner
    }

    func definitions() async throws -> [[String: Any]] {
        var tools = try await inner.definitions()
        tools = tools.filter { tool in
            guard let name = tool["name"] as? String else { return false }
            return policy.allows(name)
        }
        tools.append(Self.finishDefinition)
        return tools
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        switch policy.permitsCall(name, arguments: arguments) {
        case .failure(let error):
            throw error
        case .success:
            break
        }
        if name == RunToolPolicy.finishRun {
            return try finish(arguments)
        }
        let prepared = policy.preparedArguments(name, arguments)
        let result = try await inner.execute(name: name, arguments: prepared)
        if name.hasPrefix("create_") || name.hasPrefix("update_") {
            if let link = Self.artifact(from: result, tool: name) {
                journal.append(link)
            }
        }
        return result
    }

    private func finish(_ arguments: [String: Any]) throws -> String {
        let summary = (arguments["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else {
            throw RunToolDenied("summary is required.")
        }
        finishSummary = summary
        finishLinks = Self.links(from: arguments["links"])
        return "{\"ok\":true}"
    }

    private static func artifact(from result: String, tool: String) -> RunResultLink? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              UUID(uuidString: id) != nil
        else { return nil }
        let kind: String
        if tool.contains("note") { kind = "note" }
        else if tool.contains("decision") { kind = "decision" }
        else if tool.contains("thread") { kind = "thread" }
        else if tool.contains("task") { kind = "task" }
        else { return nil }
        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RunResultLink(
            label: title?.isEmpty == false ? title! : kind.capitalized,
            url: "slate://\(kind)/\(id)",
            kind: .document
        )
    }

    private static func links(from raw: Any?) -> [RunResultLink] {
        guard let items = raw as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let label = (item["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = (item["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty, RunLinkSafety.allows(url) else { return nil }
            return RunResultLink(
                label: label.isEmpty ? url : label,
                url: url,
                kind: RunLinkSafety.kind(for: url)
            )
        }
    }

    private static let finishDefinition: [String: Any] = [
        "type": "function",
        "name": RunToolPolicy.finishRun,
        "description": "Stock the run receipt with a short summary and optional links. Do not complete the assigned task.",
        "parameters": [
            "type": "object",
            "properties": [
                "summary": ["type": "string", "description": "What was done."],
                "links": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string"],
                            "url": ["type": "string"]
                        ],
                        "required": ["url"]
                    ]
                ]
            ],
            "required": ["summary"]
        ]
    ]
}

enum RunLinkSafety {
    static func allows(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "https", "slate":
            return true
        case "file":
            return true
        default:
            return false
        }
    }

    static func kind(for raw: String) -> RunLinkKind {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return .link }
        switch scheme {
        case "slate": return .document
        case "file": return .file
        default: return .link
        }
    }

    static func fileAllowed(_ raw: String, roots: [ProjectCodeRoot]) -> Bool {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "file" else { return true }
        let path = url.path
        return roots.contains { root in
            path == root.path || path.hasPrefix(root.path + "/")
        }
    }
}
