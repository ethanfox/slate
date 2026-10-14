import Foundation

enum MCPSchema {
    static func compact(_ arguments: [String: Any]) -> [String: Any] {
        arguments.reduce(into: [:]) { result, item in
            guard !isBlank(item.value) else { return }
            result[item.key] = item.value
        }
    }

    static func providerParameters(_ schema: [String: Any]) -> [String: Any] {
        var next = schema
        if next["type"] == nil { next["type"] = "object" }
        if next["properties"] == nil { next["properties"] = [:] as [String: Any] }
        let properties = next["properties"] as? [String: Any] ?? [:]
        next["required"] = (schema["required"] as? [String] ?? []).filter { key in
            !isOptionalProperty(properties[key])
        }
        return next
    }

    static func validate(arguments: [String: Any], schema: [String: Any]) throws {
        let compact = compact(arguments)
        let required = (providerParameters(schema)["required"] as? [String] ?? [])
        for key in required {
            if compact[key] != nil { continue }
            if let raw = arguments[key], isBlank(raw) { continue }
            throw MCPConnectionError("\(key) is required.")
        }
        if schema["additionalProperties"] as? Bool == false {
            let allowed = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
            let extra = compact.keys.filter { !allowed.contains($0) }
            if let first = extra.first {
                throw MCPConnectionError("\(first) is not a valid argument.")
            }
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for (key, value) in compact {
            guard let property = properties[key] as? [String: Any],
                  let type = property["type"] as? String else { continue }
            if !matches(value, type: type) {
                throw MCPConnectionError("\(key) must be \(type).")
            }
        }
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "string": return value is String
        case "integer": return value is Int || value is NSNumber
        case "number": return value is Int || value is Double || value is NSNumber
        case "boolean": return value is Bool
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        default: return true
        }
    }

    static func isBlank(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private static func isOptionalProperty(_ raw: Any?) -> Bool {
        guard let property = raw as? [String: Any] else { return false }
        if property["default"] != nil { return true }
        let description = (property["description"] as? String ?? "").lowercased()
        if description.contains("optional") { return true }
        if let anyOf = property["anyOf"] as? [[String: Any]],
           anyOf.contains(where: { $0["type"] as? String == "null" }) {
            return true
        }
        return false
    }
}

enum MCPToolResult {
    static func format(_ data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data, as: UTF8.self)
        }
        if object["isError"] as? Bool == true {
            let text = contentText(object)
            throw MCPConnectionError(text.isEmpty ? "The MCP tool failed." : text)
        }
        var parts: [String] = []
        let text = contentText(object)
        if !text.isEmpty { parts.append(text) }
        if let structured = object["structuredContent"] {
            parts.append(try jsonString(structured))
        }
        var unsupported: [String] = []
        if let content = object["content"] as? [[String: Any]] {
            for item in content {
                let type = item["type"] as? String ?? ""
                switch type {
                case "text", "":
                    break
                case "image":
                    parts.append("[image \(item["mimeType"] as? String ?? "image")]")
                case "resource", "resource_link":
                    unsupported.append(type)
                default:
                    if !type.isEmpty { unsupported.append(type) }
                }
            }
        }
        if !unsupported.isEmpty {
            parts.append("This tool also returned \(unsupported.joined(separator: ", ")), which Membrae cannot display yet.")
        }
        if parts.isEmpty {
            return try jsonString(object)
        }
        return parts.joined(separator: "\n")
    }

    private static func contentText(_ object: [String: Any]) -> String {
        guard let content = object["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func jsonString(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

struct MCPToolDefinition {
    var namespacedName: String
    var connectionID: UUID
    var connectionName: String
    var originalName: String
    var description: String
    var schema: [String: Any]
    var classification: MCPToolClassification

    var providerDefinition: [String: Any] {
        [
            "type": "function",
            "name": namespacedName,
            "description": "\(connectionName): \(description)",
            "parameters": schema.isEmpty
                ? ["type": "object", "properties": [:] as [String: Any]]
                : MCPSchema.providerParameters(schema)
        ]
    }
}

enum MCPToolCatalog {
    static func definitions(
        connections: [MCPConnectionRecord],
        tools: [UUID: [MCPDiscoveredTool]]
    ) -> [MCPToolDefinition] {
        connections.flatMap { connection in
            (tools[connection.id] ?? []).map { tool in
                MCPToolDefinition(
                    namespacedName: MCPToolName.namespaced(connectionID: connection.id, original: tool.name),
                    connectionID: connection.id,
                    connectionName: connection.name,
                    originalName: tool.name,
                    description: tool.description,
                    schema: tool.schemaObject,
                    classification: tool.classification
                )
            }
        }
    }

    static let importDefinition: [String: Any] = [
        "type": "function",
        "name": MCPToolName.importServers,
        "description": "Add MCP connections from standard mcpServers JSON. Saves configuration only. Does not connect, launch, or grant any Space access. If a name already exists with different settings, call again with replace=true.",
        "parameters": [
            "type": "object",
            "properties": [
                "json": [
                    "type": "string",
                    "description": "The mcpServers JSON object, exactly as pasted."
                ],
                "replace": [
                    "type": "boolean",
                    "description": "Replace an existing connection with the same name when configuration differs."
                ]
            ],
            "required": ["json"]
        ]
    ]
}
