import Foundation
import FoundationModels
import SwiftData

/// What Apple's on-device model can do in Membrae. Its window is small, so it always has the five things
/// people ask for most, and finds the rest by asking for them instead of reading the whole list.
@MainActor
final class AppleToolBox {
    private let gateway: RunGateway
    private let workspace: ChatWorkspace
    private var catalog: [[String: Any]]?
    /// Shows each call in the chat as it runs.
    var report: (@Sendable (ChatStreamEvent) -> Void)?

    /// Characters of a tool's answer the model reads. The rest would push the chat out of its window.
    static let resultBudget = 1_200
    /// Membrae tools the model always has in its own shape, so find_tool leaves them out.
    static let alwaysThere: Set<String> = ["get_space", "create_task", "create_note", "complete_task"]

    init(workspace: ChatWorkspace) {
        self.workspace = workspace
        gateway = RunGateway(
            policy: .chat(spaceID: workspace.project?.id),
            inner: MembraeToolGateway(
                includeMembraeTools: true,
                includeProjectTools: false,
                mcp: workspace.mcp,
                store: workspace.conversation.modelContext?.container,
                projectID: workspace.project?.id,
                includeExternalMCP: workspace.project != nil,
                conversationID: workspace.conversation.id
            ),
            includeFinishRun: false
        )
    }

    var tools: [any Tool] {
        [
            AppleFindTool(box: self),
            AppleReadSpaceTool(box: self),
            AppleCreateTaskTool(box: self),
            AppleCreateNoteTool(box: self),
            AppleCompleteTaskTool(box: self),
            AppleFindToolTool(box: self),
            AppleUseToolTool(box: self)
        ]
    }

    /// Titles across every Space that contain the words.
    func find(_ words: String) -> String {
        let query = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let context = workspace.conversation.modelContext else {
            return "Say what to look for."
        }
        var descriptor = FetchDescriptor<TitleIndex>(
            predicate: #Predicate { $0.title.localizedStandardContains(query) && !$0.isArchived },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 10
        let rows = (try? context.fetch(descriptor)) ?? []
        let id = UUID().uuidString
        report?(.tool(name: "find", status: "completed", id: id, detail: "Looked for “\(query)”", sources: []))
        guard !rows.isEmpty else { return "Nothing in Membrae is titled with “\(query)”." }
        return rows.map { row in
            var line = "\(row.kind.rawValue): \(row.displayTitle) (id \(row.id.uuidString))"
            if !row.owner.isEmpty, row.kind != .space { line += " in \(row.owner)" }
            return line
        }.joined(separator: "\n")
    }

    /// A Space's open tasks, tracks, and newest decisions, written short.
    func read(spaceID: String?) -> String {
        let space: Project?
        if let spaceID, !spaceID.isEmpty {
            guard let id = UUID(uuidString: spaceID), let context = workspace.conversation.modelContext else {
                return "Error: that is not a Space id. Use find to get one."
            }
            space = try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })).first
        } else {
            space = workspace.project
        }
        guard let space else { return "Error: no Space given. Use find to get a Space id." }
        report?(.tool(name: "get_space", status: "completed", id: UUID().uuidString, detail: "Read \(space.name)", sources: []))
        var lines = ["Space: \(space.name) (id \(space.id.uuidString))"]
        if !space.summary.isEmpty { lines.append(String(space.summary.prefix(300))) }
        let tasks = space.agendaItems
            .filter { $0.kind == .task && !$0.isCompleted }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(10)
        if !tasks.isEmpty {
            lines.append("Open tasks:")
            lines += tasks.map { "- \($0.title) [\($0.workflowStatus.rawValue)] (id \($0.id.uuidString))" }
        }
        let tracks = space.threads.filter { $0.status != .completed }.prefix(6)
        if !tracks.isEmpty {
            lines.append("Tracks:")
            lines += tracks.map { "- \($0.title) [\($0.status.rawValue)]" }
        }
        let decisions = space.decisions
            .filter { $0.status == .active }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(5)
        if !decisions.isEmpty {
            lines.append("Newest decisions:")
            lines += decisions.map { "- \($0.title)" }
        }
        return Self.clip(lines.joined(separator: "\n"))
    }

    /// Calls one Membrae tool. The current Space fills in space_id when the model leaves it out.
    func call(_ name: String, _ values: [String: String]) async -> String {
        await run(name, values)
    }

    private func run(_ name: String, _ arguments: [String: Any]) async -> String {
        var arguments = arguments
        if arguments["space_id"] == nil, let space = workspace.project {
            arguments["space_id"] = space.id.uuidString
        }
        let id = UUID().uuidString
        report?(.tool(
            name: name, status: "running", id: id,
            detail: ChatToolActivity.detail(for: name, arguments: arguments), sources: []
        ))
        do {
            let output = try await gateway.execute(name: name, arguments: arguments)
            report?(.tool(
                name: name, status: "completed", id: id,
                detail: ChatToolActivity.detail(for: name, arguments: arguments, result: output), sources: []
            ))
            return Self.clip(output)
        } catch {
            report?(.tool(name: name, status: "error", id: id, detail: error.localizedDescription, sources: []))
            return "Error: \(error.localizedDescription)"
        }
    }

    /// The three tools that best match what the model wants to do, with their arguments.
    func findTools(_ want: String) async -> String {
        let words = want.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
        guard !words.isEmpty else { return "Say what you want to do." }
        let catalog = await loadCatalog()
        let ranked = catalog.compactMap { tool -> (score: Int, tool: [String: Any])? in
            guard let name = tool["name"] as? String else { return nil }
            let description = (tool["description"] as? String ?? "").lowercased()
            let score = words.reduce(0) { total, word in
                total + (name.contains(word) ? 3 : 0) + (description.contains(word) ? 1 : 0)
            }
            return score > 0 ? (score, tool) : nil
        }
        .sorted { $0.score > $1.score }
        .prefix(3)
        guard !ranked.isEmpty else { return "No tool does that." }
        report?(.tool(name: "find_tool", status: "completed", id: UUID().uuidString, detail: "Looked for a tool to \(want)", sources: []))
        return ranked.map { Self.summary(of: $0.tool) }.joined(separator: "\n\n")
    }

    /// Runs a tool find_tool returned, with its arguments written as JSON.
    func useTool(_ name: String, json: String) async -> String {
        let catalog = await loadCatalog()
        guard catalog.contains(where: { $0["name"] as? String == name }) else {
            return "Error: there is no tool named \(name). Call find_tool first."
        }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String: Any] = [:]
        if !trimmed.isEmpty {
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return "Error: the arguments must be a JSON object." }
            arguments = object
        }
        return await run(name, arguments)
    }

    private func loadCatalog() async -> [[String: Any]] {
        if let catalog { return catalog }
        let loaded = ((try? await gateway.definitions()) ?? [])
            .filter { !Self.alwaysThere.contains($0["name"] as? String ?? "") }
        catalog = loaded
        return loaded
    }

    private static func summary(of tool: [String: Any]) -> String {
        let name = tool["name"] as? String ?? ""
        let description = String((tool["description"] as? String ?? "").prefix(200))
        let parameters = tool["parameters"] as? [String: Any] ?? [:]
        let properties = parameters["properties"] as? [String: Any] ?? [:]
        let required = Set(parameters["required"] as? [String] ?? [])
        let arguments = properties.keys.sorted().map { key in
            let type = (properties[key] as? [String: Any])?["type"] as? String ?? "string"
            return "\(key) (\(type)\(required.contains(key) ? ", required" : ""))"
        }
        let list = arguments.isEmpty ? "none" : arguments.joined(separator: ", ")
        return "\(name): \(description)\nArguments: \(list)"
    }

    static func clip(_ text: String) -> String {
        text.count > resultBudget ? String(text.prefix(resultBudget)) + "…" : text
    }
}

