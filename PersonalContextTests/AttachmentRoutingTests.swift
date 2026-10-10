import XCTest
@testable import Slate

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

    func testMissingAttachmentIsNotSilentlyDropped() {
        let missing = ChatAttachmentRef(id: UUID(), kind: .image, filename: "lost.png", mimeType: "image/png")
        let message = TalkMessage(role: .user, content: [.attachment(missing)])
        let content = ChatGPTProvider.content(for: message, options: ChatTurnOptions())
        let parts = content as? [[String: Any]]
        XCTAssertEqual(parts?.first?["type"] as? String, "input_text")
        XCTAssertTrue((parts?.first?["text"] as? String)?.contains("missing") == true)
    }
}
