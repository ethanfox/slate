import Foundation

struct RunToolPolicy: Equatable, Sendable {
    var runID: UUID
    var projectID: UUID?
    var assignedTaskID: UUID?
    var allowCode: Bool

    var allowsSlateWrites: Bool { projectID != nil }

    static let denied: Set<String> = [
        "complete_task",
        "mark_for_deletion",
        "create_project",
        "update_project",
        "delete_completion",
        "consult_code"
    ]

    static let finishRun = "finish_run"

    func allows(_ name: String) -> Bool {
        if name == Self.finishRun { return true }
        if Self.denied.contains(name) { return false }
        if name.hasPrefix("project_") { return allowCode }
        if !allowsSlateWrites {
            return false
        }
        return true
    }

    func allowedNames(from listed: [String]) -> [String] {
        listed.filter(allows)
    }

    func permitsCall(_ name: String, arguments: [String: Any]) -> Result<Void, RunToolDenied> {
        guard allows(name) else {
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
        return .success(())
    }

    func preparedArguments(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        var arguments = arguments
        if let projectID, writesProject(name) {
            arguments["project_id"] = projectID.uuidString
        }
        if name == "create_note", arguments["source"] == nil || (arguments["source"] as? String)?.isEmpty == true {
            arguments["source"] = "slate://run/\(runID.uuidString)"
        }
        return arguments
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
