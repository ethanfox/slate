import Foundation
import SwiftData
#if SLATE_TESTS
@testable import Slate
#endif

struct ToolError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

struct Args {
    let raw: [String: Any]

    func string(_ key: String) -> String? {
        guard let value = raw[key] as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else { throw ToolError("\(key) is required.") }
        return value
    }

    func uuid(_ key: String) throws -> UUID {
        let value = try required(key)
        guard let id = UUID(uuidString: value) else { throw ToolError("\(key) is not a valid id: \(value)") }
        return id
    }

    /// nil when the key is absent, .some(nil) when it is an empty string (clear the link).
    func optionalUUID(_ key: String) throws -> UUID?? {
        guard let value = string(key) else { return nil }
        if value.isEmpty { return .some(nil) }
        guard let id = UUID(uuidString: value) else { throw ToolError("\(key) is not a valid id: \(value)") }
        return .some(id)
    }

    func bool(_ key: String) -> Bool? { raw[key] as? Bool }

    func choice<T: RawRepresentable & CaseIterable>(_ key: String, as type: T.Type) throws -> T? where T.RawValue == String {
        guard let value = string(key) else { return nil }
        if let parsed = T(rawValue: value) { return parsed }
        if let parsed = T(rawValue: value.lowercased()) { return parsed }
        let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
        throw ToolError("\(key) must be one of: \(allowed).")
    }

    func date(_ key: String) throws -> Date?? {
        guard let value = string(key) else { return nil }
        if value.isEmpty { return .some(nil) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return .some(date) }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return .some(date) }
        throw ToolError("\(key) must be an ISO-8601 date.")
    }

    func strings(_ key: String) throws -> [String]? {
        guard let raw = raw[key] else { return nil }
        if let array = raw as? [String] { return array }
        if let array = raw as? [Any] {
            return try array.map { value in
                guard let string = value as? String else {
                    throw ToolError("\(key) must be an array of strings.")
                }
                return string
            }
        }
        throw ToolError("\(key) must be an array of strings.")
    }

    func objects(_ key: String) throws -> [[String: Any]]? {
        guard let raw = raw[key] else { return nil }
        if let array = raw as? [[String: Any]] { return array }
        if let array = raw as? [Any] {
            return try array.map { value in
                guard let object = value as? [String: Any] else {
                    throw ToolError("\(key) must be an array of objects.")
                }
                return object
            }
        }
        throw ToolError("\(key) must be an array of objects.")
    }

    func uuids(_ key: String) throws -> [UUID]? {
        guard let raw = raw[key] else { return nil }
        let strings: [String]
        if let array = raw as? [String] {
            strings = array
        } else if let array = raw as? [Any] {
            strings = array.compactMap { $0 as? String }
        } else {
            throw ToolError("\(key) must be an array of ids.")
        }
        return try strings.map { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: trimmed) else {
                throw ToolError("\(key) contains an invalid id: \(value)")
            }
            return id
        }
    }
}

enum ProjectExpand: String, CaseIterable {
    case decisions
    case threads
    case notes
    case tasks
    case deletionMarks = "deletion_marks"

    static func parse(_ values: [String]?) throws -> Set<ProjectExpand> {
        guard let values else { return [] }
        return Set(try values.map { value in
            guard let parsed = ProjectExpand(rawValue: value) else {
                let allowed = ProjectExpand.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolError("include must be one of: \(allowed).")
            }
            return parsed
        })
    }
}

enum Tools {
    typealias Handler = (Args, ModelContext) throws -> Any

    private struct Tool {
        var name: String
        var description: String
        var properties: [String: [String: Any]]
        var required: [String]
        var readOnly: Bool
        var handler: Handler
    }

