import Foundation
import SwiftData

let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

let instructions = """
Membrae is the user's knowledge base of projects. Each project has decisions (what was decided and why), \
threads (directions, features, problems, experiments, topics, which can nest), notes, and tasks. \
Active decisions are the source of truth. When the user states a fact, choice, or plan, record it here instead of \
asking them to save it. Read before you write so you update an existing record rather than duplicating it. \
When a decision replaces an older one, create the new decision with supersedes_id. \
Use the task tools to list, create, update, and complete Membrae tasks. complete_task records repeat history; \
do not set status to done on a repeating task. \
\(ContextBuilder.knowledgeRules) \
get_project is lean. Use get_thread for a track body and its linked work, list_tasks with track_id for tasks, \
and get_note for reference material. \
Agents cannot delete. To propose removing a note, track, decision, or chat, call mark_for_deletion \
with a reason. Optionally link a replacement. The user Keeps or Deletes.
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

/// Cursor keeps this process for hours. The app writes to the same store and
/// reopens its container after our saves. A held ModelContainer then traps on
/// the next property access (EXC_BREAKPOINT in SwiftData getters).
func openStore() throws -> ModelContainer {
    var last: Error?
    for attempt in 0..<3 {
        do {
            return try Store.open()
        } catch {
            last = error
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.2) }
        }
    }
    throw last!
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
        respond(id, result: ["tools": Tools.definitions])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let container = try openStore()
            respond(id, result: Tools.call(name, arguments: arguments, container: container))
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
