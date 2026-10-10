import Foundation
import SwiftData

enum ImportToolHost {
    static let allowed = ["list_projects", "create_thread", "create_note", "create_decision"]

    static let instructions = """
    Membrae import is one-way. Pick a project by name from list_projects, create a new track \
    for this conversation, then add notes and decisions under that track. Do not invent a \
    project id. Existing tracks, notes, and decisions are not available.
    """

    static func handle(
        rpc: [String: Any],
        client: String,
        container: ModelContainer,
        metadata: inout ImportKeyMetadata
    ) -> [String: Any] {
        let id = rpc["id"]
        let method = rpc["method"] as? String ?? ""
        let params = rpc["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return result(id, [
                "protocolVersion": ["2025-06-18", "2025-03-26", "2024-11-05"].contains(requested) ? requested : "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "membrae-import", "version": "1.0"],
                "instructions": instructions
            ])
        case "ping", "initialized", "notifications/initialized":
            return result(id, [:] as [String: Any])
        case "tools/list":
            return result(id, ["tools": definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return call(id, name: name, arguments: arguments, client: client, container: container, metadata: &metadata)
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    private static func call(
        _ id: Any?,
        name: String,
        arguments: [String: Any],
        client: String,
        container: ModelContainer,
        metadata: inout ImportKeyMetadata
    ) -> [String: Any] {
        guard allowed.contains(name) else {
            return toolFailure(id, "This tool is not available.")
        }
        if name == "create_decision", arguments["supersedes_id"] != nil {
            return toolFailure(id, "Import cannot replace an existing decision. Create a new one.")
        }
        let fingerprint = ImportKeyStore.fingerprint(tool: name, arguments: arguments, idempotency: "")
        if let cached = ImportKeyStore.cachedResult(fingerprint: fingerprint, in: metadata),
           let object = (try? JSONSerialization.jsonObject(with: Data(cached.utf8))) as? [String: Any] {
            return object
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let value = try invoke(name, arguments: arguments, client: client, context: context, metadata: &metadata)
            if name != "list_projects" {
                try context.save()
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(Store.changedNotification as CFString),
                    nil, nil, true
                )
            }
            let encoded = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let payload: [String: Any] = ["content": [["type": "text", "text": String(decoding: encoded, as: UTF8.self)]]]
            let response = result(id, payload)
            if name != "list_projects" {
                ImportKeyStore.storeResult(
                    fingerprint: fingerprint,
                    resultJSON: String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8) ?? "",
                    in: &metadata
                )
            }
            return response
        } catch let error as ImportToolError {
            return toolFailure(id, error.message)
        } catch {
            return toolFailure(id, error.localizedDescription)
        }
    }

    private static func invoke(
        _ name: String,
        arguments: [String: Any],
        client: String,
        context: ModelContext,
        metadata: inout ImportKeyMetadata
    ) throws -> Any {
        let args = ImportArgs(arguments)
        switch name {
        case "list_projects":
            return try context.fetch(FetchDescriptor<Project>())
                .sorted { $0.lastActivity > $1.lastActivity }
                .map { ["id": $0.id.uuidString, "name": $0.name, "summary": $0.summary] }
        case "create_thread":
            let project = try project(args.uuid("project_id"), in: context)
            let parent = try allowedThread(args.optionalUUID("parent_id"), project: project, metadata: metadata)
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
            ImportKeyStore.rememberTrack(thread.id, in: &metadata)
            ImportKeyStore.recordImport(.init(kind: "Track", title: thread.title, projectName: project.name, at: .now), in: &metadata)
            return threadShape(thread)
        case "create_note":
            let project = try project(args.uuid("project_id"), in: context)
            let thread = try allowedThread(args.optionalUUID("thread_id"), project: project, metadata: metadata)
            let note = Note(
                content: try args.required("content"),
                project: project,
                title: args.string("title") ?? "",
                source: client,
                thread: thread
            )
            context.insert(note)
            project.touch()
            ImportKeyStore.recordImport(.init(kind: "Note", title: note.displayTitle, projectName: project.name, at: .now), in: &metadata)
            return noteShape(note)
        case "create_decision":
            let project = try project(args.uuid("project_id"), in: context)
            let thread = try allowedThread(args.optionalUUID("thread_id"), project: project, metadata: metadata)
            let decision = Decision(
                title: try args.required("title"),
                decision: try args.required("decision"),
                project: project,
                rationale: args.string("rationale") ?? "",
                thread: thread
            )
            context.insert(decision)
            project.touch()
            ImportKeyStore.recordImport(.init(kind: "Decision", title: decision.title, projectName: project.name, at: .now), in: &metadata)
            return decisionShape(decision)
        default:
            throw ImportToolError("This tool is not available.")
        }
    }

