import CryptoKit
import Foundation
import SwiftData

struct FileStore: Sendable {
    var root: URL
    var context: ModelContext

    static func `default`(context: ModelContext) -> FileStore {
        FileStore(root: defaultRoot, context: context)
    }

    static var defaultRoot: URL {
        if let store = Store.applicationGroupStoreURL {
            return store.deletingLastPathComponent().appendingPathComponent("StoredAssets", isDirectory: true)
        }
        return Store.productSupportDirectory().appendingPathComponent("StoredAssets", isDirectory: true)
    }

    func importFile(url: URL, ownerKind: AssetOwnerKind, ownerID: UUID, orderIndex: Int) throws -> StoredAsset {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try importData(data, filename: url.lastPathComponent, ownerKind: ownerKind, ownerID: ownerID, orderIndex: orderIndex)
    }

    func importData(
        _ data: Data,
        filename: String,
        ownerKind: AssetOwnerKind,
        ownerID: UUID,
        orderIndex: Int
    ) throws -> StoredAsset {
        try validateSize(data.count, filename: filename)
        let detected = FileTypeDetector.inspect(filename: filename, data: data)
        if case .rejected(let error) = detected { throw error }
        if case .image(_, true) = detected { throw AttachmentError.animatedGIF(filename) }

        let id = UUID()
        let relative = "\(id.uuidString.prefix(2).lowercased())/\(id.uuidString.lowercased())"
        let stage = root.appendingPathComponent(".stage/\(id.uuidString.lowercased())", isDirectory: false)
        let final = root.appendingPathComponent(relative, isDirectory: false)
        try FileManager.default.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: stage, options: .atomic)
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: stage, to: final)

        let asset = StoredAsset(
            id: id,
            filename: filename,
            mediaType: FileTypeDetector.mimeType(for: detected),
            byteSize: data.count,
            relativePath: relative,
            contentHash: SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined(),
            kind: FileTypeDetector.kind(for: detected)
        )
        context.insert(asset)
        context.insert(AssetReference(assetID: id, ownerKind: ownerKind, ownerID: ownerID, orderIndex: orderIndex))
        try context.save()
        return asset
    }

    func read(_ asset: StoredAsset) throws -> Data {
        let url = resolve(asset)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AttachmentError.missingAsset(asset.filename)
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty {
            throw AttachmentError.missingAsset(asset.filename)
        }
        return data
    }

    func resolve(_ asset: StoredAsset) -> URL {
        root.appendingPathComponent(asset.relativePath, isDirectory: false)
    }

    func asset(id: UUID) -> StoredAsset? {
        let key = id.uuidString.lowercased()
        let found = try? context.fetch(FetchDescriptor<StoredAsset>())
        return found?.first { $0.id.uuidString.lowercased() == key }
    }

    func references(ownerKind: AssetOwnerKind, ownerID: UUID) -> [AssetReference] {
        let owner = ownerID.uuidString.lowercased()
        let found = (try? context.fetch(FetchDescriptor<AssetReference>())) ?? []
        return found
            .filter { $0.ownerKind == ownerKind && $0.ownerIDString == owner }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    func attachments(ownerKind: AssetOwnerKind, ownerID: UUID) -> [ChatAttachmentRef] {
        references(ownerKind: ownerKind, ownerID: ownerID).compactMap { reference in
            guard let id = reference.assetID, let asset = asset(id: id) else { return nil }
            return asset.reference
        }
    }

    func retain(assetIDs: [UUID], ownerKind: AssetOwnerKind, ownerID: UUID) throws {
        let existing = references(ownerKind: ownerKind, ownerID: ownerID)
        var known = Set(existing.compactMap(\.assetID))
        var order = existing.map(\.orderIndex).max().map { $0 + 1 } ?? 0
        for id in assetIDs where !known.contains(id) {
            context.insert(AssetReference(assetID: id, ownerKind: ownerKind, ownerID: ownerID, orderIndex: order))
            known.insert(id)
            order += 1
        }
        try context.save()
    }

    func replace(assetIDs: [UUID], ownerKind: AssetOwnerKind, ownerID: UUID) throws {
        for reference in references(ownerKind: ownerKind, ownerID: ownerID) {
            context.delete(reference)
        }
        for (index, id) in assetIDs.enumerated() {
            context.insert(AssetReference(assetID: id, ownerKind: ownerKind, ownerID: ownerID, orderIndex: index))
        }
        try context.save()
    }

    func release(ownerKind: AssetOwnerKind, ownerID: UUID) throws {
        for reference in references(ownerKind: ownerKind, ownerID: ownerID) {
            context.delete(reference)
        }
        try context.save()
    }

    func release(assetID: UUID, ownerKind: AssetOwnerKind, ownerID: UUID) throws {
        let owner = ownerID.uuidString.lowercased()
        let key = assetID.uuidString.lowercased()
        for reference in references(ownerKind: ownerKind, ownerID: ownerID) where reference.assetIDString == key {
            context.delete(reference)
        }
        _ = owner
        try context.save()
    }

    func releaseConversation(_ conversation: Conversation) throws {
        try release(ownerKind: .chatDraft, ownerID: conversation.id)
        for message in conversation.messages {
            try release(ownerKind: .chatMessage, ownerID: message.id)
        }
    }

    func cleanup(now: Date = .now, grace: TimeInterval = AttachmentLimits.abandonedGrace) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".stage", isDirectory: true)
        if FileManager.default.fileExists(atPath: stage.path),
           let leftovers = try? FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in leftovers {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(modified) >= grace {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        let refs = (try? context.fetch(FetchDescriptor<AssetReference>())) ?? []
        let live = Set(refs.map(\.assetIDString))
        let assets = (try? context.fetch(FetchDescriptor<StoredAsset>())) ?? []
        for asset in assets {
            let key = asset.id.uuidString.lowercased()
            guard !live.contains(key) else { continue }
            guard now.timeIntervalSince(asset.createdAt) >= grace else { continue }
            let url = resolve(asset)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            context.delete(asset)
        }
        try context.save()
    }

    private func validateSize(_ bytes: Int, filename: String) throws {
        if bytes > AttachmentLimits.maxFileBytes {
            throw AttachmentError.fileTooLarge(filename, AttachmentLimits.maxFileBytes)
        }
    }
}
