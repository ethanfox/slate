import SwiftData
import XCTest
@testable import Membrae

final class AttachmentRoutingTests: XCTestCase {
    func testUnknownImageSupportBlocksSend() {
        let defaults = UserDefaults(suiteName: "capability.unknown.\(UUID().uuidString)")!
        let snapshot = AttachmentCapabilityStore.snapshot(
            provider: .chatgpt,
            model: "mystery",
            defaults: defaults
        )
        XCTAssertEqual(snapshot.image, .unknown)
        XCTAssertEqual(snapshot.imageSource, .unknown)
    }

    func testKnownChatGPTModelUsesMaintainedMetadataWithoutUserSetup() {
        let defaults = UserDefaults(suiteName: "capability.known.chatgpt.\(UUID().uuidString)")!
        for model in ["gpt-4o", "GPT-6.1-Sol", "gpt-5.5"] {
            let snapshot = AttachmentCapabilityStore.snapshot(
                provider: .chatgpt,
                model: model,
                defaults: defaults
            )
            XCTAssertEqual(snapshot.image, .supported, model)
            XCTAssertEqual(snapshot.document, .supported, model)
            XCTAssertEqual(snapshot.imageSource, .maintained, model)
            XCTAssertEqual(snapshot.documentSource, .maintained, model)
        }
    }

    func testPrefixHeuristicDoesNotGrantChatGPTImageSupport() {
        let defaults = UserDefaults(suiteName: "capability.prefix.\(UUID().uuidString)")!
        let snapshot = AttachmentCapabilityStore.snapshot(
            provider: .chatgpt,
            model: "gpt-not-a-real-model",
            defaults: defaults
        )
        XCTAssertEqual(snapshot.image, .unknown)
        XCTAssertEqual(snapshot.imageSource, .unknown)
    }

    func testKnownTextOnlyChatGPTModelIsUnsupported() {
        let defaults = UserDefaults(suiteName: "capability.textonly.\(UUID().uuidString)")!
        let snapshot = AttachmentCapabilityStore.snapshot(
            provider: .chatgpt,
            model: "gpt-3.5-turbo",
            defaults: defaults
        )
        XCTAssertEqual(snapshot.image, .unsupported)
        XCTAssertEqual(snapshot.imageSource, .maintained)
    }

    func testKnownCursorModelUsesMaintainedImageMetadata() {
        let defaults = UserDefaults(suiteName: "capability.known.cursor.\(UUID().uuidString)")!
        for model in ["", "composer-1", "gpt-5"] {
            let snapshot = AttachmentCapabilityStore.snapshot(
                provider: .cursor,
                model: model,
                defaults: defaults
            )
            XCTAssertEqual(snapshot.image, .supported, model)
            XCTAssertEqual(snapshot.imageSource, .maintained, model)
            XCTAssertEqual(snapshot.document, .unsupported, model)
        }
    }

    func testUserOverrideBeatsMaintainedMetadata() {
        let defaults = UserDefaults(suiteName: "capability.override.\(UUID().uuidString)")!
        AttachmentCapabilityStore.setUser(
            provider: .chatgpt,
            model: "gpt-4o",
            image: .unsupported,
            defaults: defaults
        )
        let snapshot = AttachmentCapabilityStore.snapshot(
            provider: .chatgpt,
            model: "gpt-4o",
            defaults: defaults
        )
        XCTAssertEqual(snapshot.image, .unsupported)
        XCTAssertEqual(snapshot.imageSource, .user)
        XCTAssertEqual(snapshot.document, .supported)
        XCTAssertEqual(snapshot.documentSource, .maintained)
    }