    static var definitions: [[String: Any]] {
        tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "inputSchema": [
                    "type": "object",
                    "properties": tool.properties,
                    "required": tool.required,
                    "additionalProperties": false
                ],
                "annotations": ["readOnlyHint": tool.readOnly, "destructiveHint": false]
            ]
        }
    }

    static func call(_ name: String, arguments: [String: Any], container: ModelContainer) -> [String: Any] {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return failure("Unknown tool: \(name)")
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let value = try tool.handler(Args(raw: arguments), context)
            if !tool.readOnly {
                try context.save()
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(Store.changedNotification as CFString),
                    nil, nil, true
                )
            }
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
        } catch let error as ToolError {
            return failure(error.message)
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: - Schema helpers

    private static func text(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func flag(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func options<T: RawRepresentable & CaseIterable>(_ type: T.Type, _ description: String) -> [String: Any] where T.RawValue == String {
        ["type": "string", "enum": T.allCases.map(\.rawValue), "description": description]
    }

    private static let projectID = text("Project id from list_projects.")
    private static let threadLink = text("Thread id to file this under. Empty string removes the link.")

    // MARK: - Tools

    private static let tools: [Tool] = [
        Tool(
            name: "list_projects",
            description: "List every project with its id, status, summary, and record counts.",
            properties: [:], required: [], readOnly: true
        ) { _, context in
            try context.fetch(FetchDescriptor<Project>())
                .sorted { $0.lastActivity > $1.lastActivity }
                .map(JSONShape.project)
        },
        Tool(
            name: "get_project",
            description: "Get one project: fields, identity context, and counts. Pass include for bounded lists. Use get_thread for a track body and get_note for reference material.",
            properties: [
                "project_id": projectID,
                "include": [
                    "type": "array",
                    "items": ["type": "string", "enum": ["decisions", "threads", "notes", "tasks", "deletion_marks"]],
                    "description": "Record lists to add. Omit for a lean project record. Lists are bounded; use list_* and get_thread for the rest."
                ]
            ],
            required: ["project_id"],
            readOnly: true
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            let include = try ProjectExpand.parse(args.strings("include"))
            var shape = JSONShape.project(project)
            shape["context"] = ContextBuilder.identity(for: project)
            shape["attachments"] = JSONShape.attachments(on: project, in: context)
            if include.contains(.decisions) {
                shape["decisions"] = project.decisions
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(20)
                    .map(JSONShape.decision)
            }
            if include.contains(.threads) {
                shape["threads"] = project.threads
                    .sorted { $0.createdAt < $1.createdAt }
                    .prefix(24)
                    .map { JSONShape.thread($0, full: false) }
            }
            if include.contains(.notes) {
                shape["notes"] = project.notes
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(8)
                    .map { JSONShape.note($0, full: false) }
            }
            if include.contains(.tasks) {
                shape["tasks"] = TaskStore.tasks(in: context, project: project)
                    .sorted(by: TaskStore.boardSort)
                    .prefix(20)
                    .map { JSONShape.task($0, full: false) }
            }
            if include.contains(.deletionMarks) {
                shape["deletion_marks"] = project.deletionMarks
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(20)
                    .map(JSONShape.deletionMark)
            }
            return shape
        },
        Tool(
            name: "create_project",
            description: "Create a project.",
            properties: [
                "name": text("Project name."),
                "summary": text("What the project is."),
                "current_direction": text("Where the project is heading right now."),
                "symbol": text("SF Symbol name for the icon. Defaults to folder.")
            ],
            required: ["name"], readOnly: false
        ) { args, context in
            let project = Project(name: try args.required("name"), symbol: args.string("symbol") ?? "folder", summary: args.string("summary") ?? "")
            project.currentDirection = args.string("current_direction") ?? ""
            context.insert(project)
            return JSONShape.project(project)
        },
        Tool(
            name: "update_project",
            description: "Change a project's fields. Only the fields you pass are changed.",
            properties: [
                "project_id": projectID,
                "name": text("New name."),
                "summary": text("New summary."),
                "current_direction": text("New current direction."),
                "status": options(ProjectStatus.self, "Project status."),
                "is_pinned": flag("Pin the project to the top of the sidebar."),
                "symbol": text("SF Symbol name for the icon.")
            ],
            required: ["project_id"], readOnly: false
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            if let name = args.string("name"), !name.isEmpty { project.name = name }
            if let summary = args.string("summary") { project.summary = summary }
            if let direction = args.string("current_direction") { project.currentDirection = direction }
            if let status = try args.choice("status", as: ProjectStatus.self) {
                project.status = status
                TaskStore.syncProjectStatus(project, in: context)
            }
            if let pinned = args.bool("is_pinned") { project.isPinned = pinned }
            if let symbol = args.string("symbol"), !symbol.isEmpty { project.symbol = symbol }
            project.touch()
            return JSONShape.project(project)
        },

        Tool(
            name: "list_tasks",
            description: "List Slate tasks. Completions are not included. Use list_completions for repeat history. Pass track_id to list work on a track.",
            properties: [
                "project_id": text("Optional project id. Omit to list every task."),
                "track_id": text("Only tasks linked to this track."),
                "include_descendants": flag("When track_id is set, also include tasks on child tracks. Defaults to false."),
                "status": options(TaskWorkflowStatus.self, "Only tasks with this workflow status."),
                "next_only": flag("Only the Next task in each project.")
            ],
            required: [], readOnly: true
        ) { args, context in
            let project = try args.string("project_id").map { _ in try Lookup.project(try args.uuid("project_id"), in: context) }
            let track = try args.string("track_id").map { _ in try Lookup.thread(try args.uuid("track_id"), in: context) }
            let includeDescendants = args.bool("include_descendants") ?? false
            let status = try args.choice("status", as: TaskWorkflowStatus.self)
            let nextOnly = args.bool("next_only") ?? false
            let items = track.map { TaskStore.tasks(on: $0, includingDescendants: includeDescendants) }
                ?? TaskStore.tasks(in: context, project: project)
            return items
                .filter { task in
                    if let project, track != nil, task.project?.id != project.id { return false }
                    if let status, task.workflowStatus != status { return false }
                    if nextOnly, !task.isNext { return false }
                    return true
                }
                .sorted(by: TaskStore.boardSort)
                .map { JSONShape.task($0, full: false) }
        },
        Tool(
            name: "get_task",
            description: "Get one Slate task, including linked notes, blockers, dependents, and completion ids.",
            properties: ["task_id": text("Task id.")],
            required: ["task_id"], readOnly: true
        ) { args, context in
            JSONShape.task(try Lookup.task(try args.uuid("task_id"), in: context), full: true)
        },
        Tool(
            name: "create_task",
            description: "Create a Slate task. project_id is optional. is_next requires an active project. Link governing tracks with track_ids. Reference notes are supplementary via note_ids. Do not put built/not-built in notes.",
            properties: [
                "title": text("Task title."),
                "project_id": text("Optional project id."),
                "notes": text("Short working comment. Not status. Do not write built or not-built here."),
                "due": text("ISO-8601 due date."),
                "status": options(TaskWorkflowStatus.self, "Workflow status. Defaults to ready."),
                "is_next": flag("Mark this task Next for its project."),
                "track_ids": ["type": "array", "items": ["type": "string"], "description": "Governing track ids. Feature and problem work lives on these tracks."],
                "note_ids": ["type": "array", "items": ["type": "string"], "description": "Optional reference note ids. Notes are not the spec."],
                "blocked_reason": text("Free-text blocked reason."),
                "blocker_ids": ["type": "array", "items": ["type": "string"], "description": "Task ids that block this one."],
                "repeat": options(TaskRepeat.self, "Repeat rule. Defaults to none. custom is not settable.")
            ],
            required: ["title"], readOnly: false
        ) { args, context in
            let item = AgendaItem(kind: .task, eventKitID: "", title: try args.required("title"))
            context.insert(item)
            try TaskMutations.apply(args, to: item, creating: true, in: context)
            return JSONShape.task(item, full: true)
        },
        Tool(
            name: "update_task",
            description: "Change a Slate task. Only the fields you pass are changed. track_ids, note_ids, and blocker_ids replace the whole set.",
            properties: [
                "task_id": text("Task id."),
                "title": text("New title."),
                "notes": text("Short working comment. Not status. Do not write built or not-built here."),
                "due": text("ISO-8601 due date. Empty string clears it."),
                "status": options(TaskWorkflowStatus.self, "Workflow status."),
                "is_next": flag("Set or clear Next."),
                "project_id": text("Move to this project. Empty string clears it."),
                "track_ids": ["type": "array", "items": ["type": "string"], "description": "Replacement governing track ids."],
                "note_ids": ["type": "array", "items": ["type": "string"], "description": "Replacement reference note ids. Notes are not the spec."],
                "blocked_reason": text("Free-text blocked reason."),
                "blocker_ids": ["type": "array", "items": ["type": "string"], "description": "Replacement blocker task ids."],
                "repeat": options(TaskRepeat.self, "Repeat rule. custom is not settable.")
            ],
            required: ["task_id"], readOnly: false
        ) { args, context in
            let item = try Lookup.task(try args.uuid("task_id"), in: context)
            try TaskMutations.apply(args, to: item, creating: false, in: context)
            return JSONShape.task(item, full: true)
        },
        Tool(
            name: "complete_task",
            description: "Complete a Slate task. Repeating tasks write a completion and advance the due date. Non-repeating tasks move to Done. Already-done tasks are returned unchanged.",
            properties: ["task_id": text("Task id.")],
            required: ["task_id"], readOnly: false
        ) { args, context in
            let item = try Lookup.task(try args.uuid("task_id"), in: context)
            if !item.isCompleted {
                if item.repeatRule.advances, item.due != nil {
                    TaskStore.completeRepeating(item, in: context)
                } else {
                    TaskStore.setStatus(.done, on: item, in: context)
                }
            }
            return JSONShape.task(item, full: true)
        },
        Tool(
            name: "list_completions",
            description: "List immutable completion records for repeating tasks.",
            properties: [
                "project_id": text("Optional project id."),
                "task_id": text("Optional parent task id.")
            ],
            required: [], readOnly: true
        ) { args, context in
            let projectID = try args.string("project_id").map { _ in try args.uuid("project_id") }
            let taskID = try args.string("task_id").map { _ in try args.uuid("task_id") }
            let descriptor = FetchDescriptor<TaskCompletion>(sortBy: [SortDescriptor(\.completedAt, order: .reverse)])
            return try context.fetch(descriptor)
                .filter { completion in
                    if let projectID, completion.project?.id != projectID { return false }
                    if let taskID, completion.parentTask?.id != taskID { return false }
                    return true
                }
                .map(JSONShape.completion)
        },
        Tool(
            name: "get_completion",
            description: "Get one completion record.",
            properties: ["completion_id": text("Completion id.")],
            required: ["completion_id"], readOnly: true
        ) { args, context in
            JSONShape.completion(try Lookup.completion(try args.uuid("completion_id"), in: context))
        },
        Tool(
            name: "delete_completion",
            description: "Delete a completion. The latest one undoes the series due date. Older ones delete history only.",
            properties: ["completion_id": text("Completion id.")],
            required: ["completion_id"], readOnly: false
        ) { args, context in
            let completion = try Lookup.completion(try args.uuid("completion_id"), in: context)
            try TaskStore.deleteCompletion(completion, in: context)
            return ["deleted": true]
        },

        Tool(
            name: "list_decisions",
            description: "List a project's decisions, newest first.",
            properties: ["project_id": projectID, "status": options(DecisionStatus.self, "Only decisions with this status.")],
            required: ["project_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            let status = try args.choice("status", as: DecisionStatus.self)
            return project.decisions
                .filter { status == nil || $0.status == status }
                .sorted { $0.createdAt > $1.createdAt }
                .map(JSONShape.decision)
        },
        Tool(
            name: "get_decision",
            description: "Get one decision.",
            properties: ["decision_id": text("Decision id.")], required: ["decision_id"], readOnly: true
        ) { args, context in
            JSONShape.decision(try Lookup.decision(try args.uuid("decision_id"), in: context))
        },
        Tool(
            name: "create_decision",
            description: "Record a decision. Pass supersedes_id when it replaces an earlier decision; that one is marked superseded.",
            properties: [
                "project_id": projectID,
                "title": text("Short name for the decision."),
                "decision": text("What was decided."),
                "rationale": text("Why."),
                "thread_id": threadLink,
                "supersedes_id": text("Id of the decision this one replaces.")
            ],
            required: ["project_id", "title", "decision"], readOnly: false
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            let decision = Decision(
                title: try args.required("title"),
                decision: try args.required("decision"),
                project: project,
                rationale: args.string("rationale") ?? "",
                thread: try Lookup.thread(args.optionalUUID("thread_id"), in: project)
            )
            context.insert(decision)
            if let oldID = try args.optionalUUID("supersedes_id") ?? nil {
                let old = try Lookup.decision(oldID, in: context)
                old.status = .superseded
                old.supersededByID = decision.id
            }
            project.touch()
            return JSONShape.decision(decision)
        },
        Tool(
            name: "update_decision",
            description: "Change a decision. Only the fields you pass are changed.",
            properties: [
                "decision_id": text("Decision id."),
                "title": text("New title."),
                "decision": text("New decision text."),
                "rationale": text("New rationale."),
                "status": options(DecisionStatus.self, "Decision status."),
                "thread_id": threadLink
            ],
            required: ["decision_id"], readOnly: false
        ) { args, context in
            let decision = try Lookup.decision(try args.uuid("decision_id"), in: context)
            if let title = args.string("title"), !title.isEmpty { decision.title = title }
            if let text = args.string("decision"), !text.isEmpty { decision.decision = text }
            if let rationale = args.string("rationale") { decision.rationale = rationale }
            if let status = try args.choice("status", as: DecisionStatus.self) {
                decision.status = status
                if status == .active { decision.supersededByID = nil }
            }
            if let link = try args.optionalUUID("thread_id"), let project = decision.project {
                decision.thread = try Lookup.thread(link, in: project)
            }
            decision.project?.touch()
            return JSONShape.decision(decision)
        },

        Tool(
            name: "list_threads",
            description: "List a project's threads with ids, kinds, statuses, summaries, and parent ids.",
            properties: ["project_id": projectID], required: ["project_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            return project.threads.sorted { $0.createdAt < $1.createdAt }.map { JSONShape.thread($0, full: false) }
        },
        Tool(
            name: "get_thread",
            description: "Get one track with its full body, linked decisions, note previews, tasks including child-track tasks, and child-track summaries.",
            properties: ["thread_id": text("Thread id.")], required: ["thread_id"], readOnly: true
        ) { args, context in
            let thread = try Lookup.thread(try args.uuid("thread_id"), in: context)
            var shape = JSONShape.thread(thread, full: true)
            shape["decisions"] = thread.decisions.map(JSONShape.decision)
            shape["notes"] = thread.notes.map { JSONShape.note($0, full: false) }
            shape["tasks"] = TaskStore.tasks(on: thread, includingDescendants: true)
                .map { JSONShape.task($0, full: false) }
            return shape
        },
        Tool(
            name: "create_thread",
            description: "Start a track: a line of work such as a direction, feature, problem, experiment, or topic. Put the spec in the body. Work to do is a task, not a body edit.",
            properties: [
                "project_id": projectID,
                "title": text("Thread title."),
                "kind": options(ThreadKind.self, "Kind of thread. Defaults to topic."),
                "status": options(ThreadStatus.self, "Defaults to exploring."),
                "summary": text("One or two sentences."),
                "body": text("Markdown spec."),
                "parent_id": text("Parent thread id, to nest this thread.")
            ],
            required: ["project_id", "title"], readOnly: false
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            let parent = try Lookup.thread(args.optionalUUID("parent_id"), in: project)
            let thread = ProjectThread(
                title: try args.required("title"),
                kind: try args.choice("kind", as: ThreadKind.self) ?? .topic,
                project: project,
                parent: parent
            )
            if let status = try args.choice("status", as: ThreadStatus.self) { thread.status = status }
            thread.summary = args.string("summary") ?? ""
            thread.body = args.string("body") ?? ""
            context.insert(thread)
            project.touch()
            return JSONShape.thread(thread, full: true)
        },
        Tool(
            name: "update_thread",
            description: "Change a thread. Only the fields you pass are changed. Use append_to_body to add to the body without rewriting it.",
            properties: [
                "thread_id": text("Thread id."),
                "title": text("New title."),
                "kind": options(ThreadKind.self, "Kind of thread."),
                "status": options(ThreadStatus.self, "Thread status."),
                "summary": text("New summary."),
                "body": text("Replaces the whole markdown spec. Omit or leave empty to keep the current body."),
                "append_to_body": text("Markdown appended to the end of the spec."),
                "parent_id": text("New parent thread id. Empty string makes it a top-level thread.")
            ],
            required: ["thread_id"], readOnly: false
        ) { args, context in
            let thread = try Lookup.thread(try args.uuid("thread_id"), in: context)
            if let title = args.string("title"), !title.isEmpty { thread.title = title }
            if let kind = try args.choice("kind", as: ThreadKind.self) { thread.kind = kind }
            if let status = try args.choice("status", as: ThreadStatus.self) { thread.status = status }
            if let summary = args.string("summary") { thread.summary = summary }
            if let body = args.string("body"), !body.isEmpty { thread.body = body }
            if let addition = args.string("append_to_body"), !addition.isEmpty {
                thread.body = thread.body.isEmpty ? addition : thread.body + "\n\n" + addition
            }
            if let link = try args.optionalUUID("parent_id"), let project = thread.project {
                let parent = try Lookup.thread(link, in: project)
                if let parent, thread.contains(parent) { throw ToolError("A thread can't be nested under itself or its own children.") }
                thread.parent = parent
            }
            thread.updatedAt = .now
            thread.project?.touch()
            return JSONShape.thread(thread, full: true)
        },

        Tool(
            name: "list_notes",
            description: "List a project's notes, most recently changed first, with a preview of each.",
            properties: ["project_id": projectID, "thread_id": text("Only notes filed under this thread.")],
            required: ["project_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            let threadID = try args.optionalUUID("thread_id") ?? nil
            return project.notes
                .filter { threadID == nil || $0.thread?.id == threadID }
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { JSONShape.note($0, full: false) }
        },
        Tool(
            name: "get_note",
            description: "Get one note with its full content.",
            properties: ["note_id": text("Note id.")], required: ["note_id"], readOnly: true
        ) { args, context in
            JSONShape.note(try Lookup.note(try args.uuid("note_id"), in: context), full: true)
        },
        Tool(
            name: "create_note",
            description: "Save a note: reference material, findings, links, or anything worth keeping that isn't a decision.",
            properties: [
                "project_id": projectID,
                "title": text("Note title."),
                "content": text("Markdown content."),
                "source": text("Where this came from, such as a URL or conversation."),
                "thread_id": threadLink
            ],
            required: ["project_id", "content"], readOnly: false
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            let note = Note(
                content: try args.required("content"),
                project: project,
                title: args.string("title") ?? "",
                source: args.string("source") ?? "",
                thread: try Lookup.thread(args.optionalUUID("thread_id"), in: project)
            )
            context.insert(note)
            project.touch()
            return JSONShape.note(note, full: true)
        },
        Tool(
            name: "update_note",
            description: "Change a note. Only the fields you pass are changed.",
            properties: [
                "note_id": text("Note id."),
                "title": text("New title."),
                "content": text("Replaces the whole content."),
                "source": text("New source."),
                "thread_id": threadLink
            ],
            required: ["note_id"], readOnly: false
        ) { args, context in
            let note = try Lookup.note(try args.uuid("note_id"), in: context)
            if let title = args.string("title") { note.title = title }
            if let content = args.string("content"), !content.isEmpty { note.content = content }
            if let source = args.string("source") { note.source = source }
            if let link = try args.optionalUUID("thread_id"), let project = note.project {
                note.thread = try Lookup.thread(link, in: project)
            }
            note.updatedAt = .now
            note.project?.touch()
            return JSONShape.note(note, full: true)
        },

        Tool(
            name: "mark_for_deletion",
            description: "Propose deleting a note, track, decision, or chat. Agents cannot delete. The user sees the mark and can Keep or Delete. Reason is required. Optionally link a replacement in the same project. Calling again updates the reason and replacement.",
            properties: [
                "target_type": options(DeletionTargetKind.self, "Kind of record to mark."),
                "target_id": text("Id of the record to mark."),
                "reason": text("Why this should be deleted."),
                "replacement_type": options(DeletionTargetKind.self, "Kind of the replacement record."),
                "replacement_id": text("Id of the record that replaces it. Empty string clears the replacement.")
            ],
            required: ["target_type", "target_id", "reason"],
            readOnly: false
        ) { args, context in
            guard let targetKind = try args.choice("target_type", as: DeletionTargetKind.self) else {
                throw ToolError("target_type is required.")
            }
            let targetID = try args.uuid("target_id")
            let target = try Lookup.markedRecord(targetKind, targetID, in: context)
            let replacement = try Lookup.replacement(
                type: try args.choice("replacement_type", as: DeletionTargetKind.self),
                id: try args.optionalUUID("replacement_id"),
                targetID: targetID,
                project: target.project,
                existing: DeletionMarks.existing(for: targetID, in: target.project),
                in: context
            )
            let mark = DeletionMarks.upsert(
                targetKind: targetKind,
                targetID: targetID,
                reason: try args.required("reason"),
                project: target.project,
                replacementKind: replacement.kind,
                replacementID: replacement.id,
                in: context
            )
            target.project.touch()
            return JSONShape.deletionMark(mark)
        },
        Tool(
            name: "list_runs",
            description: "List Slate agent Runs. Newest first. Filter by project, task, status, or origin.",
            properties: [
                "project_id": text("Optional project id."),
                "task_id": text("Optional task id."),
                "status": options(RunStatus.self, "Optional status."),
                "origin": options(RunOrigin.self, "Optional origin door.")
            ],
            required: [],
            readOnly: true
        ) { args, context in
            let projectID = try args.string("project_id").map { _ in try args.uuid("project_id") }
            let taskID = try args.string("task_id").map { _ in try args.uuid("task_id") }
            let status = try args.choice("status", as: RunStatus.self)
            let origin = try args.choice("origin", as: RunOrigin.self)
            return RunStore.runs(in: context)
                .filter { run in
                    if let projectID, run.project?.id != projectID { return false }
                    if let taskID, run.task?.id != taskID { return false }
                    if let status, run.status != status { return false }
                    if let origin, run.origin != origin { return false }
                    return true
                }
                .map { JSONShape.run($0, full: false) }
        },
        Tool(
            name: "get_run",
            description: "Get one Run: origin, history, receipt, and snapshots.",
            properties: ["run_id": text("Run id.")],
            required: ["run_id"],
            readOnly: true
        ) { args, context in
            JSONShape.run(try Lookup.run(try args.uuid("run_id"), in: context), full: true)
        },
        Tool(
            name: "list_code_references",
            description: "List a project’s repository attachments and their architecture references. Pass project_id only. Returns published entries when available; otherwise the latest staged or discarded attempt, why it is unpublished, and the last indexing run. Each result includes attachment_id for get_code_reference_entry. Does not return entry bodies.",
            properties: [
                "project_id": text("Project id. Prefer this. Do not pass a folder path."),
                "attachment_id": text("Optional attachment UUID from a previous list or from get_project. Omit to list every attachment on the project. Never pass a file path.")
            ],
            required: [],
            readOnly: true
        ) { args, context in
            let projectID = try args.optionalUUID("project_id")?.flatMap { $0 }
            let attachmentID = try args.optionalUUID("attachment_id")?.flatMap { $0 }
            let project = try projectID.map { try Lookup.project($0, in: context) }
            return CodeReferenceStore.summaries(project: project, attachmentID: attachmentID, in: context)
        },
        Tool(
            name: "get_code_reference_entry",
            description: "Retrieve one code-reference entry: explanation, source locations, and relationships. Prefers the published reference; if none, returns the latest staged or discarded entry so you can inspect a failed index. Use list_code_references with project_id first.",
            properties: [
                "attachment_id": text("Attachment UUID from list_code_references or get_project. Not a folder path."),
                "key": text("Entry key or id from list_code_references.")
            ],
            required: ["attachment_id", "key"],
            readOnly: true
        ) { args, context in
            try CodeReferenceStore.publishedEntry(
                attachmentID: try args.uuid("attachment_id"),
                key: try args.required("key"),
                in: context
            )
        },
        Tool(
            name: "upsert_code_reference_entry",
            description: "Create or update one staged architecture-reference entry for the attachment this indexing run owns. Each entry must include at least one supporting source location from source you actually inspected. Publication is not this tool.",
            properties: [
                "attachment_id": text("Attachment id this indexing run is scoped to."),
                "key": text("Stable key, lowercase letters, numbers, and hyphens."),
                "title": text("Component title."),
                "body": text("Markdown explanation of the current implementation."),
                "source_locations": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "path": text("Path relative to the attachment root that you inspected."),
                            "declaration": text("Optional declaration name in that file.")
                        ],
                        "required": ["path"]
                    ],
                    "description": "Supporting source locations you inspected. At least one is required. Slate attaches the content hash from the project_read_file result; do not supply hashes."
                ],
                "related_keys": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Keys of other entries this component interacts with."
                ]
            ],
            required: ["attachment_id", "key", "title", "body", "source_locations"],
            readOnly: false
        ) { args, context in
            let attachment = try Lookup.attachment(try args.uuid("attachment_id"), in: context)
            let locations = try args.objects("source_locations")?.compactMap { item -> CodeSourceLocation? in
                guard let path = item["path"] as? String else { return nil }
                return CodeSourceLocation(path: path, declaration: item["declaration"] as? String, contentHash: nil)
            } ?? []
            let entry = try CodeReferenceStore.upsertEntry(
                attachment: attachment,
                key: try args.required("key"),
                title: try args.required("title"),
                body: try args.required("body"),
                sourceLocations: locations,
                relatedKeys: try args.strings("related_keys") ?? [],
                rootPath: CodeReferenceStore.rootPath(
                    for: attachment,
                    storeURL: context.container.configurations.first?.url
                ),
                in: context
            )
            return JSONShape.codeReferenceEntry(entry)
        },
        Tool(
            name: "set_code_reference_meta",
            description: "Record coverage, provenance, and uncertainties on the staged code reference. Does not publish.",
            properties: [
                "attachment_id": text("Attachment id this indexing run is scoped to."),
                "coverage": options(CodeReferenceCoverage.self, "inventory, partial, or complete."),
                "coverage_notes": text("Uncertainties and uninvestigated areas."),
                "source_revision": text("Commit SHA examined, when available."),
                "local_changes_examined": text("What local or dirty-tree changes were examined.")
            ],
            required: ["attachment_id"],
            readOnly: false
        ) { args, context in
            let attachment = try Lookup.attachment(try args.uuid("attachment_id"), in: context)
            let reference = try CodeReferenceStore.updateMeta(
                attachment: attachment,
                coverage: try args.choice("coverage", as: CodeReferenceCoverage.self),
                coverageNotes: args.string("coverage_notes"),
                sourceRevision: args.string("source_revision"),
                localChangesExamined: args.string("local_changes_examined"),
                in: context
            )
            return JSONShape.codeReference(reference, full: false, in: context)
        }
    ]
}

enum TaskMutations {
    static func apply(_ args: Args, to item: AgendaItem, creating: Bool, in context: ModelContext) throws {
        if let title = args.string("title"), !title.isEmpty { item.title = title }
        if let notes = args.string("notes") { item.notes = notes }
        if let due = try args.date("due") { item.due = due }
        if let projectLink = try args.optionalUUID("project_id") {
            if let id = projectLink {
                AssociationService.assignUserProject(try Lookup.project(id, in: context), on: item)
            } else {
                AssociationService.clearProject(from: item)
            }
        }
        if let trackIDs = try args.uuids("track_ids") {
            AssociationService.clearTracks(from: item, in: context)
            for id in trackIDs {
                AssociationService.applyLink(thread: try Lookup.thread(id, in: context), onto: item)
            }
        }
        if let noteIDs = try args.uuids("note_ids") {
            AssociationService.clearNotes(from: item, in: context)
            for id in noteIDs {
                AssociationService.applyLink(note: try Lookup.note(id, in: context), onto: item)
            }
        }
        if let status = try args.choice("status", as: TaskWorkflowStatus.self) {
            TaskStore.setStatus(status, on: item, in: context)
        }
        if let reason = args.string("blocked_reason") {
            TaskStore.setBlockedReason(reason, on: item, in: context)
        }
        if let blockerIDs = try args.uuids("blocker_ids") {
            let current = item.blockerLinks.compactMap(\.blockingTask)
            for blocker in current {
                TaskStore.removeBlocker(blocker, from: item, in: context)
            }
            for id in blockerIDs {
                try TaskStore.addBlocker(try Lookup.task(id, in: context), to: item, in: context)
            }
        }
        if let repeatRule = try args.choice("repeat", as: TaskRepeat.self) {
            if repeatRule == .custom { throw ToolError("repeat cannot be custom.") }
            item.repeatRule = repeatRule
        }
        if let isNext = args.bool("is_next") {
            if isNext {
                try TaskStore.setNext(item, in: context)
            } else {
                TaskStore.clearNext(on: item, in: context)
            }
        }
        item.touch()
        item.project?.touch()
        if creating, item.workflowStatusRaw.isEmpty {
            item.workflowStatusRaw = TaskWorkflowStatus.ready.rawValue
        }
    }
}

enum Lookup {
    static func project(_ id: UUID, in context: ModelContext) throws -> Project {
        guard let found = try context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No project with id \(id.uuidString).")
        }
        return found
    }

    static func decision(_ id: UUID, in context: ModelContext) throws -> Decision {
        guard let found = try context.fetch(FetchDescriptor<Decision>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No decision with id \(id.uuidString).")
        }
        return found
    }

    static func note(_ id: UUID, in context: ModelContext) throws -> Note {
        guard let found = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No note with id \(id.uuidString).")
        }
        return found
    }

    static func thread(_ id: UUID, in context: ModelContext) throws -> ProjectThread {
        guard let found = try context.fetch(FetchDescriptor<ProjectThread>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No thread with id \(id.uuidString).")
        }
        return found
    }

    static func task(_ id: UUID, in context: ModelContext) throws -> AgendaItem {
        guard let found = try context.fetch(FetchDescriptor<AgendaItem>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No task with id \(id.uuidString).")
        }
        guard found.kind == .task else { throw ToolError("That id is not a Slate task.") }
        return found
    }

    static func completion(_ id: UUID, in context: ModelContext) throws -> TaskCompletion {
        guard let found = try context.fetch(FetchDescriptor<TaskCompletion>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No completion with id \(id.uuidString).")
        }
        return found
    }

    static func run(_ id: UUID, in context: ModelContext) throws -> AgentRun {
        guard let found = RunStore.run(id, in: context) else {
            throw ToolError("No run with id \(id.uuidString).")
        }
        return found
    }

    static func attachment(_ id: UUID, in context: ModelContext) throws -> CodeAttachment {
        guard let found = CodeReferenceStore.attachment(id, in: context) else {
            throw ToolError("No code attachment with id \(id.uuidString).")
        }
        return found
    }

    static func conversation(_ id: UUID, in context: ModelContext) throws -> Conversation {
        guard let found = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No chat with id \(id.uuidString).")
        }
        return found
    }

    static func markedRecord(_ kind: DeletionTargetKind, _ id: UUID, in context: ModelContext) throws -> (project: Project, title: String) {
        switch kind {
        case .note:
            let note = try Self.note(id, in: context)
            guard let project = note.project else { throw ToolError("That note has no project.") }
            return (project, note.displayTitle)
        case .thread:
            let thread = try Self.thread(id, in: context)
            guard let project = thread.project else { throw ToolError("That track has no project.") }
            return (project, thread.title.isEmpty ? "Untitled" : thread.title)
        case .decision:
            let decision = try Self.decision(id, in: context)
            guard let project = decision.project else { throw ToolError("That decision has no project.") }
            return (project, decision.title.isEmpty ? "Untitled" : decision.title)
        case .conversation:
            let conversation = try Self.conversation(id, in: context)
            guard let project = conversation.project else { throw ToolError("That chat has no project.") }
            return (project, conversation.title.isEmpty ? "Chat" : conversation.title)
        }
    }

    /// nil/nil means leave an existing replacement, or none on a new mark. Empty id clears it.
    static func replacement(
        type: DeletionTargetKind?,
        id: UUID??,
        targetID: UUID,
        project: Project,
        existing: DeletionMark?,
        in context: ModelContext
    ) throws -> (kind: DeletionTargetKind?, id: UUID?) {
        if id == nil, type == nil {
            return (existing?.replacementKind, existing?.replacementID)
        }
        if let wrapped = id, wrapped == nil {
            return (nil, nil)
        }
        guard let type, let wrapped = id, let replacementID = wrapped else {
            throw ToolError("replacement_type and replacement_id must be passed together.")
        }
        if replacementID == targetID {
            throw ToolError("A record can't replace itself.")
        }
        let resolved = try markedRecord(type, replacementID, in: context)
        if resolved.project.id != project.id {
            throw ToolError("The replacement must be in the same project.")
        }
        return (type, replacementID)
    }

    /// Resolves an optional thread link within a project. nil means "not given" or "cleared".
    static func thread(_ link: UUID??, in project: Project) throws -> ProjectThread? {
        guard let link, let id = link else { return nil }
        guard let thread = project.threads.first(where: { $0.id == id }) else {
            throw ToolError("No thread with id \(id.uuidString) in \(project.name).")
        }
        return thread
    }
}

