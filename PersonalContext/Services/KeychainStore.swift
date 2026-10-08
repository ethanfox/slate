import Foundation
import Security

enum KeychainAccount: String {
    case cursorAPIKey = "cursor-api-key"
    case chatGPT = "chatgpt-session"
    case github = "github-token"
    case gitlab = "gitlab-token"
}

enum KeychainStore {
    static let service = "com.ethanfox.PersonalContext"

    static func read(_ account: KeychainAccount = .cursorAPIKey) -> String? {
        read(account: account.rawValue)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = baseQuery(account).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]) { _, new in new }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                ChatTrace.event("keychain read \(account) failed status=\(status)")
            }
            return nil
        }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func save(_ value: String, account: KeychainAccount = .cursorAPIKey) throws {
        try save(value, account: account.rawValue)
    }

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(_ account: KeychainAccount = .cursorAPIKey) throws {
        try delete(account: account.rawValue)
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    static func forgeAccount(_ provider: ForgeProvider, id: UUID) -> String {
        "\(provider.rawValue)-token.\(id.uuidString)"
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

struct KeychainError: LocalizedError {
    var status: OSStatus

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Keychain error \(status)."
    }
}
