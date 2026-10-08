import AppKit
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Start writing…"
    var fontSize: CGFloat = 15
    var minHeight: CGFloat = 0
    var findField: ObjectFind.Field? = nil
    @Environment(\.objectFind) private var find

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.baseFont = .systemFont(ofSize: fontSize)
        view.placeholder = placeholder
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        view.string = text
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        context.coordinator.parent = self
        view.placeholder = placeholder
        let ranges = findField.flatMap { find?.isOpen == true ? find?.ranges(in: $0) : [] } ?? []
        let current = find?.isOpen == true ? findField.flatMap { find?.currentRange(in: $0) } : nil
        let findChanged = view.findRanges != ranges || view.findCurrent != current
        view.findRanges = ranges
        view.findCurrent = current
        if view.string != text, !view.hasMarkedText() {
            view.string = text
        } else if findChanged {
            view.applyFindHighlights(reveal: true)
        }
        let width = view.bounds.width
        if width > 0 {
            view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        let content = nsView.height(forWidth: width)
        let proposed = proposal.height ?? 0
        return CGSize(width: width, height: max(content, proposed, minHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? MarkdownTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let view = notification.object as? MarkdownTextView else { return }
            let trimmed = view.string.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            if trimmed != view.string {
                parent.text = trimmed
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? MarkdownTextView else { return }
            view.updateRevealed()
            view.scheduleFormatBar()
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            MarkdownStyler.style(textStorage, font: .systemFont(ofSize: parent.fontSize))
            (textStorage.layoutManagers.first?.firstTextView as? MarkdownTextView)?
                .applyFindHighlights(restyle: false)
        }
    }
}
final class MarkdownTextView: NSTextView, NSLayoutManagerDelegate {
    var baseFont: NSFont = .systemFont(ofSize: 15) {
        didSet { configure() }
    }
    var placeholder = "" {
        didSet { if string.isEmpty { needsDisplay = true } }
    }
    var findRanges: [NSRange] = []
    var findCurrent: NSRange?

    private var formatPopover: NSPopover?
    private var pendingFormatBar: DispatchWorkItem?
    private var revealed = NSRange(location: NSNotFound, length: 0)

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    convenience init(usingTextLayoutManager: Bool) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        layout.delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        font = baseFont
        typingAttributes = MarkdownStyler.baseAttributes(baseFont)
        if let storage = textStorage {
            MarkdownStyler.style(storage, font: baseFont)
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 22 }
        let current = textContainer.containerSize
        textContainer.containerSize = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        textContainer.containerSize = current
        let line = layoutManager.defaultLineHeight(for: baseFont) + MarkdownStyler.lineSpacing
        return ceil(max(used, line))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 480))
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(
            at: textContainerOrigin,
            withAttributes: [.font: baseFont, .foregroundColor: NSColor.placeholderTextColor]
        )
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { self.updateRevealed() } }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        formatPopover?.close()
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { self.updateRevealed() } }
        return resigned
    }

    func updateRevealed() {
        let text = string as NSString
        let next = window?.firstResponder === self
            ? text.paragraphRange(for: selectedRange())
            : NSRange(location: NSNotFound, length: 0)
        guard next != revealed else { return }
        let previous = revealed
        revealed = next
        for range in [previous, next] where range.location != NSNotFound {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
            layoutManager?.invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
            layoutManager?.invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
        }
        invalidateIntrinsicContentSize()
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        var modified: [NSLayoutManager.GlyphProperty]?
        for index in 0..<glyphRange.length {
            let character = characterIndexes[index]
            guard character < storage.length,
                  storage.attribute(.markdownMarker, at: character, effectiveRange: nil) != nil,
                  !NSLocationInRange(character, revealed) else { continue }
            if modified == nil {
                modified = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
            }
            modified?[index] = .null
        }
        guard var modified else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: &modified, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
    }

    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(nil)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": apply(.bold)
        case "i": apply(.italic)
        case "k": apply(.link)
        case "f", "g": return false
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func performFindPanelAction(_ sender: Any?) {}

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange().location
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: caret - line.location))
        guard selectedRange().length == 0,
              let match = MarkdownStyler.listPrefix.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else {
            super.insertNewline(sender)
            return
        }
        let prefix = (before as NSString).substring(with: match.range)
        if prefix == before {
            replace(NSRange(location: line.location, length: match.range.length), with: "", select: NSRange(location: line.location, length: 0))
            return
        }
        var next = prefix
        let numberRange = match.range(at: 2)
        if numberRange.location != NSNotFound, let number = Int((before as NSString).substring(with: numberRange)) {
            next = (before as NSString).substring(with: match.range(at: 1)) + "\(number + 1). "
        }
        super.insertNewline(sender)
        insertText(next, replacementRange: selectedRange())
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let format = NSMenu(title: "Format")
        for action in MarkdownAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(formatFromMenu(_:)), keyEquivalent: action.key)
            item.keyEquivalentModifierMask = action.key.isEmpty ? [] : .command
            item.representedObject = action.rawValue
            item.target = self
            format.addItem(item)
        }
        let parent = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        parent.submenu = format
        menu.insertItem(parent, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func formatFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = MarkdownAction(rawValue: raw) else { return }
        apply(action)
    }

    func applyFindHighlights(restyle: Bool = true, reveal: Bool = false) {
        guard let storage = textStorage else { return }
        if restyle {
            MarkdownStyler.style(storage, font: baseFont)
        }
        let current = findCurrent
        for range in findRanges {
            let color = range == current ? NSColor.findHighlightColor : NSColor.findHighlightColor.withAlphaComponent(0.35)
            guard range.location != NSNotFound, range.upperBound <= storage.length else { continue }
            storage.addAttribute(.backgroundColor, value: color, range: range)
        }
        if reveal, let current, current.location != NSNotFound, current.upperBound <= storage.length {
            self.reveal(current)
        }
    }

    private func reveal(_ range: NSRange) {
        guard let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        scrollToVisible(rect.insetBy(dx: -12, dy: -40))
    }

    func apply(_ action: MarkdownAction) {
        switch action {
        case .bold: toggleWrap("**")
        case .italic: toggleWrap("*")
        case .code: toggleWrap("`")
        case .link: insertLink()
        case .heading: toggleLinePrefix("## ")
        case .list: toggleLinePrefix("- ")
        case .quote: toggleLinePrefix("> ")
        }
        scheduleFormatBar()
    }

    private func replace(_ range: NSRange, with replacement: String, select selection: NSRange) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(selection)
    }

    private func toggleWrap(_ marker: String) {
        let text = string as NSString
        let range = selectedRange()
        let length = (marker as NSString).length
        let selected = text.substring(with: range)

        if range.location >= length, range.upperBound + length <= text.length,
           text.substring(with: NSRange(location: range.location - length, length: length)) == marker,
           text.substring(with: NSRange(location: range.upperBound, length: length)) == marker {
            let outer = NSRange(location: range.location - length, length: range.length + length * 2)
            replace(outer, with: selected, select: NSRange(location: outer.location, length: range.length))
        } else if range.length > length * 2, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            replace(range, with: inner, select: NSRange(location: range.location, length: (inner as NSString).length))
        } else {
            replace(range, with: marker + selected + marker, select: NSRange(location: range.location + length, length: range.length))
        }
    }

    private func insertLink() {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        let replacement = "[\(selected)]()"
        let caret = selected.isEmpty ? range.location + 1 : range.location + (selected as NSString).length + 3
        replace(range, with: replacement, select: NSRange(location: caret, length: 0))
    }

    private func toggleLinePrefix(_ prefix: String) {
        let text = string as NSString
        var block = text.lineRange(for: selectedRange())
        if block.length > 0, text.substring(with: NSRange(location: block.upperBound - 1, length: 1)) == "\n" {
            block.length -= 1
        }
        let lines = text.substring(with: block).components(separatedBy: "\n")
        let isHeading = prefix.hasPrefix("#")
        let allHave = lines.allSatisfy { $0.isEmpty || $0.hasPrefix(prefix) }
        let updated = lines.map { line -> String in
            if line.isEmpty { return line }
            if allHave { return String(line.dropFirst(prefix.count)) }
            let stripped = isHeading ? line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression) : line
            return prefix + stripped
        }.joined(separator: "\n")
        replace(block, with: updated, select: NSRange(location: block.location, length: (updated as NSString).length))
    }

    func scheduleFormatBar() {
        pendingFormatBar?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateFormatBar() }
        pendingFormatBar = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        scheduleFormatBar()
    }

    private func updateFormatBar() {
        guard window?.firstResponder === self,
              selectedRange().length > 0,
              NSEvent.pressedMouseButtons == 0,
              let layoutManager, let textContainer else {
            formatPopover?.close()
            return
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect = NSRect(x: rect.minX, y: rect.minY, width: min(rect.width, 1), height: rect.height)

        let popover = formatPopover ?? makeFormatPopover()
        formatPopover = popover
        if popover.isShown {
            popover.positioningRect = rect
        } else {
            popover.show(relativeTo: rect, of: self, preferredEdge: .minY)
        }
    }

    private func makeFormatPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: FormatBar { [weak self] action in
            self?.apply(action)
        })
        return popover
    }
}
enum MarkdownAction: String, CaseIterable {
    case bold, italic, code, link, heading, list, quote

