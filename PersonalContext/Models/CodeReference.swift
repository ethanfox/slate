import CryptoKit
import Foundation
import SwiftData

/// Code indexing was removed. This table and the next stay only so opening the store does not
/// drop them; nothing reads or writes them.
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

    init() {
        self.id = UUID()
        self.revision = 1
        self.sourceRevision = ""
        self.localChangesExamined = ""
        self.coverageRaw = ""
        self.publicationRaw = ""
        self.coverageNotes = ""
        self.sourceChangedDuringIndex = false
        self.startFingerprintJSON = ""
        self.lastUpdatedAt = .now
        self.createdAt = .now
        self.originatingRunID = UUID()
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

    init() {
        self.id = UUID()
        self.key = ""
        self.title = ""
        self.body = ""
        self.sourceLocationsJSON = "[]"
        self.relatedKeysJSON = "[]"
        self.sourceRevision = ""
        self.lastUpdatedAt = .now
    }
}

enum CodeContentHash {
    static func sha256(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
