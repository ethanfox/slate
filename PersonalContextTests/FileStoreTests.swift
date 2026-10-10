import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class FileStoreTests: XCTestCase {
    func testImportRoundTripAndSharedReferences() throws {
        let env = try Env()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let first = UUID()
        let second = UUID()
        let asset = try env.store.importData(png, filename: "a.png", ownerKind: .chatMessage, ownerID: first, orderIndex: 0)
        try env.store.retain(assetIDs: [asset.id], ownerKind: .chatMessage, ownerID: second)
        XCTAssertEqual(try env.store.read(asset), png)
        try env.store.release(ownerKind: .chatMessage, ownerID: first)
        XCTAssertNotNil(env.store.asset(id: asset.id))
        try env.store.release(ownerKind: .chatMessage, ownerID: second)
        try env.store.cleanup(now: .now.addingTimeInterval(AttachmentLimits.abandonedGrace + 1), grace: AttachmentLimits.abandonedGrace)
        XCTAssertNil(env.store.asset(id: asset.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.store.resolve(asset).path))
    }

    func testInterruptedStageDoesNotCreateAValidAsset() throws {
        let env = try Env()
        let stage = env.root.appendingPathComponent(".stage/incomplete", isDirectory: false)
        try FileManager.default.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: stage)
        XCTAssertTrue(((try? env.context.fetch(FetchDescriptor<StoredAsset>())) ?? []).isEmpty)
        try env.store.cleanup(now: .now.addingTimeInterval(AttachmentLimits.abandonedGrace + 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }

    func testMissingBytesSurfaceAnError() throws {
        let env = try Env()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let owner = UUID()
        let asset = try env.store.importData(png, filename: "gone.png", ownerKind: .composer, ownerID: owner, orderIndex: 0)
        try FileManager.default.removeItem(at: env.store.resolve(asset))
        XCTAssertThrowsError(try env.store.read(asset)) { error in
            XCTAssertEqual(error as? AttachmentError, .missingAsset("gone.png"))
        }
    }

    func testRejectsUnsupportedAndOversizeFiles() throws {
        let env = try Env()
        XCTAssertThrowsError(
            try env.store.importData(Data("MZ".utf8), filename: "bad.exe", ownerKind: .composer, ownerID: UUID(), orderIndex: 0)
        )
        let huge = Data(repeating: 1, count: AttachmentLimits.maxFileBytes + 1)
        XCTAssertThrowsError(
            try env.store.importData(huge, filename: "big.png", ownerKind: .composer, ownerID: UUID(), orderIndex: 0)
        )
    }

    @MainActor
    private struct Env {
        var root: URL
        var context: ModelContext
        var store: FileStore

        init() throws {
            let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: Store.schema, configurations: configuration)
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            context = container.mainContext
            store = FileStore(root: root, context: context)
        }
    }
}
