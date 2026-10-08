import AppKit
import SwiftUI

struct SelectableText: NSViewRepresentable {
    var text: String
    var markdown = false
    var hugsWidth = false
    var fontSize: CGFloat = 15
    var lineSpacing: CGFloat = 7
    var color: NSColor = .labelColor

    func makeNSView(context: Context) -> ChatSelectableTextView {
        let view = ChatSelectableTextView()
        view.apply(text: text, markdown: markdown, fontSize: fontSize, lineSpacing: lineSpacing, color: color)
        return view
    }

    func updateNSView(_ view: ChatSelectableTextView, context: Context) {
        view.apply(text: text, markdown: markdown, fontSize: fontSize, lineSpacing: lineSpacing, color: color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatSelectableTextView, context: Context) -> CGSize? {
        nsView.fittedSize(for: proposal.width, hugging: hugsWidth)
    }
}

final class ChatSelectableTextView: NSTextView {
    private var source = ""
    private var usesMarkdown = false
    private var fontSize: CGFloat = 15
    private var lineSpacing: CGFloat = 7
    private var color: NSColor = .labelColor
    private var fittedWidth: CGFloat = 0
    private var fittedHeight: CGFloat = 22
    private var intrinsicWidth: CGFloat = 0

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

    func apply(text: String, markdown: Bool, fontSize: CGFloat, lineSpacing: CGFloat, color: NSColor) {
        let same = source == text
            && usesMarkdown == markdown
            && self.fontSize == fontSize
            && self.lineSpacing == lineSpacing
            && self.color.isEqual(color)
        guard !same else { return }
        source = text
        usesMarkdown = markdown
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.color = color
        fittedWidth = 0
        intrinsicWidth = 0
        let selected = selectedRange()
        textStorage?.setAttributedString(Self.attributed(text, markdown: markdown, fontSize: fontSize, lineSpacing: lineSpacing, color: color))
        let max = (string as NSString).length
        let location = min(selected.location, max)
        setSelectedRange(NSRange(location: location, length: min(selected.length, max - location)))
        invalidateIntrinsicContentSize()
    }

    func fittedSize(for proposed: CGFloat?, hugging: Bool) -> CGSize {
        let maxWidth = proposed.map { $0 > 1 ? $0.rounded() : 680 } ?? 680
        if !hugging {
            return CGSize(width: maxWidth, height: height(forWidth: maxWidth))
        }
        let natural = widthThatFits() + 8
        let width = min(max(natural, 1), maxWidth)
        return CGSize(width: width, height: height(forWidth: width))
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let width = width.rounded()
        if width <= 1 { return fittedHeight }
        if abs(width - fittedWidth) < 0.5 { return fittedHeight }
        guard let layoutManager, let textContainer else { return 22 }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        fittedWidth = width
        fittedHeight = ceil(max(layoutManager.usedRect(for: textContainer).height, 22))
        return fittedHeight
    }

    func widthThatFits() -> CGFloat {
        if intrinsicWidth > 0 { return intrinsicWidth }
        guard let layoutManager, let textContainer else { return 0 }
        let current = textContainer.containerSize
        textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        intrinsicWidth = ceil(layoutManager.usedRect(for: textContainer).width)
        textContainer.containerSize = current
        return intrinsicWidth
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 680))
    }

    override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {}

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
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        usesAdaptiveColorMappingForDarkAppearance = true
    }

    private static func attributed(
        _ text: String,
        markdown: Bool,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        color: NSColor
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = 8
        let fallback = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        guard markdown else { return fallback }
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return fallback
        }
        let result = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttributes(in: full, options: [.reverse]) { attrs, range, _ in
            var nextFont = (attrs[.font] as? NSFont) ?? font
            var intentKeys: [NSAttributedString.Key] = []
            for (key, value) in attrs {
                if let intent = value as? InlinePresentationIntent {
                    intentKeys.append(key)
                    if intent.contains(.code) {
                        nextFont = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
                    } else {
                        var traits = nextFont.fontDescriptor.symbolicTraits
                        if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                        if intent.contains(.emphasized) { traits.insert(.italic) }
                        let descriptor = nextFont.fontDescriptor.withSymbolicTraits(traits)
                        nextFont = NSFont(descriptor: descriptor, size: nextFont.pointSize) ?? nextFont
                    }
                    if intent.contains(.strikethrough) {
                        result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                    }
                } else if let intent = value as? PresentationIntent {
                    intentKeys.append(key)
                    for component in intent.components {
                        switch component.kind {
                        case .header(let level):
                            let size = fontSize + CGFloat(max(0, 5 - level)) * 2
                            nextFont = NSFont.systemFont(ofSize: size, weight: .semibold)
                            let header = paragraph.mutableCopy() as! NSMutableParagraphStyle
                            header.paragraphSpacingBefore = level == 1 ? 18 : 14
                            header.paragraphSpacing = 8
                            result.addAttribute(.paragraphStyle, value: header, range: range)
                        case .codeBlock:
                            nextFont = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
                        case .listItem:
                            let list = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                                ?? paragraph.mutableCopy() as! NSMutableParagraphStyle
                            list.headIndent = 22
                            list.firstLineHeadIndent = 8
                            list.paragraphSpacing = 4
                            result.addAttribute(.paragraphStyle, value: list, range: range)
                        default:
                            break
                        }
                    }
                }
            }
            result.addAttribute(.font, value: nextFont, range: range)
            if attrs[.foregroundColor] == nil {
                result.addAttribute(.foregroundColor, value: attrs[.link] == nil ? color : NSColor.linkColor, range: range)
            }
            if attrs[.paragraphStyle] == nil {
                result.addAttribute(.paragraphStyle, value: paragraph, range: range)
            } else if let existing = attrs[.paragraphStyle] as? NSParagraphStyle, existing.lineSpacing < lineSpacing {
                let mutable = existing.mutableCopy() as! NSMutableParagraphStyle
                mutable.lineSpacing = lineSpacing
                result.addAttribute(.paragraphStyle, value: mutable, range: range)
            }
            for key in intentKeys {
                result.removeAttribute(key, range: range)
            }
        }
        return result
    }
}
