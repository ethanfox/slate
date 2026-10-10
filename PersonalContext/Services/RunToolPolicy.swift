import Foundation

struct RunToolPolicy: Equatable, Sendable {
    var runID: UUID
    var projectID: UUID?
    var assignedTaskID: UUID?
    var allowCode: Bool
    var allowMembraeKnowledgeWrite: Bool
    var allowCodeReferenceWrite: Bool
    var scopedAttachmentID: UUID?
    var denied: Set<String>
    var requireProject: Bool
    var attachesRunSource: Bool

    var allowsMembraeWrites: Bool { allowMembraeKnowledgeWrite && projectID != nil }

    static let denied: Set<String> = [
        "complete_task",
        "mark_for_deletion",
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
        allowCodeReferenceWrite: Bool = false,
        scopedAttachmentID: UUID? = nil,
        denied: Set<String> = RunToolPolicy.denied,
        requireProject: Bool = true,
        attachesRunSource: Bool = true
    ) {
        self.runID = runID
        self.projectID = projectID
        self.assignedTaskID = assignedTaskID
        self.allowCode = allowCode
        self.allowMembraeKnowledgeWrite = allowMembraeKnowledgeWrite
        self.allowCodeReferenceWrite = allowCodeReferenceWrite
        self.scopedAttachmentID = scopedAttachmentID
        self.denied = denied
        self.requireProject = requireProject
        self.attachesRunSource = attachesRunSource
    }

    static func chat(projectID: UUID?) -> RunToolPolicy {
        RunToolPolicy(
            runID: UUID(),
            projectID: projectID,
            assignedTaskID: nil,
            allowCode: true,
            allowMembraeKnowledgeWrite: true,
            allowCodeReferenceWrite: false,
            denied: [],
            requireProject: false,
            attachesRunSource: false
        )
    }

    static func indexing(runID: UUID, projectID: UUID?, attachmentID: UUID) -> RunToolPolicy {
        RunToolPolicy(
            runID: runID,
            projectID: projectID,
            assignedTaskID: nil,
            allowCode: true,
            allowMembraeKnowledgeWrite: false,
            allowCodeReferenceWrite: true,
            scopedAttachmentID: attachmentID,
            denied: RunToolPolicy.denied.union(projectWrites),
            requireProject: false,
            attachesRunSource: false
        )
    }

    func allows(_ name: String) -> Bool {
        if name == Self.finishRun { return true }
        if denied.contains(name) { return false }
        if Self.projectWrites.contains(name) { return false }
        if RepositoryIndex.toolWrites.contains(name) { return allowCodeReferenceWrite }
        if RepositoryIndex.toolReads.contains(name) { return true }
        if name.hasPrefix("project_") { return allowCode }
        if isMembraeWrite(name) { return allowsMembraeWrites }
        if allowCodeReferenceWrite {
            return name == "list_projects" || name == "get_project"
        }
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
                return .failure(RunToolDenied(CodeReferenceError.sourceEditDenied.localizedDescription ?? "This run cannot edit source."))
            }
            if isMembraeWrite(name) && !allowsMembraeWrites {
                return .failure(RunToolDenied(CodeReferenceError.unrelatedWriteDenied.localizedDescription ?? "This run cannot change unrelated Membrae records."))
            }
            return .failure(RunToolDenied("This run cannot use \(name)."))
        }
        if name == "update_task" || name == "complete_task" {
            if let assigned = assignedTaskID,
               let raw = arguments["task_id"] as? String,
               let taskID = UUID(uuidString: raw),
               taskID == assigned {
                if name == "complete_task" {
                    return .failure(RunToolDenied("This run cannot complete the assigned task."))
                }
                if let status = arguments["status"] as? String, status.lowercased() == "done" {
                    return .failure(RunToolDenied("This run cannot complete the assigned task."))
                }
            }
        }
        if let expected = projectID,
           let raw = arguments["project_id"] as? String,
           let incoming = UUID(uuidString: raw),
           incoming != expected {
            return .failure(RunToolDenied("This run can only write in its own project."))
        }
        if RepositoryIndex.toolWrites.contains(name), let scoped = scopedAttachmentID {
            if let raw = arguments["attachment_id"] as? String,
               let incoming = UUID(uuidString: raw),
               incoming != scoped {
                return .failure(RunToolDenied(CodeReferenceError.attachmentMismatch.localizedDescription ?? "Wrong attachment."))
            }
        }
        return .success(())
    }

    func preparedArguments(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        var arguments = arguments
        if let projectID, writesProject(name) {
            arguments["project_id"] = projectID.uuidString
        }
        if attachesRunSource, name == "create_note",
           arguments["source"] == nil || (arguments["source"] as? String)?.isEmpty == true {
            arguments["source"] = "membrae://run/\(runID.uuidString)"
        }
        if RepositoryIndex.toolWrites.contains(name), let scopedAttachmentID {
            arguments["attachment_id"] = scopedAttachmentID.uuidString
        }
        return arguments
    }

    static func effective(for run: AgentRun) -> RunToolPolicy {
        if run.purpose == .indexRepository, let attachmentID = run.indexedAttachmentID {
            return .indexing(runID: run.id, projectID: run.project?.id, attachmentID: attachmentID)
        }
        return RunToolPolicy(
            runID: run.id,
            projectID: run.project?.id,
            assignedTaskID: run.task?.id,
            allowCode: run.project != nil && !run.repositoryLocators.isEmpty
        )
    }

    static func catalogNames(for run: AgentRun) -> [String] {
        let policy = effective(for: run)
        let catalog = run.purpose == .indexRepository && run.indexedAttachmentID != nil
            ? indexingCatalog
            : membraeCatalog
        return policy.allowedNames(from: catalog)
    }
}

struct RunToolDenied: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func writesProject(_ name: String) -> Bool {
    name.hasPrefix("create_") || name.hasPrefix("list_")
}

private func isMembraeWrite(_ name: String) -> Bool {
    name.hasPrefix("create_")
        || name.hasPrefix("update_")
        || name.hasPrefix("delete_")
        || name == "complete_task"
        || name == "mark_for_deletion"
}

private func isMembraeTool(_ name: String) -> Bool {
    name.hasPrefix("list_")
        || name.hasPrefix("get_")
        || name.hasPrefix("create_")
        || name.hasPrefix("update_")
        || name.hasPrefix("delete_")
        || name == "complete_task"
        || name == "mark_for_deletion"
}
