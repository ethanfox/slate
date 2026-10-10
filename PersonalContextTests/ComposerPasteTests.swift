import AppKit
import XCTest
@testable import Slate

final class ComposerPasteTests: XCTestCase {
    func testPrefersImageOverTextRepresentation() throws {
        let board = NSPasteboard.withUniqueName()
        let png = try XCTUnwrap(tinyPNG())
        board.clearContents()
        board.declareTypes([.png, .string], owner: nil)
        board.setData(png, forType: .png)
        board.setString("https://example.com/shot.png", forType: .string)

        let payload = try XCTUnwrap(ComposerPaste.payload(from: board))
        guard case .image(let data, let filename) = payload else {
            return XCTFail("expected image payload, got \(payload)")
        }
        XCTAssertEqual(filename, "pasted-image.png")
        XCTAssertEqual(data, png)
    }

    func testConvertsClipboardTIFFToPNG() throws {
        let board = NSPasteboard.withUniqueName()
        let png = try XCTUnwrap(tinyPNG())
        let image = try XCTUnwrap(NSImage(data: png))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        board.clearContents()
        board.declareTypes([.tiff, .string], owner: nil)
        board.setData(tiff, forType: .tiff)
        board.setString("Screenshot 2026-10-09", forType: .string)

        let payload = try XCTUnwrap(ComposerPaste.payload(from: board))
        guard case .image(let data, let filename) = payload else {
            return XCTFail("expected image payload, got \(payload)")
        }
        XCTAssertEqual(filename, "pasted-image.png")
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        if case .image = FileTypeDetector.inspect(filename: filename, data: data) {
            // accepted native image
        } else {
            XCTFail("converted TIFF was not a usable image")
        }
    }

    func testPlainTextPasteIsUnchanged() {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.setString("just text", forType: .string)
        XCTAssertNil(ComposerPaste.payload(from: board))
    }

    func testPrefersExistingFileURLsOverImagePreview() throws {
        let board = NSPasteboard.withUniqueName()
        let png = try XCTUnwrap(tinyPNG())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        board.clearContents()
        board.declareTypes([.fileURL, .tiff], owner: nil)
        board.writeObjects([url as NSURL])
        board.setData(try XCTUnwrap(NSImage(data: png)?.tiffRepresentation), forType: .tiff)

        let payload = try XCTUnwrap(ComposerPaste.payload(from: board))
        guard case .files(let urls) = payload else {
            return XCTFail("expected file URLs, got \(payload)")
        }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["notes.txt"])
    }

    private func tinyPNG() -> Data? {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return ComposerPaste.pngData(from: image)
    }
}