enum JSONShape {
    private static let iso = ISO8601DateFormatter()

    static func project(_ project: Project) -> [String: Any] {
        var shape: [String: Any] = [
            "id": project.id.uuidString,
            "name": project.name,
            "symbol": project.symbol,
            "status": project.status.rawValue,
            "summary": project.summary,
            "current_direction": project.currentDirection,
            "is_pinned": project.isPinned,
            "last_activity": iso.string(from: project.lastActivity),
            "counts": [
                "decisions": project.decisions.count,
                "threads": project.threads.count,
                "notes": project.notes.count,
                "tasks": project.agendaItems.filter { $0.kind == .task }.count
            ]
        ]
        if let next = TaskStore.nextTask(in: project) {
            shape["next_task"] = ["id": next.id.uuidString, "title": next.displayTitle]
        }
        return shape
    }

    static func attachments(on project: Project, in context: ModelContext) -> [[String: Any]] {
        CodeReferenceStore.attachmentsOn(project, in: context)
            .sorted { $0.createdAt < $1.createdAt }
            .map { attachment in
                let shown = CodeReferenceStore.inspectable(on: attachment, in: context)
                let published = shown?.publication == .published ? shown : CodeReferenceStore.published(on: attachment, in: context)
                return [
                    "id": attachment.id.uuidString,
                    "title": attachment.title.isEmpty ? attachment.locator : attachment.title,
                    "kind": attachment.kind.rawValue,
                    "locator": attachment.locator,
                    "has_published_reference": published != nil,
                    "publication": shown?.publication.rawValue ?? "",
                    "coverage": shown?.coverage.rawValue ?? "",
                    "entry_count": shown.map { CodeReferenceStore.entries(on: $0, in: context).count } ?? 0
                ] as [String: Any]
            }
    }