    private static func project(_ id: UUID, in context: ModelContext) throws -> Project {
        let projects = try context.fetch(FetchDescriptor<Project>())
        guard let project = projects.first(where: { $0.id == id }) else {
            throw ImportToolError("That project does not exist.")
        }
        return project
    }

    private static func allowedThread(_ id: UUID?, project: Project, metadata: ImportKeyMetadata) throws -> ProjectThread? {
        guard let id else { return nil }
        guard metadata.createdTrackIDs.contains(id),
              let thread = project.threads.first(where: { $0.id == id }) else {
            throw ImportToolError("Create a new track in this import, then file under it. Existing tracks are not available.")
        }
        return thread
    }

    private static var definitions: [[String: Any]] {
        [
            tool("list_projects", "List every project. Each item is id, name, and summary only. Pick a project by name, then create a new track for this import. Do not invent a project id.", [:], [], true),
            tool("create_thread", "Start a new track in this import.", [
                "project_id": text("Project id from list_projects."),
                "title": text("Thread title."),
                "kind": enumText(ThreadKind.self, "Kind of thread. Defaults to topic."),
                "status": enumText(ThreadStatus.self, "Defaults to exploring."),
                "summary": text("One or two sentences."),
                "body": text("Markdown spec."),
                "parent_id": text("Parent track id created in this import.")
            ], ["project_id", "title"], false),
            tool("create_note", "Add a note. source is ignored; Membrae sets it.", [
                "project_id": text("Project id from list_projects."),
                "title": text("Note title."),
                "content": text("Markdown content."),
                "thread_id": text("Track id created in this import. Omit for a project-level note.")
            ], ["project_id", "content"], false),
            tool("create_decision", "Record a new decision. Cannot replace an existing one.", [
                "project_id": text("Project id from list_projects."),
                "title": text("Short name for the decision."),
                "decision": text("What was decided."),
                "rationale": text("Why."),
                "thread_id": text("Track id created in this import.")
            ], ["project_id", "title", "decision"], false)
        ]
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String], _ readOnly: Bool) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false]
        ]
    }

    private static func text(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func enumText<T: RawRepresentable & CaseIterable>(_ type: T.Type, _ description: String) -> [String: Any] where T.RawValue == String {
        ["type": "string", "enum": T.allCases.map(\.rawValue), "description": description]
    }

    private static func threadShape(_ thread: ProjectThread) -> [String: Any] {
        [
            "id": thread.id.uuidString,
            "project_id": thread.project?.id.uuidString ?? "",
            "title": thread.title,
            "kind": thread.kind.rawValue,
            "status": thread.status.rawValue,
            "summary": thread.summary,
            "body": thread.body,
            "parent_id": thread.parent?.id.uuidString ?? ""
        ]
    }

    private static func noteShape(_ note: Note) -> [String: Any] {
        [
            "id": note.id.uuidString,
            "project_id": note.project?.id.uuidString ?? "",
            "title": note.displayTitle,
            "content": note.content,
            "source": note.source,
            "thread_id": note.thread?.id.uuidString ?? ""
        ]
    }

    private static func decisionShape(_ decision: Decision) -> [String: Any] {
        [
            "id": decision.id.uuidString,
            "project_id": decision.project?.id.uuidString ?? "",
            "title": decision.title,
            "decision": decision.decision,
            "rationale": decision.rationale,
            "thread_id": decision.thread?.id.uuidString ?? ""
        ]
    }

    private static func result(_ id: Any?, _ value: [String: Any]) -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "result": value]
        if let id { message["id"] = id }
        return message
    }

    private static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        var payload: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { payload["id"] = id }
        return payload
    }

    private static func toolFailure(_ id: Any?, _ message: String) -> [String: Any] {
        result(id, ["content": [["type": "text", "text": message]], "isError": true])
    }
}

struct ImportToolError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

private struct ImportArgs {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func string(_ key: String) -> String? {
        guard let value = raw[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw ImportToolError("\(key) is required.") }
        return value
    }

    func uuid(_ key: String) throws -> UUID {
        let value = try required(key)
        guard let id = UUID(uuidString: value) else { throw ImportToolError("That project does not exist.") }
        return id
    }

    func optionalUUID(_ key: String) throws -> UUID? {
        guard let value = string(key) else { return nil }
        guard let id = UUID(uuidString: value) else {
            throw ImportToolError("Create a new track in this import, then file under it. Existing tracks are not available.")
        }
        return id
    }

    func choice<T: RawRepresentable & CaseIterable>(_ key: String, as type: T.Type) throws -> T? where T.RawValue == String {
        guard let value = string(key) else { return nil }
        if let parsed = T(rawValue: value) { return parsed }
        let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
        throw ImportToolError("\(key) must be one of: \(allowed).")
    }
}
