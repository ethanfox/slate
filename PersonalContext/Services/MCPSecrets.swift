import Foundation

enum MCPSecrets {
    static func environmentAccount(connectionID: UUID, key: String) -> String {
        "mcp.env.\(connectionID.uuidString).\(key)"
    }

    static func headerAccount(connectionID: UUID, key: String) -> String {
        "mcp.header.\(connectionID.uuidString).\(key)"
    }

    static func readEnvironment(connectionID: UUID, keys: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            guard let value = KeychainStore.read(account: environmentAccount(connectionID: connectionID, key: key)) else {
                return nil
            }
            return (key, value)
        })
    }

    static func readHeaders(connectionID: UUID, keys: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            guard let value = KeychainStore.read(account: headerAccount(connectionID: connectionID, key: key)) else {
                return nil
            }
            return (key, value)
        })
    }

    static func saveEnvironment(connectionID: UUID, values: [String: String]) throws {
        for (key, value) in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = environmentAccount(connectionID: connectionID, key: key)
            if trimmed.isEmpty {
                try KeychainStore.delete(account: account)
            } else {
                try KeychainStore.save(trimmed, account: account)
            }
        }
    }

    static func saveHeaders(connectionID: UUID, values: [String: String]) throws {
        for (key, value) in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = headerAccount(connectionID: connectionID, key: key)
            if trimmed.isEmpty {
                try KeychainStore.delete(account: account)
            } else {
                try KeychainStore.save(trimmed, account: account)
            }
        }
    }

    static func deleteAll(connectionID: UUID, environmentKeys: [String], headerKeys: [String]) {
        for key in environmentKeys {
            try? KeychainStore.delete(account: environmentAccount(connectionID: connectionID, key: key))
        }
        for key in headerKeys {
            try? KeychainStore.delete(account: headerAccount(connectionID: connectionID, key: key))
        }
    }

    static func resolve(_ record: MCPConnectionRecord) -> MCPResolvedConnection {
        MCPResolvedConnection(
            record: record,
            environment: readEnvironment(connectionID: record.id, keys: record.environmentKeys),
            headers: readHeaders(connectionID: record.id, keys: record.headerKeys)
        )
    }
}
