import AppKit
import SwiftData
import SwiftUI

struct AssistantMarkdown: View {
    var text: String
    var sources: [ChatSource] = []
    var pinUnused = true
    var streaming = false
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        let blocks = ChatObjectLink.blocks(in: text)
        let leftover = ChatObjectLink.unlinked(sources, in: text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                switch block.content {
                case .text(let value):
                    MarkdownBlock(
                        text: value,
                        sources: leftover,
                        pinUnused: pinUnused && isLastText(index, in: blocks),
                        streaming: streaming && isLastText(index, in: blocks) && !reduceMotion,
                        modelContext: modelContext,
                        onOpen: { $0.open(app: app, context: modelContext) }
                    )
                case .object(let source):
                    ObjectLinkCard(source: source) {
                        source.open(app: app, context: modelContext)
                    }
                }
            }
        }
        .transaction { transaction in
            if streaming { transaction.animation = nil }
        }
    }

    private func isLastText(_ index: Int, in blocks: [ChatContentBlock]) -> Bool {
        !blocks.suffix(from: index + 1).contains { block in
            if case .text = block.content { return true }
            return false
        }
    }
}

private struct MarkdownBlock: View {
    var text: String
    var sources: [ChatSource]
    var pinUnused: Bool
    var streaming: Bool
    var modelContext: ModelContext
    var onOpen: (ChatSource) -> Void
    @State private var hover: LinkHover?

    var body: some View {
        MarkdownBody(
            text: text,
            sources: sources,
            pinUnused: pinUnused,
            streaming: streaming,
            hover: $hover,
            modelContext: modelContext,
            onOpen: onOpen
        )
        .overlay(alignment: .topLeading) {
            if let hover {
                LinkPreviewCard(url: hover.url)
                    .offset(x: hover.rect.minX, y: previewY(for: hover.rect, height: 76))
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.hover, value: hover?.url)
    }

    private func previewY(for rect: CGRect, height: CGFloat) -> CGFloat {
        let above = rect.minY - height
        return above > 4 ? above : rect.maxY + 8
    }
}

private struct LinkHover: Equatable {
    var url: URL
    var rect: CGRect
}

private struct MarkdownBody: NSViewRepresentable {
    var text: String
    var sources: [ChatSource]
    var pinUnused: Bool
    var streaming: Bool
    @Binding var hover: LinkHover?
    var modelContext: ModelContext
    var onOpen: (ChatSource) -> Void

    func makeNSView(context: Context) -> AssistantMarkdownTextView {
        let view = AssistantMarkdownTextView()
        bind(view)
        view.apply(text, sources: sources, pinUnused: pinUnused, streaming: streaming, context: modelContext)
        return view
    }

    func updateNSView(_ view: AssistantMarkdownTextView, context: Context) {
        bind(view)
        view.apply(text, sources: sources, pinUnused: pinUnused, streaming: streaming, context: modelContext)
    }