    func testUserConfigurationIsLabelled() {
        let defaults = UserDefaults(suiteName: "capability.user.\(UUID().uuidString)")!
        AttachmentCapabilityStore.setUser(
            provider: .chatgpt,
            model: "gpt-test",
            image: .supported,
            document: .supported,
            defaults: defaults
        )
        let snapshot = AttachmentCapabilityStore.snapshot(
            provider: .chatgpt,
            model: "gpt-test",
            defaults: defaults
        )
        XCTAssertEqual(snapshot.image, .supported)
        XCTAssertEqual(snapshot.imageSource, .user)
        XCTAssertEqual(snapshot.documentSource, .user)
    }

    func testCursorAdapterCannotClaimNativeDocuments() {
        let adapter = AttachmentCapabilityStore.adapter(for: .cursor)
        XCTAssertTrue(adapter.images)
        XCTAssertFalse(adapter.nativeDocuments)
        XCTAssertTrue(adapter.extraction)
    }

    func testChatGPTPayloadKeepsSeparateImageParts() {
        let first = PreparedAttachment(
            ref: ChatAttachmentRef(id: UUID(), kind: .image, filename: "a.png", mimeType: "image/png"),
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            route: .nativeImage
        )
        let second = PreparedAttachment(
            ref: ChatAttachmentRef(id: UUID(), kind: .image, filename: "b.png", mimeType: "image/png"),
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0A]),
            route: .nativeImage
        )
        let message = TalkMessage(
            role: .user,
            content: [.text("look"), .attachment(first.ref), .attachment(second.ref)]
        )
        let content = ChatGPTProvider.content(for: message, options: ChatTurnOptions(attachments: [first, second]))
        let parts = content as? [[String: Any]]
        XCTAssertEqual(parts?.count, 3)
        XCTAssertEqual(parts?[0]["type"] as? String, "input_text")
        XCTAssertEqual(parts?[1]["type"] as? String, "input_image")
        XCTAssertEqual(parts?[2]["type"] as? String, "input_image")
    }

    func testCompatiblePayloadUsesImageURLParts() {
        let image = PreparedAttachment(
            ref: ChatAttachmentRef(id: UUID(), kind: .image, filename: "a.png", mimeType: "image/png"),
            data: Data([1, 2, 3]),
            route: .nativeImage
        )
        let message = TalkMessage(role: .user, content: [.text("hi"), .attachment(image.ref)])
        let content = GenericChatProvider.completionsContent(message, options: ChatTurnOptions(attachments: [image]))
        let parts = content as? [[String: Any]]
        XCTAssertEqual(parts?[1]["type"] as? String, "image_url")
    }

    func testCompatibleKeyAccountIsIsolatedFromChatGPT() {
        XCTAssertNotEqual(KeychainAccount.compatibleAPIKey.rawValue, KeychainAccount.chatGPT.rawValue)
        XCTAssertNotEqual(KeychainAccount.compatibleAPIKey.rawValue, KeychainAccount.cursorAPIKey.rawValue)
    }

    @MainActor
    func testKnownChatGPTImagePreparesWithoutCapabilityOverride() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileStore(root: root, context: container.mainContext)
        let defaults = UserDefaults(suiteName: "capability.prepare.\(UUID().uuidString)")!
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let asset = try store.importData(png, filename: "shot.png", ownerKind: .composer, ownerID: UUID(), orderIndex: 0)
        let prepared = try AttachmentPrep.prepare(
            refs: [asset.reference],
            history: [],
            provider: .chatgpt,
            model: "gpt-6.1-sol",
            endpoint: "",
            store: store,
            includeHistory: false,
            defaults: defaults
        )
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared[0].route, .nativeImage)
    }

    func testMissingAttachmentIsNotSilentlyDropped() {
        let missing = ChatAttachmentRef(id: UUID(), kind: .image, filename: "lost.png", mimeType: "image/png")
        let message = TalkMessage(role: .user, content: [.attachment(missing)])
        let content = ChatGPTProvider.content(for: message, options: ChatTurnOptions())
        let parts = content as? [[String: Any]]
        XCTAssertEqual(parts?.first?["type"] as? String, "input_text")
        XCTAssertTrue((parts?.first?["text"] as? String)?.contains("missing") == true)
    }
}