struct AppleFindTool: Tool {
    let box: AppleToolBox
    let name = "find"
    let description = "Find Spaces, tasks, notes, tracks, decisions, and chats by words in their title."

    @Generable
    struct Arguments {
        @Guide(description: "Words to look for")
        var words: String
    }

    func call(arguments: Arguments) async throws -> String {
        await box.find(arguments.words)
    }
}

struct AppleReadSpaceTool: Tool {
    let box: AppleToolBox
    let name = "read_space"
    let description = "Read a Space's open tasks, tracks, and newest decisions."

    @Generable
    struct Arguments {
        @Guide(description: "Space id. Leave empty for the Space this chat is in.")
        var spaceID: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await box.read(spaceID: arguments.spaceID)
    }
}

struct AppleCreateTaskTool: Tool {
    let box: AppleToolBox
    let name = "create_task"
    let description = "Add a task. It goes in the Space this chat is in."

    @Generable
    struct Arguments {
        var title: String
        @Guide(description: "Due date as YYYY-MM-DD")
        var due: String?
        @Guide(description: "Space id, when the chat is in no Space")
        var spaceID: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var values: [String: String] = ["title": arguments.title]
        if let due = arguments.due, !due.isEmpty { values["due"] = due }
        if let space = arguments.spaceID, !space.isEmpty { values["space_id"] = space }
        return await box.call("create_task", values)
    }
}

struct AppleCreateNoteTool: Tool {
    let box: AppleToolBox
    let name = "create_note"
    let description = "Save a note in the Space this chat is in."

    @Generable
    struct Arguments {
        var title: String
        var content: String
        @Guide(description: "Space id, when the chat is in no Space")
        var spaceID: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var values: [String: String] = ["title": arguments.title, "content": arguments.content]
        if let space = arguments.spaceID, !space.isEmpty { values["space_id"] = space }
        return await box.call("create_note", values)
    }
}

struct AppleCompleteTaskTool: Tool {
    let box: AppleToolBox
    let name = "complete_task"
    let description = "Mark a task done."

    @Generable
    struct Arguments {
        @Guide(description: "Task id from read_space or find")
        var taskID: String
    }

    func call(arguments: Arguments) async throws -> String {
        await box.call("complete_task", ["task_id": arguments.taskID])
    }
}

struct AppleFindToolTool: Tool {
    let box: AppleToolBox
    let name = "find_tool"
    let description = "Find a tool for anything the other tools can't do, such as decisions, tracks, sources, tags, or calendar events."

    @Generable
    struct Arguments {
        @Guide(description: "What you want to do, in a few words")
        var want: String
    }

    func call(arguments: Arguments) async throws -> String {
        await box.findTools(arguments.want)
    }
}

struct AppleUseToolTool: Tool {
    let box: AppleToolBox
    let name = "use_tool"
    let description = "Use a tool that find_tool returned."

    @Generable
    struct Arguments {
        var name: String
        @Guide(description: "The tool's arguments as a JSON object")
        var arguments: String
    }

    func call(arguments: Arguments) async throws -> String {
        await box.useTool(arguments.name, json: arguments.arguments)
    }
}