    private func bind(_ view: AssistantMarkdownTextView) {
        view.onHoverLink = { url, rect in
            if let url, let rect {
                hover = LinkHover(url: url, rect: rect)
            } else {
                hover = nil
            }
        }
        view.pager.onOpen = onOpen
        view.pager.context = modelContext
        view.onOpenSource = { source in
            view.pager.close()
            onOpen(source)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AssistantMarkdownTextView, context: Context) -> CGSize? {
        nsView.fittedSize(for: proposal.width)
    }
}

fileprivate final class AssistantMarkdownTextView: NSTextView {
    var onHoverLink: ((URL?, CGRect?) -> Void)?
    var onOpenSource: ((ChatSource) -> Void)?
    let pager = SourcePagerAnchor()
    private var shown = ""
    private var sourceIDs: [String] = []
    private var pendingSources: [ChatSource] = []
    private var pendingPin = true
    private var pendingContext: ModelContext?
    private var tracking: NSTrackingArea?
    private var sizing = false
    private var fittedWidth: CGFloat = 0
    private var fittedHeight: CGFloat = 22
    private var paintedPrefix = ""
    private var paintedPrefixLength = 0

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { pager.close() }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func apply(_ text: String, sources: [ChatSource] = [], pinUnused: Bool = true, streaming: Bool = false, context: ModelContext? = nil) {
        let sameSources = sourceIDs == sources.map(\.id) && pendingPin == pinUnused
        pendingSources = sources
        pendingPin = pinUnused
        pendingContext = context
        sourceIDs = sources.map(\.id)
        if !streaming {
            if shown != text || !sameSources {
                paint(text)
            }
            return
        }
        if shown == text, sameSources { return }
        if sameSources, paintIncremental(text) { return }
        paint(text)
    }

    private func paintIncremental(_ text: String) -> Bool {
        guard pendingSources.isEmpty else { return false }
        guard text.hasPrefix(paintedPrefix) || paintedPrefix.isEmpty else { return false }
        let start = ChatMarkdown.incompleteStart(in: text)
        let prefix = String(text[..<start])
        let tail = ChatMarkdown.attributed(String(text[start...]))
        if prefix == paintedPrefix, let storage = textStorage {
            let range = NSRange(location: paintedPrefixLength, length: max(0, storage.length - paintedPrefixLength))
            storage.replaceCharacters(in: range, with: tail)
            shown = text
            fittedWidth = 0
            invalidateIntrinsicContentSize()
            return true
        }
        if prefix.hasPrefix(paintedPrefix), let storage = textStorage {
            let rest = ChatMarkdown.attributed(String(text.dropFirst(paintedPrefix.count)))
            let range = NSRange(location: paintedPrefixLength, length: max(0, storage.length - paintedPrefixLength))
            storage.replaceCharacters(in: range, with: rest)
            shown = text
            paintedPrefix = prefix
            paintedPrefixLength = storage.length - tail.length
            fittedWidth = 0
            invalidateIntrinsicContentSize()
            return true
        }
        return false
    }

    private func paint(_ text: String) {
        shown = text
        fittedWidth = 0
        let selected = selectedRange()
        let rendered = Self.attributed(text, sources: pendingSources, pinUnused: pendingPin, context: pendingContext)
        textStorage?.setAttributedString(rendered)
        let start = ChatMarkdown.incompleteStart(in: text)
        paintedPrefix = String(text[..<start])
        let tailLength = ChatMarkdown.attributed(String(text[start...])).length
        paintedPrefixLength = max(0, rendered.length - tailLength)
        let max = (string as NSString).length
        let location = min(selected.location, max)
        setSelectedRange(NSRange(location: location, length: min(selected.length, max - location)))
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: self)
        if !pendingSources.isEmpty {
            loadChipIcons()
        }
    }