    static func task(_ item: AgendaItem, full: Bool) -> [String: Any] {
        var shape: [String: Any] = [
            "id": item.id.uuidString,
            "title": item.displayTitle,
            "notes": item.notes,
            "due": item.due.map { iso.string(from: $0) } ?? "",
            "status": item.workflowStatus.rawValue,
            "is_next": item.isNext,
            "project_id": item.project?.id.uuidString ?? "",
            "project_name": item.project?.name ?? "",
            "repeat": item.repeatRule.rawValue,
            "blocked_reason": item.blockedReason,
            "tracks": item.liveTracks.map { ["id": $0.id.uuidString, "title": $0.title] },
            "linked_notes": item.liveNotes.map { ["id": $0.id.uuidString, "title": $0.displayTitle] },
            "blockers": item.unresolvedBlockers.map {
                [
                    "id": $0.id.uuidString,
                    "title": $0.displayTitle,
                    "project_name": $0.project?.name ?? ""
                ]
            }
        ]
        if full {
            shape["blocked_by_ids"] = item.blockerLinks.compactMap { $0.blockingTask?.id.uuidString }
            shape["blocks"] = item.blockingLinks.compactMap { $0.blockedTask?.id.uuidString }
            shape["completion_ids"] = item.completions.map(\.id.uuidString)
        }
        return shape
    }

