import Foundation

struct MCPStorePayload: Codable, Equatable, Sendable {
    var connections: [MCPConnectionRecord]
    var projectAccess: [String: [String]]
}

@MainActor
@Observable
final class MCPConnectionStore {
    private(set) var connections: [MCPConnectionRecord] = []
    private var projectAccess: [UUID: Set<UUID>] = [:]
    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Store.productSupportDirectory().appendingPathComponent("mcp-connections.json")
        load()
    }

    var enabledConnections: [MCPConnectionRecord] {
        connections.filter(\.enabled)
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(MCPStorePayload.self, from: data) else {
            connections = []
            projectAccess = [:]
            MCPDisplay.refresh([], access: [:])
            return
        }
        connections = payload.connections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        projectAccess = Dictionary(uniqueKeysWithValues: payload.projectAccess.compactMap { key, values in
            guard let projectID = UUID(uuidString: key) else { return nil }
            return (projectID, Set(values.compactMap(UUID.init(uuidString:))))
        })
        MCPDisplay.refresh(connections, access: projectAccess)
    }

    @discardableResult
    func save(_ record: MCPConnectionRecord) throws -> MCPConnectionRecord {
        var next = record
        next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.name.isEmpty else {
            throw MCPConnectionError("Name is required.")
        }
        try validate(next)
        if let index = connections.firstIndex(where: { $0.id == next.id }) {
            next.createdAt = connections[index].createdAt
            next.updatedAt = .now
            connections[index] = next
        } else {
            next.createdAt = .now
            next.updatedAt = .now
            connections.append(next)
        }
        connections.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
        MCPDisplay.refresh(connections, access: projectAccess)
        return next
    }

    func remove(_ id: UUID) {
        guard let record = connections.first(where: { $0.id == id }) else { return }
        connections.removeAll { $0.id == id }
        for key in projectAccess.keys {
            projectAccess[key]?.remove(id)
            if projectAccess[key]?.isEmpty == true {
                projectAccess[key] = nil
            }
        }
        persist()
        MCPDisplay.refresh(connections, access: projectAccess)
        MCPSecrets.deleteAll(
            connectionID: id,
            environmentKeys: record.environmentKeys,
            headerKeys: record.headerKeys
        )
    }

    func connection(id: UUID) -> MCPConnectionRecord? {
        connections.first { $0.id == id }
    }

    func connection(named name: String) -> MCPConnectionRecord? {
        connections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func allowedIDs(for projectID: UUID) -> Set<UUID> {
        projectAccess[projectID] ?? []
    }

    func allows(_ connectionID: UUID, in projectID: UUID) -> Bool {
        allowedIDs(for: projectID).contains(connectionID)
    }

    func setAllowed(_ connectionID: UUID, in projectID: UUID, allowed: Bool) {
        var current = projectAccess[projectID] ?? []
        if allowed {
            current.insert(connectionID)
        } else {
            current.remove(connectionID)
        }
        projectAccess[projectID] = current.isEmpty ? nil : current
        persist()
        MCPDisplay.refresh(connections, access: projectAccess)
    }

    func authorizedConnections(for projectID: UUID) -> [MCPConnectionRecord] {
        let allowed = allowedIDs(for: projectID)
        return enabledConnections.filter { allowed.contains($0.id) }
    }

    func importJSON(_ json: String, replace: Bool) throws -> MCPJSONImport.Result {
        let (result, accepted) = try MCPJSONImport.apply(json, onto: connections, replace: replace)
        for server in accepted {
            _ = try save(server.record)
            try MCPSecrets.saveEnvironment(connectionID: server.record.id, values: server.environment)
            try MCPSecrets.saveHeaders(connectionID: server.record.id, values: server.headers)
        }
        return result
    }

    func exportJSON() throws -> String {
        let object: [String: Any] = [
            "mcpServers": Dictionary(uniqueKeysWithValues: connections.map { record in
                (record.name, record.redactedExport())
            })
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    func validate(_ record: MCPConnectionRecord) throws {
        switch record.transport {
        case .stdio:
            guard !record.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPConnectionError("Executable is required.")
            }
        case .http:
            let url = record.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw MCPConnectionError("Enter an http or https server URL.")
            }
        }
        let names = connections.filter { $0.id != record.id }.map { $0.name.lowercased() }
        if names.contains(record.name.lowercased()) {
            throw MCPConnectionError("A connection named \(record.name) already exists.")
        }
    }

    private func persist() {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = MCPStorePayload(
            connections: connections,
            projectAccess: Dictionary(uniqueKeysWithValues: projectAccess.map { key, values in
                (key.uuidString, values.map(\.uuidString).sorted())
            })
        )
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
