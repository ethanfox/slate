import EventKit
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

    func integer(_ key: String) throws -> Int? {
        guard let value = raw[key] else { return nil }
        if let number = value as? Int { return number }
        if let number = value as? Double, number == number.rounded() { return Int(number) }
        if let text = value as? String {
            if text.isEmpty { return nil }
            if let number = Int(text.trimmingCharacters(in: .whitespaces)) { return number }
        }
        throw ToolError("\(key) must be a whole number.")
    }

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

enum SpaceExpand: String, CaseIterable {
    case decisions
    case tracks
    case notes
    case tasks
    case deletionMarks = "deletion_marks"

    static func parse(_ values: [String]?) throws -> Set<SpaceExpand> {
        guard let values else { return [] }
        return Set(try values.map { value in
            let normalized = value == "threads" ? "tracks" : value
            guard let parsed = SpaceExpand(rawValue: normalized) else {
                let allowed = SpaceExpand.allCases.map(\.rawValue).joined(separator: ", ")
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
        "create_space": (.added, "space"), "update_space": (.changed, "space"),
        "create_task": (.added, "task"), "update_task": (.changed, "task"), "complete_task": (.completed, "task"),
        "delete_completion": (.removed, "completion"),
        "create_decision": (.added, "decision"), "update_decision": (.changed, "decision"),
        "create_track": (.added, "track"), "update_track": (.changed, "track"), "set_stops": (.changed, "track"), "convert_track_to_stop": (.changed, "track"),
        "set_junction": (.changed, "track"), "delete_junction": (.changed, "track"), "merge_tracks": (.changed, "track"),
        "create_note": (.added, "note"), "update_note": (.changed, "note"),
        "create_source": (.added, "source"), "update_source": (.changed, "source"),
        "create_tag": (.added, "tag"), "update_tag": (.changed, "tag"),
        "assign_tag": (.tagged, ""), "remove_tag": (.untagged, ""),
        "mark_for_deletion": (.flagged, ""), "delete_record": (.removed, ""),
        "set_space_type": (.changed, "space"), "set_space_card": (.changed, "space"), "set_space_layout": (.changed, "space"),
        "set_space_widget": (.changed, "space"), "remove_space_widget": (.changed, "space"),
        "place_space_widget": (.changed, "space"),
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
        var space = (shape["space_id"] as? String) ?? args.string("space_id") ?? ""
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
            space = index(id)?.projectIDString ?? space
        }

        switch tool {
        case "assign_tag", "remove_tag":
            detail = title
            pointAtIndexed(args.string("record_id") ?? "", kind: args.string("record_type") ?? "")
        case "mark_for_deletion":
            detail = args.string("reason") ?? ""
            pointAtIndexed(args.string("target_id") ?? "", kind: args.string("target_type") ?? "")
        case "delete_record":
            kind = args.string("target_type") ?? ""
        case "merge_tracks":
            detail = (before["track"] as? [String: Any])?["title"] as? String ?? ""
        case "delete_completion":
            target = ""
        case "create_space", "update_space":
            space = target
        case "set_space_type", "set_space_card", "set_space_layout", "set_space_widget", "remove_space_widget", "place_space_widget":
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
            spaceID: space,
            origin: origin,
            beforeJSON: before.isEmpty ? "" : (try? JSONSerialization.data(withJSONObject: before)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        ))
        AgentActionStore.trim(in: context)
    }

    // MARK: - Taking a write back

    /// For each tool that edits a record: the tool that reads it, and the argument that names it.
    private static let readers: [String: (tool: String, id: String)] = [
        "update_space": ("get_space", "space_id"),
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
        if tool == "merge_tracks" {
            if let junction = (try? args.uuid("junction_id")).flatMap({ try? Lookup.junction($0, in: context) }),
               let first = junction.first, let second = junction.second {
                return TrackMerge.snapshot(of: second, into: first)
            }
            guard let second = (try? args.uuid("track_id")).flatMap({ try? Lookup.thread($0, in: context) }),
                  let first = (try? args.uuid("into_track_id")).flatMap({ try? Lookup.thread($0, in: context) }) else { return [:] }
            return TrackMerge.snapshot(of: second, into: first)
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
        case .changed where action.tool == "merge_tracks":
            do {
                try TrackMerge.restore(before, in: context)
            } catch {
                throw ToolError(error.localizedDescription)
            }
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

    /// Names clients may still send: the thread_* tools, the project_* tools from before every Space
    /// was one thing, and the area_* widget tools.
    private static let aliases = [
        "list_threads": "list_tracks",
        "get_thread": "get_track",
        "create_thread": "create_track",
        "update_thread": "update_track",
        "list_projects": "list_spaces",
        "get_project": "get_space",
        "create_project": "create_space",
        "update_project": "update_space",
        "set_area_widget": "set_space_widget",
        "set_area_card": "set_space_card",
        "set_area_layout": "set_space_layout",
        "place_area_widget": "place_space_widget",
        "list_area_widgets": "list_space_widgets",
        "remove_area_widget": "remove_space_widget"
    ]

    private static func canonical(_ name: String) -> String {
        aliases[name] ?? name
    }

    /// Accepts the old thread_* and project_* keys so cached clients keep working.
    private static func migrate(_ arguments: [String: Any]) -> [String: Any] {
        var next = arguments
        if next["track_id"] == nil, let old = next["thread_id"] {
            next["track_id"] = old
        }
        if next["space_id"] == nil, let old = next["project_id"] {
            next["space_id"] = old
        }
        if next["space_ids"] == nil, let old = next["project_ids"] {
            next["space_ids"] = old
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

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
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

    private static let trackLink = text("Track id to file this under. Empty string removes the link.")

    // MARK: - Tools

    private static let tools: [Tool] = [
        Tool(
            name: "list_tasks",
            description: "List Membrae tasks. Completions are not included. Use list_completions for repeat history. Pass track_id to list work on a track. When asked what to work on, read the Space's active_track and list that track's tasks; tasks elsewhere are not the current work.",
            properties: [
                "space_id": text("Optional Space id. Omit to list every task."),
                "track_id": text("Only tasks linked to this track."),
                "include_descendants": flag("When track_id is set, also include tasks on child tracks. Defaults to false."),
                "status": options(TaskWorkflowStatus.self, "Only tasks with this workflow status."),
                "next_only": flag("Only the Next task in each Space. With an active track that is the first open, unblocked task on it.")
            ],
            required: [], readOnly: true
        ) { args, context in
            let project = try args.string("space_id").map { _ in try Lookup.space(try args.uuid("space_id"), in: context) }
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
                    if nextOnly, !TaskStore.isNext(task) { return false }
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
            description: "Create a Membrae task. space_id is optional. is_next requires an active Space and is refused when the Space has an active track, where Next is worked out from the track. Link governing tracks with track_ids. Reference notes are supplementary via note_ids. Do not put built/not-built in notes.",
            properties: [
                "title": text("Task title."),
                "space_id": text("Optional Space id."),
                "notes": text("Short working comment. Not status. Do not write built or not-built here."),
                "due": text("ISO-8601 due date."),
                "status": options(TaskWorkflowStatus.self, "Workflow status. Defaults to ready."),
                "is_next": flag("Mark this task Next for its Space."),
                "track_ids": ["type": "array", "items": ["type": "string"], "description": "Governing track ids. Feature and problem work lives on these tracks."],
                "stop_id": text("The stop this task sits on. It is linked to the stop's track if it is not already."),
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
                "space_id": text("Move to this Space. Empty string clears it."),
                "track_ids": ["type": "array", "items": ["type": "string"], "description": "Replacement governing track ids."],
                "stop_id": text("The stop this task sits on. Empty string takes it off its stop."),
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
            name: "list_calendars",
            description: "The current time, the Mac's time zone, and the names of the user's calendars and Apple Reminders lists. Call it before create_event or create_reminder so the date is right.",
            properties: [:], required: [], readOnly: true
        ) { _, _ in
            Agenda.context()
        },
        Tool(
            name: "create_event",
            description: "Add an event to the user's calendar on this Mac. Not a Membrae task.",
            properties: [
                "title": text("Event title."),
                "start": text("ISO-8601 start, such as 2026-01-31T15:00:00. Without an offset it is read in the Mac's time zone. A bare day, 2026-01-31, makes an all-day event."),
                "end": text("ISO-8601 end. Defaults to one hour after start, or the same day for an all-day event."),
                "all_day": flag("Make it an all-day event."),
                "calendar": text("Calendar name from list_calendars. Defaults to the user's default calendar."),
                "location": text("Where it is."),
                "notes": text("Notes on the event.")
            ],
            required: ["title", "start"], readOnly: false
        ) { args, _ in
            try Agenda.createEvent(args)
        },
        Tool(
            name: "create_reminder",
            description: "Add a reminder to Apple Reminders on this Mac. Use it when the user asks to be reminded. Not a Membrae task.",
            properties: [
                "title": text("What to be reminded of."),
                "due": text("ISO-8601 time to be reminded, such as 2026-01-31T15:00:00. Without an offset it is read in the Mac's time zone. A bare day, 2026-01-31, is due that day with no time."),
                "list": text("Reminders list name from list_calendars. Defaults to the user's default list."),
                "notes": text("Notes on the reminder."),
                "repeat": options(Agenda.Repeat.self, "How often it repeats. Needs due.")
            ],
            required: ["title"], readOnly: false
        ) { args, _ in
            try Agenda.createReminder(args)
        },
        Tool(
            name: "list_completions",
            description: "List immutable completion records for repeating tasks.",
            properties: [
                "space_id": text("Optional Space id."),
                "task_id": text("Optional parent task id.")
            ],
            required: [], readOnly: true
        ) { args, context in
            let projectID = try args.string("space_id").map { _ in try args.uuid("space_id") }
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
            description: "List a Space's decisions, newest first.",
            properties: ["space_id": spaceID, "status": options(DecisionStatus.self, "Only decisions with this status.")],
            required: ["space_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.space(try args.uuid("space_id"), in: context)
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
                "space_id": spaceID,
                "title": text("Short name for the decision."),
                "decision": text("What was decided."),
                "rationale": text("Why."),
                "track_id": trackLink,
                "supersedes_id": text("Id of the decision this one replaces.")
            ],
            required: ["space_id", "title", "decision"], readOnly: false
        ) { args, context in
            let project = try Lookup.space(try args.uuid("space_id"), in: context)
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
            description: "List a Space's tracks with ids, kinds, statuses, summaries, themes, and which one is active. A theme is a named group of tracks and holds no work of its own. parent_id is set only on a track still nested from before; tracks no longer nest.",
            properties: ["space_id": spaceID], required: ["space_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.space(try args.uuid("space_id"), in: context)
            return project.threads.sorted { $0.createdAt < $1.createdAt }.map { JSONShape.track($0, full: false) }
        },
        Tool(
            name: "get_track",
            description: "Get one track with its full body, its stops in order, linked decisions, note previews, tasks including child-track tasks, and child-track summaries.",
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
                "space_id": spaceID,
                "title": text("Track title."),
                "kind": options(ThreadKind.self, "Kind of track. Defaults to topic."),
                "status": options(ThreadStatus.self, "Defaults to exploring."),
                "summary": text("One or two sentences."),
                "body": text("Markdown spec."),
                "theme": text("Name of the theme to list this track under. A theme with that name is made if the Space has none."),
                "fare_days": integer("The fare: how many days the user is willing to spend on this track, counted from the day it was made. Set it only when the user says how long. 0 clears it."),
            ],
            required: ["space_id", "title"], readOnly: false
        ) { args, context in
            let project = try Lookup.space(try args.uuid("space_id"), in: context)
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
            if let fare = try args.integer("fare_days") { thread.fareDays = max(0, fare) }
            context.insert(thread)
            if let theme = args.string("theme") { ThemeStore.setTheme(theme, on: thread, in: context) }
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
                "parent_id": text("Empty string takes a nested track out from under its parent. Tracks no longer nest, so do not set a parent."),
                "theme": text("Name of the theme to list this track under. Empty string takes it out of its theme."),
                "fare_days": integer("The fare: how many days the user is willing to spend on this track, counted from the day it was made. Set it only when the user says how long. 0 clears it."),
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
            if let theme = args.string("theme") { ThemeStore.setTheme(theme, on: thread, in: context) }
            if let fare = try args.integer("fare_days") { thread.fareDays = max(0, fare) }
            thread.updatedAt = .now
            thread.project?.touch()
            return JSONShape.track(thread, full: true)
        },
        Tool(
            name: "convert_track_to_stop",
            description: "Turn a track that is nested under another into a stop on that parent. The stop takes its title, and its summary and body as the stop's text. Its tasks move onto the stop, and its decisions, notes, and chats move to the parent. The nested track is then removed. Its own nested tracks must be converted first. Returns the parent.",
            properties: ["track_id": text("The nested track to convert.")],
            required: ["track_id"], readOnly: false
        ) { args, context in
            let thread = try Lookup.thread(try args.uuid("track_id"), in: context)
            guard let parent = thread.parent else { throw ToolError(StopStoreError.noParent.localizedDescription) }
            do {
                try StopStore.absorb(thread, in: context)
            } catch let error as StopStoreError {
                throw ToolError(error.localizedDescription)
            }
            return JSONShape.track(parent, full: true)
        },
        Tool(
            name: "set_stops",
            description: "Write a track's stops, or update them. A stop is one idea inside the track, and the stops are in the order they are to be worked on, most important first. Send every stop each time, in order. Give id for a stop that already exists, so it keeps its tasks; leave id out for a new one. A stop you leave out is removed and its tasks stay on the track. Put a task on a stop with stop_id on create_task or update_task.",
            properties: [
                "track_id": text("Track id."),
                "stops": objectList("Every stop, in order: {id, title, body, is_done}. id only for an existing stop. body is a short spec for the stop.")
            ],
            required: ["track_id", "stops"], readOnly: false
        ) { args, context in
            let thread = try Lookup.thread(try args.uuid("track_id"), in: context)
            let entries = try (try args.objects("stops") ?? []).map { item -> StopEntry in
                let rawID = (item["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var id: UUID?
                if !rawID.isEmpty {
                    guard let parsed = UUID(uuidString: rawID) else { throw ToolError("id is not a valid stop id: \(rawID)") }
                    id = parsed
                }
                return StopEntry(
                    id: id,
                    title: item["title"] as? String ?? "",
                    body: item["body"] as? String,
                    isDone: item["is_done"] as? Bool
                )
            }
            do {
                try StopStore.replace(on: thread, with: entries, in: context)
            } catch let error as StopStoreError {
                throw ToolError(error.localizedDescription)
            }
            return JSONShape.track(thread, full: true)
        },
        Tool(
            name: "set_junction",
            description: "Make or change a junction between two tracks in one Space. kind wait, the default: second_track_id cannot go on until first_track_id has done what the junction requires; both stay separate tracks. Give held_stop_id for the stop on the second track that waits, or leave it out to hold the whole track. A wait with no requirements is met when the first track is completed. kind merge: the two tracks are the same work and will become one, continuing as the first. Its requirements are the gaps and conflicts between the two that have to be reconciled first, which can be real work. Send every requirement each time, in order. A requirement with stop_id or task_id is met when that stop or task is done; one with only text is ticked with is_done. Pass junction_id to change an existing junction. Returns the first track.",
            properties: [
                "junction_id": text("An existing junction to change. Leave out to make a new one."),
                "kind": ["type": "string", "enum": JunctionKind.allCases.map(\.rawValue), "description": "wait or merge. Defaults to wait."],
                "first_track_id": text("The track waited on, or the track a merge continues as. Needed for a new junction."),
                "second_track_id": text("The track that waits, or the track a merge folds in. Needed for a new junction."),
                "held_stop_id": text("On a wait, the stop on the second track that cannot start. Empty string holds the whole track."),
                "requirements": objectList("Every requirement, in order: {id, text, stop_id, task_id, is_done}. id only for an existing requirement.")
            ],
            required: [], readOnly: false
        ) { args, context in
            do {
                let heldLink = try args.optionalUUID("held_stop_id")
                let junction: TrackJunction
                if let rawID = args.string("junction_id"), !rawID.isEmpty {
                    junction = try Lookup.junction(try args.uuid("junction_id"), in: context)
                    let kind = try args.choice("kind", as: JunctionKind.self) ?? junction.kind
                    let held = try heldLink.map { try $0.map { try Lookup.stop($0, in: context) } } ?? junction.heldStop
                    try JunctionStore.update(junction, kind: kind, heldStop: held, in: context)
                } else {
                    let first = try Lookup.thread(try args.uuid("first_track_id"), in: context)
                    let second = try Lookup.thread(try args.uuid("second_track_id"), in: context)
                    let held = try (heldLink ?? nil).map { try Lookup.stop($0, in: context) }
                    junction = try JunctionStore.add(
                        try args.choice("kind", as: JunctionKind.self) ?? .wait,
                        first: first, second: second, heldStop: held, in: context
                    )
                }
                if let items = try args.objects("requirements") {
                    func id(_ item: [String: Any], _ key: String) throws -> UUID? {
                        let raw = (item[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !raw.isEmpty else { return nil }
                        guard let parsed = UUID(uuidString: raw) else { throw ToolError("\(key) is not a valid id: \(raw)") }
                        return parsed
                    }
                    let entries = try items.map { item in
                        RequirementEntry(
                            id: try id(item, "id"),
                            text: item["text"] as? String ?? "",
                            stopID: try id(item, "stop_id"),
                            taskID: try id(item, "task_id"),
                            isChecked: item["is_done"] as? Bool
                        )
                    }
                    try JunctionStore.replaceRequirements(on: junction, with: entries, in: context)
                }
                guard let first = junction.first else { throw ToolError(JunctionStoreError.missingTrack.localizedDescription) }
                return JSONShape.track(first, full: true)
            } catch let error as JunctionStoreError {
                throw ToolError(error.localizedDescription)
            }
        },
        Tool(
            name: "delete_junction",
            description: "Remove a junction. Both tracks stay as they are, and nothing waits on it any more.",
            properties: ["junction_id": text("Junction id, from get_track.")],
            required: ["junction_id"], readOnly: false
        ) { args, context in
            let junction = try Lookup.junction(try args.uuid("junction_id"), in: context)
            let first = junction.first
            JunctionStore.delete(junction, in: context)
            return first.map { JSONShape.track($0, full: true) } ?? ["deleted": true]
        },
        Tool(
            name: "merge_tracks",
            description: "Make two tracks one. With junction_id: a merge junction's two tracks, once every requirement on it is met; fails and names what is left otherwise. With track_id and into_track_id: fold track_id into into_track_id directly, for two tracks that are plainly the same thing with nothing to reconcile. Either way the folded track's stops follow the other's, and its tasks, decisions, notes, and chats move across. What it said is kept as a note on the track that continues, and it is then removed. The user can take a merge back from Lately. Returns the merged track.",
            properties: [
                "junction_id": text("A merge junction's id, from get_track."),
                "track_id": text("The track to fold in. Use with into_track_id when there is no junction."),
                "into_track_id": text("The track that continues.")
            ],
            required: [], readOnly: false
        ) { args, context in
            do {
                if let raw = args.string("junction_id"), !raw.isEmpty {
                    let junction = try Lookup.junction(try args.uuid("junction_id"), in: context)
                    return JSONShape.track(try JunctionStore.merge(junction, in: context), full: true)
                }
                let second = try Lookup.thread(try args.uuid("track_id"), in: context)
                let first = try Lookup.thread(try args.uuid("into_track_id"), in: context)
                return JSONShape.track(try TrackMerge.fold(second, into: first, in: context), full: true)
            } catch let error as JunctionStoreError {
                throw ToolError(error.localizedDescription)
            }
        },
        Tool(
            name: "get_cleanup_review",
            description: "Everything in one Space, in brief, for tidying it: every track with what it holds, every decision, every open task, and every note, plus how to do the cleanup. Call this first when asked to tidy, clean up, or consolidate a Space, then propose_cleanup.",
            properties: ["space_id": spaceID],
            required: ["space_id"], readOnly: true
        ) { args, context in
            CleanupStore.review(try Lookup.space(try args.uuid("space_id"), in: context))
        },
        Tool(
            name: "propose_cleanup",
            description: "Propose a cleanup of one Space. Nothing changes: the user sees the list in the app, turns off what they disagree with, and applies it. Each change they apply shows in Lately and can be taken back. A new proposal replaces one still waiting. Send every change in one call. \(ContextBuilder.cleanupRules)",
            properties: [
                "space_id": spaceID,
                "summary": text("One or two plain sentences on what this cleanup does, for the user."),
                "changes": objectList("Each change: {action, reason} plus its ids. action merge_tracks takes track_id and into_track_id. action delete takes target_type (track, task, note, or decision) and target_id. action retire_decision takes decision_id. reason is one plain sentence the user can judge without opening the record.")
            ],
            required: ["space_id", "summary", "changes"], readOnly: false
        ) { args, context in
            let project = try Lookup.space(try args.uuid("space_id"), in: context)
            let plan = try CleanupStore.propose(
                for: project,
                summary: args.string("summary") ?? "",
                items: try args.objects("changes") ?? [],
                in: context
            )
            return CleanupStore.shape(plan)
        },

        Tool(
            name: "list_chats",
            description: "List a Space's chats, most recently updated first, with a preview of the last message. Hidden (archived) chats are omitted.",
            properties: ["space_id": spaceID, "track_id": text("Only chats filed under this track.")],
            required: ["space_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.space(try args.uuid("space_id"), in: context)
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
            description: "List a Space's notes, most recently changed first, with a preview of each.",
            properties: ["space_id": spaceID, "track_id": text("Only notes filed under this track.")],
            required: ["space_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.space(try args.uuid("space_id"), in: context)
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
                "space_id": spaceID,
                "title": text("Note title."),
                "content": text("Markdown content."),
                "source": text("Where this came from, such as a URL or conversation."),
                "track_id": trackLink
            ],
            required: ["space_id", "content"], readOnly: false
        ) { args, context in
            let project = try Lookup.space(try args.uuid("space_id"), in: context)
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
            description: "List saved sources in the Library: links, PDFs, and articles the user kept, newest first, each with a summary. The Library is shared across Spaces, so search it from any Space. Pass query to search titles, summaries, and the saved text.",
            properties: [
                "query": text("Words to look for in the title, summary, address, or saved text."),
                "linked_to": text("Only sources linked to this Space id."),
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
            description: "Save a link, article, or document to the Library. Pass the address; the app fetches the page text itself when you leave text out. Write a two-line summary when you know what the page says. Link it to every Space it belongs to with space_ids, or to none. Saving an address that is already in the Library updates that source instead of adding a second one.",
            properties: [
                "url": text("The address of the page or file."),
                "title": text("Title of the page or document."),
                "summary": text("Two lines on what it says and why it was kept."),
                "text": text("The readable text, when you already have it."),
                "file_id": text("Id of a file already stored in Membrae, to keep with the source. Only the app has these ids."),
                "space_ids": ["type": "array", "items": ["type": "string"], "description": "Spaces this source belongs to. May be empty."]
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
            let projects = try (args.uuids("space_ids") ?? []).map { try Lookup.space($0, in: context) }
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
            description: "Change a saved source. Only the fields you pass are changed. space_ids replaces the whole set of linked Spaces.",
            properties: [
                "source_id": text("Source id."),
                "title": text("New title."),
                "summary": text("New summary."),
                "text": text("Replaces the saved text."),
                "space_ids": ["type": "array", "items": ["type": "string"], "description": "Replacement set of linked Spaces."],
                "read": flag("Mark read or unread."),
                "archived": flag("Archive or bring back.")
            ],
            required: ["source_id"], readOnly: false
        ) { args, context in
            let source = try Lookup.source(try args.uuid("source_id"), in: context)
            if let title = args.string("title") { source.title = title }
            if let summary = args.string("summary") { source.summary = summary }
            if let body = args.string("text") { source.text = body }
            if let ids = try args.uuids("space_ids") {
                source.projects = try ids.map { try Lookup.space($0, in: context) }
            }
            if let read = args.bool("read") { source.readAt = read ? (source.readAt ?? .now) : nil }
            if let archived = args.bool("archived") { source.isArchived = archived }
            source.updatedAt = .now
            return JSONShape.source(source, full: false)
        },

        Tool(
            name: "list_tags",
            description: "List the global tag vocabulary. Tags are sparse cross-cutting labels, not Spaces, status, or relationships. Spaces do not receive tags.",
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
            description: "Assign a tag to a note, track, decision, conversation, or task. Does not assign a Space. Spaces cannot be tagged.",
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
            description: "Propose deleting a note, track, decision, or chat when the user should decide. To delete outright, use delete_record. The user sees the mark and can Keep or Delete. Reason is required. Optionally link a replacement in the same Space. Calling again updates the reason and replacement.",
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
            description: "Delete a task, note, track, decision, or chat. The delete shows in the user's Lately feed, where they can take it back. Delete what is obsolete, duplicated, or what the user asked to remove. A track with tracks under it cannot be deleted until those are moved or deleted; notes, decisions, and tasks filed under a deleted track stay in the Space.",
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
            description: "List Membrae agent Runs. Newest first. Filter by Space, task, status, or origin.",
            properties: [
                "space_id": text("Optional Space id."),
                "task_id": text("Optional task id."),
                "status": options(RunStatus.self, "Optional status."),
                "origin": options(RunOrigin.self, "Optional origin door.")
            ],
            required: [],
            readOnly: true
        ) { args, context in
            let projectID = try args.string("space_id").map { _ in try args.uuid("space_id") }
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
            name: "set_run_steps",
            description: "Write the plan for the Run you are working on, or update it. Send every step each time, in order, with done true on the ones you have finished. At most \(RunStep.limit) steps, each a few words.",
            properties: [
                "run_id": text("Leave out. It is your own Run."),
                "steps": objectList("Every step, in order: {title, done}.")
            ],
            required: ["steps"], readOnly: false
        ) { args, context in
            // A worker started for a Run can only write that Run's steps.
            let raw = ProcessInfo.processInfo.environment["MEMBRAE_RUN_ID"] ?? args.string("run_id") ?? ""
            guard let id = UUID(uuidString: raw) else { throw ToolError("There is no Run to write steps for.") }
            let run = try Lookup.run(id, in: context)
            let steps = (try args.objects("steps") ?? []).compactMap { item -> RunStep? in
                let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? nil : RunStep(title: String(title.prefix(120)), done: item["done"] as? Bool ?? false)
            }
            guard steps.count <= RunStep.limit else {
                throw ToolError("A Run's plan holds \(RunStep.limit) steps, and this has \(steps.count). Merge some and send it again.")
            }
            run.steps = steps
            run.updatedAt = .now
            try context.save()
            return ["steps": steps.map { ["title": $0.title, "done": $0.done] }]
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
            description: "List every Space with its id, status, summary, brief, what it holds, your notes on it, and counts. A Space is one container for a part of the user's life or work: it can hold lines of work (tracks, decisions, tasks, notes), records of its own types (recipes, habits, applications), or both.",
            properties: [:], required: [], readOnly: true
        ) { _, context in
            SpaceStore.all(in: context)
                .sorted { $0.lastActivity > $1.lastActivity }
                .map { JSONShape.space($0, in: context) }
        },
        Tool(
            name: "get_space",
            description: "Get one Space: fields, identity context, attachment ids, each of its types with their fields, and counts. Pass include for bounded lists. Use get_track for a track body and get_note for reference material.",
            properties: [
                "space_id": spaceID,
                "include": [
                    "type": "array",
                    "items": ["type": "string", "enum": ["decisions", "tracks", "notes", "tasks", "deletion_marks"]],
                    "description": "Record lists to add. Omit for a lean Space record. Lists are bounded; use list_* and get_track for the rest."
                ]
            ],
            required: ["space_id"],
            readOnly: true
        ) { args, context in
            let space = try Lookup.space(try args.uuid("space_id"), in: context)
            let include = try SpaceExpand.parse(args.strings("include"))
            var shape = JSONShape.space(space, in: context, fullTypes: true)
            shape["context"] = ContextBuilder.identity(for: space)
            shape["attachments"] = JSONShape.attachments(on: space, in: context)
            if include.contains(.decisions) {
                shape["decisions"] = space.decisions
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(20)
                    .map(JSONShape.decision)
            }
            if include.contains(.tracks) {
                shape["tracks"] = space.threads
                    .sorted { $0.createdAt < $1.createdAt }
                    .prefix(24)
                    .map { JSONShape.track($0, full: false) }
            }
            if include.contains(.notes) {
                shape["notes"] = space.notes
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(8)
                    .map { JSONShape.note($0, full: false) }
            }
            if include.contains(.tasks) {
                shape["tasks"] = TaskStore.tasks(in: context, project: space)
                    .sorted(by: TaskStore.boardSort)
                    .prefix(20)
                    .map { JSONShape.task($0, full: false) }
            }
            if include.contains(.deletionMarks) {
                shape["deletion_marks"] = space.deletionMarks
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(20)
                    .map(JSONShape.deletionMark)
            }
            return shape
        },
        Tool(
            name: "get_space_catalog",
            description: "Read this before set_space_type or set_space_widget. Lists the field kinds, the widget blocks with the settings they accept, and the calculations.",
            properties: [:], required: [], readOnly: true
        ) { _, _ in
            SpaceTools.catalog
        },
        Tool(
            name: "create_space",
            description: "Create a Space. Propose it to the user first and wait for a yes. For work, give it a summary and current_direction, then tracks and tasks. For records, follow with set_space_type.",
            properties: [
                "name": text("Short name, such as Kitchen or Article One."),
                "summary": text("One line on what it is."),
                "current_direction": text("Where the work is heading right now."),
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
            space.currentDirection = args.string("current_direction") ?? ""
            return JSONShape.space(space, in: context, fullTypes: true)
        },
        Tool(
            name: "update_space",
            description: "Change a Space. Only what you pass changes.",
            properties: [
                "space_id": spaceID,
                "name": text("New name."),
                "summary": text("One line on what it is."),
                "current_direction": text("Where the work is heading right now."),
                "brief": text("One sentence, to the user, on what they are doing in this Space now, such as: You're building sync, so web AIs can reach Membrae when the Mac is off. It leads the Space's page. Keep it current when the direction or the next task changes."),
                "status": options(ProjectStatus.self, "active, paused, or done."),
                "is_pinned": flag("Pin the Space to the top of the sidebar."),
                "symbol": text("SF Symbol name for its icon."),
                "color": text("Card color: \(SpaceGradientName.all.joined(separator: ", "))."),
                "picture_shape": text("The shape of pictures on this Space's cards: landscape, or portrait for covers and posters."),
                "active_track_id": text("The one track this Space is being worked on. Its tasks are what the board shows and where Next comes from. Empty string clears it. Change it only when the user asks."),
                "notes": text("Your own notes on this Space: what the user calls things, the units they use, standing preferences. This replaces the notes, so send the whole text, old lines included. At most \(Space.agentNotesLimit) characters.")
            ],
            required: ["space_id"], readOnly: false
        ) { args, context in
            let space = try Lookup.space(try args.uuid("space_id"), in: context)
            let shape = args.string("picture_shape")
            if let shape, !["landscape", "portrait"].contains(shape) {
                throw ToolError("picture_shape must be landscape or portrait.")
            }
            if let notes = args.string("notes"), notes.count > Space.agentNotesLimit {
                throw ToolError("notes can hold \(Space.agentNotesLimit) characters, and this is \(notes.count). Shorten it and send it again.")
            }
            if let color = args.string("color"), !color.isEmpty, !SpaceGradientName.all.contains(color) {
                throw ToolError("color must be one of: \(SpaceGradientName.all.joined(separator: ", ")).")
            }
            if let direction = args.string("current_direction") { space.currentDirection = direction }
            if let brief = args.string("brief") { space.brief = brief.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let status = try args.choice("status", as: ProjectStatus.self) {
                space.status = status
                TaskStore.syncProjectStatus(space, in: context)
            }
            if let pinned = args.bool("is_pinned") { PinStore.set(.space, space.id, pinned: pinned, in: context) }
            if let link = try args.optionalUUID("active_track_id") {
                TaskStore.setActiveTrack(try Lookup.thread(link, in: space), on: space, in: context)
            }
            try SpaceStore.update(
                space,
                name: args.string("name"),
                symbol: args.string("symbol"),
                summary: args.string("summary"),
                gradient: args.string("color"),
                notes: args.string("notes"),
                portraitCards: shape.map { $0 == "portrait" },
                in: context
            )
            return JSONShape.space(space, in: context)
        },
        Tool(
            name: "set_space_type",
            description: "Create a type in a Space, or change the fields of the type with this key. role object is a lasting thing (a recipe, a habit); role event is something logged about objects (cooked, check-in); role settings holds one record for the whole Space (daily targets). A field cannot change kind; a field you leave out is hidden and its values are kept.",
            properties: [
                "space_id": spaceID,
                "key": text("Stable lowercase key, such as recipe or check-in."),
                "name": text("Name shown to the user, such as Recipes."),
                "role": options(SpaceTypeRole.self, "object, event, or settings. Defaults to object."),
                "fields": objectList("Fields: {id, name, kind, options?, fields?, ordered?, target?, formula?, currency?, default?}. See get_space_catalog for kinds.")
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
            return SpaceTools.type(type, in: context)
        },
        Tool(
            name: "set_space_widget",
            description: "Make a widget for a Space, or change one by passing widget_id. A widget is a small card about one object type: rows of blocks from the widget part of get_space_catalog. You choose which blocks go in which row; the app sets the spacing. If anything does not fit, nothing is saved and you are told every reason. Show a widget to the user by writing its link on a line by itself.",
            properties: [
                "space_id": spaceID,
                "type_key": typeKey,
                "widget_id": text("Pass to change an existing widget. Leave out to make a new one."),
                "name": text("A short title shown at the top, such as Weight or This week."),
                "size": options(AreaWidgetSize.self, "1x1 holds 2 rows of 1 block. 2x1 holds 2 rows of up to 2. 2x2 holds 4 rows of up to 2."),
                "rows": [
                    "type": "array",
                    "items": ["type": "array", "items": ["type": "object", "additionalProperties": true]],
                    "description": "Rows from top to bottom. Each row is a list of blocks left to right: {component, ...settings}."
                ]
            ],
            required: ["space_id", "type_key", "name", "size", "rows"], readOnly: false
        ) { args, context in
            let type = try SpaceTools.type(args, in: context)
            guard let size = try args.choice("size", as: AreaWidgetSize.self) else { throw ToolError("size is required.") }
            let name = try args.required("name")
            let rows = try SpaceTools.widgetRows(args)
            var existing: AreaWidget?
            if let id = try args.optionalUUID("widget_id").flatMap({ $0 }) {
                guard let found = SpaceStore.widget(id, in: context), found.spaceIDString == type.spaceIDString else {
                    throw ToolError("This Space has no widget with id \(id.uuidString).")
                }
                existing = found
            }
            let widget = try SpaceStore.setWidget(
                AreaWidgetDefinition(rows: rows),
                for: type,
                name: name,
                size: size,
                replacing: existing,
                in: context
            )
            return SpaceTools.widget(widget, typeKey: type.key)
        },
        Tool(
            name: "set_space_card",
            description: "Choose which fields show on the cards of an object type, under the name, in the order given. At most \(SpaceType.cardFieldLimit). An empty list shows only the picture and the name. Leave fields out to let the app choose again.",
            properties: [
                "space_id": spaceID,
                "type_key": typeKey,
                "fields": ["type": "array", "items": ["type": "string"], "description": "Field ids, at most \(SpaceType.cardFieldLimit). Not group, long text, image, or file fields."]
            ],
            required: ["space_id", "type_key"], readOnly: false
        ) { args, context in
            let type = try SpaceTools.type(args, in: context)
            do {
                try SpaceStore.setCardFields(try args.strings("fields"), for: type, in: context)
            } catch SpaceStoreError.invalidScreen(let problems) {
                throw ToolError(problems.joined(separator: " "))
            }
            return SpaceTools.type(type, in: context)
        },
        Tool(
            name: "set_space_layout",
            description: "Choose the one layout an object type's records are shown in: table, cards, board (grouped by its first choice field), or calendar (placed on its first date field). The page shows only this layout; the user is not given a switcher, so pick the one that suits what the type is for. An empty string lets the app choose from the data.",
            properties: [
                "space_id": spaceID,
                "type_key": typeKey,
                "layout": ["type": "string", "enum": SpaceStore.layouts + [""], "description": "table, cards, board, or calendar. Empty lets the app choose."]
            ],
            required: ["space_id", "type_key", "layout"], readOnly: false
        ) { args, context in
            let type = try SpaceTools.type(args, in: context)
            do {
                try SpaceStore.setLayout(args.string("layout") ?? "", for: type, in: context)
            } catch SpaceStoreError.invalidScreen(let problems) {
                throw ToolError(problems.joined(separator: " "))
            }
            return SpaceTools.type(type, in: context)
        },
        Tool(
            name: "place_space_widget",
            description: "Put a widget on the user's You page, or take it off. After you make a widget, ask the user in one line whether they want it on their You page, and call this only if they say yes.",
            properties: [
                "space_id": spaceID,
                "widget_id": text("Widget id from set_space_widget or list_space_widgets."),
                "on_you_page": flag("true to put it on the You page, false to take it off.")
            ],
            required: ["space_id", "widget_id", "on_you_page"], readOnly: false
        ) { args, context in
            let space = try SpaceTools.space(args, in: context)
            let id = try args.uuid("widget_id")
            guard let widget = SpaceStore.widget(id, in: context), widget.spaceIDString == SpaceJSON.key(space.id) else {
                throw ToolError("This Space has no widget with id \(id.uuidString).")
            }
            widget.isOnYou = args.bool("on_you_page") ?? false
            widget.updatedAt = .now
            try context.save()
            let types = SpaceStore.types(in: space, context: context)
            return SpaceTools.widget(widget, typeKey: types.first { SpaceJSON.key($0.id) == widget.typeIDString }?.key ?? "")
        },
        Tool(
            name: "list_space_widgets",
            description: "List the widgets of a Space, with their rows.",
            properties: ["space_id": spaceID], required: ["space_id"], readOnly: true
        ) { args, context in
            let space = try SpaceTools.space(args, in: context)
            let types = SpaceStore.types(in: space, context: context)
            return SpaceStore.widgets(in: space, context: context).map { widget in
                SpaceTools.widget(widget, typeKey: types.first { SpaceJSON.key($0.id) == widget.typeIDString }?.key ?? "")
            }
        },
        Tool(
            name: "remove_space_widget",
            description: "Remove a widget from a Space. Its data is not touched.",
            properties: ["space_id": spaceID, "widget_id": text("Widget id from list_space_widgets.")],
            required: ["space_id", "widget_id"], readOnly: false, destructive: true
        ) { args, context in
            let space = try SpaceTools.space(args, in: context)
            let id = try args.uuid("widget_id")
            guard let widget = SpaceStore.widget(id, in: context), widget.spaceIDString == SpaceJSON.key(space.id) else {
                throw ToolError("This Space has no widget with id \(id.uuidString).")
            }
            let name = widget.name
            try SpaceStore.delete(widget, in: context)
            return ["removed": name]
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
        if let projectLink = try args.optionalUUID("space_id") {
            if let id = projectLink {
                AssociationService.assignUserProject(try Lookup.space(id, in: context), on: item)
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
        if let stopLink = try args.optionalUUID("stop_id") {
            StopStore.assign(item, to: try stopLink.map { try Lookup.stop($0, in: context) }, in: context)
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
/// Tidying a Space: what an AI is shown, the plan it proposes, and applying the parts the user accepts.
enum CleanupStore {
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func clipped(_ text: String, to limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// The whole Space in brief, sized to be read in one go.
    static func review(_ project: Project) -> [String: Any] {
        let tasks = project.agendaItems.filter { $0.kind == .task }
        let tracks = project.threads.sorted { $0.updatedAt > $1.updatedAt }.map { track -> [String: Any] in
            let own = tasks.filter { item in item.liveTracks.contains { $0.id == track.id } }
            return [
                "id": track.id.uuidString,
                "title": track.title,
                "theme": track.theme?.displayName ?? "",
                "status": track.status.rawValue,
                "is_active": project.activeTrackID == track.id,
                "summary": clipped(track.summary.isEmpty ? track.body : track.summary, to: 240),
                "body_characters": track.body.count,
                "stops": track.stops.count,
                "open_tasks": own.count { !$0.isCompleted },
                "done_tasks": own.count { $0.isCompleted },
                "decisions": track.decisions.count,
                "notes": track.notes.count,
                "chats": track.conversations.count,
                "updated": day.string(from: track.updatedAt)
            ]
        }
        let decisions = project.decisions.sorted { $0.createdAt > $1.createdAt }.map { decision -> [String: Any] in
            [
                "id": decision.id.uuidString,
                "title": decision.title,
                "status": decision.status.rawValue,
                "track_id": decision.thread?.id.uuidString ?? "",
                "decision": clipped(decision.decision, to: 200),
                "created": day.string(from: decision.createdAt)
            ]
        }
        let open = tasks.filter { !$0.isCompleted }.sorted { $0.updatedAt > $1.updatedAt }.map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "title": item.displayTitle,
                "status": item.workflowStatus.rawValue,
                "track_ids": item.liveTracks.map(\.id.uuidString),
                "updated": day.string(from: item.updatedAt)
            ]
        }
        let notes = project.notes.sorted { $0.updatedAt > $1.updatedAt }.map { note -> [String: Any] in
            [
                "id": note.id.uuidString,
                "title": note.displayTitle,
                "track_id": note.thread?.id.uuidString ?? "",
                "characters": note.content.count,
                "updated": day.string(from: note.updatedAt)
            ]
        }
        return [
            "space_id": project.id.uuidString,
            "name": project.name,
            "current_direction": project.currentDirection,
            "brief": project.brief,
            "how_to": ContextBuilder.cleanupRules,
            "tracks": tracks,
            "decisions": decisions,
            "open_tasks": open,
            "notes": notes
        ]
    }

    static func proposed(for projectID: UUID, in context: ModelContext) -> CleanupPlan? {
        let key = projectID.uuidString.lowercased()
        let status = CleanupPlanStatus.proposed.rawValue
        var descriptor = FetchDescriptor<CleanupPlan>(
            predicate: #Predicate { $0.projectIDString == key && $0.statusRaw == status },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Checks every change against the Space and stores the plan. Replaces a plan still waiting.
    static func propose(
        for project: Project,
        summary: String,
        items: [[String: Any]],
        client: String = "",
        in context: ModelContext
    ) throws -> CleanupPlan {
        guard !items.isEmpty else { throw ToolError("A cleanup needs at least one change. If the Space is already tidy, say so and do not call this.") }
        var changes: [CleanupChange] = []
        var problems: [String] = []
        var touched: Set<String> = []
        var kept: Set<String> = []

        func id(_ item: [String: Any], _ key: String) -> UUID? {
            (item[key] as? String).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        func track(_ id: UUID?) -> ProjectThread? {
            guard let id else { return nil }
            return project.threads.first { $0.id == id }
        }
        func name(_ title: String) -> String { title.isEmpty ? "Untitled" : title }

        for (index, item) in items.enumerated() {
            let place = "Change \(index + 1)"
            let reason = (item["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { problems.append("\(place) needs a reason."); continue }
            guard let action = CleanupChange.Action(rawValue: item["action"] as? String ?? "") else {
                problems.append("\(place): action is merge_tracks, delete, or retire_decision.")
                continue
            }
            var change: CleanupChange?
            switch action {
            case .mergeTracks:
                guard let second = track(id(item, "track_id")), let first = track(id(item, "into_track_id")) else {
                    problems.append("\(place): track_id and into_track_id must both be tracks in this Space.")
                    continue
                }
                guard first.id != second.id else { problems.append("\(place) merges a track into itself."); continue }
                kept.insert(first.id.uuidString)
                change = CleanupChange(
                    action: action, targetType: "track", targetID: second.id.uuidString, intoID: first.id.uuidString,
                    title: name(second.title), intoTitle: name(first.title), reason: reason
                )
            case .delete:
                let type = item["target_type"] as? String ?? ""
                guard let target = id(item, "target_id") else { problems.append("\(place) needs target_id."); continue }
                var title: String?
                switch type {
                case "track": title = track(target).map { name($0.title) }
                case "task": title = project.agendaItems.first { $0.id == target && $0.kind == .task }?.displayTitle
                case "note": title = project.notes.first { $0.id == target }?.displayTitle
                case "decision": title = project.decisions.first { $0.id == target }.map { name($0.title) }
                default:
                    problems.append("\(place): target_type is track, task, note, or decision.")
                    continue
                }
                guard let title else { problems.append("\(place): no \(type) with that id in this Space."); continue }
                change = CleanupChange(action: action, targetType: type, targetID: target.uuidString, title: title, reason: reason)
            case .retireDecision:
                guard let target = id(item, "decision_id"), let decision = project.decisions.first(where: { $0.id == target }) else {
                    problems.append("\(place): decision_id must be a decision in this Space.")
                    continue
                }
                guard decision.status == .active else { problems.append("\(place): “\(decision.title)” is already retired."); continue }
                change = CleanupChange(action: action, targetType: "decision", targetID: target.uuidString, title: name(decision.title), reason: reason)
            }
            guard let change else { continue }
            guard touched.insert(change.targetID).inserted else {
                problems.append("\(place): “\(change.title)” is already in an earlier change.")
                continue
            }
            changes.append(change)
        }
        for change in changes where change.targetType == "track" && kept.contains(change.targetID) {
            problems.append("“\(change.title)” is merged away or deleted, and is also the track another merge continues as. Pick one track to keep and merge the others into it.")
        }
        if project.activeTrackID.map({ touched.contains($0.uuidString) }) == true {
            problems.append("The active track cannot be merged away or deleted. Merge the other track into it.")
        }
        guard problems.isEmpty else { throw ToolError(problems.joined(separator: " ")) }

        if let waiting = proposed(for: project.id, in: context) { context.delete(waiting) }
        let plan = CleanupPlan(
            project: project,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            changes: changes,
            client: client
        )
        context.insert(plan)
        project.touch()
        return plan
    }

    static func shape(_ plan: CleanupPlan) -> [String: Any] {
        [
            "id": plan.id.uuidString,
            "status": plan.status.rawValue,
            "summary": plan.summary,
            "changes": plan.changes.map { ["change": $0.sentence, "reason": $0.reason, "outcome": $0.outcome] },
            "next": "Nothing has changed. The user reviews this on the Space's page in the app and applies it there. Tell them it is ready."
        ]
    }

    static func setAccepted(_ accepted: Bool, change id: UUID, on plan: CleanupPlan) {
        var changes = plan.changes
        guard let index = changes.firstIndex(where: { $0.id == id }) else { return }
        changes[index].isAccepted = accepted
        plan.changes = changes
    }

    static func dismiss(_ plan: CleanupPlan, in context: ModelContext) {
        plan.status = .dismissed
        try? context.persist()
    }

    /// Makes the accepted changes, each through the same tool an agent would use, so each lands in Lately and
    /// can be taken back. Returns how many were made and how many could not be.
    @discardableResult
    static func apply(_ planID: UUID, container: ModelContainer) -> (done: Int, failed: Int) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let plan = try? context.fetch(FetchDescriptor<CleanupPlan>(predicate: #Predicate { $0.id == planID })).first,
              plan.status == .proposed else { return (0, 0) }
        var changes = plan.changes
        var done = 0
        var failed = 0
        let origin = ActionOrigin(client: plan.client.isEmpty ? "Membrae" : plan.client)
        for index in changes.indices where changes[index].isAccepted {
            let change = changes[index]
            let result: [String: Any]
            switch change.action {
            case .mergeTracks:
                result = Tools.call("merge_tracks", arguments: ["track_id": change.targetID, "into_track_id": change.intoID], container: container, announce: false, origin: origin)
            case .delete:
                result = Tools.call("delete_record", arguments: ["target_type": change.targetType, "target_id": change.targetID], container: container, announce: false, origin: origin)
            case .retireDecision:
                result = Tools.call("update_decision", arguments: ["decision_id": change.targetID, "status": DecisionStatus.superseded.rawValue], container: container, announce: false, origin: origin)
            }
            if result["isError"] as? Bool == true {
                changes[index].outcome = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "Could not be done."
                failed += 1
            } else {
                changes[index].outcome = "done"
                done += 1
            }
        }
        plan.changes = changes
        plan.status = .applied
        try? context.persist()
        Store.announceChange()
        return (done, failed)
    }
}

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
            saved["space"] = key(item.project?.id)
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
            saved["space"] = key(note.project?.id)
            saved["track"] = key(note.thread?.id)
            saved["tags"] = note.tags.map(\.id.uuidString)
        case .decision:
            let decision = try Lookup.decision(id, in: context)
            saved["title"] = decision.title
            saved["decision"] = decision.decision
            saved["rationale"] = decision.rationale
            saved["status"] = decision.statusRaw
            saved["superseded_by"] = key(decision.supersededByID)
            saved["created"] = stamp(decision.createdAt)
            saved["space"] = key(decision.project?.id)
            saved["track"] = key(decision.thread?.id)
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
            saved["space"] = key(track.project?.id)
            saved["parent"] = key(track.parent?.id)
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
            saved["space"] = key(chat.project?.id)
            saved["track"] = key(chat.thread?.id)
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
            "space_id": project?.id.uuidString ?? ""
        ]
    }

    /// Puts a deleted record back under its old id, with the links that still have something to point at.
    static func restore(_ saved: [String: Any], in context: ModelContext) throws {
        guard let kind = (saved["type"] as? String).flatMap(DeletableKind.init(rawValue:)), let id = uuid(saved["id"]) else {
            throw ToolError("This cannot be taken back.")
        }
        func text(_ key: String) -> String { saved[key] as? String ?? "" }
        func gone() -> ToolError { ToolError("Its Space is gone, so it cannot be brought back.") }
        func back() -> ToolError { ToolError("That \(kind.rawValue) is already back.") }

        var project: Project?
        // Rows written before every Space was one thing named it under "project".
        if let spaceID = uuid(saved["space"]) ?? uuid(saved["Space"]) {
            guard let found = try? Lookup.space(spaceID, in: context) else { throw gone() }
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
    static func space(_ id: UUID, in context: ModelContext) throws -> Space {
        guard let found = SpaceStore.space(id, in: context) else {
            throw ToolError("No Space with id \(id.uuidString).")
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

    static func stop(_ id: UUID, in context: ModelContext) throws -> TrackStop {
        guard let found = try context.fetch(FetchDescriptor<TrackStop>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No stop with id \(id.uuidString).")
        }
        return found
    }

    static func junction(_ id: UUID, in context: ModelContext) throws -> TrackJunction {
        guard let found = try context.fetch(FetchDescriptor<TrackJunction>(predicate: #Predicate { $0.id == id })).first else {
            throw ToolError("No junction with id \(id.uuidString).")
        }
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
            guard let project = note.project else { throw ToolError("That note has no Space.") }
            return (project, note.displayTitle)
        case .thread:
            let thread = try Self.thread(id, in: context)
            guard let project = thread.project else { throw ToolError("That track has no Space.") }
            return (project, thread.title.isEmpty ? "Untitled" : thread.title)
        case .decision:
            let decision = try Self.decision(id, in: context)
            guard let project = decision.project else { throw ToolError("That decision has no Space.") }
            return (project, decision.title.isEmpty ? "Untitled" : decision.title)
        case .conversation:
            let conversation = try Self.conversation(id, in: context)
            guard let project = conversation.project else { throw ToolError("That chat has no Space.") }
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
            throw ToolError("The replacement must be in the same Space.")
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

    /// One Space: what it is, what it holds, and where its work stands. `fullTypes` adds each
    /// type's fields; otherwise types are named only.
    static func space(_ space: Space, in context: ModelContext, fullTypes: Bool = false) -> [String: Any] {
        let types = SpaceStore.types(in: space, context: context)
        var shape: [String: Any] = [
            "id": space.id.uuidString,
            "name": space.displayName,
            "symbol": space.symbol,
            "status": space.status.rawValue,
            "summary": space.summary,
            "current_direction": space.currentDirection,
            "brief": space.brief,
            "is_pinned": PinStore.isPinned(space.id, in: context),
            "picture_shape": space.hasPortraitCards ? "portrait" : "landscape",
            "agent_notes": space.agentNotes,
            "last_activity": iso.string(from: space.lastActivity),
            "counts": [
                "decisions": space.decisions.count,
                "tracks": space.threads.count,
                "notes": space.notes.count,
                "chats": space.conversations.filter { !$0.isArchived }.count,
                "tasks": space.agendaItems.filter { $0.kind == .task }.count,
                "records": space.collects ? SpaceStore.records(in: space, context: context).count : 0
            ],
            "types": fullTypes
                ? types.map { SpaceTools.type($0, in: context) }
                : types.map { ["key": $0.key, "name": $0.name, "role": $0.role.rawValue] }
        ]
        if let track = space.activeTrack {
            shape["active_track"] = ["id": track.id.uuidString, "title": track.title]
        }
        if let next = TaskStore.nextTask(in: space) {
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
            "is_next": TaskStore.isNext(item),
            "space_id": item.project?.id.uuidString ?? "",
            "space_name": item.project?.name ?? "",
            "repeat": item.repeatRule.rawValue,
            "blocked_reason": item.blockedReason,
            "tracks": item.liveTracks.map { ["id": $0.id.uuidString, "title": $0.title] },
            "stop": item.stop.map { ["id": $0.id.uuidString, "title": $0.displayTitle] } ?? [:],
            "linked_notes": item.liveNotes.map { ["id": $0.id.uuidString, "title": $0.displayTitle] },
            "blockers": item.unresolvedBlockers.map {
                [
                    "id": $0.id.uuidString,
                    "title": $0.displayTitle,
                    "space_name": $0.project?.name ?? ""
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
            "space_id": completion.project?.id.uuidString ?? "",
            "task_id": completion.parentTask?.id.uuidString ?? ""
        ]
    }

    static func decision(_ decision: Decision) -> [String: Any] {
        var shape: [String: Any] = [
            "id": decision.id.uuidString,
            "space_id": decision.project?.id.uuidString ?? "",
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

    static func stop(_ stop: TrackStop) -> [String: Any] {
        [
            "id": stop.id.uuidString,
            "title": stop.displayTitle,
            "body": stop.body,
            "is_done": stop.isDone,
            "tasks": stop.tasks
                .filter { $0.kind == .task }
                .sorted { $0.createdAt < $1.createdAt }
                .map { ["id": $0.id.uuidString, "title": $0.displayTitle, "status": $0.workflowStatus.rawValue] }
        ]
    }

    static func junction(_ junction: TrackJunction) -> [String: Any] {
        func track(_ thread: ProjectThread?) -> [String: Any] {
            ["id": thread?.id.uuidString ?? "", "title": thread?.title ?? ""]
        }
        return [
            "id": junction.id.uuidString,
            "kind": junction.kind.rawValue,
            "first_track": track(junction.first),
            "second_track": track(junction.second),
            "held_stop_id": junction.heldStop?.id.uuidString ?? "",
            "is_met": junction.isMet,
            "requirements": junction.orderedRequirements.map { requirement in
                [
                    "id": requirement.id.uuidString,
                    "text": requirement.displayText,
                    "stop_id": requirement.stop?.id.uuidString ?? "",
                    "task_id": requirement.task?.id.uuidString ?? "",
                    "is_done": requirement.isMet
                ] as [String: Any]
            }
        ]
    }

    static func track(_ thread: ProjectThread, full: Bool) -> [String: Any] {
        var shape: [String: Any] = [
            "id": thread.id.uuidString,
            "space_id": thread.project?.id.uuidString ?? "",
            "title": thread.title,
            "kind": thread.kind.rawValue,
            "status": thread.status.rawValue,
            "summary": thread.summary,
            "parent_id": thread.parent?.id.uuidString ?? "",
            "is_active": thread.project?.activeTrackID == thread.id,
            "theme": thread.theme?.displayName ?? "",
            "departed_at": iso.string(from: thread.departedAt),
            "arrived_at": thread.arrivedAt.map { iso.string(from: $0) } ?? "",
            "fare_days": thread.fareDays,
            "fare_ends_at": thread.fareEndsAt.map { iso.string(from: $0) } ?? "",
            "updated_at": iso.string(from: thread.updatedAt),
            "tags": tags(thread.tags)
        ]
        if full {
            shape["body"] = thread.body
            shape["stops"] = thread.orderedStops.map(stop)
            shape["junctions"] = thread.junctions.map(junction)
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
            "space_id": conversation.project?.id.uuidString ?? "",
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
            "space_ids": source.projects.map(\.id.uuidString),
            "space_id": source.projects.first?.id.uuidString ?? "",
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
            "space_id": note.project?.id.uuidString ?? "",
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
            "space_id": run.project?.id.uuidString ?? "",
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
            shape["steps"] = run.steps.map { ["title": $0.title, "done": $0.done] }
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
        try Lookup.space(try args.uuid("space_id"), in: context)
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

    /// A widget's rows: a list of lists of blocks, also accepted as a JSON string.
    static func widgetRows(_ args: Args) throws -> [[SpaceComponent]] {
        var raw = args.raw["rows"]
        if let text = raw as? String {
            raw = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        }
        guard let rows = raw as? [[[String: Any]]] else {
            throw ToolError("rows must be a list of rows, and each row a list of blocks.")
        }
        return try rows.map(components)
    }

    static func widget(_ widget: AreaWidget, typeKey: String) -> [String: Any] {
        [
            "id": widget.id.uuidString,
            "name": widget.name,
            "type_key": typeKey,
            "size": widget.size.rawValue,
            "rows": widget.definition.rows.map(json),
            "link": "membrae://widget/\(widget.id.uuidString)",
            "on_you_page": widget.isOnYou
        ]
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
        if let chosen = type.cardFields { shape["card_fields"] = chosen }
        if !type.layoutRaw.isEmpty { shape["layout"] = type.layoutRaw }
        return shape
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
            "how_to": "1. create_space, unless you were given a space id. 2. set_space_type for each event type first. 3. set_space_type for each object type. Do not build screens: the app draws every Space itself from the fields. 4. set_space_widget for anything worth a glance. Widgets name fields by id and events by key. Every record already has a name; do not add a name field.",
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
            "blocks": SpaceScreenCatalog.components.map { spec -> [String: Any] in
                [
                    "component": spec.name,
                    "does": spec.summary,
                    "takes_children": spec.takesChildren,
                    "settings": spec.props.map { prop -> [String: Any] in
                        ["name": prop.name, "accepts": accepts(prop.kind), "required": prop.required, "note": prop.note]
                    }
                ]
            },
            "widgets": [
                "what": "A widget is a small card about one object type, made with set_space_widget. It is rows of blocks, listed under blocks.",
                "sizes": AreaWidgetSize.allCases.map { size -> [String: Any] in
                    ["size": size.rawValue, "rows": size.maxRows, "blocks_per_row": size.maxAcross]
                },
                "example": [
                    "name": "Weight",
                    "size": "2x1",
                    "rows": [
                        [
                            ["component": "metric", "value": "avg:weighed.weight:week", "label": "Average this week"],
                            ["component": "metric", "value": "change:weighed.weight:month", "label": "Change this month"]
                        ],
                        [["component": "chart", "events": "weighed", "field": "weight", "period": "month"]]
                    ]
                ] as [String: Any]
            ] as [String: Any],
            "defaults": "Any field can take default: what a new record starts with. A number, an option id, true, or today for a date.",
            "roles": [
                "object": "a lasting thing with many records, such as recipes",
                "event": "something logged about records, such as cooked",
                "settings": "exactly one record for the whole Space, such as daily targets. Other types read it in formulas as key.field."
            ],
            "calculations": [
                "count:eventKey": "how many events",
                "latest:eventKey": "when the newest event happened, as a day. Not its value",
                "streak:eventKey": "days in a row with an event",
                "best:eventKey": "longest run of days with an event",
                "week:eventKey": "events in the last seven days",
                "pace:eventKey": "where the record stands against its schedule: 2 of 3 this week, or done today",
                "sum:eventKey.field:period": "a logged number added up. period is today, week, month, year or all. The field belongs to the event: to add up something about the records the events are about, give the event a number field and copy the value into it when you log, such as sum:eaten.calories:today",
                "avg:eventKey.field:period": "the average of a logged number",
                "min:eventKey.field:period": "the smallest logged number",
                "max:eventKey.field:period": "the largest logged number",
                "last:eventKey.field": "the most recent reading of a logged number, such as the latest weight. Use this, not latest, to show a current value",
                "change:eventKey.field:period": "how far a logged number has moved since the period began, such as weight this month",
                "count:eventKey:period": "how many events in a period",
                "today:eventKey": "records with an event today, out of all",
                "records": "how many records"
            ],
            "example": [
                "type": ["key": recipe.key, "name": recipe.name, "role": "object", "fields": recipe.fields.map(field)],
                "event_type": ["key": "cooked", "name": "Cooked", "role": "event"]
            ]
        ]
    }
}

// MARK: - Calendar and Reminders

/// Calendar and Reminders through EventKit. macOS grants access to Membrae, so
/// this process has it only when Membrae started it.
enum Agenda {
    enum Repeat: String, CaseIterable {
        case daily, weekly, monthly, yearly

        var frequency: EKRecurrenceFrequency {
            switch self {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
        }
    }

    private static let store = EKEventStore()

    static func context() -> [String: Any] {
        let events = allowed(.event)
        let reminders = allowed(.reminder)
        var shape: [String: Any] = [
            "now": stamp(.now),
            "time_zone": TimeZone.current.identifier,
            "calendar_access": events,
            "reminders_access": reminders
        ]
        if events {
            shape["calendars"] = names(.event)
            shape["default_calendar"] = store.defaultCalendarForNewEvents?.title ?? ""
        }
        if reminders {
            shape["reminder_lists"] = names(.reminder)
            shape["default_reminder_list"] = store.defaultCalendarForNewReminders()?.title ?? ""
        }
        return shape
    }

    static func createEvent(_ args: Args) throws -> [String: Any] {
        try require(.event)
        let title = try args.required("title")
        guard let start = try moment("start", in: args) else { throw ToolError("start is required.") }
        let end = try moment("end", in: args)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = try list(args.string("calendar"), for: .event)
        if args.bool("all_day") ?? start.dayOnly {
            let calendar = Calendar.current
            let first = calendar.startOfDay(for: start.date)
            let last = calendar.startOfDay(for: max(start.date, end?.date ?? start.date))
            event.startDate = first
            event.endDate = calendar.date(byAdding: .day, value: 1, to: last) ?? last
            event.isAllDay = true
        } else {
            event.startDate = start.date
            event.endDate = max(end?.date ?? start.date.addingTimeInterval(3600), start.date)
        }
        if let location = args.string("location"), !location.isEmpty { event.location = location }
        if let notes = args.string("notes"), !notes.isEmpty { event.notes = notes }
        try store.save(event, span: .thisEvent, commit: true)
        return [
            "title": title,
            "start": stamp(event.startDate),
            "end": stamp(event.endDate),
            "all_day": event.isAllDay,
            "calendar": event.calendar.title
        ]
    }

    static func createReminder(_ args: Args) throws -> [String: Any] {
        try require(.reminder)
        let title = try args.required("title")
        let due = try moment("due", in: args)
        let repeats = try args.choice("repeat", as: Repeat.self)
        if repeats != nil, due == nil { throw ToolError("A repeating reminder needs due.") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = try list(args.string("list"), for: .reminder)
        if let notes = args.string("notes"), !notes.isEmpty { reminder.notes = notes }
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                due.dayOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute],
                from: due.date
            )
            if !due.dayOnly { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        if let repeats {
            reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: repeats.frequency, interval: 1, end: nil)]
        }
        try store.save(reminder, commit: true)
        var shape: [String: Any] = ["title": title, "list": reminder.calendar.title]
        if let due { shape["due"] = due.dayOnly ? String(stamp(due.date).prefix(10)) : stamp(due.date) }
        if let repeats { shape["repeat"] = repeats.rawValue }
        return shape
    }

    private static func allowed(_ entity: EKEntityType) -> Bool {
        let status = EKEventStore.authorizationStatus(for: entity)
        return status == .fullAccess || (entity == .event && status == .writeOnly)
    }

    private static func require(_ entity: EKEntityType) throws {
        guard allowed(entity) else {
            let name = entity == .event ? "Calendar" : "Reminders"
            throw ToolError("\(name) is not available here. Allow \(name) for Membrae in System Settings, Privacy & Security, and ask from a chat inside Membrae.")
        }
    }

    private static func names(_ entity: EKEntityType) -> [String] {
        store.calendars(for: entity).filter(\.allowsContentModifications).map(\.title).sorted()
    }

    private static func list(_ name: String?, for entity: EKEntityType) throws -> EKCalendar {
        let kind = entity == .event ? "calendar" : "reminders list"
        let writable = store.calendars(for: entity).filter(\.allowsContentModifications)
        if let name, !name.isEmpty {
            if let match = writable.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { return match }
            throw ToolError("No \(kind) named \(name). Choose from: \(names(entity).joined(separator: ", ")).")
        }
        let preferred = entity == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let found = preferred ?? writable.first else { throw ToolError("There is no \(kind) to add to.") }
        return found
    }

    /// A time with an offset, a time in the Mac's zone without one, or a bare day.
    private static func moment(_ key: String, in args: Args) throws -> (date: Date, dayOnly: Bool)? {
        guard let value = args.string(key), !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: value) { return (date, false) }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for (format, dayOnly) in [("yyyy-MM-dd'T'HH:mm:ss", false), ("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd", true)] {
            local.dateFormat = format
            if let date = local.date(from: value) { return (date, dayOnly) }
        }
        throw ToolError("\(key) must be an ISO-8601 date, such as 2026-01-31T15:00:00 or 2026-01-31.")
    }

    private static func stamp(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        return iso.string(from: date)
    }
}
