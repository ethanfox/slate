import XCTest
@testable import Slate

final class FileExtractionTests: XCTestCase {
    func testDetectsPNGAndRejectsAnimatedGIFHeuristic() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if case .image(let mime, let animated) = FileTypeDetector.inspect(filename: "a.png", data: png) {
            XCTAssertEqual(mime, "image/png")
            XCTAssertFalse(animated)
        } else {
            XCTFail("expected png")
        }

        var gif = Data("GIF89a".utf8)
        gif.append(contentsOf: [0x2C, 0x00, 0x2C])
        if case .image(_, let animated) = FileTypeDetector.inspect(filename: "a.gif", data: gif) {
            XCTAssertTrue(animated)
        } else {
            XCTFail("expected gif")
        }
    }

    func testTextExtractionPreservesCSV() throws {
        let csv = "a,b\n1,2\n"
        let extracted = try FileExtraction.extract(
            filename: "t.csv",
            mimeType: "text/csv",
            data: Data(csv.utf8)
        )
        XCTAssertEqual(extracted.text, csv)
        XCTAssertTrue(extracted.disclosure.contains("t.csv"))
    }

    func testExtractedTooLargeIsRejected() {
        let text = String(repeating: "x", count: AttachmentLimits.maxExtractedCharacters + 1)
        XCTAssertThrowsError(
            try FileExtraction.extract(filename: "big.txt", mimeType: "text/plain", data: Data(text.utf8))
        ) { error in
            XCTAssertEqual(error as? AttachmentError, .extractedTooLarge("big.txt"))
        }
    }

    func testInvalidEncodingIsVisible() {
        XCTAssertThrowsError(
            try FileExtraction.extract(
                filename: "bad.txt",
                mimeType: "text/plain",
                data: Data([0xC0])
            )
        )
    }
}
