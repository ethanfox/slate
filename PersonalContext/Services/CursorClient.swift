import Foundation
import os

enum ChatTrace {
    static let logger = Logger(subsystem: "com.ethanfox.PersonalContext", category: "chat")

    private static let lock = NSLock()
    private static let iso = ISO8601DateFormatter()
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Slate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chat.log")
    }()

    static func event(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[PC-OS chat] \(message)")
        let line = "\(iso.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    static func clip(_ text: String, _ limit: Int = 160) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

struct CursorModel: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var description: String?
}

struct CursorAccount: Decodable, Sendable {
    var apiKeyName: String
    var userEmail: String?
}

struct CursorAPIError: LocalizedError, Sendable {
    var status: Int
    var message: String

    var errorDescription: String? { message }
}

struct CursorClient: Sendable {
    var apiKey: String
    var session: URLSession

    init(apiKey: String, session: URLSession = CursorClient.makeSession()) {
        self.apiKey = apiKey
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func account() async throws -> CursorAccount {
        ChatTrace.event("GET /v1/me")
        return try await send(make(path: "/v1/me", method: "GET"), as: CursorAccount.self)
    }

    func models() async throws -> [CursorModel] {
        ChatTrace.event("GET /v1/models")
        struct Response: Decodable { var items: [CursorModel] }
        return try await send(make(path: "/v1/models", method: "GET"), as: Response.self).items
    }

    private func make(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.cursor.com\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let path = request.url?.path ?? "?"
        let method = request.httpMethod ?? "?"
        ChatTrace.event("http \(method) \(path) start")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        ChatTrace.event("http \(method) \(path) status=\(status) bytes=\(data.count)")
        do {
            try validate(response, data: data)
        } catch {
            ChatTrace.event("http \(method) \(path) rejected: \(error.localizedDescription) body=\(ChatTrace.clip(String(data: data, encoding: .utf8) ?? "", 400))")
            throw error
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            ChatTrace.event("http \(method) \(path) decode failed as \(T.self): \(error) body=\(ChatTrace.clip(String(data: data, encoding: .utf8) ?? "", 400))")
            throw CursorAPIError(status: status, message: "Cursor returned a response this app couldn't read.")
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw CursorAPIError(status: http.statusCode, message: Self.message(for: http.statusCode, data: data))
        }
    }

    private static func message(for status: Int, data: Data) -> String {
        if status == 401 { return "Cursor rejected the API key." }
        if status == 409 { return "This conversation already has a run in progress." }
        if status == 429 { return "Cursor is rate limiting requests. Wait a moment and try again." }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String, !message.isEmpty { return message }
            if let error = json["error"] as? String, !error.isEmpty { return error }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
                return message
            }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count < 280 {
            return text
        }
        return "Cursor request failed (\(status))."
    }
}
