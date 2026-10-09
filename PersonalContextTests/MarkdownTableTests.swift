import XCTest
@testable import Slate

final class MarkdownTableTests: XCTestCase {
    func testFindsPipeTable() {
        let source = """
        Intro

        | Field | Rule |
        | --- | --- |
        | Brief | Required. |

        After
        """
        let blocks = ChatMarkdown.tableBlocks(in: source)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].source.contains("| Field | Rule |"))
        XCTAssertTrue(blocks[0].source.contains("| Brief | Required. |"))
        XCTAssertEqual((source as NSString).substring(with: blocks[0].range), blocks[0].source)
    }

    func testIgnoresPipesWithoutSeparator() {
        let blocks = ChatMarkdown.tableBlocks(in: "Field | Rule |\nNot a table")
        XCTAssertTrue(blocks.isEmpty)
    }

    func testIgnoresFencedTable() {
        let source = """
        ```
        | Field | Rule |
        | --- | --- |
        | Brief | Required. |
        ```
        """
        XCTAssertTrue(ChatMarkdown.tableBlocks(in: source).isEmpty)
    }

    func testStylesTableForRender() {
        let storage = NSTextStorage(string: """
        | Field | Rule |
        | --- | --- |
        | Brief | Required. |
        """)
        MarkdownStyler.style(storage, font: .systemFont(ofSize: 15))
        let blocks = ChatMarkdown.tableBlocks(in: storage.string)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertEqual(storage.attribute(.markdownMarker, at: blocks[0].range.location, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(storage.attribute(.markdownTable, at: blocks[0].range.location, effectiveRange: nil) as? String, blocks[0].source)
    }

    func testKeepsSourceWhenEditingTable() {
        let storage = NSTextStorage(string: """
        | Field | Rule |
        | --- | --- |
        | Brief | Required. |
        """)
        MarkdownStyler.style(storage, font: .systemFont(ofSize: 15), sourceRanges: [NSRange(location: 0, length: 8)])
        var rendered = false
        storage.enumerateAttribute(.markdownTable, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            rendered = value != nil
        }
        XCTAssertFalse(rendered)
    }

    func testFindsFenceAndLeavesTablesInside() {
        let source = """
        Before
        ```swift
        let x = 1
        ```
        After
        """
        let fences = ChatMarkdown.fenceBlocks(in: source)
        XCTAssertEqual(fences.count, 1)
        XCTAssertTrue((source as NSString).substring(with: fences[0].body).contains("let x = 1"))
        XCTAssertNotNil(fences[0].close)
    }

    func testStylesInlineCodeAsMonoChip() {
        let storage = NSTextStorage(string: "Use `this` here")
        MarkdownStyler.style(storage, font: .systemFont(ofSize: 15))
        let inner = (storage.string as NSString).range(of: "this")
        let font = storage.attribute(.font, at: inner.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: inner.location, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(.markdownMarker, at: inner.location - 1, effectiveRange: nil) as? Bool, true)
    }

    func testStylesFenceBodyAndHidesTicks() {
        let storage = NSTextStorage(string: "```swift\nlet x = 1\n```")
        MarkdownStyler.style(storage, font: .systemFont(ofSize: 15))
        let fences = ChatMarkdown.fenceBlocks(in: storage.string)
        XCTAssertEqual(fences.count, 1)
        XCTAssertEqual(storage.attribute(.markdownCollapsed, at: fences[0].open.location, effectiveRange: nil) as? Bool, true)
        let body = (storage.string as NSString).range(of: "let x = 1")
        let font = storage.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        let style = storage.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertFalse(style?.textBlocks.isEmpty ?? true)
    }

    func testDoesNotStyleMarkdownInsideFence() {
        let storage = NSTextStorage(string: "```\n**bold**\n```")
        MarkdownStyler.style(storage, font: .systemFont(ofSize: 15))
        let inner = (storage.string as NSString).range(of: "bold")
        let font = storage.attribute(.font, at: inner.location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }
}
