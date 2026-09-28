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
        let maxWidth = proposal.width ?? 680
        let width = hugsWidth ? min(max(nsView.widthThatFits(), 1), maxWidth) : maxWidth
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

final class ChatSelectableTextView: NSTextView {
    private var source = ""
    private var usesMarkdown = false
    private var fontSize: CGFloat = 15
    private var lineSpacing: CGFloat = 7
    private var color: NSColor = .labelColor

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
        let selected = selectedRange()
        textStorage?.setAttributedString(Self.attributed(text, markdown: markdown, fontSize: fontSize, lineSpacing: lineSpacing, color: color))
        let max = (string as NSString).length
        let location = min(selected.location, max)
        setSelectedRange(NSRange(location: location, length: min(selected.length, max - location)))
        invalidateIntrinsicContentSize()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 22 }
        let current = textContainer.containerSize
        textContainer.containerSize = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        textContainer.containerSize = current
        return ceil(max(used, 22))
    }

    func widthThatFits() -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        let current = textContainer.containerSize
        textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).width
        textContainer.containerSize = current
        return ceil(used)
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
        let fallback = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        guard markdown else { return fallback }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return fallback
        }
        let result = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttributes(in: full) { attrs, range, _ in
            if attrs[.foregroundColor] == nil {
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
            if attrs[.font] == nil {
                result.addAttribute(.font, value: font, range: range)
            }
            if let existing = attrs[.paragraphStyle] as? NSParagraphStyle {
                let mutable = existing.mutableCopy() as! NSMutableParagraphStyle
                if mutable.lineSpacing < lineSpacing { mutable.lineSpacing = lineSpacing }
                result.addAttribute(.paragraphStyle, value: mutable, range: range)
            } else {
                result.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
        }
        return result
    }
}
