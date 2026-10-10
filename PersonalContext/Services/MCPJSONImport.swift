import Foundation

enum MCPJSONImport {
    struct Result: Equatable {
        var added: [MCPConnectionRecord]
        var updated: [MCPConnectionRecord]
        var unchanged: [MCPConnectionRecord]
        var conflicts: [String]

        var summary: String {
            var parts: [String] = []
            if !added.isEmpty { parts.append("Added \(names(added)).") }
            if !updated.isEmpty { parts.append("Replaced \(names(updated)).") }
            if !unchanged.isEmpty { parts.append("Already present: \(names(unchanged)).") }
            if !conflicts.isEmpty {
                parts.append(
                    "These names already exist with different settings: \(conflicts.joined(separator: ", ")). Call again with replace=true to overwrite."
                )
            }
            return parts.isEmpty ? "No connections in that JSON." : parts.joined(separator: " ")
        }

        private func names(_ records: [MCPConnectionRecord]) -> String {
            records.map(\.name).joined(separator: ", ")
        }
    }

    struct ParsedServer: Equatable {
        var name: String
        var record: MCPConnectionRecord
        var environment: [String: String]
        var headers: [String: String]
    }

    static func parse(_ json: String) throws -> [ParsedServer] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPConnectionError("Paste mcpServers JSON.")
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConnectionError("That JSON is not an object.")
        }
        let servers = object["mcpServers"] as? [String: Any] ?? (object.keys.contains(where: { isServer($0, object[$0]) }) ? object : nil)
        guard let servers, !servers.isEmpty else {
            throw MCPConnectionError("JSON must contain an mcpServers object.")
        }
        return try servers.keys.sorted().map { name in
            try parseServer(name: name, value: servers[name])
        }
    }

    static func apply(
        _ json: String,
        onto existing: [MCPConnectionRecord],
        replace: Bool
    ) throws -> (Result, [ParsedServer]) {
        let parsed = try parse(json)
        var result = Result(added: [], updated: [], unchanged: [], conflicts: [])
        var accepted: [ParsedServer] = []
        for server in parsed {
            if let current = existing.first(where: { $0.name.caseInsensitiveCompare(server.name) == .orderedSame }) {
                var incoming = server.record
                incoming.id = current.id
                incoming.enabled = current.enabled
                incoming.createdAt = current.createdAt
                incoming.executableBookmark = current.executableBookmark
                incoming.workingDirectoryBookmark = current.workingDirectoryBookmark
                if current.configurationMatches(incoming) && current.environmentKeys == incoming.environmentKeys && current.headerKeys == incoming.headerKeys {
                    result.unchanged.append(current)
                    continue
                }
                if replace {
                    incoming.updatedAt = .now
                    result.updated.append(incoming)
                    accepted.append(ParsedServer(name: server.name, record: incoming, environment: server.environment, headers: server.headers))
                } else {
                    result.conflicts.append(current.name)
                }
            } else {
                result.added.append(server.record)
                accepted.append(server)
            }
        }
        return (result, accepted)
    }

    private static func isServer(_ key: String, _ value: Any?) -> Bool {
        key != "mcpServers" && value is [String: Any]
    }

    private static func parseServer(name: String, value: Any?) throws -> ParsedServer {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw MCPConnectionError("Each mcpServers key needs a name.")
        }
        guard let object = value as? [String: Any] else {
            throw MCPConnectionError("\(trimmedName) must be an object.")
        }
        let type = string(object["type"])?.lowercased()
        if type == "sse" {
            throw MCPConnectionError("\(trimmedName) uses SSE. This pass supports stdio and Streamable HTTP.")
        }
        let hasCommand = string(object["command"]) != nil
        let hasURL = string(object["url"]) != nil || string(object["serverUrl"]) != nil
        if type == "http" || type == "streamable-http" || type == "streamablehttp" || (!hasCommand && hasURL) {
            return try httpServer(name: trimmedName, object: object)
        }
        if type == "stdio" || hasCommand {
            return try stdioServer(name: trimmedName, object: object)
        }
        throw MCPConnectionError("\(trimmedName) needs a command (stdio) or a url (Streamable HTTP).")
    }

    private static func stdioServer(name: String, object: [String: Any]) throws -> ParsedServer {
        guard let command = string(object["command"]) else {
            throw MCPConnectionError("\(name) is missing command.")
        }
        let arguments = strings(object["args"] ?? object["arguments"])
        let environment = stringMap(object["env"] ?? object["environment"])
        let record = MCPConnectionRecord(
            name: name,
            transport: .stdio,
            command: command,
            arguments: arguments,
            workingDirectory: string(object["cwd"] ?? object["workingDirectory"] ?? object["working_directory"]) ?? "",
            environmentKeys: environment.keys.sorted()
        )
        return ParsedServer(name: name, record: record, environment: environment, headers: [:])
    }

    private static func httpServer(name: String, object: [String: Any]) throws -> ParsedServer {
        guard let url = string(object["url"] ?? object["serverUrl"]) else {
            throw MCPConnectionError("\(name) is missing url.")
        }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MCPConnectionError("\(name) needs an http or https url.")
        }
        let headers = stringMap(object["headers"])
        let record = MCPConnectionRecord(
            name: name,
            transport: .http,
            url: url,
            headerKeys: headers.keys.sorted()
        )
        return ParsedServer(name: name, record: record, environment: [:], headers: headers)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func strings(_ value: Any?) -> [String] {
        if let values = value as? [String] {
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let value = string(value) {
            return [value]
        }
        return []
    }

    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else { return [:] }
        return Dictionary(uniqueKeysWithValues: object.compactMap { key, raw in
            let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let value = string(raw) else { return nil }
            return (name, value)
        })
    }
}
