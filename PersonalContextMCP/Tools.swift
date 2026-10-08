import Foundation
import SwiftData

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
        guard let parsed = T(rawValue: value.lowercased()) else {
            let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolError("\(key) must be one of: \(allowed).")
        }
        return parsed
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
            description: "Get one project: its fields, a context summary, and every decision, thread, and note with ids.",
            properties: ["project_id": projectID], required: ["project_id"], readOnly: true
        ) { args, context in
            let project = try Lookup.project(try args.uuid("project_id"), in: context)
            var shape = JSONShape.project(project)
            shape["context"] = ContextBuilder.package(for: project)
            shape["decisions"] = project.decisions.sorted { $0.createdAt > $1.createdAt }.map(JSONShape.decision)
            shape["threads"] = project.threads.sorted { $0.createdAt < $1.createdAt }.map { JSONShape.thread($0, full: false) }
            shape["notes"] = project.notes.sorted { $0.updatedAt > $1.updatedAt }.map { JSONShape.note($0, full: false) }
            shape["deletion_marks"] = project.deletionMarks
                .sorted { $0.createdAt > $1.createdAt }
                .map(JSONShape.deletionMark)
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
            if let status = try args.choice("status", as: ProjectStatus.self) { project.status = status }
            if let pinned = args.bool("is_pinned") { project.isPinned = pinned }
            if let symbol = args.string("symbol"), !symbol.isEmpty { project.symbol = symbol }
            project.touch()
            return JSONShape.project(project)
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
            description: "Get one thread with its full body and linked decisions and notes.",
            properties: ["thread_id": text("Thread id.")], required: ["thread_id"], readOnly: true
        ) { args, context in
            let thread = try Lookup.thread(try args.uuid("thread_id"), in: context)
            var shape = JSONShape.thread(thread, full: true)
            shape["decisions"] = thread.decisions.map(JSONShape.decision)
            shape["notes"] = thread.notes.map { JSONShape.note($0, full: false) }
            return shape
        },
        Tool(
            name: "create_thread",
            description: "Start a thread: a line of work such as a direction, feature, problem, experiment, or topic.",
            properties: [
                "project_id": projectID,
                "title": text("Thread title."),
                "kind": options(ThreadKind.self, "Kind of thread. Defaults to topic."),
                "status": options(ThreadStatus.self, "Defaults to exploring."),
                "summary": text("One or two sentences."),
                "body": text("Markdown body."),
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
                "body": text("Replaces the whole markdown body."),
                "append_to_body": text("Markdown appended to the end of the body."),
                "parent_id": text("New parent thread id. Empty string makes it a top-level thread.")
            ],
            required: ["thread_id"], readOnly: false
        ) { args, context in
            let thread = try Lookup.thread(try args.uuid("thread_id"), in: context)
            if let title = args.string("title"), !title.isEmpty { thread.title = title }
            if let kind = try args.choice("kind", as: ThreadKind.self) { thread.kind = kind }
            if let status = try args.choice("status", as: ThreadStatus.self) { thread.status = status }
            if let summary = args.string("summary") { thread.summary = summary }
            if let body = args.string("body") { thread.body = body }
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
        }
    ]
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
        [
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
                "notes": project.notes.count
            ]
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
            shape["children"] = thread.orderedChildren.map { ["id": $0.id.uuidString, "title": $0.title] }
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

    private static func attachMark(_ shape: inout [String: Any], id: UUID, project: Project?) {
        if let mark = project?.deletionMarks.first(where: { $0.targetID == id }) {
            shape["deletion_mark"] = deletionMark(mark)
        }
    }
}
