import Foundation
import Network

enum LoopbackAuth {
    static func listen(path: String = "/auth/callback") async throws -> Session {
        var lastError: Error?
        for port in UInt16(1455)...1485 {
            do {
                return try await Session.listen(path: path, port: port)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LoopbackError("Could not bind a local callback port.")
    }

    final class Session: @unchecked Sendable {
        let redirectURI: String
        private let listener: NWListener
        private let path: String
        private var continuation: CheckedContinuation<[String: String], Error>?
        private let lock = NSLock()

        static func listen(path: String, port: UInt16) async throws -> Session {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw LoopbackError("Invalid callback port.")
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            let listener = try NWListener(using: parameters)
            let session = Session(listener: listener, path: path, redirectURI: "http://127.0.0.1:\(port)\(path)")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                listener.start(queue: .global())
            }
            return session
        }

        private init(listener: NWListener, path: String, redirectURI: String) {
            self.listener = listener
            self.path = path
            self.redirectURI = redirectURI
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
        }

        func wait() async throws -> [String: String] {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
            }
        }

        func cancel() {
            listener.cancel()
            finish(.failure(CancellationError()))
        }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: .global())
            receive(connection, buffer: Data())
        }

        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
                guard let self else {
                    connection.cancel()
                    return
                }
                if let error {
                    connection.cancel()
                    self.finish(.failure(error))
                    return
                }
                var next = buffer
                if let data { next.append(data) }
                if let request = String(data: next, encoding: .utf8), request.contains("\r\n\r\n") || isComplete {
                    self.reply(connection, request: request)
                    return
                }
                if isComplete {
                    connection.cancel()
                    self.finish(.failure(LoopbackError("Empty callback.")))
                    return
                }
                self.receive(connection, buffer: next)
            }
        }

        private func reply(_ connection: NWConnection, request: String) {
            let query = Self.query(from: request, path: path)
            let html = "<!doctype html><meta charset=utf-8><title>Slate</title><p>Signed in. You can close this window and return to Slate.</p>"
            let body = Data(html.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
                self.listener.cancel()
                if let query {
                    self.finish(.success(query))
                } else {
                    self.finish(.failure(LoopbackError("Callback was missing the sign-in code.")))
                }
            })
        }

        private func finish(_ result: Result<[String: String], Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }

        private static func query(from request: String, path: String) -> [String: String]? {
            let line = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            guard let url = URL(string: "http://127.0.0.1\(parts[1])") else { return nil }
            guard url.path == path else { return nil }
            var values: [String: String] = [:]
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .forEach { item in
                    if let value = item.value { values[item.name] = value }
                }
            return values
        }
    }
}

struct LoopbackError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