    static func completion(_ completion: TaskCompletion) -> [String: Any] {
        [
            "id": completion.id.uuidString,
            "title": completion.titleSnapshot,
            "completed_at": iso.string(from: completion.completedAt),
            "occurred_due": completion.occurredDue.map { iso.string(from: $0) } ?? "",
            "project_id": completion.project?.id.uuidString ?? "",
            "task_id": completion.parentTask?.id.uuidString ?? ""
        ]
    }

    static func decision(_ decision: Decision) -> [String: Any] {
        var shape: [String: Any] = [
            "id": decision.id.uuidString,
            "project_id": decision.project?.id.uuidString ?? "",
            "title": decision.title,
            "decision": decision.decision,
            "rationale": decision.rationale,
            "status": decision.status.rawValue,
            "superseded_by_id": decision.supersededByID?.uuidString ?? "",
            "thread_id": decision.thread?.id.uuidString ?? "",
            "created_at": iso.string(from: decision.createdAt)
        ]
        attachMark(&shape, id: decision.id, project: decision.project)
        return shape
    }

    static func thread(_ thread: ProjectThread, full: Bool) -> [String: Any] {
        var shape: [String: Any] = [
            "id": thread.id.uuidString,
            "project_id": thread.project?.id.uuidString ?? "",
            "title": thread.title,
            "kind": thread.kind.rawValue,
            "status": thread.status.rawValue,
            "summary": thread.summary,
            "parent_id": thread.parent?.id.uuidString ?? "",
            "updated_at": iso.string(from: thread.updatedAt)
        ]
        if full {
            shape["body"] = thread.body
            shape["children"] = thread.orderedChildren.map { child in
                [
                    "id": child.id.uuidString,
                    "title": child.title,
                    "kind": child.kind.rawValue,
                    "status": child.status.rawValue,
                    "summary": child.summary
                ]
            }
        }
        attachMark(&shape, id: thread.id, project: thread.project)
        return shape
    }

