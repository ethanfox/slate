import XCTest
@testable import Membrae

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

    func testRendersUnorderedListWithBullet() {
        let rendered = ChatMarkdown.attributed("- One expiring key\n- URL/key setup")
        XCTAssertTrue(rendered.string.contains("• One expiring key"))
        XCTAssertTrue(rendered.string.contains("• URL/key setup"))
        XCTAssertFalse(rendered.string.contains("- One"))
    }

    func testRendersOrderedListWithNumbers() {
        let rendered = ChatMarkdown.attributed("1. Implement open object\n2. Finish widgets")
        XCTAssertTrue(rendered.string.contains("1. Implement open object"))
        XCTAssertTrue(rendered.string.contains("2. Finish widgets"))
    }

    func testMarksInlineCodeSpanForChipAndSelection() {
        let rendered = ChatMarkdown.attributed("See `this kind of text` now")
        let range = (rendered.string as NSString).range(of: "this kind of text")
        XCTAssertNotEqual(range.location, NSNotFound)
        XCTAssertEqual(rendered.attribute(.chatInlineCode, at: range.location, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(rendered.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
        let space = (rendered.string as NSString).range(of: "kind of")
        let span = ChatMarkdown.inlineCodeRange(at: space.location, in: rendered)
        XCTAssertEqual(span, ChatMarkdown.inlineCodeRange(at: range.location, in: rendered))
        XCTAssertEqual((rendered.string as NSString).substring(with: span ?? NSRange()), "this kind of text")
        XCTAssertNil(ChatMarkdown.inlineCodeRange(at: 0, in: rendered))
    }

    func testKeepsInlineCodeInsideListItem() {
        let rendered = ChatMarkdown.attributed("- Forward to `membrae-mcp` while open")
        let range = (rendered.string as NSString).range(of: "membrae-mcp")
        XCTAssertNotEqual(range.location, NSNotFound)
        let font = rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    func testDoesNotStyleMarkdownInsideFence() {
        let storage = NSTextStorage(string: "```\n**bold**\n```")
        MarkdownStyler.style(storage, font: .systemFont(ofSize: 15))
        let inner = (storage.string as NSString).range(of: "bold")
        let font = storage.attribute(.font, at: inner.location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testStructuredBlocksSkipIncrementalPaint() {
        XCTAssertTrue(ChatMarkdown.containsStructuredBlocks("```\nlet x = 1\n```"))
        XCTAssertTrue(ChatMarkdown.containsStructuredBlocks("| Field | Rule |\n| --- | --- |\n| Brief | Required. |"))
        XCTAssertTrue(ChatMarkdown.containsStructuredBlocks("> quoted"))
        XCTAssertTrue(ChatMarkdown.containsStructuredBlocks("---"))
        XCTAssertFalse(ChatMarkdown.containsStructuredBlocks("Just a sentence with a | pipe."))
    }

    func testSplitsStructuredSegments() {
        let source = """
        Intro

        > Keep one composer.

        ```swift
        struct ChatInput: View {}
        ```

        | Surface | Owner |
        | --- | --- |
        | Composer | ChatInput |
        """
        let segments = ChatMarkdown.segments(in: source)
        XCTAssertEqual(segments.count, 4)
        guard case .prose(let prose) = segments[0] else { return XCTFail("prose") }
        XCTAssertTrue(prose.contains("Intro"))
        guard case .quote(let quote) = segments[1] else { return XCTFail("quote") }
        XCTAssertEqual(quote, "Keep one composer.")
        guard case .fence(let language, let body) = segments[2] else { return XCTFail("fence") }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(body.contains("struct ChatInput"))
        guard case .table(let rows, _) = segments[3] else { return XCTFail("table") }
        XCTAssertEqual(rows.first, ["Surface", "Owner"])
    }

    func testRendersBlockquoteWithoutMarker() {
        let rendered = ChatMarkdown.attributed("> Hello there")
        XCTAssertTrue(rendered.string.contains("Hello there"))
        XCTAssertFalse(rendered.string.contains("> Hello"))
        let style = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertFalse(style?.textBlocks.isEmpty ?? true)
    }

    func testRendersQuotedListAndDropsMarkers() {
        let rendered = ChatMarkdown.attributed("> 1. First\n> 2. Second")
        XCTAssertTrue(rendered.string.contains("1. First"))
        XCTAssertTrue(rendered.string.contains("2. Second"))
        XCTAssertFalse(rendered.string.contains("> 1."))
    }

    func testRendersNestedBlockquote() {
        let rendered = ChatMarkdown.attributed("> outer\n>> inner")
        XCTAssertTrue(rendered.string.contains("outer"))
        XCTAssertTrue(rendered.string.contains("inner"))
        XCTAssertFalse(rendered.string.contains(">"))
    }

    func testKeepsQuoteMarkerInsideFence() {
        let rendered = ChatMarkdown.attributed("```\n> not a quote\n```")
        XCTAssertTrue(rendered.string.contains("> not a quote"))
    }

    func testRendersStrikethrough() {
        let rendered = ChatMarkdown.attributed("keep ~~this~~")
        XCTAssertEqual(rendered.string, "keep this")
        let range = (rendered.string as NSString).range(of: "this")
        XCTAssertNotEqual(range.location, NSNotFound)
        XCTAssertNotNil(rendered.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil))
    }

    func testRendersThematicBreak() {
        let rendered = ChatMarkdown.attributed("Before\n---\nAfter")
        XCTAssertTrue(rendered.string.contains("Before"))
        XCTAssertTrue(rendered.string.contains("After"))
        XCTAssertFalse(rendered.string.contains("---"))
    }

    func testRendersTaskList() {
        let rendered = ChatMarkdown.attributed("- [ ] open\n- [x] done")
        XCTAssertTrue(rendered.string.contains("open"))
        XCTAssertTrue(rendered.string.contains("done"))
        XCTAssertTrue(rendered.string.contains("☐"))
        XCTAssertTrue(rendered.string.contains("☑"))
        XCTAssertFalse(rendered.string.contains("[ ]"))
        XCTAssertFalse(rendered.string.contains("[x]"))
    }

    func testRendersNestedList() {
        let rendered = ChatMarkdown.attributed("- parent\n  - child")
        XCTAssertTrue(rendered.string.contains("• parent"))
        XCTAssertTrue(rendered.string.contains("◦ child"))
    }

    func testRendersAutolinkAndBareURL() {
        let angled = ChatMarkdown.attributed("See <https://example.com>")
        XCTAssertFalse(angled.string.contains("<https"))
        let angledRange = (angled.string as NSString).range(of: "https://example.com")
        XCTAssertNotEqual(angledRange.location, NSNotFound)
        XCTAssertNotNil(angled.attribute(.link, at: angledRange.location, effectiveRange: nil))

        let bare = ChatMarkdown.attributed("See https://example.com now")
        let bareRange = (bare.string as NSString).range(of: "https://example.com")
        XCTAssertNotEqual(bareRange.location, NSNotFound)
        XCTAssertNotNil(bare.attribute(.link, at: bareRange.location, effectiveRange: nil))
    }

    func testRendersBoldItalic() {
        let rendered = ChatMarkdown.attributed("***both***")
        XCTAssertEqual(rendered.string, "both")
        let font = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    }

    func testRendersImageAsLink() {
        let rendered = ChatMarkdown.attributed("![Alt](https://example.com/a.png)")
        XCTAssertEqual(rendered.string, "Alt")
        XCTAssertNotNil(rendered.attribute(.link, at: 0, effectiveRange: nil))
    }

    func testProseLineFragmentCapsAtMeasure() {
        let container = MarkdownTextContainer(size: NSSize(width: 1200, height: 10_000))
        container.lineFragmentPadding = 0
        let rect = container.lineFragmentRect(
            forProposedRect: NSRect(x: 0, y: 0, width: 1200, height: 18),
            at: 0,
            writingDirection: .leftToRight,
            remaining: nil
        )
        XCTAssertEqual(rect.width, DocumentMeasure.proseWidth, accuracy: 0.01)
    }

    func testTableFaceFillsEqualColumns() {
        let face = MarkdownTableFace(
            source: "| A | B |\n| --- | --- |\n| Hello world this wraps | x |",
            fontSize: 15
        )
        let layout = face.layout(forWidth: 800)
        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.columnWidth, 400, accuracy: 0.01)
        XCTAssertEqual(layout.textWidth, 384, accuracy: 0.01)
        XCTAssertGreaterThan(layout.height, 22)
    }

    func testTableFaceTextUsesWiderColumns() {
        let face = MarkdownTableFace(
            source: "| Feature | Benefit |\n| --- | --- |\n| Project knowledge base | Stop rebuilding context every time work resumes or moves between tools. |",
            fontSize: 15
        )
        let narrow = face.layout(forWidth: 400)
        let wide = face.layout(forWidth: 900)
        XCTAssertGreaterThan(wide.textWidth, narrow.textWidth)
        XCTAssertLessThan(wide.height, narrow.height)
    }

    func testFenceAndTableNeedMoreThanOneLineOfHeight() {
        let line = measure(ChatMarkdown.attributed("Hello"))
        let fence = measure(ChatMarkdown.attributed("```\nline one\nline two\nline three\n```"))
        let table = measure(ChatMarkdown.attributed("| Field | Rule |\n| --- | --- |\n| Brief | Required. |"))
        XCTAssertGreaterThan(fence, line + 20)
        XCTAssertGreaterThan(table, line + 20)
    }

    private func measure(_ attributed: NSAttributedString) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        return ChatMarkdown.layoutHeight(layoutManager: layout, textContainer: container, storage: storage)
    }
}
