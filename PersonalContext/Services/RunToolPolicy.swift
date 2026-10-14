import Foundation

struct RunToolPolicy: Equatable, Sendable {
    var runID: UUID
    /// The Space the Run or chat is in. Nil means it is outside every Space.
    var spaceID: UUID?
    var assignedTaskID: UUID?
    var allowCode: Bool
    var allowMembraeKnowledgeWrite: Bool
    var denied: Set<String>
    var requireSpace: Bool
    var attachesRunSource: Bool
    var allowExternalMCP: Bool
    var allowBrowser: Bool
    /// With no Space, writes may land in any Space. This is how the one input files things.
    var allowUnscopedWrites: Bool
    /// The prompt may name another Space. The Run's own Space is then only the default.
    var allowOtherSpaces = false

    var allowsMembraeWrites: Bool {
        allowMembraeKnowledgeWrite && (spaceID != nil || allowUnscopedWrites)
    }

    /// A Run never deletes, never makes a Space, and never takes a completion back.
    static let denied: Set<String> = [
        "mark_for_deletion",
        "delete_record",
        "create_space",
        "delete_completion"
    ]

    static let projectWrites: Set<String> = [
        "project_write_file",
        "project_edit_file",
        "project_apply_patch",
        "project_delete_file"
    ]

    static let finishRun = "finish_run"
    /// Writes the Run's own plan. Always allowed, and always pointed at this Run.
    static let setRunSteps = "set_run_steps"

    init(
        runID: UUID,
        spaceID: UUID?,
        assignedTaskID: UUID?,
        allowCode: Bool,
        allowMembraeKnowledgeWrite: Bool = true,
        denied: Set<String> = RunToolPolicy.denied,
        requireSpace: Bool = true,
        attachesRunSource: Bool = true,
        allowExternalMCP: Bool = false,
        allowBrowser: Bool = true,
        allowUnscopedWrites: Bool = false
    ) {
        self.runID = runID
        self.spaceID = spaceID
        self.assignedTaskID = assignedTaskID
        self.allowCode = allowCode
        self.allowMembraeKnowledgeWrite = allowMembraeKnowledgeWrite
        self.denied = denied
        self.requireSpace = requireSpace
        self.attachesRunSource = attachesRunSource
        self.allowExternalMCP = allowExternalMCP
        self.allowBrowser = allowBrowser
        self.allowUnscopedWrites = allowUnscopedWrites
    }

    static func chat(spaceID: UUID?) -> RunToolPolicy {
        RunToolPolicy(
            runID: UUID(),
            spaceID: spaceID,
            assignedTaskID: nil,
            allowCode: true,
            allowMembraeKnowledgeWrite: true,
            denied: [],
            requireSpace: false,
            attachesRunSource: false,
            allowExternalMCP: true,
            allowBrowser: true,
            allowUnscopedWrites: spaceID == nil
        )
    }

    func allows(_ name: String) -> Bool {
        if name == Self.finishRun { return true }
        // A chat has no Run to write a plan on.
        if name == Self.setRunSteps { return attachesRunSource }
        if BrowserPermissions.isBrowserTool(name) { return allowBrowser }
        if name == MCPToolName.importServers { return allowExternalMCP }
        if MCPToolName.isExternal(name) { return allowExternalMCP }
        if denied.contains(name) { return false }
        // A Run may complete the task it was started from, and no other.
        if name == "complete_task", attachesRunSource { return assignedTaskID != nil }
        if Self.projectWrites.contains(name) { return false }
        if name.hasPrefix("project_") { return allowCode }
        if isMembraeWrite(name) { return allowsMembraeWrites }
        if requireSpace && spaceID == nil && isMembraeTool(name) {
            return false
        }
        return true
    }

    func allowedNames(from listed: [String]) -> [String] {
        listed.filter(allows)
    }

    func permitsCall(_ name: String, arguments: [String: Any]) -> Result<Void, RunToolDenied> {
        guard allows(name) else {
            if Self.projectWrites.contains(name) {
                return .failure(RunToolDenied("This run cannot edit source."))
            }
            if isMembraeWrite(name) && !allowsMembraeWrites {
                return .failure(RunToolDenied("This run cannot change Membrae records."))
            }
            return .failure(RunToolDenied("This run cannot use \(name)."))
        }
        if name == "complete_task", attachesRunSource {
            let taskID = (arguments["task_id"] as? String).flatMap(UUID.init(uuidString:))
            if taskID == nil || taskID != assignedTaskID {
                return .failure(RunToolDenied("This run can only complete the task it was started from."))
            }
        }
        if !allowOtherSpaces,
           let expected = spaceID,
           let raw = Self.namedSpace(arguments),
           let incoming = UUID(uuidString: raw),
           incoming != expected {
            return .failure(RunToolDenied("This run can only write in its own Space."))
        }
        return .success(())
    }

    /// Fills in the Run's own Space on every tool that takes one, unless the prompt named another.
    func preparedArguments(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        var arguments = arguments
        if name == Self.setRunSteps { arguments["run_id"] = runID.uuidString }
        if arguments["space_id"] == nil, let old = arguments["project_id"] {
            arguments["space_id"] = old
            arguments["project_id"] = nil
        }
        let named = Self.namedSpace(arguments).flatMap(UUID.init(uuidString:)) != nil
        if let spaceID, Self.takesSpaceID(name), !(allowOtherSpaces && named) {
            arguments["space_id"] = spaceID.uuidString
        }
        if attachesRunSource, name == "create_note",
           arguments["source"] == nil || (arguments["source"] as? String)?.isEmpty == true {
            arguments["source"] = "membrae://run/\(runID.uuidString)"
        }
        return arguments
    }

    private static func namedSpace(_ arguments: [String: Any]) -> String? {
        (arguments["space_id"] as? String) ?? (arguments["project_id"] as? String)
    }

    /// The tools whose schema has a space_id, read once from the tool definitions.
    static let spaceIDTools: Set<String> = Set(Tools.definitions.compactMap { tool in
        guard let name = tool["name"] as? String,
              let schema = tool["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              properties["space_id"] != nil else { return nil }
        return name
    })

    static func takesSpaceID(_ name: String) -> Bool {
        spaceIDTools.contains(name)
    }

    static func effective(for run: AgentRun) -> RunToolPolicy {
        var policy = RunToolPolicy(
            runID: run.id,
            spaceID: run.project?.id,
            assignedTaskID: run.task?.id,
            allowCode: run.project != nil && !run.repositoryLocators.isEmpty,
            requireSpace: false,
            allowUnscopedWrites: run.project == nil
        )
        policy.allowOtherSpaces = true
        return policy
    }

    /// The Membrae tools a general Run may be offered. Completing is only there when it has a task.
    static func generalCatalog(for run: AgentRun) -> [String] {
        (run.task == nil ? membraeCatalog : membraeCatalog + ["complete_task"]) + [setRunSteps]
    }
}

struct RunToolDenied: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func isMembraeWrite(_ name: String) -> Bool {
    name.hasPrefix("create_")
        || name.hasPrefix("update_")
        || name.hasPrefix("delete_")
        || name.hasPrefix("set_")
        || name.hasPrefix("log_")
        || name.hasPrefix("place_")
        || name.hasPrefix("remove_")
        || name == "complete_task"
        || name == "mark_for_deletion"
        || name == "assign_tag"
        || name == "propose_cleanup"
        || name == "merge_tracks"
        || name == "convert_track_to_stop"
}

private func isMembraeTool(_ name: String) -> Bool {
    name.hasPrefix("list_")
        || name.hasPrefix("get_")
        || isMembraeWrite(name)
}