    static func note(_ note: Note, full: Bool) -> [String: Any] {
        var shape: [String: Any] = [
            "id": note.id.uuidString,
            "project_id": note.project?.id.uuidString ?? "",
            "title": note.displayTitle,
            "source": note.source,
            "thread_id": note.thread?.id.uuidString ?? "",
            "updated_at": iso.string(from: note.updatedAt)
        ]
        if full {
            shape["content"] = note.content
        } else {
            shape["preview"] = clip(note.content, 240)
        }
        attachMark(&shape, id: note.id, project: note.project)
        return shape
    }

    static func run(_ run: AgentRun, full: Bool) -> [String: Any] {
        var shape: [String: Any] = [
            "id": run.id.uuidString,
            "title": run.displayTitle,
            "status": run.status.rawValue,
            "origin": run.origin.rawValue,
            "project_id": run.project?.id.uuidString ?? "",
            "task_id": run.task?.id.uuidString ?? "",
            "origin_chat_id": run.originChat?.id.uuidString ?? "",
            "provider": run.providerID,
            "model": run.modelID,
            "created_at": iso.string(from: run.createdAt),
            "updated_at": iso.string(from: run.updatedAt),
            "purpose": run.purpose.rawValue,
            "status_detail": run.statusDetail,
            "indexed_attachment_id": run.indexedAttachmentID?.uuidString ?? ""
        ]
        if full {
            shape["brief"] = run.brief
            shape["title_snapshot"] = run.titleSnapshot
            shape["status_detail"] = run.statusDetail
            shape["result_summary"] = run.resultSummary
            shape["result_links"] = run.resultLinks.map {
                ["id": $0.id.uuidString, "label": $0.label, "url": $0.url, "kind": $0.kindRaw]
            }
            shape["history"] = run.history.map {
                [
                    "id": $0.id.uuidString,
                    "at": iso.string(from: $0.at),
                    "kind": $0.kind.rawValue,
                    "detail": $0.detail
                ]
            }
            shape["repository_locators"] = run.repositoryLocators
            shape["purpose"] = run.purpose.rawValue
            shape["indexed_attachment_id"] = run.indexedAttachmentID?.uuidString ?? ""
            shape["retry_of"] = run.retryOf?.id.uuidString ?? ""
        } else {
            shape["preview"] = clip(run.brief, 240)
        }
        return shape
    }

