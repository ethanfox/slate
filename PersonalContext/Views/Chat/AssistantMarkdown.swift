import AppKit
import SwiftUI

struct AssistantMarkdown: View {
    var text: String
    var sources: [ChatSource] = []
    var pinUnused = true
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var hover: LinkHover?
    @State private var sourceHover: SourceHover?

    var body: some View {
        MarkdownBody(
            text: text,
            sources: sources,
            pinUnused: pinUnused,
            hover: $hover,
            sourceHover: $sourceHover,
            onOpen: { $0.open(app: app, context: modelContext) }
        )
            .overlay(alignment: .topLeading) {
                if let sourceHover {
                    SourcePager(sources: sourceHover.sources) { source in
                        source.open(app: app, context: modelContext)
                    }
                    .offset(x: sourceHover.rect.minX, y: previewY(for: sourceHover.rect, height: 92))
                } else if let hover {
                    LinkPreviewCard(url: hover.url)
                        .offset(x: hover.rect.minX, y: previewY(for: hover.rect, height: 76))
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.hover, value: hover?.url)
            .animation(Motion.hover, value: sourceHover?.sources.map(\.id))
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
    @Binding var hover: LinkHover?
    @Binding var sourceHover: SourceHover?
    var onOpen: (ChatSource) -> Void

    func makeNSView(context: Context) -> AssistantMarkdownTextView {
        let view = AssistantMarkdownTextView()
        bind(view)
        view.apply(text, sources: sources, pinUnused: pinUnused)
        return view
    }

    func updateNSView(_ view: AssistantMarkdownTextView, context: Context) {
        bind(view)
        view.apply(text, sources: sources, pinUnused: pinUnused)
    }

    private func bind(_ view: AssistantMarkdownTextView) {
        view.onHoverLink = { url, rect in
            if let url, let rect {
                hover = LinkHover(url: url, rect: rect)
            } else {
                hover = nil
            }
        }
        view.onHoverSources = { sources, rect in
            if let sources, let rect {
                sourceHover = SourceHover(sources: sources, rect: rect)
            } else {
                sourceHover = nil
            }
        }
        view.onOpenSource = onOpen
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AssistantMarkdownTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 680
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

fileprivate final class AssistantMarkdownTextView: NSTextView {
    var onHoverLink: ((URL?, CGRect?) -> Void)?
    var onHoverSources: (([ChatSource]?, CGRect?) -> Void)?
    var onOpenSource: ((ChatSource) -> Void)?
    private var source = ""
    private var sourceIDs: [String] = []
    private var tracking: NSTrackingArea?

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

    func apply(_ text: String, sources: [ChatSource] = [], pinUnused: Bool = true) {
        let ids = sources.map(\.id)
        guard source != text || sourceIDs != ids else { return }
        source = text
        sourceIDs = ids
        let selected = selectedRange()
        textStorage?.setAttributedString(Self.attributed(text, sources: sources, pinUnused: pinUnused))
        let max = (string as NSString).length
        let location = min(selected.location, max)
        setSelectedRange(NSRange(location: location, length: min(selected.length, max - location)))
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: self)
        loadChipIcons()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 22 }
        let current = textContainer.containerSize
        textContainer.containerSize = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        textContainer.containerSize = current
        return ceil(max(used, 22))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
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
        onHoverSources?(nil, nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let sources = sources(at: point), let first = sources.first {
            onOpenSource?(first)
            return
        }
        super.mouseDown(with: event)
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
        if let sources = sources(at: point) {
            onHoverLink?(nil, nil)
            onHoverSources?(sources, chipRect(for: sources))
            return
        }
        onHoverSources?(nil, nil)
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
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index < textStorage.length else { return nil }
        return textStorage.attribute(.chatSources, at: index, effectiveRange: nil) as? [ChatSource]
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

    private static func attributed(_ markdown: String, sources: [ChatSource] = [], pinUnused: Bool = true) -> NSAttributedString {
        let result = ChatMarkdown.attributed(markdown)
        insertSources(sources, pinUnused: pinUnused, into: result)
        return result
    }

    private static func insertSources(_ sources: [ChatSource], pinUnused: Bool, into result: NSMutableAttributedString) {
        let placements = ChatSourceMatcher.place(sources, in: result.string, pinUnused: pinUnused)
        for placement in placements.reversed() {
            let attachment = SourceChipAttachment(sources: placement.sources)
            let chip = NSMutableAttributedString(string: " ")
            chip.append(NSAttributedString(attachment: attachment))
            chip.addAttribute(.chatSources, value: placement.sources, range: NSRange(location: 0, length: chip.length))
            let location = min(max(placement.utf16, 0), result.length)
            result.insert(chip, at: location)
        }
    }
}

/// Styles markers in the source text. Does not join lines or drop spaces.
private enum ChatMarkdown {
    static func attributed(_ source: String, fontSize: CGFloat = 15) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var inFence = false
        for (index, raw) in lines.enumerated() {
            let line = String(raw)
            if line.hasPrefix("```") {
                inFence.toggle()
                if index < lines.count - 1 { result.append(breakLine(fontSize: fontSize, empty: true)) }
                continue
            }
            if inFence {
                result.append(NSAttributedString(string: line, attributes: attributes(
                    fontSize: fontSize, code: true, empty: line.isEmpty
                )))
            } else {
                result.append(renderLine(line, fontSize: fontSize))
            }
            if index < lines.count - 1 {
                result.append(breakLine(fontSize: fontSize, empty: line.isEmpty))
            }
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
