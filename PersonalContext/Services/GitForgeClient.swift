import Foundation

struct GitForgeAccount: Sendable {
    var login: String
    var name: String?

    var label: String { name?.isEmpty == false ? (name ?? login) : login }
}

struct GitForgeRepo: Identifiable, Hashable, Sendable {
    var id: String
    var owner: String
    var name: String
    var defaultBranch: String
    var provider: CodeAttachmentKind
    var tokenID: UUID
    var tokenName: String

    var title: String { "\(owner)/\(name)" }

    var remoteURL: String {
        switch provider {
        case .github: GitHubRemote.url(forLocator: title)
        case .gitlab: "https://gitlab.com/\(title)"
        case .folder: title
        }
    }

    func tagged(token: ForgeToken) -> GitForgeRepo {
        var next = self
        next.id = "\(token.id.uuidString).\(id)"
        next.tokenID = token.id
        next.tokenName = token.name
        return next
    }
}

enum GitHubRemote {
    static func url(forLocator locator: String) -> String {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http") {
            return canonical(trimmed)
        }
        let path = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "https://github.com/\(path)"
    }

    static func canonical(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix(".git") {
            value = String(value.dropLast(4))
        }
        if let url = URL(string: value), let host = url.host {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "https://\(host.lowercased())/\(path)"
        }
        return value.lowercased()
    }

    static func sameRepository(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }
}

enum GitForgeClient {
    static func githubAccount(token: String) async throws -> GitForgeAccount {
        let json = try await get(URL(string: "https://api.github.com/user")!, token: token, accept: "application/vnd.github+json")
        guard let login = json["login"] as? String, !login.isEmpty else {
            throw GitForgeError("GitHub did not return a login.")
        }
        return GitForgeAccount(login: login, name: json["name"] as? String)
    }

    static func gitlabAccount(token: String) async throws -> GitForgeAccount {
        let json = try await get(URL(string: "https://gitlab.com/api/v4/user")!, token: token, header: "PRIVATE-TOKEN")
        let login = (json["username"] as? String) ?? (json["email"] as? String)
        guard let login, !login.isEmpty else {
            throw GitForgeError("GitLab did not return a username.")
        }
        return GitForgeAccount(login: login, name: json["name"] as? String)
    }

    static func githubRepos(token: String) async throws -> [GitForgeRepo] {
        let items = try await getList(
            URL(string: "https://api.github.com/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member")!,
            token: token,
            accept: "application/vnd.github+json"
        )
        return items.compactMap { item in
            let name = item["name"] as? String
            let owner = (item["owner"] as? [String: Any])?["login"] as? String
            guard let name, let owner else { return nil }
            return GitForgeRepo(
                id: "github.\(owner).\(name)",
                owner: owner,
                name: name,
                defaultBranch: item["default_branch"] as? String ?? "main",
                provider: .github,
                tokenID: UUID(),
                tokenName: ""
            )
        }
    }

    static func gitlabRepos(token: String) async throws -> [GitForgeRepo] {
        let items = try await getList(
            URL(string: "https://gitlab.com/api/v4/projects?membership=true&simple=true&order_by=last_activity_at&per_page=100")!,
            token: token,
            header: "PRIVATE-TOKEN"
        )
        return items.compactMap { item in
            let path = item["path_with_namespace"] as? String
            guard let path, let slash = path.split(separator: "/").first, path.contains("/") else { return nil }
            let owner = String(slash)
            let name = String(path.split(separator: "/").dropFirst().joined(separator: "/"))
            return GitForgeRepo(
                id: "gitlab.\(path)",
                owner: owner,
                name: name,
                defaultBranch: item["default_branch"] as? String ?? "main",
                provider: .gitlab,
                tokenID: UUID(),
                tokenName: ""
            )
        }
    }

    private static func get(
        _ url: URL,
        token: String,
        header: String = "Authorization",
        accept: String = "application/json"
    ) async throws -> [String: Any] {
        let json = try await request(url, token: token, header: header, accept: accept)
        guard let object = json as? [String: Any] else {
            throw GitForgeError("Unexpected response.")
        }
        if let message = object["message"] as? String {
            throw GitForgeError(message)
        }
        return object
    }

    private static func getList(
        _ url: URL,
        token: String,
        header: String = "Authorization",
        accept: String = "application/json"
    ) async throws -> [[String: Any]] {
        let json = try await request(url, token: token, header: header, accept: accept)
        if let object = json as? [String: Any], let message = object["message"] as? String {
            throw GitForgeError(message)
        }
        return json as? [[String: Any]] ?? []
    }

    private static func request(
        _ url: URL,
        token: String,
        header: String,
        accept: String
    ) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if header == "Authorization" {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(token, forHTTPHeaderField: header)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            ChatTrace.event("gitforge \(url.host ?? "") failed status=\(status) \(ChatTrace.clip(text))")
            if status == 401 { throw GitForgeError("That token was rejected.") }
            throw GitForgeError("Could not reach \(url.host ?? "the server").")
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}

struct GitForgeError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