    static func deletionMark(_ mark: DeletionMark) -> [String: Any] {
        var shape: [String: Any] = [
            "id": mark.id.uuidString,
            "target_type": mark.targetKind.rawValue,
            "target_id": mark.targetID.uuidString,
            "reason": mark.reason,
            "created_at": iso.string(from: mark.createdAt)
        ]
        if let kind = mark.replacementKind, let id = mark.replacementID {
            shape["replacement_type"] = kind.rawValue
            shape["replacement_id"] = id.uuidString
        }
        return shape
    }

    static func codeReference(_ reference: CodeReference, full: Bool, in context: ModelContext) -> [String: Any] {
        let entries = CodeReferenceStore.sortedEntries(on: reference, in: context)
        var shape: [String: Any] = [
            "id": reference.id.uuidString,
            "attachment_id": reference.attachmentID?.uuidString ?? "",
            "revision": reference.revision,
            "publication": reference.publication.rawValue,
            "coverage": reference.coverage.rawValue,
            "coverage_label": CodeReferenceStore.coverageLabel(reference),
            "source_revision": reference.sourceRevision,
            "local_changes_examined": reference.localChangesExamined,
            "source_changed_during_index": reference.sourceChangedDuringIndex,
            "originating_run_id": reference.originatingRunID.uuidString,
            "last_updated_at": iso.string(from: reference.lastUpdatedAt),
            "entry_count": entries.count
        ]
        if full {
            shape["coverage_notes"] = reference.coverageNotes
            shape["entries"] = entries.map { codeReferenceEntry($0) }
        }
        return shape
    }

    static func codeReferenceEntry(_ entry: CodeReferenceEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "key": entry.key,
            "title": entry.title,
            "body": entry.body,
            "source_locations": entry.sourceLocations.map { location in
                var shape: [String: Any] = ["path": location.path]
                if let declaration = location.declaration, !declaration.isEmpty {
                    shape["declaration"] = declaration
                }
                if let hash = location.contentHash, !hash.isEmpty {
                    shape["content_hash"] = hash
                }
                return shape
            },
            "related_keys": entry.relatedKeys,
            "source_revision": entry.sourceRevision
        ]
    }

    private static func attachMark(_ shape: inout [String: Any], id: UUID, project: Project?) {
        if let mark = project?.deletionMarks.first(where: { $0.targetID == id }) {
            shape["deletion_mark"] = deletionMark(mark)
        }
    }
}
