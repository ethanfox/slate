import Foundation

@MainActor
@Observable
final class MCPClientManager {
    private(set) var statuses: [UUID: MCPSessionStatus] = [:]
    private(set) var tools: [UUID: [MCPDiscoveredTool]] = [:]
    private(set) var lastErrors: [UUID: String] = [:]

    private let store: MCPConnectionStore
    private let factory: any MCPSessionFactory
    private var sessions: [UUID: any MCPSessioning] = [:]
    private var connecting: Set<UUID> = []

    init(store: MCPConnectionStore, factory: any MCPSessionFactory = MCPLiveSessionFactory.shared) {
        self.store = store
        self.factory = factory
    }

    func status(for id: UUID) -> MCPSessionStatus {
        guard let record = store.connection(id: id) else { return .disconnected }
        if !record.enabled { return .disabled }
        return statuses[id] ?? .disconnected
    }

    func tools(for id: UUID) -> [MCPDiscoveredTool] {
        tools[id] ?? []
    }

    func lastError(for id: UUID) -> String? {
        lastErrors[id]
    }

    func connect(_ id: UUID) async {
        guard let record = store.connection(id: id), record.enabled else { return }
        if connecting.contains(id) { return }
        if sessions[id] != nil, case .connected = statuses[id] { return }
        connecting.insert(id)
        statuses[id] = .connecting
        lastErrors[id] = nil
        do {
            let session = try await factory.open(MCPSecrets.resolve(record))
            let listed = try await session.listTools()
            sessions[id] = session
            tools[id] = listed
            statuses[id] = .connected(toolCount: listed.count)
        } catch is CancellationError {
            statuses[id] = .disconnected
        } catch {
            sessions[id] = nil
            let message = error.localizedDescription
            lastErrors[id] = message
            statuses[id] = .error(message)
        }
        connecting.remove(id)
    }

    func disconnect(_ id: UUID) {
        if let session = sessions.removeValue(forKey: id) {
            Task { await session.close() }
        }
        connecting.remove(id)
        if store.connection(id: id)?.enabled == false {
            statuses[id] = .disabled
        } else {
            statuses[id] = .disconnected
        }
    }

    func invalidate(_ id: UUID) {
        tools[id] = nil
        lastErrors[id] = nil
        disconnect(id)
    }

    func remove(_ id: UUID) {
        invalidate(id)
        statuses[id] = nil
        tools[id] = nil
        lastErrors[id] = nil
    }

    func test(_ record: MCPConnectionRecord) async -> Result<[MCPDiscoveredTool], Error> {
        do {
            try store.validate(record)
            let session = try await factory.open(MCPSecrets.resolve(record))
            let listed = try await session.listTools()
            await session.close()
            return .success(listed)
        } catch {
            return .failure(error)
        }
    }

    func ensureConnected(_ id: UUID) async throws -> any MCPSessioning {
        if let session = sessions[id], case .connected = statuses[id] {
            return session
        }
        await connect(id)
        if let session = sessions[id], case .connected = statuses[id] {
            return session
        }
        throw MCPConnectionError(lastErrors[id] ?? "Couldn’t connect.")
    }

    func call(connectionID: UUID, tool: String, arguments: [String: Any]) async throws -> Data {
        let session = try await ensureConnected(connectionID)
        do {
            return try await session.call(name: tool, arguments: arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if sessions[connectionID] == nil || status(for: connectionID) == .disconnected {
                throw MCPConnectionError(error.localizedDescription)
            }
            throw error
        }
    }

    func shutdown() {
        let ids = Array(sessions.keys)
        for id in ids {
            disconnect(id)
        }
    }
}
