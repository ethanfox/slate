import CryptoKit
import Foundation
import SwiftData

enum CodeReferencePublication: String, Codable, CaseIterable, Identifiable {
    case staged
    case published
    case discarded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .staged: "Indexing"
        case .published: "Available"
        case .discarded: "Discarded"
        }
    }
}

enum CodeReferenceCoverage: String, Codable, CaseIterable, Identifiable {
    case unknown
    case inventory
    case partial
    case complete

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unknown: "Not set"
        case .inventory: "Inventory only"
        case .partial: "Partial"
        case .complete: "Complete"
        }
    }

    var appearsComprehensive: Bool { self == .complete }
}

enum CodeSourceFreshness: String, Codable, CaseIterable, Identifiable {
    case unknown
    case current
    case changed
    case missing
    case mixed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unknown: "Unknown freshness"
        case .current: "Matches examined source"
        case .changed: "Source changed since examined"
        case .missing: "Source missing"
        case .mixed: "Mixed source freshness"
        }
    }
}

struct CodeSourceLocation: Codable, Hashable, Sendable {
    var path: String
    var declaration: String?
    var contentHash: String? = nil
}

struct CodeSourceFingerprint: Codable, Equatable, Sendable {
    var commitSHA: String
    var localChanges: String
    var capturedAt: Date
}

@Model
final class CodeReference {
    var id: UUID
    var revision: Int
    var sourceRevision: String
    var localChangesExamined: String
    var coverageRaw: String
    var publicationRaw: String
    var coverageNotes: String
    var sourceChangedDuringIndex: Bool
    var sourceFreshnessRaw: String = ""
    var startFingerprintJSON: String
    var lastUpdatedAt: Date
    var createdAt: Date
    var originatingRunID: UUID
    var lastUpdatedByRunID: UUID?
    var attachmentIDString: String = ""

    var attachmentID: UUID? {
        get { UUID(uuidString: attachmentIDString) }
        set { attachmentIDString = newValue?.uuidString.lowercased() ?? "" }
    }

    var publication: CodeReferencePublication {
        get { CodeReferencePublication(rawValue: publicationRaw) ?? .staged }
        set { publicationRaw = newValue.rawValue }
    }

    var coverage: CodeReferenceCoverage {
        get { CodeReferenceCoverage(rawValue: coverageRaw) ?? .unknown }
        set { coverageRaw = newValue.rawValue }
    }

    var sourceFreshness: CodeSourceFreshness {
        get { CodeSourceFreshness(rawValue: sourceFreshnessRaw) ?? .unknown }
        set { sourceFreshnessRaw = newValue.rawValue }
    }

    var startFingerprint: CodeSourceFingerprint? {
        get { Self.decode(startFingerprintJSON, as: CodeSourceFingerprint.self) }
        set { startFingerprintJSON = newValue.map(Self.encode) ?? "" }
    }

    init(
        attachmentID: UUID,
        originatingRunID: UUID,
        fingerprint: CodeSourceFingerprint,
        revision: Int = 1
    ) {
        self.id = UUID()
        self.revision = revision
        self.sourceRevision = fingerprint.commitSHA
        self.localChangesExamined = fingerprint.localChanges
        self.coverageRaw = CodeReferenceCoverage.unknown.rawValue
        self.publicationRaw = CodeReferencePublication.staged.rawValue
        self.coverageNotes = ""
        self.sourceChangedDuringIndex = false
        self.sourceFreshnessRaw = CodeSourceFreshness.unknown.rawValue
        self.startFingerprintJSON = Self.encode(fingerprint)
        self.lastUpdatedAt = .now
        self.createdAt = .now
        self.originatingRunID = originatingRunID
        self.lastUpdatedByRunID = originatingRunID
        self.attachmentIDString = attachmentID.uuidString.lowercased()
    }

