import Foundation
import SwiftData

enum ImportToolHost {
    static let allowed = ["list_spaces", "create_space", "create_track", "create_note", "create_decision", "save_about_user"]

    static let instructions = """
    Membrae import is one-way. A Space is one container for a part of the user's life or work. \
    Use list_spaces or create_space, then create a new track for this conversation and add notes \
    and decisions under that track. Do not invent a space id. Existing tracks, notes, and \
    decisions are not available. \
    When the user asks to save what you know about them, call save_about_user. Never call it \
    unless they asked.
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
            let versions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            return result(id, [
                "protocolVersion": versions.contains(requested) ? requested : "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "membrae-import", "version": "1.2.0"],
                "instructions": instructions
            ])
        case "server/discover":
            return result(id, [
                "resultType": "complete",
                "supportedVersions": ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"],
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": instructions,
                "_meta": ["io.modelcontextprotocol/serverInfo": ["name": "membrae-import", "version": "1.2.0"]]
            ])
        case "ping", "initialized", "notifications/initialized":
            return result(id, [:] as [String: Any])
        case "tools/list":
            return result(id, ["tools": definitions])
        case "resources/list":
            return result(id, ["resources": [] as [Any]])
        case "prompts/list":
            return result(id, ["prompts": [] as [Any]])
        case "tools/call":
            let name = canonical(params["name"] as? String ?? "")
            let arguments = migrate(params["arguments"] as? [String: Any] ?? [:])
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
            if name != "list_spaces" {
                try context.persist()
            }
            let encoded = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let payload: [String: Any] = ["content": [["type": "text", "text": String(decoding: encoded, as: UTF8.self)]]]
            let response = result(id, payload)
            if name != "list_spaces" {
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
        case "list_spaces":
            return try context.fetch(FetchDescriptor<Space>())
                .sorted { $0.lastActivity > $1.lastActivity }
                .map { ["id": $0.id.uuidString, "name": $0.name, "summary": $0.summary] }
        case "create_space":
            let space = Space(
                name: try args.required("name"),
                symbol: args.string("symbol") ?? "square.grid.2x2",
                summary: args.string("summary") ?? ""
            )
            space.currentDirection = args.string("current_direction") ?? ""
            context.insert(space)
            ImportKeyStore.recordImport(.init(kind: "Space", title: space.name, projectName: space.name, at: .now), in: &metadata)
            return ["id": space.id.uuidString, "name": space.name, "summary": space.summary]
        case "create_track":
            let project = try space(args.uuid("space_id"), in: context)
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
            let project = try space(args.uuid("space_id"), in: context)
            let thread = try allowedThread(args.optionalUUID("track_id"), project: project, metadata: metadata)
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
            let project = try space(args.uuid("space_id"), in: context)
            let thread = try allowedThread(args.optionalUUID("track_id"), project: project, metadata: metadata)
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
        case "save_about_user":
            let items = (arguments["facts"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            var saved: [[String: Any]] = []
            for item in items.prefix(100) {
                guard let fact = try FactStore.add(
                    item["text"] as? String ?? "",
                    category: item["category"] as? String ?? "",
                    source: .agent,
                    origin: client,
                    in: context
                ) else { continue }
                saved.append(["id": fact.id.uuidString, "text": fact.text, "category": fact.category])
            }
            guard let first = saved.first else {
                throw ImportToolError("facts is required: a list of {text, category}.")
            }
            ImportKeyStore.recordImport(.init(kind: "Fact", title: first["text"] as? String ?? "", projectName: "About you", at: .now), in: &metadata)
            return ["saved": saved.count, "facts": saved]
        default:
            throw ImportToolError("This tool is not available.")
        }
    }

    private static func space(_ id: UUID, in context: ModelContext) throws -> Space {
        guard let space = SpaceStore.space(id, in: context) else {
            throw ImportToolError("That Space does not exist.")
        }
        return space
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
            tool("list_spaces", "List Spaces", "List every Space. Each item is id, name, and summary only. Pick a Space by name, or create_space. Do not invent a space id.", [:], [], true),
            tool("create_space", "Create Space", "Create a Space, then file a new track and notes under it.", [
                "name": text("Space name."),
                "summary": text("What the Space is."),
                "current_direction": text("Where the work is heading right now."),
                "symbol": text("SF Symbol name for the icon.")
            ], ["name"], false),
            tool("create_track", "Create track", "Start a new track in this import.", [
                "space_id": text("Space id from list_spaces or create_space."),
                "title": text("Track title."),
                "kind": enumText(ThreadKind.self, "Kind of track. Defaults to topic."),
                "status": enumText(ThreadStatus.self, "Defaults to exploring."),
                "summary": text("One or two sentences."),
                "body": text("Markdown spec."),
                "parent_id": text("Parent track id created in this import.")
            ], ["space_id", "title"], false),
            tool("create_note", "Create note", "Add a note. source is ignored; Membrae sets it.", [
                "space_id": text("Space id from list_spaces or create_space."),
                "title": text("Note title."),
                "content": text("Markdown content."),
                "track_id": text("Track id created in this import. Omit for a note on the Space itself.")
            ], ["space_id", "content"], false),
            tool("create_decision", "Create decision", "Record a new decision. Cannot replace an existing one.", [
                "space_id": text("Space id from list_spaces or create_space."),
                "title": text("Short name for the decision."),
                "decision": text("What was decided."),
                "rationale": text("Why."),
                "track_id": text("Track id created in this import.")
            ], ["space_id", "title", "decision"], false),
            tool("save_about_user", "Save what you know about me", "Only when the user asks for it. Save what you know or have inferred about the user, from this conversation and from your memory of them. One plain sentence per fact, in your own words, including what you would not normally say back to them. Do not soften or leave things out. The user reads these in Membrae under About you.", [
                "facts": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": text("One thing you know or believe about the user."),
                            "category": text("One or two words, such as work, health, preferences, or personality.")
                        ],
                        "required": ["text"],
                        "additionalProperties": false
                    ],
                    "description": "Everything you hold about the user, one fact each."
                ]
            ], ["facts"], false)
        ]
    }

    private static func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any], _ required: [String], _ readOnly: Bool) -> [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]
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
            "space_id": thread.project?.id.uuidString ?? "",
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
            "space_id": note.project?.id.uuidString ?? "",
            "title": note.displayTitle,
            "content": note.content,
            "source": note.source,
            "track_id": note.thread?.id.uuidString ?? ""
        ]
    }

    private static func decisionShape(_ decision: Decision) -> [String: Any] {
        [
            "id": decision.id.uuidString,
            "space_id": decision.project?.id.uuidString ?? "",
            "title": decision.title,
            "decision": decision.decision,
            "rationale": decision.rationale,
            "track_id": decision.thread?.id.uuidString ?? ""
        ]
    }

    /// Names a connector may still send from before every Space was one thing.
    private static func canonical(_ name: String) -> String {
        switch name {
        case "create_thread": "create_track"
        case "list_projects": "list_spaces"
        case "create_project": "create_space"
        default: name
        }
    }

    private static func migrate(_ arguments: [String: Any]) -> [String: Any] {
        var next = arguments
        if next["track_id"] == nil, let old = next["thread_id"] {
            next["track_id"] = old
        }
        if next["space_id"] == nil, let old = next["project_id"] {
            next["space_id"] = old
        }
        return next
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
        guard let id = UUID(uuidString: value) else { throw ImportToolError("That Space does not exist.") }
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
