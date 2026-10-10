import AppKit
import SwiftData
import SwiftUI

@MainActor
final class SourcePagerAnchor {
    var onOpen: ((ChatSource) -> Void)?
    var context: ModelContext?

    var isVisible: Bool { panel?.isVisible == true }

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var overPager = false
    private var shownIDs: [String] = []

    func show(sources: [ChatSource], from view: NSView, rect: CGRect) {
        dismissTask?.cancel()
        let ids = sources.map(\.id)
        if panel?.isVisible == true, shownIDs == ids {
            place(panel, from: view, rect: rect)
            return
        }
        shownIDs = ids
        present(sources: sources, from: view, rect: rect)
    }

    func hideSoon() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, !overPager else { return }
            close()
        }
    }

    func close() {
        dismissTask?.cancel()
        overPager = false
        shownIDs = []
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    private func present(sources: [ChatSource], from view: NSView, rect: CGRect) {
        guard view.window != nil else { return }
        let root = SourcePager(sources: sources, context: context) { [weak self] source in
            self?.onOpen?(source)
            self?.close()
        }
        .padding(14)
        .onHover { [weak self] hovering in
            self?.overPager = hovering
            if hovering {
                self?.dismissTask?.cancel()
            } else {
                self?.hideSoon()
            }
        }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 280, height: 120))
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 1 || size.height < 1 {
            size = NSSize(width: 280, height: 96)
        }
        host.frame = NSRect(origin: .zero, size: size)

        let panel = self.panel ?? makePanel()
        panel.contentView = host
        panel.setContentSize(size)
        place(panel, from: view, rect: rect)
        if let window = view.window, panel.parent !== window {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func place(_ panel: NSPanel?, from view: NSView, rect: CGRect) {
        guard let panel, let window = view.window else { return }
        let size = panel.frame.size
        let screen = screenBounds(of: rect, in: view)
        var origin = NSPoint(x: screen.minX, y: screen.minY - size.height - 3)
        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), max(visible.maxX - size.width - 8, visible.minX + 8))
            if origin.y < visible.minY + 8 {
                origin.y = screen.maxY + 3
            }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func screenBounds(of rect: CGRect, in view: NSView) -> CGRect {
        let corners = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY)
        ]
        let points = corners.map { corner in
            view.window?.convertPoint(toScreen: view.convert(corner, to: nil)) ?? corner
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        return panel
    }
}

struct SourceChipLabel: View {
    var sources: [ChatSource]
    var icon: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            mark
            Text(label)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(CraftColor.selection, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(CraftColor.hairline)
        )
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder private var mark: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .renderingMode(.template)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else if let source = sources.first {
            Image(systemName: source.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }

    private var label: String {
        guard let first = sources.first else { return "" }
        if sources.count > 1 { return "\(first.shortName) +\(sources.count - 1)" }
        return first.shortName
    }

    private var accessibility: String {
        sources.map(\.title).joined(separator: ", ")
    }
}

struct SourcePager: View {
    var sources: [ChatSource]
    var context: ModelContext?
    var onOpen: (ChatSource) -> Void
    @State private var page = 0
    @State private var icon: NSImage?
    @State private var overRow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { onOpen(currentCard.source) }) {
                HStack(alignment: .center, spacing: 10) {
                    pagerMark
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentCard.title)
                            .font(CraftFont.section)
                            .foregroundStyle(.primary)
                            .underline(overRow, color: .secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(currentCard.subtitle)
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { overRow = $0 }
            .accessibilityHint("Opens this source")

            if sources.count > 1 {
                HStack(spacing: 8) {
                    Button("Previous", systemImage: "chevron.left", action: previous)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(page == 0)
                    Text("\(page + 1)/\(sources.count)")
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Button("Next", systemImage: "chevron.right", action: next)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(page >= sources.count - 1)
                }
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
        .task(id: current.id) { await loadIcon() }
    }

    @ViewBuilder private var pagerMark: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: currentCard.source.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var current: ChatSource {
        sources[min(page, sources.count - 1)]
    }

    private var currentCard: (source: ChatSource, title: String, subtitle: String) {
        current.presented(in: context)
    }

    private func previous() {
        page = max(page - 1, 0)
    }

    private func next() {
        page = min(page + 1, sources.count - 1)
    }

    private func loadIcon() async {
        icon = nil
        guard let url = current.url.flatMap(URL.init(string:)) else { return }
        icon = await FaviconStore.shared.image(for: url)
    }
}

enum SourceChipImage {
    static func make(sources: [ChatSource], icon: NSImage?) -> NSImage {
        let first = sources.first
        let text = chipLabel(sources)
        let font = NSFont.systemFont(ofSize: 13)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = ceil(8 + 14 + 6 + textSize.width + 8)
        let height: CGFloat = 22
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            let markRect = NSRect(x: 8, y: (height - 14) / 2, width: 14, height: 14)
            let mark: NSImage?
            if let icon {
                mark = icon
            } else if let name = first?.symbol {
                mark = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            } else {
                mark = nil
            }
            drawTinted(mark, in: markRect, color: NSColor.secondaryLabelColor)

            (text as NSString).draw(
                in: NSRect(x: 28, y: (height - textSize.height) / 2, width: textSize.width, height: textSize.height),
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawTinted(_ image: NSImage?, in rect: NSRect, color: NSColor) {
        guard let image else { return }
        let stamped = NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            bounds.fill(using: .sourceIn)
            return true
        }
        stamped.draw(in: rect)
    }

    private static func chipLabel(_ sources: [ChatSource]) -> String {
        guard let first = sources.first else { return "" }
        if sources.count > 1 { return "\(first.shortName) +\(sources.count - 1)" }
        return first.shortName
    }
}

final class SourceChipAttachment: NSTextAttachment {
    let sources: [ChatSource]
    var icon: NSImage? {
        didSet { refresh() }
    }

    init(sources: [ChatSource]) {
        self.sources = sources
        super.init(data: nil, ofType: nil)
        refresh()
    }

    required init?(coder: NSCoder) {
        sources = []
        super.init(coder: coder)
    }

    func refresh() {
        let drawn = SourceChipImage.make(sources: sources, icon: icon)
        image = drawn
        bounds = CGRect(x: 4, y: -6, width: drawn.size.width, height: drawn.size.height)
    }
}