    func fittedSize(for proposed: CGFloat?) -> CGSize {
        let width: CGFloat
        if let proposed, proposed > 1 {
            width = proposed.rounded()
        } else if fittedWidth > 1 {
            width = fittedWidth
        } else {
            width = 680
        }
        return CGSize(width: width, height: height(forWidth: width))
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let width = width.rounded()
        if width <= 1 { return fittedHeight }
        if abs(width - fittedWidth) < 0.5 { return fittedHeight }
        guard let layoutManager, let textContainer else { return 22 }
        let target = NSSize(width: width, height: .greatestFiniteMagnitude)
        if abs(textContainer.containerSize.width - target.width) > 0.5 {
            sizing = true
            textContainer.containerSize = target
            sizing = false
        }
        layoutManager.ensureLayout(for: textContainer)
        fittedWidth = width
        fittedHeight = ceil(max(layoutManager.usedRect(for: textContainer).height, 22))
        return fittedHeight
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !sizing else { return }
        sizing = true
        textContainer?.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
        sizing = false
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        enumerateLinkRects { rect, _ in
            self.addCursorRect(rect, cursor: .pointingHand)
        }
        enumerateSourceRects { rect, _ in
            self.addCursorRect(rect, cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        reportHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverLink?(nil, nil)
        pager.hideSoon()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let sources = sources(at: point), let first = sources.first {
            onOpenSource?(first)
            return
        }
        if let url = link(at: point), let source = ChatObjectLink.parse(url) {
            onOpenSource?(source)
            return
        }
        super.mouseDown(with: event)
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        let url: URL?
        if let value = link as? URL { url = value }
        else if let string = link as? String { url = URL(string: string) }
        else { url = nil }
        if let url, let source = ChatObjectLink.parse(url) {
            onOpenSource?(source)
            return
        }
        super.clicked(onLink: link, at: charIndex)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if link(at: point) != nil || sources(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {}

    private func reportHover(at point: NSPoint) {
        if let sources = sources(at: point), let rect = chipRect(for: sources) {
            onHoverLink?(nil, nil)
            pager.show(sources: sources, from: self, rect: rect)
            return
        }
        pager.hideSoon()
        guard let url = link(at: point) else {
            onHoverLink?(nil, nil)
            return
        }
        var first: CGRect?
        enumerateLinkRects { rect, link in
            if link == url, first == nil { first = rect }
        }
        onHoverLink?(url, first)
    }

    private func sources(at point: NSPoint) -> [ChatSource]? {
        var hit: [ChatSource]?
        enumerateSourceRects { rect, sources in
            if rect.insetBy(dx: -3, dy: -3).contains(point) { hit = sources }
        }
        return hit
    }

    private func chipRect(for sources: [ChatSource]) -> CGRect? {
        var first: CGRect?
        enumerateSourceRects { rect, value in
            if value.map(\.id) == sources.map(\.id), first == nil { first = rect }
        }
        return first
    }

    private func enumerateSourceRects(_ body: @escaping (CGRect, [ChatSource]) -> Void) {
        guard let layoutManager, let textContainer, let textStorage else { return }
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.chatSources, in: full) { value, range, _ in
            guard let sources = value as? [ChatSource] else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                body(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), sources)
            }
        }
    }

    private func loadChipIcons() {
        guard let textStorage else { return }
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.attachment, in: full) { value, _, _ in
            guard let attachment = value as? SourceChipAttachment,
                  let url = attachment.sources.first?.url.flatMap(URL.init(string:))
            else { return }
            Task { @MainActor in
                let icon = await FaviconStore.shared.image(for: url)
                attachment.icon = icon
                self.needsDisplay = true
                self.invalidateIntrinsicContentSize()
            }
        }
    }

    private func link(at point: NSPoint) -> URL? {
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index < textStorage.length else { return nil }
        let value = textStorage.attribute(.link, at: index, effectiveRange: nil)
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func enumerateLinkRects(_ body: @escaping (CGRect, URL) -> Void) {
        guard let layoutManager, let textContainer, let textStorage else { return }
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.link, in: full) { value, range, _ in
            let url: URL?
            if let value = value as? URL { url = value }
            else if let string = value as? String { url = URL(string: string) }
            else { url = nil }
            guard let url else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                body(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), url)
            }
        }
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        backgroundColor = .clear
        insertionPointColor = .clear
        focusRingType = .none
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        usesAdaptiveColorMappingForDarkAppearance = true
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
    }

    private static func attributed(_ markdown: String, sources: [ChatSource] = [], pinUnused: Bool = true, context: ModelContext? = nil) -> NSAttributedString {
        let result = ChatMarkdown.attributed(markdown)
        insertSources(sources, pinUnused: pinUnused, context: context, into: result)
        return result
    }

    private static func insertSources(_ sources: [ChatSource], pinUnused: Bool, context: ModelContext?, into result: NSMutableAttributedString) {
        let placements = ChatSourceMatcher.place(sources, in: result.string, pinUnused: pinUnused)
        for placement in placements.reversed() {
            let live = placement.sources.map { $0.presented(in: context).source }
            let attachment = SourceChipAttachment(sources: live)
            let chip = NSMutableAttributedString(string: " ")
            chip.append(NSAttributedString(attachment: attachment))
            chip.addAttribute(.chatSources, value: live, range: NSRange(location: 0, length: chip.length))
            let location = min(max(placement.utf16, 0), result.length)
            result.insert(chip, at: location)
        }
    }
}

