import AppKit
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Start writing…"
    var fontSize: CGFloat = 15
    var minHeight: CGFloat = 0
    var findField: ObjectFind.Field? = nil
    @Environment(AppModel.self) private var app

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
        let find = app.objectFind
        let ranges = findField.flatMap { find.isOpen ? find.ranges(in: $0) : [] } ?? []
        let current = find.isOpen ? findField.flatMap { find.currentRange(in: $0) } : nil
        let findChanged = view.findRanges != ranges || view.findCurrent != current
        view.findRanges = ranges
        view.findCurrent = current
        view.onFind = { find.toggle() }
        view.onFindNext = { find.next() }
        view.onFindPrevious = { find.previous() }
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
            (textStorage.layoutManagers.first?.firstTextView as? MarkdownTextView)?.restyle()
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
    var onFind: (() -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?

    private var formatPopover: NSPopover?
    private var pendingFormatBar: DispatchWorkItem?
    private var revealed = NSRange(location: NSNotFound, length: 0)
    private var tableFaces: [String: MarkdownTableFace] = [:]

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
        restyle()
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
        drawTables()
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(
            at: textContainerOrigin,
            withAttributes: [.font: baseFont, .foregroundColor: NSColor.placeholderTextColor]
        )
    }

    private func drawTables() {
        guard let storage = textStorage, let layoutManager else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.markdownTable, in: full) { value, range, _ in
            guard let source = value as? String else { return }
            let face = tableFace(for: source)
            let probe = range.length > 0
                ? NSRange(location: range.upperBound - 1, length: 1)
                : range
            let glyphs = layoutManager.glyphRange(forCharacterRange: probe, actualCharacterRange: nil)
            guard glyphs.location != NSNotFound, glyphs.length > 0 else { return }
            var rect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphs.location,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            face.draw(in: rect)
        }
    }

    func restyle() {
        guard let storage = textStorage else { return }
        tableFaces.removeAll()
        MarkdownStyler.style(storage, font: baseFont, sourceRanges: sourceDisplayRanges)
        paintFindHighlights()
    }

    private func tableFace(for source: String) -> MarkdownTableFace {
        if let face = tableFaces[source] { return face }
        let face = MarkdownTableFace(source: source, fontSize: baseFont.pointSize)
        tableFaces[source] = face
        return face
    }

    private var sourceDisplayRanges: [NSRange] {
        var ranges = findRanges
        if revealed.location != NSNotFound {
            ranges.append(revealed)
        }
        return ranges
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
        var next = window?.firstResponder === self
            ? text.paragraphRange(for: selectedRange())
            : NSRange(location: NSNotFound, length: 0)
        if next.location != NSNotFound {
            for table in ChatMarkdown.tableBlocks(in: string) where NSIntersectionRange(next, table.range).length > 0 {
                next = table.range
                break
            }
            for fence in ChatMarkdown.fenceBlocks(in: string) where NSIntersectionRange(next, fence.range).length > 0 {
                next = fence.range
                break
            }
        }
        guard next != revealed else { return }
        revealed = next
        restyle()
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

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let storage = layoutManager.textStorage else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard characters.location < storage.length else { return false }
        if storage.attribute(.markdownCollapsed, at: characters.location, effectiveRange: nil) != nil {
            lineFragmentRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size.height = 0
            return true
        }
        guard let source = storage.attribute(.markdownTable, at: characters.location, effectiveRange: nil) as? String else {
            return false
        }
        let height = tableFace(for: source).height(forWidth: textContainer.containerSize.width)
        lineFragmentRect.pointee.size.width = textContainer.containerSize.width
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.width = textContainer.containerSize.width
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = baseFont.ascender
        return true
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
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command), !mods.contains(.option), !mods.contains(.control) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.keyCode {
        case 3 where !mods.contains(.shift):
            onFind?()
            return true
        case 5 where mods.contains(.shift):
            onFindPrevious?()
            return true
        case 5:
            onFindNext?()
            return true
        default: break
        }
        guard mods == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": apply(.bold)
        case "i": apply(.italic)
        case "k": apply(.link)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func performFindPanelAction(_ sender: Any?) {
        switch NSTextFinder.Action(rawValue: (sender as? NSMenuItem)?.tag ?? 1) {
        case .showFindInterface, .setSearchString:
            onFind?()
        case .hideFindInterface:
            if onFind != nil { onFind?() }
        case .nextMatch:
            onFindNext?()
        case .previousMatch:
            onFindPrevious?()
        default:
            break
        }
    }

    override func insertNewline(_ sender: Any?) {
        let caret = selectedRange().location
        if ChatMarkdown.fenceBlocks(in: string).contains(where: { NSLocationInRange(caret, $0.range) }) {
            super.insertNewline(sender)
            return
        }
        let text = string as NSString
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
        if restyle {
            self.restyle()
        } else {
            paintFindHighlights()
        }
        if reveal, let current = findCurrent, current.location != NSNotFound, current.upperBound <= (textStorage?.length ?? 0) {
            self.reveal(current)
        }
    }

    private func paintFindHighlights() {
        guard let storage = textStorage else { return }
        let current = findCurrent
        for range in findRanges {
            let color = range == current ? NSColor.findHighlightColor : NSColor.findHighlightColor.withAlphaComponent(0.35)
            guard range.location != NSNotFound, range.upperBound <= storage.length else { continue }
            storage.addAttribute(.backgroundColor, value: color, range: range)
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
    static let markdownTable = NSAttributedString.Key("PCMarkdownTable")
    static let markdownCollapsed = NSAttributedString.Key("PCMarkdownCollapsed")
}

final class MarkdownTableFace {
    let attributed: NSAttributedString
    private var measuredWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 0

    init(source: String, fontSize: CGFloat) {
        attributed = ChatMarkdown.attributed(source, fontSize: fontSize)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let width = max(width, 1)
        if abs(width - measuredWidth) < 0.5 { return measuredHeight }
        measuredWidth = width
        measuredHeight = Self.measure(attributed, width: width)
        return measuredHeight
    }

    func draw(in rect: NSRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: rect.width, height: max(rect.height, 1)))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: glyphs, at: rect.origin)
        layout.drawGlyphs(forGlyphRange: glyphs, at: rect.origin)
    }

    private static func measure(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return ceil(max(layout.usedRect(for: container).height, 22))
    }
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

    static func baseAttributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    static func style(_ storage: NSTextStorage, font: NSFont, sourceRanges: [NSRange] = []) {
        let full = NSRange(location: 0, length: storage.length)
        let text = storage.string
        storage.setAttributes(baseAttributes(font), range: full)
        let fences = ChatMarkdown.fenceBlocks(in: text)
        let fenceRanges = fences.map(\.range)

        for match in heading.matches(in: text, range: full) where !intersects(match.range, fenceRanges) {
            add(.boldFontMask, to: match.range(at: 2), in: storage)
            dim(match.range(at: 1), in: storage)
        }
        for match in quote.matches(in: text, range: full) where !intersects(match.range, fenceRanges) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range(at: 2))
            dim(match.range(at: 1), in: storage)
        }
        for match in bullet.matches(in: text, range: full) where !intersects(match.range, fenceRanges) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range(at: 1))
        }
        for match in bold.matches(in: text, range: full) where !intersects(match.range, fenceRanges) {
            add(.boldFontMask, to: match.range(at: 2), in: storage)
            dimMarkers(match, in: storage)
        }
        for match in italic.matches(in: text, range: full) where !intersects(match.range, fenceRanges) {
            add(.italicFontMask, to: match.range(at: 2), in: storage)
            dimMarkers(match, in: storage)
        }
        for match in code.matches(in: text, range: full) where !intersects(match.range, fenceRanges) {
            let inner = match.range(at: 2)
            storage.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                range: inner
            )
            storage.addAttribute(.backgroundColor, value: ChatMarkdown.inlineFill, range: inner)
            dim(match.range(at: 1), in: storage)
            dim(match.range(at: 3), in: storage)
        }
        for match in link.matches(in: text, range: full) where !intersects(match.range, fenceRanges) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range(at: 2))
            dim(match.range(at: 1), in: storage)
            dim(match.range(at: 3), in: storage)
        }
        styleFences(fences, in: storage, font: font, sourceRanges: sourceRanges)
        styleTables(storage, font: font, sourceRanges: sourceRanges)
    }

    private static func styleFences(
        _ fences: [MarkdownFenceBlock],
        in storage: NSTextStorage,
        font: NSFont,
        sourceRanges: [NSRange]
    ) {
        for fence in fences {
            let editing = intersects(fence.range, sourceRanges)
            styleFenceLine(fence.open, in: storage, collapse: !editing)
            if let close = fence.close {
                styleFenceLine(close, in: storage, collapse: !editing)
            }
            styleFenceBody(fence.body, in: storage, font: font)
        }
    }

    private static func styleFenceLine(_ range: NSRange, in storage: NSTextStorage, collapse: Bool) {
        if collapse {
            hideSource(range, in: storage)
            storage.addAttribute(.markdownCollapsed, value: true, range: range)
            return
        }
        let ns = storage.string as NSString
        var line = range
        if line.length > 0, ns.substring(with: NSRange(location: line.upperBound - 1, length: 1)) == "\n" {
            line.length -= 1
        }
        let text = ns.substring(with: line)
        let ticks = (text as NSString).range(of: "```")
        if ticks.location != NSNotFound {
            dim(NSRange(location: line.location + ticks.location, length: 3), in: storage)
        }
    }

    private static func styleFenceBody(_ range: NSRange, in storage: NSTextStorage, font: NSFont) {
        guard range.length > 0 else { return }
        let ns = storage.string as NSString
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.collapsesBorders = true
        let mono = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
        var row = 0
        var cursor = range.location
        while cursor < range.upperBound {
            var line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            if line.upperBound > range.upperBound {
                line = NSRange(location: line.location, length: range.upperBound - line.location)
            }
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: 0, columnSpan: 1)
            block.backgroundColor = ChatMarkdown.blockFill
            block.setWidth(10, type: .absoluteValueType, for: .padding)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            paragraph.textBlocks = [block]
            storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
            storage.addAttribute(.font, value: mono, range: line)
            row += 1
            cursor = line.upperBound
        }
    }

    private static func styleTables(_ storage: NSTextStorage, font: NSFont, sourceRanges: [NSRange]) {
        let ns = storage.string as NSString
        for table in ChatMarkdown.tableBlocks(in: storage.string) {
            if intersects(table.range, sourceRanges) {
                styleTableSource(table.range, in: storage)
                continue
            }
            let first = ns.lineRange(for: NSRange(location: table.range.location, length: 0))
            let rest = NSRange(location: first.upperBound, length: table.range.upperBound - first.upperBound)
            hideSource(table.range, in: storage)
            storage.addAttribute(.markdownTable, value: table.source, range: first)
            if rest.length > 0 {
                storage.addAttribute(.markdownCollapsed, value: true, range: rest)
            }
        }
    }

    private static func styleTableSource(_ range: NSRange, in storage: NSTextStorage) {
        let ns = storage.string as NSString
        var index = range.location
        while index < range.upperBound {
            if ns.substring(with: NSRange(location: index, length: 1)) == "|" {
                dim(NSRange(location: index, length: 1), in: storage)
            }
            index += 1
        }
    }

    private static func hideSource(_ range: NSRange, in storage: NSTextStorage) {
        let ns = storage.string as NSString
        var index = range.location
        while index < range.upperBound {
            if ns.substring(with: NSRange(location: index, length: 1)) != "\n" {
                dim(NSRange(location: index, length: 1), in: storage)
            }
            index += 1
        }
    }

    private static func intersects(_ range: NSRange, _ others: [NSRange]) -> Bool {
        others.contains { other in
            guard other.location != NSNotFound else { return false }
            if other.length == 0 {
                return NSLocationInRange(other.location, range)
            }
            return NSIntersectionRange(range, other).length > 0
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
