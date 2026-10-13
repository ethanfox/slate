import Foundation

struct RunToolPolicy: Equatable, Sendable {
    var runID: UUID
    var projectID: UUID?
    var assignedTaskID: UUID?
    var allowCode: Bool
    var allowMembraeKnowledgeWrite: Bool
    var denied: Set<String>
    var requireProject: Bool
    var attachesRunSource: Bool
    var allowExternalMCP: Bool
    var allowBrowser: Bool
    /// With no project, writes may land in any project or Space. This is how the one input files things.
    var allowUnscopedWrites: Bool
    /// The prompt may name another project. The Run's own project is then only the default.
    var allowOtherProjects = false

    var allowsMembraeWrites: Bool {
        allowMembraeKnowledgeWrite && (projectID != nil || allowUnscopedWrites)
    }

    static let denied: Set<String> = [
        "mark_for_deletion",
        "delete_record",
        "create_project",
        "update_project",
        "delete_completion",
        "consult_code"
    ]

    static let projectWrites: Set<String> = [
        "project_write_file",
        "project_edit_file",
        "project_apply_patch",
        "project_delete_file"
    ]

    static let finishRun = "finish_run"

    init(
        runID: UUID,
        projectID: UUID?,
        assignedTaskID: UUID?,
        allowCode: Bool,
        allowMembraeKnowledgeWrite: Bool = true,
        denied: Set<String> = RunToolPolicy.denied,
        requireProject: Bool = true,
        attachesRunSource: Bool = true,
        allowExternalMCP: Bool = false,
        allowBrowser: Bool = true,
        allowUnscopedWrites: Bool = false
    ) {
        self.runID = runID
        self.projectID = projectID
        self.assignedTaskID = assignedTaskID
        self.allowCode = allowCode
        self.allowMembraeKnowledgeWrite = allowMembraeKnowledgeWrite
        self.denied = denied
        self.requireProject = requireProject
        self.attachesRunSource = attachesRunSource
        self.allowExternalMCP = allowExternalMCP
        self.allowBrowser = allowBrowser
        self.allowUnscopedWrites = allowUnscopedWrites
    }

    static func chat(projectID: UUID?) -> RunToolPolicy {
        RunToolPolicy(
            runID: UUID(),
            projectID: projectID,
            assignedTaskID: nil,
            allowCode: true,
            allowMembraeKnowledgeWrite: true,
            denied: [],
            requireProject: false,
            attachesRunSource: false,
            allowExternalMCP: true,
            allowBrowser: true,
            allowUnscopedWrites: projectID == nil
        )
    }

    func allows(_ name: String) -> Bool {
        if name == Self.finishRun { return true }
        if BrowserPermissions.isBrowserTool(name) { return allowBrowser }
        if name == MCPToolName.importServers { return allowExternalMCP }
        if MCPToolName.isExternal(name) { return allowExternalMCP }
        if denied.contains(name) { return false }
        // A Run may complete the task it was started from, and no other.
        if name == "complete_task", attachesRunSource { return assignedTaskID != nil }
        if Self.projectWrites.contains(name) { return false }
        if name.hasPrefix("project_") { return allowCode }
        if isMembraeWrite(name) { return allowsMembraeWrites }
        if requireProject && projectID == nil && isMembraeTool(name) {
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
        if !allowOtherProjects,
           let expected = projectID,
           let raw = arguments["project_id"] as? String,
           let incoming = UUID(uuidString: raw),
           incoming != expected {
            return .failure(RunToolDenied("This run can only write in its own project."))
        }
        return .success(())
    }

    func preparedArguments(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        var arguments = arguments
        let named = (arguments["project_id"] as? String).flatMap(UUID.init(uuidString:)) != nil
        if let projectID, writesProject(name), !(allowOtherProjects && named) {
            arguments["project_id"] = projectID.uuidString
        }
        if attachesRunSource, name == "create_note",
           arguments["source"] == nil || (arguments["source"] as? String)?.isEmpty == true {
            arguments["source"] = "membrae://run/\(runID.uuidString)"
        }
        return arguments
    }

    static func effective(for run: AgentRun) -> RunToolPolicy {
        var policy = RunToolPolicy(
            runID: run.id,
            projectID: run.project?.id,
            assignedTaskID: run.task?.id,
            allowCode: run.project != nil && !run.repositoryLocators.isEmpty,
            requireProject: false,
            allowUnscopedWrites: run.project == nil
        )
        policy.allowOtherProjects = true
        return policy
    }

    /// The Membrae tools a general Run may be offered. Completing is only there when it has a task.
    static func generalCatalog(for run: AgentRun) -> [String] {
        run.task == nil ? membraeCatalog : membraeCatalog + ["complete_task"]
    }
}

struct RunToolDenied: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Space tools take a space id, never a project id.
private func writesProject(_ name: String) -> Bool {
    (name.hasPrefix("create_") || name.hasPrefix("list_")) && !name.contains("_space") && !name.contains("_area") && !name.contains("_source")
}

private func isMembraeWrite(_ name: String) -> Bool {
    name.hasPrefix("create_")
        || name.hasPrefix("update_")
        || name.hasPrefix("delete_")
        || name == "complete_task"
        || name == "mark_for_deletion"
        || name == "assign_tag"
        || name == "remove_tag"
}

private func isMembraeTool(_ name: String) -> Bool {
    name.hasPrefix("list_")
        || name.hasPrefix("get_")
        || name.hasPrefix("create_")
        || name.hasPrefix("update_")
        || name.hasPrefix("delete_")
        || name == "complete_task"
        || name == "mark_for_deletion"
        || name == "assign_tag"
        || name == "remove_tag"
}
