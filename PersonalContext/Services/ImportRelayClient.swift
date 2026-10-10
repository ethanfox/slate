import Foundation

@MainActor
@Observable
final class ImportRelayController {
    var status: ImportStatus = .noKey
    var metadata: ImportKeyMetadata?
    var revealedKey: String?
    var keyError: String?
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.importEnabled)
            if enabled { start() } else { disconnect() }
        }
    }
    var relayOverride: String {
        didSet { UserDefaults.standard.set(relayOverride, forKey: Keys.importRelayURL) }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var backoff = [1, 2, 5, 10, 15]
    @ObservationIgnored private var backoffIndex = 0
    @ObservationIgnored private var receiveLoop: Task<Void, Never>?

    var endpoint: String {
        let override = relayOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? ImportKeyStore.defaultRelayURL : override
    }

    var mcpURL: String { endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/mcp" }

    init() {
        if UserDefaults.standard.object(forKey: Keys.importEnabled) == nil {
            enabled = true
        } else {
            enabled = UserDefaults.standard.bool(forKey: Keys.importEnabled)
        }
        relayOverride = UserDefaults.standard.string(forKey: Keys.importRelayURL) ?? ""
        metadata = ImportKeyStore.loadMetadata()
        refreshStatus(socketUp: false)
    }

    func attach(_ app: AppModel) {
        self.app = app
        start()
    }

    func start() {
        refreshExpiry()
        guard enabled, ImportKeyStore.readKey() != nil, !isExpired else {
            disconnect()
            refreshStatus(socketUp: false)
            return
        }
        connect()
    }

    func handleWake() { retryNow() }
    func handleForeground() { retryNow() }

    func retryNow() {
        backoffIndex = 0
        start()
    }

    func hideKey() {
        revealedKey = nil
    }

    func clearOfflineErrors() {
        metadata?.lastOfflineError = nil
        if let metadata { ImportKeyStore.saveMetadata(metadata) }
        retryNow()
    }

    func createKey(days: Int) {
        do {
            disconnect()
            let created = try ImportKeyStore.createKey(days: days)
            metadata = created.metadata
            revealedKey = created.key
            keyError = nil
            status = .connecting
            if enabled { connect() }
        } catch {
            keyError = error.localizedDescription
        }
    }

    func replaceKey(days: Int) {
        createKey(days: days)
    }

    func revokeKey() {
        disconnect()
        try? ImportKeyStore.deleteKey()
        revealedKey = nil
        metadata = ImportKeyStore.loadMetadata()
        status = .noKey
    }

    private var isExpired: Bool {
        guard let expires = metadata?.expiresAt else { return ImportKeyStore.readKey() == nil }
        return expires <= .now
    }

    private func refreshExpiry() {
        guard let metadata, metadata.expiresAt <= .now, ImportKeyStore.readKey() != nil else { return }
        try? ImportKeyStore.deleteKey(keepingExpiredAt: metadata.expiresAt)
        self.metadata = ImportKeyStore.loadMetadata()
        revealedKey = nil
        disconnect()
        status = .expired(metadata.expiresAt)
    }

    private func refreshStatus(socketUp: Bool) {
        refreshExpiry()
        if ImportKeyStore.readKey() == nil {
            if let expired = metadata?.lastExpiredAt {
                status = .expired(expired)
            } else {
                status = .noKey
            }
            return
        }
        if !enabled {
            status = .connecting
            return
        }
        if socketUp {
            status = .ready
            return
        }
        if case .unreachable = status { return }
        status = socket == nil ? .connecting : .reconnecting
    }

    private func connect() {
        guard let key = ImportKeyStore.readKey(), let metadata, enabled else { return }
        disconnect(keepStatus: true)
        status = backoffIndex == 0 ? .connecting : .reconnecting
        guard let url = websocketURL() else {
            markUnreachable("Can’t reach the import relay")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(ISO8601DateFormatter().string(from: metadata.expiresAt), forHTTPHeaderField: "X-Membrae-Key-Expires")
        request.setValue("mac", forHTTPHeaderField: "X-Membrae-Role")
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveLoop = Task { [weak self] in
            await self?.listen(task)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.socket === task else { return }
            self.status = .ready
            self.backoffIndex = 0
            self.metadata?.lastOfflineError = nil
        }
    }

    private func listen(_ task: URLSessionWebSocketTask) async {
        while socket === task, !Task.isCancelled {
            do {
                let message = try await task.receive()
                await handle(message)
            } catch {
                if socket === task {
                    markDropped()
                }
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        let text: String
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(decoding: data, as: UTF8.self)
        @unknown default: return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object["type"] as? String == "request",
              let requestId = object["requestId"] as? String,
              let rpc = object["rpc"] as? [String: Any],
              let app else { return }
        var current = metadata ?? ImportKeyStore.loadMetadata() ?? ImportKeyMetadata(
            createdAt: .now, expiresAt: .now, lastFour: "", createdTrackIDs: [],
            lastImport: nil, lastExpiredAt: nil, lastOfflineError: nil, dedup: []
        )
        let client = object["client"] as? String ?? "Imported"
        let response = ImportToolHost.handle(rpc: rpc, client: client, container: app.container, metadata: &current)
        metadata = current
        let payload: [String: Any] = ["v": 1, "type": "response", "requestId": requestId, "rpc": response]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]),
              let outgoing = String(data: data, encoding: .utf8) else { return }
        try? await socket?.send(.string(outgoing))
    }

    private func markDropped() {
        socket = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        status = .reconnecting
        scheduleReconnect()
    }

    private func markUnreachable(_ message: String) {
        status = .unreachable
        metadata?.lastOfflineError = message
        if let metadata { ImportKeyStore.saveMetadata(metadata) }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = backoff[min(backoffIndex, backoff.count - 1)]
        backoffIndex = min(backoffIndex + 1, backoff.count - 1)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.start()
        }
    }

    private func disconnect(keepStatus: Bool = false) {
        receiveLoop?.cancel()
        receiveLoop = nil
        reconnectTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        if !keepStatus { refreshStatus(socketUp: false) }
    }

    private func websocketURL() -> URL? {
        var value = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasPrefix("https://") {
            value = "wss://" + value.dropFirst("https://".count)
        } else if value.hasPrefix("http://") {
            value = "ws://" + value.dropFirst("http://".count)
        }
        return URL(string: value + "/mac")
    }
}
