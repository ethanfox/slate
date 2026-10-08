import Foundation

enum ForgeProvider: String, Codable, CaseIterable, Identifiable {
    case github
    case gitlab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        }
    }

    var mark: BrandMark {
        switch self {
        case .github: .github
        case .gitlab: .gitlab
        }
    }

    var kind: CodeAttachmentKind {
        switch self {
        case .github: .github
        case .gitlab: .gitlab
        }
    }
}

struct ForgeToken: Identifiable, Hashable, Codable {
    var id: UUID
    var provider: ForgeProvider
    var name: String
    var login: String
}

enum ForgeTokenStatus: Equatable {
    case checking
    case ready
    case failed(String)
}

@MainActor
@Observable
final class SourceConnections {
    var chatGPT: ConnectionState = .missing
    var githubTokens: [ForgeToken] = []
    var gitlabTokens: [ForgeToken] = []
    var tokenStatus: [UUID: ForgeTokenStatus] = [:]

    private let defaults = UserDefaults.standard
    private let tokensKey = "forgeTokens"

    func load() {
        if let session = ChatGPTSignIn.load() {
            chatGPT = session.usingPlan
                ? .connected(session.label)
                : .failed("Signed in as \(session.label), but ChatGPT plan use was not granted.")
        } else {
            chatGPT = .missing
        }
        let stored = decodeTokens()
        githubTokens = stored.filter { $0.provider == .github }
        gitlabTokens = stored.filter { $0.provider == .gitlab }
        migrateLegacy(.github)
        migrateLegacy(.gitlab)
        refresh()
    }

    func refresh() {
        if ChatGPTSignIn.load() != nil, case .missing = chatGPT {
            load()
            return
        }
        for token in githubTokens + gitlabTokens {
            tokenStatus[token.id] = .checking
            Task { await validate(token) }
        }
    }

    func signInChatGPT() async throws {
        chatGPT = .checking
        do {
            let session = try await ChatGPTSignIn.signIn()
            chatGPT = session.usingPlan
                ? .connected(session.label)
                : .failed("Signed in as \(session.label), but ChatGPT plan use was not granted.")
        } catch is CancellationError {
            chatGPT = ChatGPTSignIn.load() == nil ? .missing : chatGPT
            throw CancellationError()
        } catch {
            if ChatGPTSignIn.load() == nil { chatGPT = .missing }
            throw error
        }
    }

    func saveGitHub(_ token: String, name: String) async throws {
        try await save(token, name: name, provider: .github)
    }

    func saveGitLab(_ token: String, name: String) async throws {
        try await save(token, name: name, provider: .gitlab)
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
        persist()
    }

    func removeChatGPT() {
        try? ChatGPTSignIn.remove()
        chatGPT = .missing
    }

    func remove(_ id: UUID) {
        let token = githubTokens.first { $0.id == id } ?? gitlabTokens.first { $0.id == id }
        githubTokens.removeAll { $0.id == id }
        gitlabTokens.removeAll { $0.id == id }
        tokenStatus[id] = nil
        if let token {
            try? KeychainStore.delete(account: KeychainStore.forgeAccount(token.provider, id: id))
        }
        persist()
    }

    func secret(for id: UUID) -> String? {
        let token = githubTokens.first { $0.id == id } ?? gitlabTokens.first { $0.id == id }
        guard let token else { return nil }
        return KeychainStore.read(account: KeychainStore.forgeAccount(token.provider, id: id))
    }

    var hasGitHub: Bool { !githubTokens.isEmpty }
    var hasGitLab: Bool { !gitlabTokens.isEmpty }
    var hasChatGPT: Bool {
        if case .connected = chatGPT { return true }
        return false
    }

    private func save(_ token: String, name: String, provider: ForgeProvider) async throws {
        let account = try await account(for: provider, secret: token)
        let id = UUID()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = ForgeToken(
            id: id,
            provider: provider,
            name: trimmed.isEmpty ? account.login : trimmed,
            login: account.login
        )
        try KeychainStore.save(token, account: KeychainStore.forgeAccount(provider, id: id))
        switch provider {
        case .github: githubTokens.append(record)
        case .gitlab: gitlabTokens.append(record)
        }
        tokenStatus[id] = .ready
        persist()
    }

    private func validate(_ token: ForgeToken) async {
        guard let secret = secret(for: token.id) else {
            tokenStatus[token.id] = .failed("Token is missing.")
            return
        }
        do {
            let account = try await account(for: token.provider, secret: secret)
            tokenStatus[token.id] = .ready
            if token.login != account.login {
                update(token.id) { $0.login = account.login }
                persist()
            }
        } catch {
            tokenStatus[token.id] = .failed(error.localizedDescription)
        }
    }

    private func account(for provider: ForgeProvider, secret: String) async throws -> GitForgeAccount {
        switch provider {
        case .github: try await GitForgeClient.githubAccount(token: secret)
        case .gitlab: try await GitForgeClient.gitlabAccount(token: secret)
        }
    }

    private func migrateLegacy(_ account: KeychainAccount) {
        let provider: ForgeProvider
        switch account {
        case .github: provider = .github
        case .gitlab: provider = .gitlab
        default: return
        }
        let existing = provider == .github ? githubTokens : gitlabTokens
        guard existing.isEmpty, let secret = KeychainStore.read(account) else { return }
        let id = UUID()
        let record = ForgeToken(id: id, provider: provider, name: provider.title, login: "")
        do {
            try KeychainStore.save(secret, account: KeychainStore.forgeAccount(provider, id: id))
            try KeychainStore.delete(account)
            switch provider {
            case .github: githubTokens.append(record)
            case .gitlab: gitlabTokens.append(record)
            }
            persist()
        } catch {
            ChatTrace.event("forge migrate \(provider.rawValue) failed: \(error.localizedDescription)")
        }
    }

    private func update(_ id: UUID, _ body: (inout ForgeToken) -> Void) {
        if let index = githubTokens.firstIndex(where: { $0.id == id }) {
            body(&githubTokens[index])
        } else if let index = gitlabTokens.firstIndex(where: { $0.id == id }) {
            body(&gitlabTokens[index])
        }
    }

    private func persist() {
        let all = githubTokens + gitlabTokens
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: tokensKey)
        }
    }

    private func decodeTokens() -> [ForgeToken] {
        guard let data = defaults.data(forKey: tokensKey),
              let tokens = try? JSONDecoder().decode([ForgeToken].self, from: data)
        else { return [] }
        return tokens
    }
}
