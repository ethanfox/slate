import Foundation
import Security

enum ImportLifetime: Hashable {
    case days(Int)
    case custom

    static let presets = [1, 7, 30, 90, 180]

    static func clamped(_ days: Int) -> Int {
        min(max(days, 1), 180)
    }
}

struct ImportLastWrite: Codable, Equatable {
    var kind: String
    var title: String
    var projectName: String
    var at: Date
}

struct ImportDedupEntry: Codable {
    var fingerprint: String
    var resultJSON: String
    var expiresAt: Date
}

struct ImportKeyMetadata: Codable {
    var createdAt: Date
    var expiresAt: Date
    var lastFour: String
    var createdTrackIDs: [UUID]
    var lastImport: ImportLastWrite?
    var lastExpiredAt: Date?
    var lastOfflineError: String?
    var dedup: [ImportDedupEntry]
}

enum ImportStatus: Equatable {
    case noKey
    case expired(Date)
    case connecting
    case ready
    case reconnecting
    case unreachable
}

enum ImportKeyStore {
    static let account = "import-key"
    static let defaultRelayURL = "https://mcp.membrae.com"

    private static var metadataURL: URL {
        let folder = Store.productSupportDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("import-key.json")
    }

    static func readKey() -> String? {
        KeychainStore.read(account: account)
    }

    static func loadMetadata() -> ImportKeyMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImportKeyMetadata.self, from: data)
    }

    static func saveMetadata(_ metadata: ImportKeyMetadata) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    static func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return "slt_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func createKey(days: Int) throws -> (key: String, metadata: ImportKeyMetadata) {
        try deleteKey()
        let key = generateKey()
        try KeychainStore.save(key, account: account)
        let now = Date.now
        let metadata = ImportKeyMetadata(
            createdAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(ImportLifetime.clamped(days) * 24 * 60 * 60)),
            lastFour: String(key.suffix(4)),
            createdTrackIDs: [],
            lastImport: nil,
            lastExpiredAt: nil,
            lastOfflineError: nil,
            dedup: []
        )
        saveMetadata(metadata)
        return (key, metadata)
    }

    static func deleteKey(keepingExpiredAt expiredAt: Date? = nil) throws {
        try KeychainStore.delete(account: account)
        try? FileManager.default.removeItem(at: metadataURL)
        if let expiredAt {
            saveMetadata(ImportKeyMetadata(
                createdAt: .now,
                expiresAt: expiredAt,
                lastFour: "",
                createdTrackIDs: [],
                lastImport: nil,
                lastExpiredAt: expiredAt,
                lastOfflineError: nil,
                dedup: []
            ))
        }
    }

    static func rememberTrack(_ id: UUID, in metadata: inout ImportKeyMetadata) {
        if !metadata.createdTrackIDs.contains(id) {
            metadata.createdTrackIDs.append(id)
        }
        saveMetadata(metadata)
    }

    static func recordImport(_ write: ImportLastWrite, in metadata: inout ImportKeyMetadata) {
        metadata.lastImport = write
        saveMetadata(metadata)
    }

    static func cachedResult(fingerprint: String, in metadata: ImportKeyMetadata) -> String? {
        metadata.dedup.first { $0.fingerprint == fingerprint && $0.expiresAt > .now }?.resultJSON
    }

    static func storeResult(fingerprint: String, resultJSON: String, in metadata: inout ImportKeyMetadata) {
        metadata.dedup.removeAll { $0.fingerprint == fingerprint || $0.expiresAt <= .now }
        metadata.dedup.append(ImportDedupEntry(
            fingerprint: fingerprint,
            resultJSON: resultJSON,
            expiresAt: Date.now.addingTimeInterval(15 * 60)
        ))
        if metadata.dedup.count > 50 {
            metadata.dedup.removeFirst(metadata.dedup.count - 50)
        }
        saveMetadata(metadata)
    }

    static func fingerprint(tool: String, arguments: [String: Any], idempotency: String) -> String {
        if !idempotency.isEmpty { return "idemp:" + idempotency }
        let data = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data()
        return "\(tool):\(String(decoding: data, as: UTF8.self))"
    }
}
