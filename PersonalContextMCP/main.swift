import Foundation
import SwiftData

let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

let instructions = """
Slate is the user's knowledge base of projects. Each project has decisions (what was decided and why), \
threads (directions, features, problems, experiments, topics, which can nest), and notes. \
Active decisions are the source of truth. When the user states a fact, choice, or plan, record it here instead of \
asking them to save it. Read before you write so you update an existing record rather than duplicating it. \
When a decision replaces an older one, create the new decision with supersedes_id.
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

let container: ModelContainer
do {
    container = try Store.open()
} catch {
    FileHandle.standardError.write(Data("Slate store could not be opened: \(error.localizedDescription)\n".utf8))
    exit(1)
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
        respond(NSNull(), code: -32700, message: "Parse error")
        continue
    }
    let method = message["method"] as? String ?? ""
    guard let id = message["id"] else { continue }
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        respond(id, result: [
            "protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "slate", "version": "1.0"],
            "instructions": instructions
        ])
    case "ping":
        respond(id, result: [:])
    case "tools/list":
        respond(id, result: ["tools": Tools.definitions])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        respond(id, result: Tools.call(name, arguments: arguments, container: container))
    default:
        respond(id, code: -32601, message: "Method not found: \(method)")
    }
}