struct MarkdownTableBlock: Equatable {
    var range: NSRange
    var source: String
}

struct MarkdownFenceBlock: Equatable {
    var range: NSRange
    var open: NSRange
    var body: NSRange
    var close: NSRange?
}

/// Styles markers in the source text. Does not join lines or drop spaces.
enum ChatMarkdown {
    static let inlineFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(white: 0, alpha: 0.08)
    }

    static let blockFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(white: 0, alpha: 0.045)
    }
    static func incompleteStart(in source: String) -> String.Index {
        var inFence = false
        var fenceStart = source.startIndex
        var lineStart = source.startIndex
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "\n" {
                if source[lineStart..<index].hasPrefix("```") {
                    if inFence {
                        inFence = false
                    } else {
                        inFence = true
                        fenceStart = lineStart
                    }
                }
                lineStart = source.index(after: index)
            }
            index = source.index(after: index)
        }
        return inFence ? fenceStart : lineStart
    }

    static func attributed(_ source: String, fontSize: CGFloat = 15) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = takeFence(lines, from: index) {
                result.append(renderFence(fence.lines, fontSize: fontSize))
                if fence.end < lines.count {
                    result.append(breakLine(fontSize: fontSize, empty: true))
                }
                index = fence.end
                continue
            }
            if let table = takeTable(lines, from: index) {
                result.append(renderTable(table.rows, alignments: table.alignments, fontSize: fontSize))
                if table.end < lines.count {
                    result.append(breakLine(fontSize: fontSize, empty: true))
                }
                index = table.end
                continue
            }
            if let list = takeList(lines, from: index) {
                result.append(renderList(list, fontSize: fontSize))
                if list.end < lines.count {
                    result.append(breakLine(fontSize: fontSize, empty: isBlank(lines[list.end])))
                }
                index = list.end
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            result.append(renderLine(line, fontSize: fontSize))
            if index < lines.count - 1 {
                result.append(breakLine(fontSize: fontSize, empty: isBlank(lines[index + 1])))
            }
            index += 1
        }
        return result
    }

    static func tableBlocks(in source: String) -> [MarkdownTableBlock] {
        let parsed = lines(in: source)
        var blocks: [MarkdownTableBlock] = []
        var inFence = false
        var index = 0
        while index < parsed.texts.count {
            if parsed.texts[index].hasPrefix("```") {
                inFence.toggle()
                index += 1
                continue
            }
            if !inFence, let table = takeTable(parsed.texts, from: index) {
                let start = parsed.ranges[index].location
                let last = parsed.ranges[table.end - 1]
                let range = NSRange(location: start, length: last.upperBound - start)
                blocks.append(MarkdownTableBlock(range: range, source: (source as NSString).substring(with: range)))
                index = table.end
                continue
            }
            index += 1
        }
        return blocks
    }

    static func fenceBlocks(in source: String) -> [MarkdownFenceBlock] {
        let parsed = lines(in: source)
        var blocks: [MarkdownFenceBlock] = []
        var index = 0
        while index < parsed.texts.count {
            guard parsed.texts[index].hasPrefix("```"),
                  let fence = takeFence(parsed.texts, from: index) else {
                index += 1
                continue
            }
            let open = parsed.ranges[index]
            let close = fence.closed ? parsed.ranges[fence.end - 1] : nil
            let bodyStart = open.upperBound
            let bodyEnd = close?.location ?? parsed.ranges[fence.end - 1].upperBound
            let body = NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart))
            let end = close?.upperBound ?? body.upperBound
            blocks.append(MarkdownFenceBlock(
                range: NSRange(location: open.location, length: end - open.location),
                open: open,
                body: body,
                close: close
            ))
            index = fence.end
        }
        return blocks
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func lines(in source: String) -> (ranges: [NSRange], texts: [String]) {
        let ns = source as NSString
        var ranges: [NSRange] = []
        var texts: [String] = []
        var cursor = 0
        while cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            ranges.append(line)
            var text = line
            if text.length > 0, ns.substring(with: NSRange(location: text.upperBound - 1, length: 1)) == "\n" {
                text.length -= 1
            }
            texts.append(ns.substring(with: text))
            cursor = line.upperBound
        }
        return (ranges, texts)
    }

    private static func takeFence(
        _ lines: [String],
        from start: Int
    ) -> (lines: [String], end: Int, closed: Bool)? {
        guard start < lines.count, lines[start].hasPrefix("```") else { return nil }
        var body: [String] = []
        var index = start + 1
        while index < lines.count {
            if lines[index].hasPrefix("```") {
                return (body, index + 1, true)
            }
            body.append(lines[index])
            index += 1
        }
        return (body, index, false)
    }

    private static func renderFence(_ lines: [String], fontSize: CGFloat) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.collapsesBorders = true
        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        block.backgroundColor = blockFill
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [block]
        paragraph.lineSpacing = 3
        let text = lines.joined(separator: "\n")
        let cell = NSMutableAttributedString(string: text.isEmpty ? " " : text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        cell.append(breakLine(fontSize: fontSize - 1, empty: false))
        cell.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length))
        return cell
    }

    private static func takeTable(
        _ lines: [String],
        from start: Int
    ) -> (rows: [[String]], alignments: [NSTextAlignment], end: Int)? {
        guard start + 1 < lines.count, isTableRow(lines[start]) else { return nil }
        let separator = tableCells(in: lines[start + 1])
        guard isSeparatorRow(separator) else { return nil }
        var rows = [tableCells(in: lines[start])]
        var index = start + 2
        while index < lines.count {
            let line = lines[index]
            guard isTableRow(line), !isSeparatorRow(tableCells(in: line)) else { break }
            rows.append(tableCells(in: line))
            index += 1
        }
        return (rows, alignments(from: separator), index)
    }

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && tableCells(in: trimmed).count >= 2
    }

    private static func tableCells(in line: String) -> [String] {
        var raw = line.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("|") { raw.removeFirst() }
        if raw.hasSuffix("|") { raw.removeLast() }
        return raw.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let marks = cell.filter { !$0.isWhitespace }
            return marks.contains("-") && marks.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func alignments(from cells: [String]) -> [NSTextAlignment] {
        cells.map { cell in
            let marks = cell.trimmingCharacters(in: .whitespaces)
            let leading = marks.hasPrefix(":")
            let trailing = marks.hasSuffix(":")
            if leading && trailing { return .center }
            if trailing { return .right }
            return .left
        }
    }

    private static func renderTable(
        _ rows: [[String]],
        alignments: [NSTextAlignment],
        fontSize: CGFloat
    ) -> NSAttributedString {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return NSAttributedString() }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        let result = NSMutableAttributedString()
        for (row, cells) in rows.enumerated() {
            for column in 0..<columns {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: row,
                    rowSpan: 1,
                    startingColumn: column,
                    columnSpan: 1
                )
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(8, type: .absoluteValueType, for: .padding)
                block.setValue(100 / CGFloat(columns), type: .percentageValueType, for: .width)
                if row == 0 {
                    block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06)
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.lineSpacing = 3
                paragraph.alignment = column < alignments.count ? alignments[column] : .left
                let value = column < cells.count ? cells[column] : ""
                let cell = NSMutableAttributedString(
                    attributedString: renderInline(
                        value.isEmpty ? " " : value,
                        fontSize: fontSize - 1,
                        header: row == 0 ? 6 : nil,
                        list: false
                    )
                )
                cell.append(breakLine(fontSize: fontSize - 1, empty: false))
                cell.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length))
                result.append(cell)
            }
        }
        return result
    }

    private static func takeList(
        _ lines: [String],
        from start: Int
    ) -> (ordered: Bool, number: Int, items: [String], end: Int)? {
        guard start < lines.count, let first = listItem(lines[start]) else { return nil }
        var items = [first.text]
        var index = start + 1
        while index < lines.count {
            if isBlank(lines[index]) {
                if let next = nextListItem(lines, after: index), next.ordered == first.ordered {
                    index += 1
                    continue
                }
                break
            }
            guard let item = listItem(lines[index]), item.ordered == first.ordered else { break }
            items.append(item.text)
            index += 1
        }
        return (first.ordered, first.number, items, index)
    }

    private static func nextListItem(_ lines: [String], after index: Int) -> (ordered: Bool, number: Int, text: String)? {
        var cursor = index + 1
        while cursor < lines.count {
            if isBlank(lines[cursor]) {
                cursor += 1
                continue
            }
            return listItem(lines[cursor])
        }
        return nil
    }

    private static func listItem(_ line: String) -> (ordered: Bool, number: Int, text: String)? {
        let trimmed = line.drop(while: \.isWhitespace)
        if trimmed.hasPrefix("- ") { return (false, 1, String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("* ") { return (false, 1, String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("+ ") { return (false, 1, String(trimmed.dropFirst(2))) }
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let after = trimmed.dropFirst(digits.count)
        guard after.hasPrefix(". ") else { return nil }
        return (true, Int(digits) ?? 1, String(after.dropFirst(2)))
    }

    private static func renderList(
        _ list: (ordered: Bool, number: Int, items: [String], end: Int),
        fontSize: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (offset, item) in list.items.enumerated() {
            let marker = list.ordered ? "\(list.number + offset). " : "• "
            let indent = list.ordered ? 28 : 22
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = CGFloat(indent)
            paragraph.firstLineHeadIndent = 0
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 6
            let body = NSMutableAttributedString(
                attributedString: piece(marker, fontSize: fontSize, header: nil, list: true)
            )
            body.append(renderInline(item, fontSize: fontSize, header: nil, list: true))
            if item.isEmpty {
                body.append(NSAttributedString(string: "\u{00a0}"))
            }
            body.append(breakLine(fontSize: fontSize, empty: false))
            body.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: body.length))
            result.append(body)
        }
        return result
    }

    private static func renderLine(_ line: String, fontSize: CGFloat) -> NSAttributedString {
        var rest = Substring(line)
        var header: Int?
        let hashes = rest.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), rest.dropFirst(hashes).first == " " {
            header = hashes
            rest = rest.dropFirst(hashes + 1)
        }
        return renderInline(String(rest), fontSize: fontSize, header: header, list: lineHasList(line))
    }

    private static func lineHasList(_ line: String) -> Bool {
        let trimmed = line.drop(while: \.isWhitespace)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        let digits = trimmed.prefix(while: \.isNumber)
        return !digits.isEmpty && trimmed.dropFirst(digits.count).hasPrefix(". ")
    }

    private static func renderInline(_ text: String, fontSize: CGFloat, header: Int?, list: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var index = text.startIndex
        while index < text.endIndex {
            if let fence = take(text, from: index, opening: "`", closing: "`") {
                result.append(piece(fence.inner, fontSize: fontSize, header: header, list: list, code: true))
                index = fence.end
                continue
            }
            if let link = takeLink(text, from: index) {
                result.append(piece(link.label, fontSize: fontSize, header: header, list: list, url: link.url))
                index = link.end
                continue
            }
            if let bold = take(text, from: index, opening: "**", closing: "**")
                ?? take(text, from: index, opening: "__", closing: "__") {
                result.append(piece(bold.inner, fontSize: fontSize, header: header, list: list, bold: true))
                index = bold.end
                continue
            }
            if let italic = take(text, from: index, opening: "*", closing: "*")
                ?? take(text, from: index, opening: "_", closing: "_") {
                result.append(piece(italic.inner, fontSize: fontSize, header: header, list: list, italic: true))
                index = italic.end
                continue
            }
            let next = specialStart(text, from: index) ?? text.endIndex
            if next > index {
                result.append(piece(String(text[index..<next]), fontSize: fontSize, header: header, list: list))
                index = next
            } else {
                result.append(piece(String(text[index]), fontSize: fontSize, header: header, list: list))
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func take(
        _ text: String,
        from start: String.Index,
        opening: String,
        closing: String
    ) -> (inner: String, end: String.Index)? {
        guard text[start...].hasPrefix(opening) else { return nil }
        let innerStart = text.index(start, offsetBy: opening.count)
        guard innerStart < text.endIndex else { return nil }
        var search = innerStart
        while let found = text[search...].range(of: closing) {
            if found.lowerBound > innerStart {
                return (String(text[innerStart..<found.lowerBound]), found.upperBound)
            }
            search = found.upperBound
        }
        return nil
    }

    private static func takeLink(
        _ text: String,
        from start: String.Index
    ) -> (label: String, url: URL, end: String.Index)? {
        guard text[start] == "[" , let close = text[start...].range(of: "](") else { return nil }
        let labelStart = text.index(after: start)
        guard close.lowerBound > labelStart else { return nil }
        let urlStart = close.upperBound
        guard let end = text[urlStart...].firstIndex(of: ")") else { return nil }
        let label = String(text[labelStart..<close.lowerBound])
        guard let url = URL(string: String(text[urlStart..<end])) else { return nil }
        return (label, url, text.index(after: end))
    }

    private static func specialStart(_ text: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < text.endIndex {
            switch text[index] {
            case "`", "[", "*":
                return index
            case "_":
                return index
            default:
                index = text.index(after: index)
            }
        }
        return nil
    }

    private static func piece(
        _ text: String,
        fontSize: CGFloat,
        header: Int?,
        list: Bool,
        bold: Bool = false,
        italic: Bool = false,
        code: Bool = false,
        url: URL? = nil
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: attributes(
            fontSize: fontSize,
            header: header,
            list: list,
            bold: bold,
            italic: italic,
            code: code,
            url: url,
            empty: text.isEmpty
        ))
    }

    private static func breakLine(fontSize: CGFloat, empty: Bool) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: attributes(fontSize: fontSize, empty: empty))
    }

    private static func attributes(
        fontSize: CGFloat,
        header: Int? = nil,
        list: Bool = false,
        bold: Bool = false,
        italic: Bool = false,
        code: Bool = false,
        url: URL? = nil,
        empty: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = empty ? 8 : 4
        if let header {
            paragraph.paragraphSpacingBefore = header == 1 ? 16 : 12
            paragraph.paragraphSpacing = 8
        }
        if list {
            paragraph.headIndent = 22
            paragraph.firstLineHeadIndent = 0
            paragraph.paragraphSpacing = 4
        }
        let font: NSFont
        if code {
            font = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
        } else if let header {
            font = NSFont.systemFont(ofSize: fontSize + CGFloat(max(0, 5 - header)) * 2, weight: .semibold)
        } else {
            var traits = NSFont.systemFont(ofSize: fontSize).fontDescriptor.symbolicTraits
            if bold { traits.insert(.bold) }
            if italic { traits.insert(.italic) }
            font = NSFont(
                descriptor: NSFont.systemFont(ofSize: fontSize).fontDescriptor.withSymbolicTraits(traits),
                size: fontSize
            ) ?? NSFont.systemFont(ofSize: fontSize, weight: bold ? .semibold : .regular)
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: url == nil ? NSColor.labelColor : NSColor.linkColor,
            .paragraphStyle: paragraph
        ]
        if code {
            attrs[.backgroundColor] = inlineFill
        }
        if let url {
            attrs[.link] = url
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.cursor] = NSCursor.pointingHand
        }
        return attrs
    }
}

private struct LinkPreviewCard: View {
    var url: URL
    @State private var title: String?
    @State private var icon: NSImage?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? host)
                    .font(CraftFont.section)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(host)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: 280, alignment: .leading)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CraftColor.hairline)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .task(id: url) { await load() }
    }

    @ViewBuilder private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var host: String {
        url.host() ?? url.absoluteString
    }

    private func load() async {
        icon = await FaviconStore.shared.image(for: url)
        if let metadata = await FaviconStore.shared.metadata(for: url) {
            title = metadata.title
        }
    }
}
