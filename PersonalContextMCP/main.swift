import Foundation
import SwiftData

let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

let instructions = """
Membrae is the user's knowledge base of projects. Each project has decisions (what was decided and why), \
tracks (directions, features, problems, experiments, topics, which can nest), notes, and tasks. \
Active decisions are the source of truth. Answer the user first. When they state a fact, choice, or plan, persist it \
    here after you start the reply instead of asking them to save it. Do not mention the save unless they asked. \
    Read before you write so you update an existing record rather than duplicating it. \
When a decision replaces an older one, create the new decision with supersedes_id. \
Use the task tools to list, create, update, and complete Membrae tasks. complete_task records repeat history; \
do not set status to done on a repeating task. \
\(ContextBuilder.knowledgeRules) \
\(ContextBuilder.agendaRules) \
\(ContextBuilder.spaceRules) \
get_project is lean. Use get_track for a track body and its linked work, list_tasks with track_id for tasks, \
get_note for reference material, and list_chats then get_chat to read a past conversation. \
Tags are sparse cross-cutting labels. Use list_tags, create_tag, assign_tag, and remove_tag on notes, tracks, decisions, conversations, and tasks. Do not tag projects. \
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
