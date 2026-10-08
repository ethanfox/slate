import AppKit
import CryptoKit
import Foundation

struct ChatGPTSession: Codable, Sendable {
    var email: String
    var subject: String
    var clientID: String
    var hostID: String
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scopes: [String]
    var usingPlan: Bool

    var label: String { email }
}

struct ChatGPTModel: Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String

    static let fallback: [ChatGPTModel] = [
        .init(id: "gpt-5", displayName: "GPT-5"),
        .init(id: "gpt-5-mini", displayName: "GPT-5 mini"),
        .init(id: "gpt-4.1", displayName: "GPT-4.1"),
        .init(id: "o4-mini", displayName: "o4-mini")
    ]
}

enum ChatGPTSignIn {
    static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let resource = "https://api.openai.com/v1"
    static let usageURL = URL(string: "https://chatgpt.com/#settings")!
    static let identityScopes = "openid profile email"
    static let planScopes = "offline_access resource.invoke chatgpt.tokens.use.direct"
    static let scopes = "\(identityScopes) \(planScopes)"

    static func hostID() -> String {
        let key = "chatgptHostID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let value = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    static func load() -> ChatGPTSession? {
        guard let raw = KeychainStore.read(.chatGPT),
              let data = raw.data(using: .utf8),
              let session = try? JSONDecoder().decode(ChatGPTSession.self, from: data)
        else { return nil }
        return session
    }

    static func save(_ session: ChatGPTSession) throws {
        let data = try JSONEncoder().encode(session)
        guard let raw = String(data: data, encoding: .utf8) else { return }
        try KeychainStore.save(raw, account: .chatGPT)
    }

    static func remove() throws {
        try KeychainStore.delete(.chatGPT)
    }

    static func signIn() async throws -> ChatGPTSession {
        let existing = load()
        let listener = try await LoopbackAuth.listen()
        let verifier = PKCE.verifier()
        let state = PKCE.nonce()
        let nonce = PKCE.nonce()
        var items: [URLQueryItem] = [
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: listener.redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "resource", value: resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: PKCE.challenge(verifier)),
            .init(name: "ext_agent_host_id", value: hostID())
        ]
        if let existing {
            items.append(.init(name: "client_id", value: existing.clientID))
            items.append(.init(name: "login_hint", value: existing.email))
            items.append(.init(name: "id_token_hint", value: existing.idToken))
        } else {
            items.append(.init(name: "client_id", value: "dynamic_agent_client"))
            items.append(.init(name: "agent_name_hint", value: "Slate"))
        }
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        guard let url = components.url else {
            listener.cancel()
            throw ChatGPTAuthError("Could not start ChatGPT sign-in.")
        }
        ChatTrace.event("chatgpt authorize")
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        let callback: [String: String]
        do {
            callback = try await listener.wait()
        } catch {
            listener.cancel()
            throw error
        }
        if let error = callback["error"] {
            if error == "access_denied" {
                throw ChatGPTAuthError("ChatGPT sign-in was cancelled.")
            }
            throw ChatGPTAuthError(callback["error_description"] ?? error)
        }
        guard callback["state"] == state else {
            throw ChatGPTAuthError("ChatGPT returned a mismatched state.")
        }
        guard let code = callback["code"] else {
            throw ChatGPTAuthError("ChatGPT did not return an authorization code.")
        }
        let clientID = callback["client_id"] ?? existing?.clientID
        guard let clientID, clientID != "dynamic_agent_client" else {
            throw ChatGPTAuthError("ChatGPT did not issue a client id.")
        }
        let tokens = try await exchange(
            code: code,
            verifier: verifier,
            redirectURI: listener.redirectURI,
            clientID: clientID
        )
        let claims = try IDToken.decode(tokens.idToken)
        if claims.nonce != nonce {
            throw ChatGPTAuthError("ChatGPT identity token nonce did not match.")
        }
        if claims.iss != "https://auth.openai.com" {
            throw ChatGPTAuthError("ChatGPT identity token issuer was unexpected.")
        }
        let granted = tokens.scope.split(whereSeparator: \.isWhitespace).map(String.init)
        let session = ChatGPTSession(
            email: claims.email ?? existing?.email ?? "ChatGPT",
            subject: claims.sub,
            clientID: clientID,
            hostID: hostID(),
            idToken: tokens.idToken,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? existing?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3600)),
            scopes: granted,
            usingPlan: granted.contains("chatgpt.tokens.use.direct")
        )
        try save(session)
        return session
    }

    private static func exchange(
        code: String,
        verifier: String,
        redirectURI: String,
        clientID: String
    ) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "resource": resource
        ]
        request.httpBody = body.formEncoded
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            ChatTrace.event("chatgpt token failed status=\(status) \(ChatTrace.clip(text))")
            throw ChatGPTAuthError("ChatGPT would not exchange the sign-in code.")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func models(session: ChatGPTSession) async throws -> [ChatGPTModel] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ChatGPTAuthError("ChatGPT would not list models.")
        }
        struct Payload: Decodable {
            var data: [Item]
            struct Item: Decodable { var id: String }
        }
        let items = try JSONDecoder().decode(Payload.self, from: data).data
            .map(\.id)
            .filter { id in
                let lower = id.lowercased()
                return lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") || lower.hasPrefix("chatgpt")
            }
            .sorted()
        return items.map { ChatGPTModel(id: $0, displayName: $0) }
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String
        var expiresIn: Int?
        var scope: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case expiresIn = "expires_in"
            case scope
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
            idToken = try container.decode(String.self, forKey: .idToken)
            expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
            scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
        }
    }
}

enum PKCE {
    static func verifier() -> String {
        nonce(bytes: 32)
    }

    static func nonce(bytes: Int = 16) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }

    static func challenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URL
    }
}

enum IDToken {
    struct Claims: Decodable {
        var sub: String
        var email: String?
        var nonce: String?
        var iss: String
        var exp: TimeInterval
    }

    static func decode(_ token: String) throws -> Claims {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { throw ChatGPTAuthError("ChatGPT identity token was malformed.") }
        var encoded = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded) else {
            throw ChatGPTAuthError("ChatGPT identity token was malformed.")
        }
        return try JSONDecoder().decode(Claims.self, from: data)
    }
}

struct ChatGPTAuthError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Dictionary where Key == String, Value == String {
    var formEncoded: Data {
        map { key, value in
            "\(key.formEscaped)=\(value.formEscaped)"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
    }
}

private extension String {
    var formEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%2B")
            ?? self
    }
}
