import Foundation
import SwiftData

struct ChatAttachmentRef: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case image
        case file
    }

    var id: UUID
    var kind: Kind
    var filename: String
    var mimeType: String
}

enum AssetOwnerKind: String, Sendable {
    case composer
    case chatDraft
    case chatMessage
}

@Model
final class StoredAsset {
    var id: UUID
    var filename: String
    var mediaType: String
    var byteSize: Int
    var createdAt: Date
    var relativePath: String
    var contentHash: String
    var kindRaw: String

    var kind: ChatAttachmentRef.Kind {
        get { ChatAttachmentRef.Kind(rawValue: kindRaw) ?? .file }
        set { kindRaw = newValue.rawValue }
    }

    var reference: ChatAttachmentRef {
        ChatAttachmentRef(id: id, kind: kind, filename: filename, mimeType: mediaType)
    }

    init(
        id: UUID = UUID(),
        filename: String,
        mediaType: String,
        byteSize: Int,
        relativePath: String,
        contentHash: String,
        kind: ChatAttachmentRef.Kind
    ) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.byteSize = byteSize
        self.createdAt = .now
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.kindRaw = kind.rawValue
    }
}

@Model
final class AssetReference {
    var id: UUID
    var assetIDString: String
    var ownerKindRaw: String
    var ownerIDString: String
    var orderIndex: Int
    var createdAt: Date

    var assetID: UUID? { UUID(uuidString: assetIDString) }

    var ownerKind: AssetOwnerKind {
        get { AssetOwnerKind(rawValue: ownerKindRaw) ?? .composer }
        set { ownerKindRaw = newValue.rawValue }
    }

    var ownerID: UUID? { UUID(uuidString: ownerIDString) }

    init(assetID: UUID, ownerKind: AssetOwnerKind, ownerID: UUID, orderIndex: Int) {
        self.id = UUID()
        self.assetIDString = assetID.uuidString.lowercased()
        self.ownerKindRaw = ownerKind.rawValue
        self.ownerIDString = ownerID.uuidString.lowercased()
        self.orderIndex = orderIndex
        self.createdAt = .now
    }
}
