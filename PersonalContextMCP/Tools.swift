import Foundation
import SwiftData
#if MEMBRAE_TESTS
@testable import Membrae
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
    case tracks
    case notes
    case tasks
    case deletionMarks = "deletion_marks"

    static func parse(_ values: [String]?) throws -> Set<ProjectExpand> {
        guard let values else { return [] }
        return Set(try values.map { value in
            let normalized = value == "threads" ? "tracks" : value
            guard let parsed = ProjectExpand(rawValue: normalized) else {
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
        var destructive = false
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
                "annotations": ["readOnlyHint": tool.readOnly, "destructiveHint": tool.destructive]
            ]
        }
    }

    static func call(
        _ name: String,
        arguments: [String: Any],
        container: ModelContainer,
        announce: Bool = true,
        origin: ActionOrigin = ActionOrigin(),
        logs: Bool = true
    ) -> [String: Any] {
        guard let tool = tools.first(where: { $0.name == canonical(name) }) else {
            return failure("Unknown tool: \(name)")
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let args = Args(raw: migrate(arguments))
            if tool.name == "delete_record", !origin.conversationID.isEmpty,
               args.string("target_id")?.lowercased() == origin.conversationID.lowercased() {
                throw ToolError("You cannot delete the chat you are in.")
            }
            let before = logs && !tool.readOnly ? snapshot(tool.name, args: args, in: context) : [:]
            let value = try tool.handler(args, context)
            if !tool.readOnly {
                if logs {
                    record(tool.name, args: args, result: value, before: before, origin: origin, in: context)
                }
                try context.persist()
                if announce {
                    Store.announceChange()
                }
            }
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
        } catch let error as ToolError {
            return failure(error.message)
        } catch {
            return failure(error.localizedDescription)
        }
    }

    // MARK: - Action log

    private static let logged: [String: (verb: AgentActionVerb, kind: String)] = [
        "create_project": (.added, "project"), "update_project": (.changed, "project"),
        "create_task": (.added, "task"), "update_task": (.changed, "task"), "complete_task": (.completed, "task"),
        "delete_completion": (.removed, "completion"),
        "create_decision": (.added, "decision"), "update_decision": (.changed, "decision"),
        "create_track": (.added, "track"), "update_track": (.changed, "track"),
        "create_note": (.added, "note"), "update_note": (.changed, "note"),
        "create_source": (.added, "source"), "update_source": (.changed, "source"),
        "create_tag": (.added, "tag"), "update_tag": (.changed, "tag"),
        "assign_tag": (.tagged, ""), "remove_tag": (.untagged, ""),
        "mark_for_deletion": (.flagged, ""), "delete_record": (.removed, ""),
        "create_space": (.added, "space"), "update_space": (.changed, "space"),
        "set_space_type": (.changed, "space"), "set_space_screen": (.changed, "space"),
        "create_space_record": (.added, "record"), "update_space_record": (.changed, "record"),
        "update_space_event": (.changed, "record"), "log_space_event": (.logged, "record")
    ]

    /// Writes one line to the action log for a write that just succeeded.
    private static func record(
        _ tool: String,
        args: Args,
        result: Any,
        before: [String: Any],
        origin: ActionOrigin,
        in context: ModelContext
    ) {
        guard let entry = logged[tool] else { return }
        let shape = result as? [String: Any] ?? [:]
        var kind = entry.kind
        var target = shape["id"] as? String ?? ""
        var title = (shape["title"] as? String) ?? (shape["name"] as? String) ?? ""
        var detail = ""
        var project = (shape["project_id"] as? String) ?? args.string("project_id") ?? ""
        var space = args.string("space_id") ?? ""
        var before = before

        func index(_ id: String) -> TitleIndex? {
            guard let uuid = UUID(uuidString: id) else { return nil }
            var descriptor = FetchDescriptor<TitleIndex>(predicate: #Predicate { $0.id == uuid })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }
        func pointAtRecord(_ id: String) {
            target = id
            guard let record = UUID(uuidString: id).flatMap({ SpaceStore.record($0, in: context) }) else { return }
            title = record.displayTitle
            space = record.spaceIDString
        }
        func pointAtIndexed(_ id: String, kind raw: String) {
            target = id
            kind = raw == "conversation" ? "chat" : raw
            title = index(id)?.displayTitle ?? ""
            project = index(id)?.projectIDString ?? project
        }

        switch tool {
        case "create_project", "update_project":
            project = target
        case "assign_tag", "remove_tag":
            detail = title
            pointAtIndexed(args.string("record_id") ?? "", kind: args.string("record_type") ?? "")
        case "mark_for_deletion":
            detail = args.string("reason") ?? ""
            pointAtIndexed(args.string("target_id") ?? "", kind: args.string("target_type") ?? "")
        case "delete_record":
            kind = args.string("target_type") ?? ""
        case "delete_completion":
            target = ""
        case "create_space", "update_space":
            space = target
        case "set_space_type", "set_space_screen":
            detail = (shape["name"] as? String) ?? args.string("type_key") ?? ""
            target = space
            title = UUID(uuidString: space).flatMap { SpaceStore.space($0, in: context) }?.displayName ?? ""
        case "create_space_record", "update_space_record":
            pointAtRecord(target)
        case "log_space_event", "update_space_event":
            detail = (try? SpaceTools.type(args, in: context))?.name ?? ""
            if tool == "log_space_event" { before = ["event_id": target] }
            pointAtRecord((shape["record_ids"] as? [String])?.first ?? "")
        default:
            break
        }

        context.insert(AgentAction(
            tool: tool,
            verb: entry.verb,
            kind: kind,
            targetID: target,
            title: title,
            detail: detail,
            projectID: project,
            spaceID: space,
            origin: origin,
            beforeJSON: before.isEmpty ? "" : (try? JSONSerialization.data(withJSONObject: before)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        ))
        AgentActionStore.trim(in: context)
    }

    // MARK: - Taking a write back

    /// For each tool that edits a record: the tool that reads it, and the argument that names it.
    private static let readers: [String: (tool: String, id: String)] = [
        "update_project": ("get_project", "project_id"),
        "update_task": ("get_task", "task_id"),
        "complete_task": ("get_task", "task_id"),
        "update_decision": ("get_decision", "decision_id"),
        "update_track": ("get_track", "track_id"),
        "update_note": ("get_note", "note_id"),
        "update_source": ("get_source", "source_id")
    ]

    /// The fields a write is about to change, as they are now, in the shape the same tool takes back.
    private static func snapshot(_ tool: String, args: Args, in context: ModelContext) -> [String: Any] {
        if tool == "delete_record" {
            guard let kind = try? args.choice("target_type", as: DeletableKind.self),
                  let id = try? args.uuid("target_id") else { return [:] }
            return (try? DeletedRecord.snapshot(kind, id, in: context)) ?? [:]
        }
        if tool == "update_space_record" {
            guard let id = args.string("record_id"),
                  let record = UUID(uuidString: id).flatMap({ SpaceStore.record($0, in: context) }),
                  let type = record.typeID.flatMap({ SpaceStore.type($0, in: context) }) else { return [:] }
            let shape = SpaceTools.record(record, schema: type.schema, in: context)
            var before: [String: Any] = ["record_id": id]
            if args.raw["title"] != nil { before["title"] = shape["title"] }
            if args.raw["archived"] != nil { before["archived"] = shape["archived"] }
            if let changed = args.raw["values"] as? [String: Any], let values = shape["values"] as? [String: Any] {
                before["values"] = values.filter { changed[$0.key] != nil }
            }
            return before
        }
        guard let reader = readers[tool],
              let id = args.string(reader.id),
              let read = tools.first(where: { $0.name == reader.tool }),
              let shape = (try? read.handler(Args(raw: [reader.id: id]), context)) as? [String: Any] else { return [:] }
        if tool == "complete_task" {
            // A repeating task writes a completion and moves its due date; that is not one field to put back.
            let repeats = (shape["repeat"] as? String ?? "none") != "none" && !(shape["due"] as? String ?? "").isEmpty
            return repeats ? [:] : [reader.id: id, "status": shape["status"] ?? "ready"]
        }
        func ids(_ key: String) -> [String] {
            (shape[key] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        var before: [String: Any] = [reader.id: id]
        for key in args.raw.keys where key != reader.id {
            switch key {
            case "track_ids": before[key] = ids("tracks")
            case "note_ids": before[key] = ids("linked_notes")
            case "blocker_ids": before[key] = ids("blockers")
            case "append_to_body": before["body"] = shape["body"]
            default: before[key] = shape[key]
            }
        }
        return before
    }

    /// Takes back one logged write: what an agent added is deleted, what it edited gets its old values,
    /// and what it deleted comes back. Only the app calls this.
    static func undo(_ actionID: UUID, container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<AgentAction>(predicate: #Predicate { $0.id == actionID })
        descriptor.fetchLimit = 1
        guard let action = try context.fetch(descriptor).first, action.canUndo else {
            throw ToolError("This cannot be taken back.")
        }
        let before = (try? JSONSerialization.jsonObject(with: Data(action.beforeJSON.utf8))) as? [String: Any] ?? [:]

        switch action.verb {
        case .added:
            guard let id = action.targetID else { throw ToolError("This cannot be taken back.") }
            switch action.kindRaw {
            case "task":
                TaskStore.delete(try Lookup.task(id, in: context), in: context)
            case "note":
                let note = try Lookup.note(id, in: context)
                DeletionMarks.remove(targetingIDs: [id], in: context)
                note.project?.touch()
                context.delete(note)
            case "decision":
                let decision = try Lookup.decision(id, in: context)
                DeletionMarks.remove(targetingIDs: [id], in: context)
                decision.project?.touch()
                context.delete(decision)
            case "track":
                let track = try Lookup.thread(id, in: context)
                guard track.children.isEmpty else {
                    throw ToolError("This track has tracks under it now. Move or delete those first.")
                }
                DeletionMarks.remove(targetingIDs: track.deletionTargetIDs, in: context)
                track.project?.touch()
                context.delete(track)
            case "source":
                context.delete(try Lookup.source(id, in: context))
                try? FileStore.default(context: context).release(ownerKind: .source, ownerID: id)
            case "record":
                guard let record = SpaceStore.record(id, in: context) else { throw ToolError("That record is already gone.") }
                try SpaceStore.delete(record, in: context)
            default:
                throw ToolError("This cannot be taken back.")
            }
        case .logged:
            guard let event = (before["event_id"] as? String).flatMap(UUID.init(uuidString:)).flatMap({ SpaceStore.event($0, in: context) }) else {
                throw ToolError("That entry is already gone.")
            }
            try SpaceStore.delete(event, in: context)
        case .removed:
            try DeletedRecord.restore(before, in: context)
        default:
            let target = action.targetIDString
            let made = action.createdAt
            let later = try context.fetchCount(FetchDescriptor<AgentAction>(
                predicate: #Predicate { $0.targetIDString == target && $0.createdAt > made && $0.undoneAt == nil }
            ))
            guard later == 0 else {
                throw ToolError("This was changed again after that. Take back the later change first.")
            }
            let tool = action.tool == "complete_task" ? "update_task" : action.tool
            let result = call(tool, arguments: before, container: container, announce: false, logs: false)
            if result["isError"] as? Bool == true {
                throw ToolError((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "This could not be taken back.")
            }
        }
        action.undoneAt = .now
        try context.persist()
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private static let aliases = [
        "list_threads": "list_tracks",
        "get_thread": "get_track",
        "create_thread": "create_track",
        "update_thread": "update_track"
    ]

    private static func canonical(_ name: String) -> String {
        aliases[name] ?? name
    }

    /// Accepts the old thread_* keys so cached clients keep working.
    private static func migrate(_ arguments: [String: Any]) -> [String: Any] {
        var next = arguments
        if next["track_id"] == nil, let old = next["thread_id"] {
            next["track_id"] = old
        }
        return next
    }

    // MARK: - Schema helpers

    private static func text(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func flag(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func objectList(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "object", "additionalProperties": true], "description": description]
    }

    private static func object(_ description: String) -> [String: Any] {
        ["type": "object", "additionalProperties": true, "description": description]
    }

    private static let spaceID = text("Space id from list_spaces or create_space.")
    private static let typeKey = text("The type's key, as given to set_space_type.")

    private static func options<T: RawRepresentable & CaseIterable>(_ type: T.Type, _ description: String) -> [String: Any] where T.RawValue == String {
        ["type": "string", "enum": T.allCases.map(\.rawValue), "description": description]
    }

    private static let projectID = text("Project id from list_projects.")
    private static let trackLink = text("Track id to file this under. Empty string removes the link.")

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
            description: "Get one project: fields, identity context, and counts. Pass include for bounded lists. Use get_track for a track body and get_note for reference material.",
            properties: [
                "project_id": projectID,
                "include": [
                    "type": "array",
                    "items": ["type": "string", "enum": ["decisions", "tracks", "notes", "tasks", "deletion_marks"]],
                    "description": "Record lists to add. Omit for a lean project record. Lists are bounded; use list_* and get_track for the rest."
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
            if include.contains(.tracks) {
                shape["tracks"] = project.threads
                    .sorted { $0.createdAt < $1.createdAt }
                    .prefix(24)
                    .map { JSONShape.track($0, full: false) }
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
            description: "List Membrae tasks. Completions are not included. Use list_completions for repeat history. Pass track_id to list work on a track.",
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
            description: "Get one Membrae task, including linked notes, blockers, dependents, and completion ids.",
            properties: ["task_id": text("Task id.")],
            required: ["task_id"], readOnly: true
        ) { args, context in
            JSONShape.task(try Lookup.task(try args.uuid("task_id"), in: context), full: true)
        },
        Tool(
            name: "create_task",
            description: "Create a Membrae task. project_id is optional. is_next requires an active project. Link governing tracks with track_ids. Reference notes are supplementary via note_ids. Do not put built/not-built in notes.",
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
            description: "Change a Membrae task. Only the fields you pass are changed. track_ids, note_ids, and blocker_ids replace the whole set.",
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
            description: "Complete a Membrae task. Repeating tasks write a completion and advance the due date. Non-repeating tasks move to Done. Already-done tasks are returned unchanged.",
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
                "track_id": trackLink,
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
                thread: try Lookup.thread(args.optionalUUID("track_id"), in: project)
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
                "track_id": trackLink
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
            if let link = try args.optionalUUID("track_id"), let project = decision.project {
                decision.thread = try Lookup.thread(link, in: project)
            }
            decision.project?.touch()
            return JSONShape.decision(decision)
        },

        Tool(
            name: "list_tracks",
            description: "List a project's tracks with ids, kinds, statuses, summaries, and parent ids.",
            properties: ["project_id": projectID], required: ["project_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            return project.threads.sorted { $0.createdAt < $1.createdAt }.map { JSONShape.track($0, full: false) }
        },
        Tool(
            name: "get_track",
            description: "Get one track with its full body, linked decisions, note previews, tasks including child-track tasks, and child-track summaries.",
            properties: ["track_id": text("Track id.")], required: ["track_id"], readOnly: true
        ) { args, context in
            let thread = try Lookup.thread(try args.uuid("track_id"), in: context)
            var shape = JSONShape.track(thread, full: true)
            shape["decisions"] = thread.decisions.map(JSONShape.decision)
            shape["notes"] = thread.notes.map { JSONShape.note($0, full: false) }
            shape["tasks"] = TaskStore.tasks(on: thread, includingDescendants: true)
                .map { JSONShape.task($0, full: false) }
            return shape
        },
        Tool(
            name: "create_track",
            description: "Start a track: a line of work such as a direction, feature, problem, experiment, or topic. Put the spec in the body. Work to do is a task, not a body edit.",
            properties: [
                "project_id": projectID,
                "title": text("Track title."),
                "kind": options(ThreadKind.self, "Kind of track. Defaults to topic."),
                "status": options(ThreadStatus.self, "Defaults to exploring."),
                "summary": text("One or two sentences."),
                "body": text("Markdown spec."),
                "parent_id": text("Parent track id, to nest this track.")
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
            return JSONShape.track(thread, full: true)
        },
        Tool(
            name: "update_track",
            description: "Change a track. Only the fields you pass are changed. Use append_to_body to add to the body without rewriting it.",
            properties: [
                "track_id": text("Track id."),
                "title": text("New title."),
                "kind": options(ThreadKind.self, "Kind of track."),
                "status": options(ThreadStatus.self, "Track status."),
                "summary": text("New summary."),
                "body": text("Replaces the whole markdown spec. Omit or leave empty to keep the current body."),
                "append_to_body": text("Markdown appended to the end of the spec."),
                "parent_id": text("New parent track id. Empty string makes it a top-level track.")
            ],
            required: ["track_id"], readOnly: false
        ) { args, context in
            let thread = try Lookup.thread(try args.uuid("track_id"), in: context)
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
                if let parent, thread.contains(parent) { throw ToolError("A track can't be nested under itself or its own children.") }
                thread.parent = parent
            }
            thread.updatedAt = .now
            thread.project?.touch()
            return JSONShape.track(thread, full: true)
        },

        Tool(
            name: "list_chats",
            description: "List a project's chats, most recently updated first, with a preview of the last message. Hidden (archived) chats are omitted.",
            properties: ["project_id": projectID, "track_id": text("Only chats filed under this track.")],
            required: ["project_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            let trackID = try args.optionalUUID("track_id") ?? nil
            return project.conversations
                .filter { !$0.isArchived }
                .filter { trackID == nil || $0.thread?.id == trackID }
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { JSONShape.conversation($0, full: false) }
        },
        Tool(
            name: "get_chat",
            description: "Get one chat and its message transcript.",
            properties: ["chat_id": text("Chat id.")], required: ["chat_id"], readOnly: true
        ) { args, context in
            JSONShape.conversation(try Lookup.conversation(try args.uuid("chat_id"), in: context), full: true)
        },
        Tool(
            name: "list_notes",
            description: "List a project's notes, most recently changed first, with a preview of each.",
            properties: ["project_id": projectID, "track_id": text("Only notes filed under this track.")],
            required: ["project_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            let trackID = try args.optionalUUID("track_id") ?? nil
            return project.notes
                .filter { trackID == nil || $0.thread?.id == trackID }
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
                "track_id": trackLink
            ],
            required: ["project_id", "content"], readOnly: false
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            let note = Note(
                content: try args.required("content"),
                project: project,
                title: args.string("title") ?? "",
                source: args.string("source") ?? "",
                thread: try Lookup.thread(args.optionalUUID("track_id"), in: project)
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
                "track_id": trackLink
            ],
            required: ["note_id"], readOnly: false
        ) { args, context in
            let note = try Lookup.note(try args.uuid("note_id"), in: context)
            if let title = args.string("title") { note.title = title }
            if let content = args.string("content"), !content.isEmpty { note.content = content }
            if let source = args.string("source") { note.source = source }
            if let link = try args.optionalUUID("track_id"), let project = note.project {
                note.thread = try Lookup.thread(link, in: project)
            }
            note.updatedAt = .now
            note.project?.touch()
            return JSONShape.note(note, full: true)
        },

        Tool(
            name: "list_sources",
            description: "List saved sources in the Library: links, PDFs, and articles the user kept, newest first, each with a summary. The Library is shared across projects, so search it from any project. Pass query to search titles, summaries, and the saved text.",
            properties: [
                "query": text("Words to look for in the title, summary, address, or saved text."),
                "linked_to": text("Only sources linked to this project id."),
                "unread_only": flag("Only sources not yet marked read."),
                "include_archived": flag("Also list archived sources. Defaults to false.")
            ],
            required: [], readOnly: true
        ) { args, context in
            let linked = try args.optionalUUID("linked_to") ?? nil
            let query = args.string("query") ?? ""
            let all = try context.fetch(FetchDescriptor<SavedSource>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
            return all
                .filter { args.bool("include_archived") == true || !$0.isArchived }
                .filter { args.bool("unread_only") != true || $0.readAt == nil }
                .filter { source in linked == nil || source.projects.contains { $0.id == linked } }
                .filter { $0.matches(query) }
                .prefix(100)
                .map { JSONShape.source($0, full: false) }
        },
        Tool(
            name: "get_source",
            description: "Get one saved source with its full saved text. Cite it by title and address when you answer from it.",
            properties: ["source_id": text("Source id from list_sources.")], required: ["source_id"], readOnly: true
        ) { args, context in
            JSONShape.source(try Lookup.source(try args.uuid("source_id"), in: context), full: true)
        },
        Tool(
            name: "create_source",
            description: "Save a link, article, or document to the Library. Pass the address; the app fetches the page text itself when you leave text out. Write a two-line summary when you know what the page says. Link it to every project it belongs to with project_ids, or to none. Saving an address that is already in the Library updates that source instead of adding a second one.",
            properties: [
                "url": text("The address of the page or file."),
                "title": text("Title of the page or document."),
                "summary": text("Two lines on what it says and why it was kept."),
                "text": text("The readable text, when you already have it."),
                "file_id": text("Id of a file already stored in Membrae, to keep with the source. Only the app has these ids."),
                "project_ids": ["type": "array", "items": ["type": "string"], "description": "Projects this source belongs to. May be empty."]
            ],
            required: [], readOnly: false
        ) { args, context in
            let url = args.string("url") ?? ""
            let body = args.string("text") ?? ""
            let files = FileStore.default(context: context)
            var file: StoredAsset?
            if let fileID = try args.optionalUUID("file_id") ?? nil {
                guard let found = files.asset(id: fileID) else { throw ToolError("No stored file with id \(fileID.uuidString).") }
                file = found
            }
            guard !url.isEmpty || !body.isEmpty || file != nil else { throw ToolError("Pass url, or text for something with no address.") }
            let projects = try (args.uuids("project_ids") ?? []).map { try Lookup.project($0, in: context) }
            let existing = url.isEmpty ? nil : try context.fetch(FetchDescriptor<SavedSource>(predicate: #Predicate { $0.url == url })).first
            let source = existing ?? SavedSource(url: url, kind: url.lowercased().hasSuffix(".pdf") ? .pdf : .link)
            if existing == nil { context.insert(source) }
            if let file {
                // The source keeps the file, so it outlives the input or chat it arrived through.
                source.kind = file.kind == .image ? .image : file.mediaType == "application/pdf" ? .pdf : .file
                if source.title.isEmpty { source.title = file.filename }
                try files.retain(assetIDs: [file.id], ownerKind: .source, ownerID: source.id)
            }
            if let title = args.string("title"), !title.isEmpty { source.title = title }
            if let summary = args.string("summary"), !summary.isEmpty { source.summary = summary }
            if !body.isEmpty { source.text = body }
            for project in projects where !source.projects.contains(where: { $0.id == project.id }) {
                source.projects.append(project)
                project.touch()
            }
            source.isArchived = false
            source.updatedAt = .now
            return JSONShape.source(source, full: false)
        },
        Tool(
            name: "update_source",
            description: "Change a saved source. Only the fields you pass are changed. project_ids replaces the whole set of linked projects.",
            properties: [
                "source_id": text("Source id."),
                "title": text("New title."),
                "summary": text("New summary."),
                "text": text("Replaces the saved text."),
                "project_ids": ["type": "array", "items": ["type": "string"], "description": "Replacement set of linked projects."],
                "read": flag("Mark read or unread."),
                "archived": flag("Archive or bring back.")
            ],
            required: ["source_id"], readOnly: false
        ) { args, context in
            let source = try Lookup.source(try args.uuid("source_id"), in: context)
            if let title = args.string("title") { source.title = title }
            if let summary = args.string("summary") { source.summary = summary }
            if let body = args.string("text") { source.text = body }
            if let ids = try args.uuids("project_ids") {
                source.projects = try ids.map { try Lookup.project($0, in: context) }
            }
            if let read = args.bool("read") { source.readAt = read ? (source.readAt ?? .now) : nil }
            if let archived = args.bool("archived") { source.isArchived = archived }
            source.updatedAt = .now
            return JSONShape.source(source, full: false)
        },

        Tool(
            name: "list_tags",
            description: "List the global tag vocabulary. Tags are sparse cross-cutting labels, not projects, status, or relationships. Projects do not receive tags.",
            properties: [:],
            required: [],
            readOnly: true
        ) { _, context in
            TagStore.all(in: context).map(JSONShape.tag)
        },
        Tool(
            name: "create_tag",
            description: "Create a global tag with a name and color. Names are unique case-insensitively; a colliding name returns the existing tag. Color is one of: slate, terracotta, ochre, moss, sea, indigo, plum. Creating a tag does not assign it.",
            properties: [
                "name": text("Tag name."),
                "color": text("Palette color: slate, terracotta, ochre, moss, sea, indigo, plum.")
            ],
            required: ["name"],
            readOnly: false
        ) { args, context in
            let name = try args.required("name")
            let color = try TagTools.color(args.string("color"))
            guard let tag = TagStore.create(named: name, color: color, in: context) else {
                throw ToolError("name is required.")
            }
            return JSONShape.tag(tag)
        },
        Tool(
            name: "update_tag",
            description: "Change a tag’s name or color. Renaming onto an existing name merges into that tag and keeps every assignment.",
            properties: [
                "tag_id": text("Tag id."),
                "name": text("New name."),
                "color": text("Palette color: slate, terracotta, ochre, moss, sea, indigo, plum.")
            ],
            required: ["tag_id"],
            readOnly: false
        ) { args, context in
            let tag = try Lookup.tag(try args.uuid("tag_id"), in: context)
            if let name = args.string("name") {
                if let other = TagStore.existing(named: name, in: context), other.id != tag.id {
                    TagStore.merge(tag, into: other, in: context)
                    if let colorRaw = args.string("color") {
                        other.swatch = try TagTools.requireColor(colorRaw)
                    }
                    return JSONShape.tag(other)
                }
                guard TagStore.rename(tag, to: name, in: context) else {
                    throw ToolError("name is required.")
                }
            }
            if let colorRaw = args.string("color") {
                tag.swatch = try TagTools.requireColor(colorRaw)
            }
            return JSONShape.tag(tag)
        },
        Tool(
            name: "assign_tag",
            description: "Assign a tag to a note, track, decision, conversation, or task. Does not assign a project. Projects cannot be tagged.",
            properties: [
                "tag_id": text("Tag id from list_tags."),
                "record_type": options(TaggableKind.self, "Kind of record to tag."),
                "record_id": text("Id of the record.")
            ],
            required: ["tag_id", "record_type", "record_id"],
            readOnly: false
        ) { args, context in
            let tag = try Lookup.tag(try args.uuid("tag_id"), in: context)
            guard let kind = try args.choice("record_type", as: TaggableKind.self) else {
                throw ToolError("record_type is required.")
            }
            try TagStore.assign(tag, to: kind, id: try args.uuid("record_id"), in: context)
            return JSONShape.tag(tag)
        },
        Tool(
            name: "remove_tag",
            description: "Remove a tag from a note, track, decision, conversation, or task.",
            properties: [
                "tag_id": text("Tag id."),
                "record_type": options(TaggableKind.self, "Kind of record."),
                "record_id": text("Id of the record.")
            ],
            required: ["tag_id", "record_type", "record_id"],
            readOnly: false
        ) { args, context in
            let tag = try Lookup.tag(try args.uuid("tag_id"), in: context)
            guard let kind = try args.choice("record_type", as: TaggableKind.self) else {
                throw ToolError("record_type is required.")
            }
            try TagStore.remove(tag, from: kind, id: try args.uuid("record_id"), in: context)
            return JSONShape.tag(tag)
        },

        Tool(
            name: "mark_for_deletion",
            description: "Propose deleting a note, track, decision, or chat when the user should decide. To delete outright, use delete_record. The user sees the mark and can Keep or Delete. Reason is required. Optionally link a replacement in the same project. Calling again updates the reason and replacement.",
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
            name: "delete_record",
            description: "Delete a task, note, track, decision, or chat. The delete shows in the user's Lately feed, where they can take it back. Delete what is obsolete, duplicated, or what the user asked to remove. A track with tracks under it cannot be deleted until those are moved or deleted; notes, decisions, and tasks filed under a deleted track stay in the project.",
            properties: [
                "target_type": options(DeletableKind.self, "Kind of record to delete."),
                "target_id": text("Id of the record to delete.")
            ],
            required: ["target_type", "target_id"],
            readOnly: false,
            destructive: true
        ) { args, context in
            guard let kind = try args.choice("target_type", as: DeletableKind.self) else {
                throw ToolError("target_type is required.")
            }
            return try DeletedRecord.delete(kind, try args.uuid("target_id"), in: context)
        },
        Tool(
            name: "list_runs",
            description: "List Membrae agent Runs. Newest first. Filter by project, task, status, or origin.",
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
            name: "list_spaces",
            description: "List every Space with its id, name, and types. A Space holds an ongoing part of the user's life, such as recipes or habits.",
            properties: [:], required: [], readOnly: true
        ) { _, context in
            SpaceStore.all(in: context).map { SpaceTools.space($0, full: false, in: context) }
        },
        Tool(
            name: "get_space",
            description: "Get one Space: each type with its fields and its collection and detail screens.",
            properties: ["space_id": spaceID], required: ["space_id"], readOnly: true
        ) { args, context in
            SpaceTools.space(try SpaceTools.space(args, in: context), full: true, in: context)
        },
        Tool(
            name: "get_space_catalog",
            description: "Read this before set_space_type or set_space_screen. Lists the field kinds, every screen component with the settings it accepts, the calculations, and a worked example.",
            properties: [:], required: [], readOnly: true
        ) { _, _ in
            SpaceTools.catalog
        },
        Tool(
            name: "create_space",
            description: "Create an empty Space. Follow with set_space_type and set_space_screen.",
            properties: [
                "name": text("Short name, such as Kitchen."),
                "summary": text("One line on what it is for."),
                "symbol": text("SF Symbol name for its icon."),
                "color": text("Card color: \(SpaceGradientName.all.joined(separator: ", ")). Leave out to take the next unused one.")
            ],
            required: ["name"], readOnly: false
        ) { args, context in
            let used = SpaceStore.all(in: context).map(\.gradientRaw)
            let color = args.string("color").flatMap { SpaceGradientName.all.contains($0) ? $0 : nil }
            let space = try SpaceStore.create(
                named: try args.required("name"),
                symbol: args.string("symbol").flatMap { $0.isEmpty ? nil : $0 } ?? "square.grid.2x2",
                summary: args.string("summary") ?? "",
                gradient: color ?? SpaceGradientName.next(after: used),
                in: context
            )
            return SpaceTools.space(space, full: true, in: context)
        },
        Tool(
            name: "update_space",
            description: "Rename a Space, or change its summary, icon, or card color. Only what you pass changes.",
            properties: [
                "space_id": spaceID,
                "name": text("New name."),
                "summary": text("One line on what it is for."),
                "symbol": text("SF Symbol name for its icon."),
                "color": text("Card color: \(SpaceGradientName.all.joined(separator: ", ")).")
            ],
            required: ["space_id"], readOnly: false
        ) { args, context in
            let space = try SpaceTools.space(args, in: context)
            if let color = args.string("color"), !color.isEmpty, !SpaceGradientName.all.contains(color) {
                throw ToolError("color must be one of: \(SpaceGradientName.all.joined(separator: ", ")).")
            }
            try SpaceStore.update(
                space,
                name: args.string("name"),
                symbol: args.string("symbol"),
                summary: args.string("summary"),
                gradient: args.string("color"),
                in: context
            )
            return SpaceTools.space(space, full: false, in: context)
        },
        Tool(
            name: "set_space_type",
            description: "Create a type in a Space, or change the fields of the type with this key. role object is a lasting thing (a recipe, a habit); role event is something logged about objects (cooked, check-in); role settings holds one record for the whole Space (daily targets). A field cannot change kind; a field you leave out is hidden and its values are kept.",
            properties: [
                "space_id": spaceID,
                "key": text("Stable lowercase key, such as recipe or check-in."),
                "name": text("Name shown to the user, such as Recipes."),
                "role": options(SpaceTypeRole.self, "object, event, or settings. Defaults to object."),
                "fields": objectList("Fields: {id, name, kind, options?, fields?, ordered?, target?, formula?, currency?, default?}. See get_space_catalog for kinds."),
                "collection": objectList("Optional. Components for this object type's collection screen, set in the same call."),
                "detail": objectList("Optional. Components for this object type's detail screen, set in the same call.")
            ],
            required: ["space_id", "key", "name", "fields"], readOnly: false
        ) { args, context in
            let space = try SpaceTools.space(args, in: context)
            let key = try args.required("key")
            let schema = SpaceSchema(fields: try SpaceTools.fields(try SpaceTools.objects(args, "fields")))
            let type: SpaceType
            if let existing = SpaceStore.types(in: space, context: context).first(where: { $0.key == key }) {
                try SpaceStore.reviseSchema(of: existing, to: schema, in: context)
                existing.name = try args.required("name")
                type = existing
            } else {
                type = try SpaceStore.defineType(
                    in: space,
                    key: key,
                    name: try args.required("name"),
                    role: try args.choice("role", as: SpaceTypeRole.self) ?? .object,
                    schema: schema,
                    origin: .agent,
                    context: context
                )
            }
            // The type is saved by now. A screen that does not fit reports its problems without undoing it,
            // so the same call can be sent again with the screens fixed.
            for kind in SpaceScreenKind.allCases where args.raw[kind.rawValue] != nil {
                let components = try SpaceTools.components(try SpaceTools.objects(args, kind.rawValue))
                do {
                    try SpaceStore.setScreen(SpaceScreenDefinition(components), for: type, kind: kind, byAgent: true, in: context)
                } catch SpaceStoreError.invalidScreen(let problems) {
                    throw ToolError("The type \(key) was saved, but its \(kind.rawValue) screen was not: " + problems.joined(separator: " "))
                }
            }
            return SpaceTools.type(type, in: context)
        },
        Tool(
            name: "set_space_screen",
            description: "Set the collection screen (browsing all records) or the detail screen (one record) of an object type. Built only from catalog components. If anything does not fit the type, nothing is saved and every problem is returned; fix them and call again.",
            properties: [
                "space_id": spaceID,
                "type_key": typeKey,
                "kind": options(SpaceScreenKind.self, "collection or detail."),
                "components": objectList("Components in order: {component, ...settings, children?}.")
            ],
            required: ["space_id", "type_key", "kind", "components"], readOnly: false
        ) { args, context in
            let type = try SpaceTools.type(args, in: context)
            guard let kind = try args.choice("kind", as: SpaceScreenKind.self) else { throw ToolError("kind is required.") }
            let components = try SpaceTools.components(try SpaceTools.objects(args, "components"))
            let screen = try SpaceStore.setScreen(SpaceScreenDefinition(components), for: type, kind: kind, byAgent: true, in: context)
            return ["type_key": type.key, "kind": kind.rawValue, "components": SpaceTools.json(screen.definition.components)]
        },
        Tool(
            name: "list_space_records",
            description: "List the records of one type in a Space, with their values. Archived records are left out unless asked for.",
            properties: [
                "space_id": spaceID,
                "type_key": typeKey,
                "include_archived": flag("true also lists archived records.")
            ],
            required: ["space_id", "type_key"], readOnly: true
        ) { args, context in
            let type = try SpaceTools.type(args, in: context)
            let schema = type.schema
            if type.role == .settings { _ = try? SpaceStore.settingsRecord(of: type, in: context) }
            let all = args.bool("include_archived") == true
            return SpaceStore.records(of: type, in: context)
                .filter { all || !$0.isArchived }
                .map { SpaceTools.record($0, schema: schema, in: context) }
        },
        Tool(
            name: "create_space_record",
            description: "Add a record to a Space, such as one recipe. values is keyed by field id.",
            properties: [
                "space_id": spaceID,
                "type_key": typeKey,
                "title": text("The record's name."),
                "values": object("Field id to value. See get_space_catalog for each kind's value shape.")
            ],
            required: ["space_id", "type_key", "title"], readOnly: false
        ) { args, context in
            let type = try SpaceTools.type(args, in: context)
            let schema = type.schema
            let record = try SpaceStore.createRecord(
                of: type,
                title: try args.required("title"),
                values: schema.defaults().merging(try SpaceTools.values(args.raw["values"], schema: schema)) { _, given in given },
                in: context
            )
            return SpaceTools.record(record, schema: schema, in: context)
        },
        Tool(
            name: "update_space_record",
            description: "Change a record. Only the title and the values you pass are changed.",
            properties: [
                "record_id": text("Record id from list_space_records."),
                "title": text("New name."),
                "values": object("Field id to new value."),
                "archived": flag("true puts the record away without deleting it; false brings it back.")
            ],
            required: ["record_id"], readOnly: false
        ) { args, context in
            let id = try args.uuid("record_id")
            guard let record = SpaceStore.record(id, in: context),
                  let type = record.typeID.flatMap({ SpaceStore.type($0, in: context) }) else {
                throw ToolError("No record with id \(id.uuidString).")
            }
            let schema = type.schema
            try SpaceStore.update(
                record,
                title: args.string("title").flatMap { $0.isEmpty ? nil : $0 },
                values: try SpaceTools.values(args.raw["values"], schema: schema),
                in: context
            )
            if let archived = args.bool("archived") {
                try SpaceStore.setArchived(archived, on: record, in: context)
            }
            return SpaceTools.record(record, schema: schema, in: context)
        },
        Tool(
            name: "list_space_events",
            description: "List what has been logged in a Space for one event type, newest first. Pass record_id for one record's history.",
            properties: [
                "space_id": spaceID,
                "type_key": text("Key of an event type in this Space."),
                "record_id": text("Only events about this record.")
            ],
            required: ["space_id", "type_key"], readOnly: true
        ) { args, context in
            let type = try SpaceTools.type(args, in: context)
            let space = try SpaceTools.space(args, in: context)
            let typeKey = SpaceJSON.key(type.id)
            let recordKey = try args.optionalUUID("record_id").flatMap { $0 }.map(SpaceJSON.key)
            return SpaceStore.events(in: space, context: context)
                .filter { $0.typeIDString == typeKey && (recordKey == nil || $0.recordIDsRaw.contains(recordKey!)) }
                .prefix(200)
                .map { SpaceTools.event($0, schema: type.schema) }
        },
        Tool(
            name: "update_space_event",
            description: "Change a logged event: when it happened, or its values. values replaces all of the event's values.",
            properties: [
                "event_id": text("Event id from list_space_events or log_space_event."),
                "occurred_at": text("ISO-8601 time it happened."),
                "values": object("Event field id to value.")
            ],
            required: ["event_id"], readOnly: false
        ) { args, context in
            let id = try args.uuid("event_id")
            guard let event = SpaceStore.event(id, in: context),
                  let typeID = event.typeID,
                  let type = SpaceStore.type(typeID, in: context) else {
                throw ToolError("No event with id \(id.uuidString).")
            }
            try SpaceStore.update(
                event,
                at: try args.date("occurred_at") ?? nil,
                values: args.raw["values"] == nil ? nil : try SpaceTools.values(args.raw["values"], schema: type.schema),
                in: context
            )
            return SpaceTools.event(event, schema: type.schema)
        },
        Tool(
            name: "log_space_event",
            description: "Log that something happened to one or more records, such as a recipe being cooked or a habit checked in.",
            properties: [
                "space_id": spaceID,
                "type_key": text("Key of an event type in this Space."),
                "record_ids": ["type": "array", "items": ["type": "string"], "description": "Records this is about."],
                "occurred_at": text("ISO-8601 time it happened. Defaults to now."),
                "values": object("Event field id to value.")
            ],
            required: ["space_id", "type_key", "record_ids"], readOnly: false
        ) { args, context in
            let type = try SpaceTools.type(args, in: context)
            let records = try (args.uuids("record_ids") ?? []).map { id -> SpaceRecord in
                guard let record = SpaceStore.record(id, in: context) else { throw ToolError("No record with id \(id.uuidString).") }
                return record
            }
            let event = try SpaceStore.logEvent(
                of: type,
                at: (try args.date("occurred_at") ?? nil) ?? .now,
                values: try SpaceTools.values(args.raw["values"], schema: type.schema),
                about: records,
                in: context
            )
            return SpaceTools.event(event, schema: type.schema)
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

enum TagTools {
    static func color(_ raw: String?) throws -> TagSwatch? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try requireColor(raw)
    }

    static func requireColor(_ raw: String) throws -> TagSwatch {
        guard let parsed = TagSwatch.parse(raw) else {
            let allowed = TagSwatch.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolError("color must be one of: \(allowed).")
        }
        return parsed
    }
}

/// The kinds of record delete_record removes.
enum DeletableKind: String, CaseIterable {
    case task, note, track, decision, chat
}

/// Deleting a record for an agent, and keeping enough of it in the action log to bring it back.
enum DeletedRecord {
    private static func stamp(_ date: Date?) -> Any {
        date.map { $0.timeIntervalSinceReferenceDate as Any } ?? NSNull()
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
    }

    private static func key(_ id: UUID?) -> Any {
        id.map { $0.uuidString as Any } ?? NSNull()
    }

    private static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    private static func uuids(_ value: Any?) -> [UUID] {
        (value as? [String] ?? []).compactMap(UUID.init(uuidString:))
    }

    /// Everything needed to put the record back as it was, including what it was linked to.
    static func snapshot(_ kind: DeletableKind, _ id: UUID, in context: ModelContext) throws -> [String: Any] {
        var saved: [String: Any] = ["type": kind.rawValue, "id": id.uuidString]
        switch kind {
        case .task:
            let item = try Lookup.task(id, in: context)
            saved["title"] = item.title
            saved["event_kit"] = item.eventKitID
            saved["due"] = stamp(item.due)
            saved["completed"] = item.isCompleted
            saved["notes"] = item.notes
            saved["repeat"] = item.repeatRaw
            saved["project_inherited"] = item.projectIsInherited
            saved["created"] = stamp(item.createdAt)
            saved["updated"] = stamp(item.updatedAt)
            saved["status"] = item.workflowStatusRaw
            saved["blocked_reason"] = item.blockedReason
            saved["project"] = key(item.project?.id)
            saved["space"] = item.spaceIDString
            saved["tags"] = item.tags.map(\.id.uuidString)
            saved["track_links"] = item.trackLinks.map { link in
                ["track": link.threadID.uuidString, "inherited": link.isInherited, "from_note": key(link.inheritedFromNoteID)] as [String: Any]
            }
            saved["note_links"] = item.noteLinks.map(\.noteID.uuidString)
            saved["blockers"] = item.blockerLinks.compactMap { $0.blockingTask?.id.uuidString }
            saved["blocking"] = item.blockingLinks.compactMap { $0.blockedTask?.id.uuidString }
            saved["completions"] = item.completions.map(\.id.uuidString)
        case .note:
            let note = try Lookup.note(id, in: context)
            saved["title"] = note.title
            saved["content"] = note.content
            saved["source"] = note.source
            saved["created"] = stamp(note.createdAt)
            saved["updated"] = stamp(note.updatedAt)
            saved["project"] = key(note.project?.id)
            saved["track"] = key(note.thread?.id)
            saved["space"] = note.spaceIDString
            saved["tags"] = note.tags.map(\.id.uuidString)
        case .decision:
            let decision = try Lookup.decision(id, in: context)
            saved["title"] = decision.title
            saved["decision"] = decision.decision
            saved["rationale"] = decision.rationale
            saved["status"] = decision.statusRaw
            saved["superseded_by"] = key(decision.supersededByID)
            saved["created"] = stamp(decision.createdAt)
            saved["project"] = key(decision.project?.id)
            saved["track"] = key(decision.thread?.id)
            saved["space"] = decision.spaceIDString
            saved["tags"] = decision.tags.map(\.id.uuidString)
        case .track:
            let track = try Lookup.thread(id, in: context)
            saved["title"] = track.title
            saved["kind"] = track.kindRaw
            saved["summary"] = track.summary
            saved["body"] = track.body
            saved["status"] = track.statusRaw
            saved["created"] = stamp(track.createdAt)
            saved["updated"] = stamp(track.updatedAt)
            saved["project"] = key(track.project?.id)
            saved["parent"] = key(track.parent?.id)
            saved["space"] = track.spaceIDString
            saved["tags"] = track.tags.map(\.id.uuidString)
            saved["notes"] = track.notes.map(\.id.uuidString)
            saved["decisions"] = track.decisions.map(\.id.uuidString)
            saved["chats"] = track.conversations.map(\.id.uuidString)
        case .chat:
            let chat = try Lookup.conversation(id, in: context)
            let files = FileStore.default(context: context)
            func assets(_ owner: AssetOwnerKind, _ ownerID: UUID) -> [String] {
                files.references(ownerKind: owner, ownerID: ownerID).compactMap { $0.assetID?.uuidString }
            }
            saved["title"] = chat.title
            saved["provider"] = chat.providerID
            saved["session"] = chat.externalSessionID
            saved["model"] = chat.modelID
            saved["context"] = chat.contextSnapshot
            saved["archived"] = chat.isArchived
            saved["created"] = stamp(chat.createdAt)
            saved["updated"] = stamp(chat.updatedAt)
            saved["project"] = key(chat.project?.id)
            saved["track"] = key(chat.thread?.id)
            saved["space"] = chat.spaceIDString
            saved["tags"] = chat.tags.map(\.id.uuidString)
            saved["draft_files"] = assets(.chatDraft, chat.id)
            saved["messages"] = chat.orderedMessages.map { message in
                [
                    "id": message.id.uuidString,
                    "role": message.roleRaw,
                    "content": message.content,
                    "run": message.externalRunID,
                    "created": stamp(message.createdAt),
                    "files": assets(.chatMessage, message.id)
                ] as [String: Any]
            }
        }
        return saved
    }

    /// Removes the record the way the app does, and says what was removed.
    static func delete(_ kind: DeletableKind, _ id: UUID, in context: ModelContext) throws -> [String: Any] {
        var title = ""
        var project: Project?
        switch kind {
        case .task:
            let item = try Lookup.task(id, in: context)
            guard RunStore.canDelete(item, in: context) else {
                throw ToolError("A Run is working on this task. Stop the Run first.")
            }
            title = item.displayTitle
            project = item.project
            TaskStore.delete(item, in: context)
        case .note:
            let note = try Lookup.note(id, in: context)
            title = note.displayTitle
            project = note.project
            DeletionMarks.remove(targetingIDs: [id], in: context)
            context.delete(note)
        case .decision:
            let decision = try Lookup.decision(id, in: context)
            title = decision.title
            project = decision.project
            DeletionMarks.remove(targetingIDs: [id], in: context)
            context.delete(decision)
        case .track:
            let track = try Lookup.thread(id, in: context)
            guard track.children.isEmpty else {
                throw ToolError("This track has tracks under it. Delete or move those first.")
            }
            title = track.title
            project = track.project
            DeletionMarks.remove(targetingIDs: [id], in: context)
            context.delete(track)
        case .chat:
            let chat = try Lookup.conversation(id, in: context)
            title = chat.title
            project = chat.project
            DeletionMarks.remove(targetingIDs: [id], in: context)
            try? FileStore.default(context: context).releaseConversation(chat)
            context.delete(chat)
        }
        project?.touch()
        return [
            "deleted": true,
            "type": kind.rawValue,
            "id": id.uuidString,
            "title": title,
            "project_id": project?.id.uuidString ?? ""
        ]
    }

    /// Puts a deleted record back under its old id, with the links that still have something to point at.
    static func restore(_ saved: [String: Any], in context: ModelContext) throws {
        guard let kind = (saved["type"] as? String).flatMap(DeletableKind.init(rawValue:)), let id = uuid(saved["id"]) else {
            throw ToolError("This cannot be taken back.")
        }
        func text(_ key: String) -> String { saved[key] as? String ?? "" }
        func gone() -> ToolError { ToolError("Its project is gone, so it cannot be brought back.") }
        func back() -> ToolError { ToolError("That \(kind.rawValue) is already back.") }

        var project: Project?
        if let projectID = uuid(saved["project"]) {
            guard let found = try? Lookup.project(projectID, in: context) else { throw gone() }
            project = found
        }
        let track = uuid(saved["track"]).flatMap { try? Lookup.thread($0, in: context) }
        let tags = uuids(saved["tags"]).compactMap { try? Lookup.tag($0, in: context) }

        switch kind {
        case .task:
            guard (try? Lookup.task(id, in: context)) == nil else { throw back() }
            let item = AgendaItem(kind: .task, eventKitID: text("event_kit"), title: text("title"))
            item.id = id
            item.due = date(saved["due"])
            item.isCompleted = saved["completed"] as? Bool ?? false
            item.notes = text("notes")
            item.repeatRaw = saved["repeat"] as? String ?? TaskRepeat.none.rawValue
            item.projectIsInherited = saved["project_inherited"] as? Bool ?? false
            item.createdAt = date(saved["created"]) ?? .now
            item.updatedAt = date(saved["updated"]) ?? .now
            item.workflowStatusRaw = saved["status"] as? String ?? TaskWorkflowStatus.ready.rawValue
            item.blockedReason = text("blocked_reason")
            item.spaceIDString = text("space")
            context.insert(item)
            item.project = project
            item.tags = tags
            for link in saved["track_links"] as? [[String: Any]] ?? [] {
                guard let thread = uuid(link["track"]).flatMap({ try? Lookup.thread($0, in: context) }) else { continue }
                let restored = AgendaTrackLink(thread: thread, inherited: link["inherited"] as? Bool ?? false, fromNoteID: uuid(link["from_note"]))
                context.insert(restored)
                restored.item = item
            }
            for noteID in uuids(saved["note_links"]) {
                guard let note = try? Lookup.note(noteID, in: context) else { continue }
                let restored = AgendaNoteLink(note: note)
                context.insert(restored)
                restored.item = item
            }
            for blockerID in uuids(saved["blockers"]) {
                guard let blocker = try? Lookup.task(blockerID, in: context) else { continue }
                context.insert(TaskDependency(blocked: item, blocking: blocker))
            }
            for blockedID in uuids(saved["blocking"]) {
                guard let blocked = try? Lookup.task(blockedID, in: context) else { continue }
                context.insert(TaskDependency(blocked: blocked, blocking: item))
                TaskStore.reconcileBlockers(for: blocked, in: context, save: false)
            }
            for completionID in uuids(saved["completions"]) {
                (try? Lookup.completion(completionID, in: context))?.parentTask = item
            }
        case .note:
            guard (try? Lookup.note(id, in: context)) == nil else { throw back() }
            guard let project else { throw gone() }
            let note = Note(content: text("content"), project: project, title: text("title"), source: text("source"), thread: track)
            note.id = id
            note.createdAt = date(saved["created"]) ?? .now
            note.updatedAt = date(saved["updated"]) ?? .now
            note.spaceIDString = text("space")
            context.insert(note)
            note.tags = tags
            let links = (try? context.fetch(FetchDescriptor<AgendaNoteLink>(predicate: #Predicate { $0.noteID == id }))) ?? []
            for link in links where link.note == nil {
                link.note = note
            }
        case .decision:
            guard (try? Lookup.decision(id, in: context)) == nil else { throw back() }
            guard let project else { throw gone() }
            let decision = Decision(title: text("title"), decision: text("decision"), project: project, rationale: text("rationale"), thread: track)
            decision.id = id
            decision.statusRaw = saved["status"] as? String ?? DecisionStatus.active.rawValue
            decision.supersededByID = uuid(saved["superseded_by"])
            decision.createdAt = date(saved["created"]) ?? .now
            decision.spaceIDString = text("space")
            context.insert(decision)
            decision.tags = tags
        case .track:
            guard (try? Lookup.thread(id, in: context)) == nil else { throw back() }
            guard let project else { throw gone() }
            let parent = uuid(saved["parent"]).flatMap { try? Lookup.thread($0, in: context) }
            let restored = ProjectThread(title: text("title"), kind: .topic, project: project, parent: parent)
            restored.id = id
            restored.kindRaw = saved["kind"] as? String ?? restored.kindRaw
            restored.summary = text("summary")
            restored.body = text("body")
            restored.statusRaw = saved["status"] as? String ?? restored.statusRaw
            restored.createdAt = date(saved["created"]) ?? .now
            restored.updatedAt = date(saved["updated"]) ?? .now
            restored.spaceIDString = text("space")
            context.insert(restored)
            restored.tags = tags
            // What was filed under the track lost its link when the track went. Give it back where nothing replaced it.
            for noteID in uuids(saved["notes"]) {
                if let note = try? Lookup.note(noteID, in: context), note.thread == nil { note.thread = restored }
            }
            for decisionID in uuids(saved["decisions"]) {
                if let decision = try? Lookup.decision(decisionID, in: context), decision.thread == nil { decision.thread = restored }
            }
            for chatID in uuids(saved["chats"]) {
                if let chat = try? Lookup.conversation(chatID, in: context), chat.thread == nil { chat.thread = restored }
            }
            let links = (try? context.fetch(FetchDescriptor<AgendaTrackLink>(predicate: #Predicate { $0.threadID == id }))) ?? []
            for link in links where link.thread == nil {
                link.thread = restored
            }
        case .chat:
            guard (try? Lookup.conversation(id, in: context)) == nil else { throw back() }
            let chat = Conversation(title: text("title"), providerID: text("provider"), modelID: text("model"), project: project)
            chat.id = id
            chat.externalSessionID = text("session")
            chat.contextSnapshot = text("context")
            chat.isArchived = saved["archived"] as? Bool ?? false
            chat.createdAt = date(saved["created"]) ?? .now
            chat.updatedAt = date(saved["updated"]) ?? .now
            chat.spaceIDString = text("space")
            context.insert(chat)
            chat.thread = track
            chat.tags = tags
            var files: [(kind: AssetOwnerKind, owner: UUID, assets: [UUID])] = [(.chatDraft, id, uuids(saved["draft_files"]))]
            for entry in saved["messages"] as? [[String: Any]] ?? [] {
                let message = ChatMessage(id: uuid(entry["id"]) ?? UUID(), role: .user, content: entry["content"] as? String ?? "")
                message.roleRaw = entry["role"] as? String ?? message.roleRaw
                message.externalRunID = entry["run"] as? String ?? ""
                message.createdAt = date(entry["created"]) ?? .now
                context.insert(message)
                message.conversation = chat
                files.append((.chatMessage, message.id, uuids(entry["files"])))
            }
            // Attached files come back while the store still holds them; it clears unused files after a while.
            let store = FileStore.default(context: context)
            for entry in files where !entry.assets.isEmpty {
                try? store.retain(assetIDs: entry.assets, ownerKind: entry.kind, ownerID: entry.owner)
            }
        }
        project?.touch()
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

    static func source(_ id: UUID, in context: ModelContext) throws -> SavedSource {
        guard let found = try context.fetch(FetchDescriptor<SavedSource>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No source with id \(id.uuidString).")
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
            throw ToolError("No track with id \(id.uuidString).")
        }
        return found
    }

    static func task(_ id: UUID, in context: ModelContext) throws -> AgendaItem {
        guard let found = try context.fetch(FetchDescriptor<AgendaItem>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No task with id \(id.uuidString).")
        }
        guard found.kind == .task else { throw ToolError("That id is not a Membrae task.") }
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
        guard let found = CodeAttachment.find(id, in: context) else {
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

    static func tag(_ id: UUID, in context: ModelContext) throws -> Tag {
        guard let found = try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No tag with id \(id.uuidString).")
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

    /// Resolves an optional track link within a project. nil means "not given" or "cleared".
    static func thread(_ link: UUID??, in project: Project) throws -> ProjectThread? {
        guard let link, let id = link else { return nil }
        guard let thread = project.threads.first(where: { $0.id == id }) else {
            throw ToolError("No track with id \(id.uuidString) in \(project.name).")
        }
        return thread
    }
}

enum JSONShape {
    private static let iso = ISO8601DateFormatter()

    static func tag(_ tag: Tag) -> [String: Any] {
        [
            "id": tag.id.uuidString,
            "name": tag.displayName,
            "color": tag.swatch.rawValue,
            "counts": [
                "tracks": tag.threads.count,
                "notes": tag.notes.count,
                "decisions": tag.decisions.count,
                "conversations": tag.conversations.count,
                "tasks": tag.agendaItems.filter { $0.kind == .task }.count
            ]
        ]
    }

    static func tags(_ tags: [Tag]) -> [[String: Any]] {
        tags
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { ["id": $0.id.uuidString, "name": $0.displayName, "color": $0.swatch.rawValue] }
    }

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
                "tracks": project.threads.count,
                "notes": project.notes.count,
                "chats": project.conversations.filter { !$0.isArchived }.count,
                "tasks": project.agendaItems.filter { $0.kind == .task }.count
            ]
        ]
        if let next = TaskStore.nextTask(in: project) {
            shape["next_task"] = ["id": next.id.uuidString, "title": next.displayTitle]
        }
        return shape
    }

    static func attachments(on project: Project, in context: ModelContext) -> [[String: Any]] {
        CodeAttachment.all(on: project, in: context)
            .sorted { $0.createdAt < $1.createdAt }
            .map { attachment in
                [
                    "id": attachment.id.uuidString,
                    "title": attachment.title.isEmpty ? attachment.locator : attachment.title,
                    "kind": attachment.kind.rawValue,
                    "locator": attachment.locator
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
            },
            "tags": tags(item.tags)
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
            "track_id": decision.thread?.id.uuidString ?? "",
            "created_at": iso.string(from: decision.createdAt),
            "tags": tags(decision.tags)
        ]
        attachMark(&shape, id: decision.id, project: decision.project)
        return shape
    }

    static func track(_ thread: ProjectThread, full: Bool) -> [String: Any] {
        var shape: [String: Any] = [
            "id": thread.id.uuidString,
            "project_id": thread.project?.id.uuidString ?? "",
            "title": thread.title,
            "kind": thread.kind.rawValue,
            "status": thread.status.rawValue,
            "summary": thread.summary,
            "parent_id": thread.parent?.id.uuidString ?? "",
            "updated_at": iso.string(from: thread.updatedAt),
            "tags": tags(thread.tags)
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

    static func conversation(_ conversation: Conversation, full: Bool) -> [String: Any] {
        let messages = conversation.orderedMessages
        let lastText = messages.last.map { chatText($0.content) } ?? ""
        var shape: [String: Any] = [
            "id": conversation.id.uuidString,
            "project_id": conversation.project?.id.uuidString ?? "",
            "title": conversation.title.isEmpty ? "Chat" : conversation.title,
            "track_id": conversation.thread?.id.uuidString ?? "",
            "updated_at": iso.string(from: conversation.updatedAt),
            "message_count": messages.count,
            "is_archived": conversation.isArchived,
            "tags": tags(conversation.tags)
        ]
        if full {
            shape["messages"] = messages.map { message in
                [
                    "id": message.id.uuidString,
                    "role": message.role.rawValue,
                    "content": chatText(message.content),
                    "created_at": iso.string(from: message.createdAt)
                ]
            }
        } else {
            shape["preview"] = clip(lastText, 240)
        }
        attachMark(&shape, id: conversation.id, project: conversation.project)
        return shape
    }

    static func source(_ source: SavedSource, full: Bool) -> [String: Any] {
        var shape: [String: Any] = [
            "id": source.id.uuidString,
            "url": source.url,
            "title": source.displayTitle,
            "summary": source.summary,
            "kind": source.kindRaw,
            "project_ids": source.projects.map(\.id.uuidString),
            "project_id": source.projects.first?.id.uuidString ?? "",
            "read": source.readAt != nil,
            "archived": source.isArchived,
            "saved_at": iso.string(from: source.createdAt)
        ]
        if full {
            shape["text"] = source.text
        } else if source.summary.isEmpty {
            shape["preview"] = clip(source.text, 240)
        }
        return shape
    }

    static func note(_ note: Note, full: Bool) -> [String: Any] {
        var shape: [String: Any] = [
            "id": note.id.uuidString,
            "project_id": note.project?.id.uuidString ?? "",
            "title": note.displayTitle,
            "source": note.source,
            "track_id": note.thread?.id.uuidString ?? "",
            "updated_at": iso.string(from: note.updatedAt),
            "tags": tags(note.tags)
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
            "status_detail": run.statusDetail
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

    private static func chatText(_ raw: String) -> String {
        guard let start = raw.range(of: "\n\n<!--membrae:", options: .backwards) else { return raw }
        return String(raw[..<start.lowerBound])
    }

    private static func attachMark(_ shape: inout [String: Any], id: UUID, project: Project?) {
        if let mark = project?.deletionMarks.first(where: { $0.targetID == id }) {
            shape["deletion_mark"] = deletionMark(mark)
        }
    }
}

/// Shapes and parsing for the Space tools. An agent sends plain JSON; this turns it into typed values
/// and says what is wrong in words the agent can act on.
enum SpaceTools {
    static func space(_ args: Args, in context: ModelContext) throws -> Space {
        let id = try args.uuid("space_id")
        guard let space = SpaceStore.space(id, in: context) else {
            throw ToolError("No Space with id \(id.uuidString).")
        }
        return space
    }

    static func type(_ args: Args, in context: ModelContext) throws -> SpaceType {
        let space = try space(args, in: context)
        let key = try args.required("type_key")
        guard let type = SpaceStore.types(in: space, context: context).first(where: { $0.key == key }) else {
            let known = SpaceStore.types(in: space, context: context).map(\.key).joined(separator: ", ")
            throw ToolError("\(space.displayName) has no type with the key \(key). It has: \(known.isEmpty ? "none" : known).")
        }
        return type
    }

    /// An array argument, also accepted as a JSON string, because some models send one.
    static func objects(_ args: Args, _ key: String) throws -> [[String: Any]] {
        if let text = args.raw[key] as? String {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
                throw ToolError("\(key) must be an array of objects.")
            }
            return parsed
        }
        guard let objects = try args.objects(key) else { throw ToolError("\(key) is required.") }
        return objects
    }

    static func slug(_ text: String) -> String {
        let pieces = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return pieces.joined(separator: "-")
    }

    static func fields(_ raw: [[String: Any]]) throws -> [SpaceField] {
        try raw.map { object in
            guard let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw ToolError("Every field needs a name.")
            }
            let kindRaw = object["kind"] as? String ?? ""
            guard let kind = SpaceFieldKind(rawValue: kindRaw) else {
                let allowed = SpaceFieldKind.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolError("\(name) has the kind \(kindRaw.isEmpty ? "(none)" : kindRaw). Use one of: \(allowed).")
            }
            let id = (object["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug(name)
            let options: [SpaceOption] = (object["options"] as? [Any] ?? []).compactMap { option in
                if let text = option as? String { return SpaceOption(id: slug(text), name: text) }
                guard let pair = option as? [String: Any], let optionName = pair["name"] as? String else { return nil }
                return SpaceOption(id: (pair["id"] as? String) ?? slug(optionName), name: optionName)
            }
            if kind == .choice || kind == .tags, options.isEmpty {
                throw ToolError("\(name) is a \(kind.rawValue) field and needs options.")
            }
            let nested = try fields((object["fields"] as? [Any] ?? []).compactMap { $0 as? [String: Any] })
            if kind == .group, nested.isEmpty {
                throw ToolError("\(name) is a group and needs fields for its rows.")
            }
            let formula = (object["formula"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if kind == .calc, formula.isEmpty {
                throw ToolError("\(name) is a calc field and needs a formula. \(SpaceFormula.grammar)")
            }
            let target = (object["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if kind == .link, target.isEmpty {
                throw ToolError("\(name) is a link and needs target: the key of the type it points at.")
            }
            return SpaceField(
                id: id,
                name: name,
                kind: kind,
                options: options,
                fields: nested,
                isOrdered: (object["ordered"] as? Bool) ?? (object["isOrdered"] as? Bool) ?? false,
                target: target,
                formula: formula,
                unit: (object["currency"] as? String) ?? (object["unit"] as? String) ?? "",
                initial: (object["default"] as? String) ?? (object["default"] as? NSNumber).map { "\($0)" } ?? ""
            )
        }
    }

    static func components(_ raw: [[String: Any]]) throws -> [SpaceComponent] {
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let parsed = try? JSONDecoder().decode([SpaceComponent].self, from: data) else {
            throw ToolError("Each component needs a component name, and its settings must be text, numbers, or lists of text.")
        }
        return parsed
    }

    static func values(_ raw: Any?, schema: SpaceSchema) throws -> [String: SpaceValue] {
        guard let raw else { return [:] }
        if let text = raw as? String {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw ToolError("values must be an object keyed by field id.")
            }
            return try values(parsed, fields: schema.liveFields)
        }
        guard let object = raw as? [String: Any] else { throw ToolError("values must be an object keyed by field id.") }
        return try values(object, fields: schema.liveFields)
    }

    private static func values(_ object: [String: Any], fields: [SpaceField]) throws -> [String: SpaceValue] {
        var result: [String: SpaceValue] = [:]
        for (key, raw) in object {
            guard let field = fields.first(where: { $0.id == key })
                ?? fields.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) else {
                let known = fields.map(\.id).joined(separator: ", ")
                throw ToolError("There is no field \(key). Fields are: \(known).")
            }
            if raw is NSNull { continue }
            result[field.id] = try value(raw, for: field)
        }
        return result
    }

    private static func value(_ raw: Any, for field: SpaceField) throws -> SpaceValue {
        func wrong(_ expected: String) -> ToolError {
            ToolError("\(field.name) needs \(expected).")
        }
        switch field.kind {
        case .text, .richText:
            guard let text = raw as? String else { throw wrong("text") }
            return .text(text)
        case .image:
            throw ToolError("\(field.name) is an image. Images are added by the user in the app.")
        case .calc:
            throw ToolError("\(field.name) is worked out automatically. Leave it out.")
        case .file:
            throw ToolError("\(field.name) is a file. Files are added by the user in the app.")
        case .url:
            guard let text = raw as? String, !text.isEmpty else { throw wrong("a web address") }
            return .text(text)
        case .tags:
            let names = (raw as? [String]) ?? (raw as? String).map(SpaceTags.ids) ?? []
            let ids = try names.map { name -> String in
                guard let option = field.options.first(where: { $0.id == name })
                    ?? field.options.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw wrong("a list from: \(field.options.map(\.id).joined(separator: ", "))")
                }
                return option.id
            }
            return .text(SpaceTags.raw(field.options.map(\.id).filter(ids.contains)))
        case .money, .rating:
            if raw is Bool { throw wrong("a number") }
            guard let number = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init) else { throw wrong("a number") }
            if field.kind == .rating, !(0...5).contains(number) { throw wrong("a number from 0 to 5") }
            return .number(number)
        case .duration:
            guard !(raw is Bool), let number = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init) else {
                throw wrong("a number of minutes")
            }
            return .number(number)
        case .time:
            if let text = raw as? String {
                let parts = text.split(separator: ":").compactMap { Double($0) }
                guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { throw wrong("a time such as 07:30") }
                return .number(parts[0] * 60 + parts[1])
            }
            guard !(raw is Bool), let number = (raw as? NSNumber)?.doubleValue else { throw wrong("a time such as 07:30") }
            return .number(number)
        case .dateRange:
            let text: String?
            if let object = raw as? [String: Any], let start = object["start"] as? String, let end = object["end"] as? String {
                text = "\(start.prefix(10))/\(end.prefix(10))"
            } else {
                text = raw as? String
            }
            guard let text, let range = SpaceDateRange(text) else { throw wrong("{start, end} as dates such as 2026-10-11") }
            return .text(range.raw)
        case .schedule:
            guard let text = raw as? String, let schedule = SpaceSchedule(text) else {
                throw wrong("daily, weekly:3 for three times a week, or days:mon,wed,fri")
            }
            return .text(schedule.raw)
        case .link:
            guard let text = raw as? String, let id = UUID(uuidString: text) else {
                throw wrong("the id of a record in \(field.target), from list_space_records")
            }
            return .text(SpaceJSON.key(id))
        case .choice:
            guard let text = raw as? String else { throw wrong("one of its options") }
            guard let option = field.options.first(where: { $0.id == text })
                ?? field.options.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) else {
                throw wrong("one of: \(field.options.map(\.id).joined(separator: ", "))")
            }
            return .text(option.id)
        case .number:
            if raw is Bool { throw wrong("a number") }
            guard let number = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init) else { throw wrong("a number") }
            return .number(number)
        case .boolean:
            guard let flag = raw as? Bool else { throw wrong("true or false") }
            return .boolean(flag)
        case .date:
            guard let text = raw as? String else { throw wrong("an ISO-8601 date") }
            let iso = ISO8601DateFormatter()
            for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate]] {
                iso.formatOptions = options
                if let date = iso.date(from: text) { return .date(date) }
            }
            throw wrong("an ISO-8601 date, such as 2026-10-11")
        case .quantity:
            if let number = (raw as? NSNumber)?.doubleValue, !(raw is Bool) {
                return .quantity(SpaceQuantity(amount: number, unit: ""))
            }
            guard let object = raw as? [String: Any], let amount = (object["amount"] as? NSNumber)?.doubleValue else {
                throw wrong("{amount, unit}")
            }
            return .quantity(SpaceQuantity(
                amount: amount,
                unit: object["unit"] as? String ?? "",
                scales: object["scales"] as? Bool ?? true
            ))
        case .group:
            guard let rows = raw as? [Any] else { throw wrong("a list of rows") }
            let columns = field.fields.filter { !$0.isRemoved }
            return .rows(try rows.map { row in
                if let text = row as? String, columns.count == 1 {
                    return [columns[0].id: try value(text, for: columns[0])]
                }
                guard let object = row as? [String: Any] else { throw wrong("rows as objects keyed by field id") }
                return try values(object, fields: columns)
            })
        }
    }

    // MARK: Shapes

    static func json<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let object = try? JSONSerialization.jsonObject(with: data) else {
            return NSNull()
        }
        return object
    }

    static func plain(_ values: [String: SpaceValue]) -> [String: Any] {
        values.mapValues { value -> Any in
            switch value {
            case .text(let text): return text
            case .number(let number): return number
            case .boolean(let flag): return flag
            case .date(let date): return ISO8601DateFormatter().string(from: date)
            case .quantity(let quantity): return ["amount": quantity.amount, "unit": quantity.unit, "scales": quantity.scales]
            case .rows(let rows): return rows.map(plain)
            }
        }
    }

    static func field(_ field: SpaceField) -> [String: Any] {
        var shape: [String: Any] = ["id": field.id, "name": field.name, "kind": field.kind.rawValue]
        if !field.options.isEmpty { shape["options"] = field.options.map { ["id": $0.id, "name": $0.name] } }
        if !field.fields.isEmpty { shape["fields"] = field.fields.filter { !$0.isRemoved }.map(SpaceTools.field) }
        if field.isOrdered { shape["ordered"] = true }
        if field.kind == .link { shape["target"] = field.target }
        if field.kind == .calc { shape["formula"] = field.formula }
        if !field.unit.isEmpty { shape["currency"] = field.unit }
        if !field.initial.isEmpty { shape["default"] = field.initial }
        return shape
    }

    static func type(_ type: SpaceType, in context: ModelContext) -> [String: Any] {
        var shape: [String: Any] = [
            "key": type.key,
            "name": type.name,
            "role": type.role.rawValue,
            "fields": type.schema.liveFields.map(field),
            "record_count": type.role == .object ? SpaceStore.records(of: type, in: context).count : 0
        ]
        var screens: [String: Any] = [:]
        for kind in SpaceScreenKind.allCases {
            if let screen = SpaceStore.screen(for: type, kind: kind, in: context) {
                screens[kind.rawValue] = json(screen.definition.components)
            }
        }
        if type.role != .event { shape["screens"] = screens }
        return shape
    }

    static func space(_ space: Space, full: Bool, in context: ModelContext) -> [String: Any] {
        let types = SpaceStore.types(in: space, context: context)
        return [
            "id": space.id.uuidString,
            "name": space.displayName,
            "summary": space.summary,
            "types": full
                ? types.map { type($0, in: context) }
                : types.map { ["key": $0.key, "name": $0.name, "role": $0.role.rawValue] }
        ]
    }

    /// Calc fields are included, worked out, so an agent reads the same numbers the user sees.
    static func record(_ record: SpaceRecord, schema: SpaceSchema, in context: ModelContext) -> [String: Any] {
        let live = Set(schema.liveFields.map(\.id))
        let values = SpaceStore.lookup(spaceKey: record.spaceIDString, in: context).resolved(record)
        return [
            "id": record.id.uuidString,
            "title": record.displayTitle,
            "archived": record.isArchived,
            "values": plain(values.filter { live.contains($0.key) }),
            "updated_at": ISO8601DateFormatter().string(from: record.updatedAt)
        ]
    }

    static func event(_ event: SpaceEvent, schema: SpaceSchema) -> [String: Any] {
        [
            "id": event.id.uuidString,
            "occurred_at": ISO8601DateFormatter().string(from: event.occurredAt),
            "record_ids": event.recordIDs.map(\.uuidString),
            "values": plain(event.values)
        ]
    }

    private static func accepts(_ kind: SpacePropKind) -> String {
        switch kind {
        case .field(let kinds): "one field id of kind: " + kinds.map(\.rawValue).joined(separator: ", ")
        case .fields(let kinds): "a list of field ids of kind: " + kinds.map(\.rawValue).joined(separator: ", ")
        case .event: "the key of an event type in the Space"
        case .calc: "a calculation"
        case .formula: "a formula: " + SpaceFormula.grammar
        case .text: "text"
        case .number: "a number"
        }
    }

    static var catalog: [String: Any] {
        let recipe = SpaceTemplate.recipes.types[0]
        return [
            "how_to": "1. create_space, unless you were given a space id. 2. set_space_type for each event type first. 3. set_space_type for each object type, passing its collection and detail screens in the same call. Use set_space_screen later to change one screen. Screens name fields by id and events by key. Every record already has a name; do not add a name field.",
            "field_kinds": [
                ["kind": "text", "value": "text"],
                ["kind": "richText", "value": "long text"],
                ["kind": "number", "value": "a number"],
                ["kind": "boolean", "value": "true or false"],
                ["kind": "date", "value": "ISO-8601 date"],
                ["kind": "choice", "value": "one option id", "needs": "options: a list of names"],
                ["kind": "image", "value": "set by the user in the app"],
                ["kind": "quantity", "value": "{amount, unit}; add scales: false for amounts like a pinch"],
                ["kind": "group", "value": "a list of rows keyed by the group's field ids", "needs": "fields: the columns of each row; ordered: true for numbered steps. Groups do not nest."],
                ["kind": "calc", "value": "never set; worked out", "needs": "formula. Use calc for anything that can be worked out, so the user never types a total. In a group row: calories * servings multiplies two numbers of that row. On the record: sum(items.calories) adds a column up. goals.calories reads a settings type. A formula cannot read a linked record: when a row refers to another record, give the row its own number field beside the link and copy the value into it when you add the row." + SpaceFormula.grammar],
                ["kind": "tags", "value": "a list of option ids", "needs": "options: a list of names"],
                ["kind": "url", "value": "a web address"],
                ["kind": "money", "value": "a number", "needs": "currency: a code such as USD, if not the user's own"],
                ["kind": "duration", "value": "minutes"],
                ["kind": "time", "value": "a time of day such as 07:30"],
                ["kind": "dateRange", "value": "{start, end} as dates"],
                ["kind": "rating", "value": "0 to 5"],
                ["kind": "file", "value": "set by the user in the app"],
                ["kind": "schedule", "value": "daily, weekly:3 (three times a week), or days:mon,wed,fri", "needs": "nothing. Give a habit or routine one schedule field; streaks, pace and done-today then follow it instead of assuming every day."],
                ["kind": "link", "value": "the id of one record of the target type", "needs": "target: the key of an object type in the same Space, created first. Use a link whenever one thing refers to another, such as a meal made from recipes, so it can be opened from there. For several, put the link in a group with any per-row fields, such as servings. A number the row needs from the linked record, such as its calories, is a number field of the row that you fill in from the linked record when you add the row; it is a snapshot and does not change when the linked record does."]
            ],
            "components": SpaceScreenCatalog.components.map { spec -> [String: Any] in
                [
                    "component": spec.name,
                    "does": spec.summary,
                    "screens": spec.screens.map(\.rawValue).sorted(),
                    "takes_children": spec.takesChildren,
                    "settings": spec.props.map { prop -> [String: Any] in
                        ["name": prop.name, "accepts": accepts(prop.kind), "required": prop.required, "note": prop.note]
                    }
                ]
            },
            "defaults": "Any field can take default: what a new record starts with. A number, an option id, true, or today for a date.",
            "roles": [
                "object": "a lasting thing with many records, such as recipes",
                "event": "something logged about records, such as cooked",
                "settings": "exactly one record for the whole Space, such as daily targets. It gets a detail screen only. Other types read it in formulas as key.field."
            ],
            "calculations": [
                "count:eventKey": "how many events",
                "latest:eventKey": "when the newest event happened",
                "streak:eventKey": "days in a row with an event",
                "best:eventKey": "longest run of days with an event",
                "week:eventKey": "events in the last seven days",
                "pace:eventKey": "where the record stands against its schedule: 2 of 3 this week, or done today",
                "sum:eventKey.field:period": "a logged number added up. period is today, week, month, year or all. The field belongs to the event: to add up something about the records the events are about, give the event a number field and copy the value into it when you log, such as sum:eaten.calories:today",
                "avg:eventKey.field:period": "the average of a logged number",
                "min:eventKey.field:period": "the smallest logged number",
                "max:eventKey.field:period": "the largest logged number",
                "change:eventKey.field:period": "how far a logged number has moved since the period began, such as weight this month",
                "count:eventKey:period": "how many events in a period",
                "today:eventKey": "collection only: records with an event today, out of all",
                "records": "collection only: how many records"
            ],
            "example": [
                "type": ["key": recipe.key, "name": recipe.name, "role": "object", "fields": recipe.fields.map(field)],
                "event_type": ["key": "cooked", "name": "Cooked", "role": "event"],
                "collection": json(recipe.collection),
                "detail": json(recipe.detail)
            ]
        ]
    }
}