    var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .code: "Code"
        case .link: "Link"
        case .heading: "Heading"
        case .list: "Bulleted List"
        case .quote: "Quote"
        }
    }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .heading: "textformat.size"
        case .list: "list.bullet"
        case .quote: "text.quote"
        }
    }

    var key: String {
        switch self {
        case .bold: "b"
        case .italic: "i"
        case .link: "k"
        default: ""
        }
    }
}

private struct FormatBar: View {
    var action: (MarkdownAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MarkdownAction.allCases, id: \.self) { item in
                Button { action(item) } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(item.key.isEmpty ? item.title : "\(item.title) (⌘\(item.key.uppercased()))")
                .accessibilityLabel(item.title)
            }
        }
        .padding(4)
    }
}
extension NSAttributedString.Key {
    static let markdownMarker = NSAttributedString.Key("PCMarkdownMarker")
}
enum MarkdownStyler {
    static let lineSpacing: CGFloat = 5

    static let listPrefix = try! NSRegularExpression(pattern: #"^(\s*)(?:[-*+] |(\d+)\. |> )"#)

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6} )(.*)$"#, options: .anchorsMatchLines)
    private static let quote = try! NSRegularExpression(pattern: #"^(> ?)(.*)$"#, options: .anchorsMatchLines)
    private static let bullet = try! NSRegularExpression(pattern: #"^\s*([-*+]|\d+\.) "#, options: .anchorsMatchLines)
    private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<![*_\w])([*_])(?![*_\s])(.+?)(?<![*_\s])\1(?![*_\w])"#)
    private static let code = try! NSRegularExpression(pattern: #"(`)([^`\n]+)(`)"#)
    private static let link = try! NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\([^)\n]*\))"#)

    private static let codeFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.08)
            : NSColor(white: 0, alpha: 0.06)
    }

    static func baseAttributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    static func style(_ storage: NSTextStorage, font: NSFont) {
        let full = NSRange(location: 0, length: storage.length)
        let text = storage.string
        storage.setAttributes(baseAttributes(font), range: full)

        for match in heading.matches(in: text, range: full) {
            add(.boldFontMask, to: match.range(at: 2), in: storage)
            dim(match.range(at: 1), in: storage)
        }
        for match in quote.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range(at: 2))
            dim(match.range(at: 1), in: storage)
        }
        for match in bullet.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range(at: 1))
        }
        for match in bold.matches(in: text, range: full) {
            add(.boldFontMask, to: match.range(at: 2), in: storage)
            dimMarkers(match, in: storage)
        }
        for match in italic.matches(in: text, range: full) {
            add(.italicFontMask, to: match.range(at: 2), in: storage)
            dimMarkers(match, in: storage)
        }
        for match in code.matches(in: text, range: full) {
            storage.addAttribute(.backgroundColor, value: codeFill, range: match.range)
            dim(match.range(at: 1), in: storage)
            dim(match.range(at: 3), in: storage)
        }
        for match in link.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range(at: 2))
            dim(match.range(at: 1), in: storage)
            dim(match.range(at: 3), in: storage)
        }
    }

    private static func dimMarkers(_ match: NSTextCheckingResult, in storage: NSTextStorage) {
        let marker = match.range(at: 1).length
        dim(NSRange(location: match.range.location, length: marker), in: storage)
        dim(NSRange(location: match.range.upperBound - marker, length: marker), in: storage)
    }

    private static func dim(_ range: NSRange, in storage: NSTextStorage) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        storage.addAttribute(.markdownMarker, value: true, range: range)
    }

    private static func add(_ trait: NSFontTraitMask, to range: NSRange, in storage: NSTextStorage) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
        }
    }
}
