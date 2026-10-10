import Foundation
import Network

enum ApprovalOutcome: Sendable {
    case redirect(URL)
    case denied(String)
}

struct ImportOAuthRequest: Equatable {
    var clientID: String
    var redirectURI: String
    var codeChallenge: String
    var state: String
    var resource: String
    var complete: String

    static let path = "/oauth/approve"
    static let port: UInt16 = 18765

    static func parse(query: [String: String]) -> ImportOAuthRequest? {
        let clientID = query["client_id"] ?? ""
        let redirectURI = query["redirect_uri"] ?? ""
        let codeChallenge = query["code_challenge"] ?? ""
        let complete = query["complete"] ?? ""
        guard !clientID.isEmpty, !redirectURI.isEmpty, !codeChallenge.isEmpty, !complete.isEmpty else { return nil }
        return ImportOAuthRequest(
            clientID: clientID,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            state: query["state"] ?? "",
            resource: query["resource"] ?? "",
            complete: complete
        )
    }

    var consentBody: [String: String] {
        [
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_challenge": codeChallenge,
            "state": state,
            "resource": resource
        ]
    }

    func completeURL(ticket: String) -> URL? {
        guard var components = URLComponents(string: complete) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "ticket", value: ticket))
        components.queryItems = items
        return components.url
    }
}

final class ImportApprovalServer: @unchecked Sendable {
    var approve: (@Sendable ([String: String]) async -> ApprovalOutcome)?
    private var listener: NWListener?

    func start() {
        if listener != nil { return }
        guard let port = NWEndpoint.Port(rawValue: ImportOAuthRequest.port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
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
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let request = String(data: next, encoding: .utf8), request.contains("\r\n\r\n") || isComplete {
                Task { await self.reply(connection, request: request) }
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: next)
        }
    }

    private func reply(_ connection: NWConnection, request: String) async {
        let query = Self.query(from: request)
        let outcome: ApprovalOutcome
        if let query, let approve {
            outcome = await approve(query)
        } else if query == nil {
            outcome = .denied("That approval request is invalid.")
        } else {
            outcome = .denied("Membrae is not ready.")
        }
        let response: Data
        switch outcome {
        case .redirect(let url):
            response = Self.http("HTTP/1.1 302 Found", headers: ["Location": url.absoluteString], body: Data())
        case .denied(let message):
            let html = "<!doctype html><meta charset=utf-8><title>Membrae</title><p>\(Self.escape(message))</p>"
            response = Self.http("HTTP/1.1 200 OK", headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func query(from request: String) -> [String: String]? {
        let line = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let url = URL(string: "http://127.0.0.1\(parts[1])" ) else { return nil }
        guard url.path == ImportOAuthRequest.path else { return nil }
        var values: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { item in
            if let value = item.value { values[item.name] = value }
        }
        return values
    }

    private static func http(_ status: String, headers: [String: String], body: Data) -> Data {
        var header = status + "\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (key, value) in headers {
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
