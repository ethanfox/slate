import Foundation
import SwiftData

let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

let instructions = """
Membrae is the user's knowledge base. It is made of Spaces: one container for each part of their life or work, \
such as a product they are building, a job search, their recipes, or their habits. Every tool that files something takes a space_id from list_spaces. \
A Space holds lines of work (decisions, tracks, notes, tasks), records of its own types (set with set_space_type), or both. \
Decisions are what was decided and why. A track is a line of work, broken into ordered stops: each stop is one idea inside it, most important first. \
get_track lists the stops, set_stops rewrites them, and stop_id puts a task on one. Break a track down with stops, not with child tracks: tracks do not nest. \
A theme is a named group of tracks, set with theme on create_track or update_track; it holds no work of its own. \
A junction sits between two tracks, in any themes, and is shown on get_track. A wait, the usual kind, holds the second track until the first has done what the junction requires. \
A merge is for two tracks that turn out to be the same work: its requirements are the gaps and conflicts to reconcile first, and merge_tracks then makes them one. Use set_junction for both. \
Active decisions are the source of truth. A Space can have one active track, shown as active_track on the Space: \
it is the work in hand. When asked what to work on or what is open, start from the active track and its tasks, \
and check the newest decisions before trusting an older task. Answer the user first. When they state a fact, choice, or plan, persist it \
here after you start the reply instead of asking them to save it. Do not mention the save unless they asked. \
Read before you write so you update an existing record rather than duplicating it. \
When a decision replaces an older one, create the new decision with supersedes_id. \
Use the task tools to list, create, update, and complete Membrae tasks. complete_task records repeat history; \
do not set status to done on a repeating task. \
\(ContextBuilder.knowledgeRules) \
\(ContextBuilder.agendaRules) \
\(ContextBuilder.spaceRules) \
get_space is lean. Use get_track for a track body and its linked work, list_tasks with track_id for tasks, \
get_note for reference material, and list_chats then get_chat to read a past conversation. \
A Space's brief is the one sentence that leads its page; when the direction or the next task changes, update it with update_space. \
When asked to tidy, clean up, or consolidate a Space, call get_cleanup_review and then propose_cleanup; the user applies the proposal in the app. \
Tags are sparse cross-cutting labels. Use list_tags, create_tag, assign_tag, and remove_tag on notes, tracks, decisions, conversations, and tasks. Do not tag Spaces. \
\(ContextBuilder.deletionRules)
"""

func write(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func respond(_ id: Any, result: [String: Any]) {
    write(["jsonrpc": "2.0", "id": id, "result": result])
}

func respond(_ id: Any, code: Int, message: String) {
    write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("membrae-mcp: \(message)\n".utf8))
}

func requestID(_ value: Any?) -> Any? {
    guard let value, !(value is NSNull) else { return nil }
    return value
}

/// Cursor keeps this process for hours. Reuse one container; reopen only when
/// the app wrote. A stale held container traps on the next property access.
func openStore() throws -> ModelContainer {
    var last: Error?
    for attempt in 0..<3 {
        do {
            return try MCPStoreSession.container()
        } catch {
            last = error
            MCPStoreSession.reset()
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.2) }
        }
    }
    throw last!
}

/// Name the connected client gave at initialize, kept for the action log.
var client = ""

/// Set by the app when it starts a worker for a Run, so the worker sees only that Run's tools.
let allowedTools = ProcessInfo.processInfo.environment["MEMBRAE_ALLOWED_TOOLS"].map {
    Set($0.split(separator: ",").map(String.init))
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
        log("ignored a malformed line")
        continue
    }
    let method = message["method"] as? String ?? ""
    guard let id = requestID(message["id"]) else { continue }
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        client = (params["clientInfo"] as? [String: Any])?["name"] as? String ?? ""
        let requested = params["protocolVersion"] as? String ?? ""
        respond(id, result: [
            "protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "membrae", "version": "1.0"],
            "instructions": instructions
        ])
    case "ping", "initialized", "notifications/initialized":
        respond(id, result: [:])
    case "tools/list":
        let definitions = Tools.definitions.filter { definition in
            guard let allowedTools else { return true }
            return allowedTools.contains(definition["name"] as? String ?? "")
        }
        respond(id, result: ["tools": definitions])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        if let allowedTools, !allowedTools.contains(name) {
            respond(id, result: [
                "content": [["type": "text", "text": "This run cannot use \(name)."]],
                "isError": true
            ])
            continue
        }
        do {
            let container = try openStore()
            let meta = params["_meta"] as? [String: Any] ?? [:]
            let origin = ActionOrigin(client: client, conversationID: meta["conversation_id"] as? String ?? "")
            let result = Tools.call(name, arguments: arguments, container: container, origin: origin)
            MCPStoreSession.noteLocalWrite()
            respond(id, result: result)
        } catch {
            log("store open failed: \(error.localizedDescription)")
            respond(id, result: [
                "content": [["type": "text", "text": "Membrae store could not be opened: \(error.localizedDescription)"]],
                "isError": true
            ])
        }
    default:
        respond(id, code: -32601, message: "Method not found: \(method)")
    }
}