    func touch(runID: UUID? = nil) {
        lastUpdatedAt = .now
        if let runID { lastUpdatedByRunID = runID }
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
        guard let data = raw.data(using: .utf8), !raw.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

@Model
final class CodeReferenceEntry {
    var id: UUID
    var key: String
    var title: String
    var body: String
    var sourceLocationsJSON: String
    var relatedKeysJSON: String
    var sourceRevision: String
    var lastUpdatedAt: Date
    var referenceIDString: String = ""

    var referenceID: UUID? {
        get { UUID(uuidString: referenceIDString) }
        set { referenceIDString = newValue?.uuidString.lowercased() ?? "" }
    }

    var sourceLocations: [CodeSourceLocation] {
        get { Self.decode(sourceLocationsJSON, as: [CodeSourceLocation].self) ?? [] }
        set { sourceLocationsJSON = Self.encode(newValue) }
    }

    var relatedKeys: [String] {
        get { Self.decode(relatedKeysJSON, as: [String].self) ?? [] }
        set { relatedKeysJSON = Self.encode(newValue) }
    }

    init(
        key: String,
        title: String,
        body: String,
        sourceLocations: [CodeSourceLocation],
        relatedKeys: [String],
        sourceRevision: String,
        referenceID: UUID
    ) {
        self.id = UUID()
        self.key = key
        self.title = title
        self.body = body
        self.sourceLocationsJSON = Self.encode(sourceLocations)
        self.relatedKeysJSON = Self.encode(relatedKeys)
        self.sourceRevision = sourceRevision
        self.lastUpdatedAt = .now
        self.referenceIDString = referenceID.uuidString.lowercased()
    }

    func touch() {
        lastUpdatedAt = .now
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum CodeContentHash {
    static func sha256(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(ofFile url: URL) throws -> String {
        sha256(of: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    static func freshness(of location: CodeSourceLocation, rootPath: String) -> CodeSourceFreshness {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let file = root.appendingPathComponent(location.path).standardizedFileURL
        guard file.path == root.path || file.path.hasPrefix(root.path + "/") else { return .missing }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .missing
        }
        guard let hash = location.contentHash, !hash.isEmpty else { return .unknown }
        let current = (try? sha256(ofFile: file)) ?? ""
        return current == hash ? .current : .changed
    }

    static func rollup(_ states: [CodeSourceFreshness]) -> CodeSourceFreshness {
        let unique = Set(states)
        if unique.isEmpty { return .unknown }
        if unique.count == 1, let only = unique.first { return only }
        if unique.contains(.missing) || unique.contains(.changed) || unique.contains(.unknown) || unique.contains(.current) {
            return .mixed
        }
        return .mixed
    }
}

enum CodeReadProvenance {
    struct Record: Codable, Equatable {
        var contentHash: String
        var readAt: Date
    }

    static func record(runID: UUID, path: String, hash: String, storeURL: URL?) {
        guard !hash.isEmpty else { return }
        let key = normalize(path)
        var records = load(runID: runID, storeURL: storeURL)
        records[key] = Record(contentHash: hash, readAt: .now)
        save(records, runID: runID, storeURL: storeURL)
    }

    static func hash(runID: UUID, path: String, storeURL: URL?) -> String? {
        load(runID: runID, storeURL: storeURL)[normalize(path)]?.contentHash
    }

    static func writeFile(at url: URL, path: String, hash: String) {
        let key = normalize(path)
        var records = load(url: url)
        records[key] = Record(contentHash: hash, readAt: .now)
        save(records, to: url)
    }

    static func hashes(inFile url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: load(url: url).map { ($0.key, $0.value.contentHash) })
    }

    static func fileURL(runID: UUID, storeURL: URL?) -> URL {
        folder(storeURL: storeURL).appendingPathComponent("\(runID.uuidString.lowercased()).json")
    }

    private static func folder(storeURL: URL?) -> URL {
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("SlateCodeReads", isDirectory: true)
        guard let storeURL, storeURL.isFileURL, !storeURL.path.isEmpty, storeURL.path != "/",
              storeURL.path != "/dev/null", !storeURL.path.contains("memory")
        else { return fallback }
        let candidate = storeURL.deletingLastPathComponent().appendingPathComponent("CodeReads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            return candidate
        } catch {
            return fallback
        }
    }

    private static func load(runID: UUID, storeURL: URL?) -> [String: Record] {
        load(url: fileURL(runID: runID, storeURL: storeURL))
    }

    private static func load(url: URL) -> [String: Record] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Record].self, from: data)) ?? [:]
    }

    private static func save(_ records: [String: Record], runID: UUID, storeURL: URL?) {
        save(records, to: fileURL(runID: runID, storeURL: storeURL))
    }

    private static func save(_ records: [String: Record], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(records).write(to: url, options: .atomic)
    }

    static func normalize(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
