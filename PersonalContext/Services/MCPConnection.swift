import Foundation

enum MCPTransportKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case stdio
    case http

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stdio: "Local stdio"
        case .http: "Streamable HTTP"
        }
    }
}

struct MCPConnectionRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var enabled: Bool
    var transport: MCPTransportKind
    var command: String
    var arguments: [String]
    var workingDirectory: String
    var environmentKeys: [String]
    var url: String
    var headerKeys: [String]
    var executableBookmark: Data?
    var workingDirectoryBookmark: Data?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        transport: MCPTransportKind,
        command: String = "",
        arguments: [String] = [],
        workingDirectory: String = "",
        environmentKeys: [String] = [],
        url: String = "",
        headerKeys: [String] = [],
        executableBookmark: Data? = nil,
        workingDirectoryBookmark: Data? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentKeys = environmentKeys
        self.url = url
        self.headerKeys = headerKeys
        self.executableBookmark = executableBookmark
        self.workingDirectoryBookmark = workingDirectoryBookmark
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var transportLabel: String { transport.label }

    var configurationSummary: String {
        switch transport {
        case .stdio:
            let args = arguments.joined(separator: " ")
            return args.isEmpty ? command : "\(command) \(args)"
        case .http:
            return url
        }
    }

    func configurationMatches(_ other: MCPConnectionRecord) -> Bool {
        transport == other.transport
            && command == other.command
            && arguments == other.arguments
            && workingDirectory == other.workingDirectory
            && environmentKeys == other.environmentKeys
            && url == other.url
            && headerKeys == other.headerKeys
    }

    func redactedExport() -> [String: Any] {
        switch transport {
        case .stdio:
            var payload: [String: Any] = [
                "type": "stdio",
                "command": command,
                "args": arguments
            ]
            if !workingDirectory.isEmpty {
                payload["cwd"] = workingDirectory
            }
            if !environmentKeys.isEmpty {
                payload["env"] = Dictionary(uniqueKeysWithValues: environmentKeys.map { ($0, "<redacted>") })
            }
            return payload
        case .http:
            var payload: [String: Any] = [
                "type": "http",
                "url": url
            ]
            if !headerKeys.isEmpty {
                payload["headers"] = Dictionary(uniqueKeysWithValues: headerKeys.map { ($0, "<redacted>") })
            }
            return payload
        }
    }
}

enum MCPSessionStatus: Equatable, Sendable {
    case disabled
    case disconnected
    case connecting
    case connected(toolCount: Int)
    case error(String)

    var label: String {
        switch self {
        case .disabled: "Disabled"
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .error: "Error"
        }
    }

    var toolCount: Int {
        if case .connected(let count) = self { return count }
        return 0
    }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

struct MCPDiscoveredTool: Identifiable, Equatable, Sendable {
    var name: String
    var description: String
    var inputSchema: [String: AnyHashable]
    var readOnlyHint: Bool?
    var destructiveHint: Bool?

    var id: String { name }

    var classification: MCPToolClassification {
        if readOnlyHint == true, destructiveHint != true { return .readOnly }
        if readOnlyHint == false || destructiveHint == true { return .mutating }
        return .unclassified
    }

    var schemaObject: [String: Any] {
        inputSchema.reduce(into: [:]) { $0[$1.key] = $1.value }
    }
}

enum MCPToolClassification: String, Sendable {
    case readOnly
    case mutating
    case unclassified

    var requiresConfirmation: Bool { self != .readOnly }
}

struct MCPResolvedConnection: Sendable {
    var record: MCPConnectionRecord
    var environment: [String: String]
    var headers: [String: String]
}

enum MCPDisplay {
    nonisolated(unsafe) static var connectionNames: [UUID: String] = [:]
    nonisolated(unsafe) static var projectAccess: [UUID: Set<UUID>] = [:]
    nonisolated(unsafe) static var tokens: [UUID: String] = [:]
    nonisolated(unsafe) static var idsByToken: [String: UUID] = [:]

    static func refresh(_ connections: [MCPConnectionRecord], access: [UUID: Set<UUID>] = projectAccess) {
        connectionNames = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0.name) })
        projectAccess = access
        var tokens: [UUID: String] = [:]
        var idsByToken: [String: UUID] = [:]
        var used = Set<String>()
        for connection in connections {
            let compact = connection.id.uuidString.replacingOccurrences(of: "-", with: "")
            var width = 8
            var token = String(compact.prefix(width))
            while used.contains(token.uppercased()), width < 32 {
                width += 2
                token = String(compact.prefix(width))
            }
            used.insert(token.uppercased())
            tokens[connection.id] = token
            idsByToken[token.uppercased()] = connection.id
        }
        self.tokens = tokens
        self.idsByToken = idsByToken
    }
}

enum ProviderToolName {
    static let maxLength = 64

    nonisolated(unsafe) static var originals: [String: String] = [:]

    static func legalize(_ name: String) -> String {
        let legal = ascii(name)
        originals[legal] = name
        return legal
    }

    static func original(_ name: String) -> String {
        originals[name] ?? name
    }

    static func ascii(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-") {
                return Character(scalar)
            }
            return "_"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = cleaned.isEmpty ? "tool" : cleaned
        if base.count <= maxLength { return base }
        return String(base.prefix(maxLength))
    }
}

enum MCPToolName {
    static let prefix = "mcp_"
    static let importServers = "import_mcp_servers"

    nonisolated(unsafe) static var bindings: [String: (UUID, String)] = [:]

    static func namespaced(connectionID: UUID, original: String) -> String {
        let token = MCPDisplay.tokens[connectionID]
            ?? String(connectionID.uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        let encoded = ProviderToolName.ascii(original)
        let budget = max(8, ProviderToolName.maxLength - prefix.count - token.count - 1)
        let clipped = String(encoded.prefix(budget))
        let name = ProviderToolName.legalize("\(prefix)\(token)_\(clipped)")
        bindings[name] = (connectionID, clipped)
        return name
    }

    static func parse(_ name: String) -> (connectionID: UUID, original: String)? {
        let raw = ProviderToolName.original(name)
        if let bound = bindings[name] ?? bindings[raw] {
            return bound
        }
        guard raw.hasPrefix(prefix) else { return nil }
        let rest = raw.dropFirst(prefix.count)
        guard let separator = rest.firstIndex(of: "_") else { return nil }
        let token = String(rest[..<separator]).uppercased()
        let original = String(rest[rest.index(after: separator)...])
        guard !original.isEmpty else { return nil }
        if let id = MCPDisplay.idsByToken[token] {
            return (id, original)
        }
        if token.count == 32, let id = UUID(uuidString: token.insertingUUIDHyphens) {
            return (id, original)
        }
        return nil
    }

    static func isExternal(_ name: String) -> Bool {
        let raw = ProviderToolName.original(name)
        return raw.hasPrefix(prefix) || name.hasPrefix(prefix)
    }

    static func matches(_ discovered: String, encoded: String) -> Bool {
        discovered == encoded || ProviderToolName.ascii(discovered) == encoded
            || discovered.hasPrefix(encoded) || ProviderToolName.ascii(discovered).hasPrefix(encoded)
    }
}

private extension String {
    var insertingUUIDHyphens: String {
        guard count == 32 else { return self }
        let chars = Array(self)
        return [
            String(chars[0..<8]),
            String(chars[8..<12]),
            String(chars[12..<16]),
            String(chars[16..<20]),
            String(chars[20..<32])
        ].joined(separator: "-")
    }
}

struct MCPConnectionError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
