import AppKit
import LinkPresentation
import SwiftUI

struct AssistantMarkdown: View {
    var text: String
    @State private var hover: LinkHover?

    var body: some View {
        MarkdownBody(text: text, hover: $hover)
            .overlay(alignment: .topLeading) {
                if let hover {
                    LinkPreviewCard(url: hover.url)
                        .offset(x: hover.rect.minX, y: previewY(for: hover.rect))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hover?.url)
    }

    private func previewY(for rect: CGRect) -> CGFloat {
        let above = rect.minY - 76
        return above > 4 ? above : rect.maxY + 8
    }
}

private struct LinkHover: Equatable {
    var url: URL
    var rect: CGRect
}

private struct MarkdownBody: NSViewRepresentable {
    var text: String
    @Binding var hover: LinkHover?

    func makeNSView(context: Context) -> AssistantMarkdownTextView {
        let view = AssistantMarkdownTextView()
        view.onHoverLink = { url, rect in
            if let url, let rect {
                hover = LinkHover(url: url, rect: rect)
            } else {
                hover = nil
            }
        }
        view.apply(text)
        return view
    }

    func updateNSView(_ view: AssistantMarkdownTextView, context: Context) {
        view.onHoverLink = { url, rect in
            if let url, let rect {
                hover = LinkHover(url: url, rect: rect)
            } else {
                hover = nil
            }
        }
        view.apply(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AssistantMarkdownTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 680
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

fileprivate final class AssistantMarkdownTextView: NSTextView {
    var onHoverLink: ((URL?, CGRect?) -> Void)?
    private var source = ""
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

    func apply(_ text: String) {
        guard source != text else { return }
        source = text
        let selected = selectedRange()
        textStorage?.setAttributedString(Self.attributed(text))
        let max = (string as NSString).length
        let location = min(selected.location, max)
        setSelectedRange(NSRange(location: location, length: min(selected.length, max - location)))
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: self)
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
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        reportHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverLink?(nil, nil)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if link(at: point) != nil {
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

    private static func attributed(_ markdown: String) -> NSAttributedString {
        let fontSize: CGFloat = 15
        let body = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 10
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [
                .font: body,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
        }

        let result = NSMutableAttributedString()
        var lastIdentity: Int?
        var prefixedIdentities = Set<Int>()

        for run in parsed.runs {
            var text = String(parsed.characters[run.range])
            var font = body
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            if let intent = run.presentationIntent {
                if let lastIdentity, lastIdentity != intent.hashValue, !text.hasPrefix("\n") {
                    result.append(NSAttributedString(string: "\n"))
                }
                lastIdentity = intent.hashValue
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        let size = fontSize + CGFloat(max(0, 5 - level)) * 2
                        font = NSFont.systemFont(ofSize: size, weight: .semibold)
                        style.paragraphSpacingBefore = level == 1 ? 16 : 12
                        style.paragraphSpacing = 8
                    case .listItem:
                        style.headIndent = 22
                        style.firstLineHeadIndent = 8
                        style.paragraphSpacing = 4
                        if !prefixedIdentities.contains(intent.hashValue) {
                            prefixedIdentities.insert(intent.hashValue)
                            if !text.hasPrefix("•"), !text.hasPrefix("- "), !text.hasPrefix("* ") {
                                text = "• " + text
                            }
                        }
                    case .codeBlock:
                        font = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
                    default:
                        break
                    }
                }
            }
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
                } else {
                    var traits = font.fontDescriptor.symbolicTraits
                    if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if inline.contains(.emphasized) { traits.insert(.italic) }
                    font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.cursor] = NSCursor.pointingHand
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
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
        if let cached = await LinkPreviewCache.shared.metadata(for: url) {
            apply(cached)
            return
        }
        let provider = LPMetadataProvider()
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return }
        await LinkPreviewCache.shared.store(metadata, for: url)
        apply(metadata)
    }

    private func apply(_ metadata: LPLinkMetadata) {
        title = metadata.title
        metadata.iconProvider?.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { icon = image }
        }
    }
}

private actor LinkPreviewCache {
    static let shared = LinkPreviewCache()
    private var values: [URL: LPLinkMetadata] = [:]

    func metadata(for url: URL) -> LPLinkMetadata? { values[url] }

    func store(_ metadata: LPLinkMetadata, for url: URL) {
        values[url] = metadata
    }
}
