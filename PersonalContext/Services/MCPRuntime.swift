import Foundation
import Observation

@MainActor
@Observable
final class MCPActionGate {
    struct Request: Identifiable {
        var id = UUID()
        var connectionID: UUID
        var connectionName: String
        var toolName: String
        var arguments: String
    }

    private(set) var request: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    func confirm(connectionID: UUID, connectionName: String, toolName: String, arguments: [String: Any]) async -> Bool {
        if let continuation {
            continuation.resume(returning: false)
            self.continuation = nil
        }
        let summary = argumentSummary(arguments)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            request = Request(
                connectionID: connectionID,
                connectionName: connectionName,
                toolName: toolName,
                arguments: summary
            )
        }
    }

    func respond(_ allowed: Bool) {
        request = nil
        continuation?.resume(returning: allowed)
        continuation = nil
    }

    func cancel() {
        respond(false)
    }

    private func argumentSummary(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return ChatTrace.clip(text, 400)
    }
}

@MainActor
@Observable
final class MCPRuntime {
    static let shared = MCPRuntime()

    let store: MCPConnectionStore
    let clients: MCPClientManager
    let actions: MCPActionGate
    private var authorizer: ((UUID, String, String, [String: Any]) async -> Bool)?

    init(
        store: MCPConnectionStore? = nil,
        factory: any MCPSessionFactory = MCPLiveSessionFactory.shared
    ) {
        let store = store ?? MCPConnectionStore()
        self.store = store
        self.clients = MCPClientManager(store: store, factory: factory)
        self.actions = MCPActionGate()
        self.authorizer = { [weak actions] connectionID, connection, tool, arguments in
            guard let actions else { return false }
            return await actions.confirm(
                connectionID: connectionID,
                connectionName: connection,
                toolName: tool,
                arguments: arguments
            )
        }
    }

    func useAuthorizer(_ authorizer: @escaping (UUID, String, String, [String: Any]) async -> Bool) {
        self.authorizer = authorizer
    }

    func setAutoApprove(_ id: UUID, enabled: Bool) throws {
        guard var record = store.connection(id: id) else { return }
        record.autoApprove = enabled
        _ = try store.save(record)
    }

    func alwaysAllowCurrentRequest() {
        guard let request = actions.request else { return }
        try? setAutoApprove(request.connectionID, enabled: true)
        actions.respond(true)
    }

    func shutdown() {
        actions.cancel()
        clients.shutdown()
    }

    func definitions(projectID: UUID?) async -> [MCPToolDefinition] {
        guard let projectID else { return [] }
        let authorized = store.authorizedConnections(for: projectID)
        for connection in authorized where clients.status(for: connection.id) != .disabled {
            if case .connected = clients.status(for: connection.id) { continue }
            await clients.connect(connection.id)
        }
        return MCPToolCatalog.definitions(connections: authorized, tools: clients.tools)
    }

    func providerDefinitions(projectID: UUID?) async -> [[String: Any]] {
        await definitions(projectID: projectID).map(\.providerDefinition)
    }

    func execute(name: String, arguments: [String: Any], projectID: UUID?) async throws -> String {
        if name == MCPToolName.importServers {
            return try importServers(arguments: arguments)
        }
        guard let parsed = MCPToolName.parse(name) else {
            throw MCPConnectionError("Unknown MCP tool.")
        }
        guard let projectID else {
            throw MCPConnectionError("External MCP tools are only available in a chat inside a Space.")
        }
        guard let record = store.connection(id: parsed.connectionID), record.enabled else {
            throw MCPConnectionError("That MCP connection is not available.")
        }
        guard store.allows(parsed.connectionID, in: projectID) else {
            throw MCPConnectionError("\(record.name) is not enabled for this Space.")
        }
        _ = try await clients.ensureConnected(parsed.connectionID)
        let compact = MCPSchema.compact(arguments)
        let discovered = clients.tools(for: parsed.connectionID).first {
            MCPToolName.matches($0.name, encoded: parsed.original)
        }
        let needsConfirmation = !record.skipsConfirmation && (discovered?.classification.requiresConfirmation ?? true)
        if let discovered {
            try MCPSchema.validate(arguments: compact, schema: discovered.schemaObject)
        }
        if needsConfirmation {
            let allowed = await (authorizer?(record.id, record.name, parsed.original, compact) ?? false)
            guard allowed else {
                throw MCPConnectionError("The user declined \(parsed.original) on \(record.name).")
            }
        }
        let data = try await clients.call(
            connectionID: parsed.connectionID,
            tool: discovered?.name ?? parsed.original,
            arguments: compact
        )
        return try MCPToolResult.format(data)
    }

    func importServers(json: String, replace: Bool) throws -> String {
        let result = try store.importJSON(json, replace: replace)
        for record in result.updated {
            clients.invalidate(record.id)
        }
        return result.summary
    }

    func save(_ record: MCPConnectionRecord, environment: [String: String] = [:], headers: [String: String] = [:]) throws -> MCPConnectionRecord {
        let saved = try store.save(record)
        try MCPSecrets.saveEnvironment(connectionID: saved.id, values: environment)
        try MCPSecrets.saveHeaders(connectionID: saved.id, values: headers)
        clients.invalidate(saved.id)
        return saved
    }

    func remove(_ id: UUID) {
        clients.remove(id)
        store.remove(id)
    }

    func setEnabled(_ id: UUID, enabled: Bool) throws {
        guard var record = store.connection(id: id) else { return }
        record.enabled = enabled
        _ = try store.save(record)
        if enabled {
            clients.invalidate(id)
        } else {
            clients.disconnect(id)
        }
    }

    private func importServers(arguments: [String: Any]) throws -> String {
        let json = (arguments["json"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let replace = arguments["replace"] as? Bool ?? false
        return try importServers(json: json, replace: replace)
    }
}
