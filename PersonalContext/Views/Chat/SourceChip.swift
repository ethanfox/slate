import AppKit
import SwiftUI

struct SourceHover: Equatable {
    var sources: [ChatSource]
    var rect: CGRect
}

struct SourceChipLabel: View {
    var sources: [ChatSource]
    var icon: NSImage?

    var body: some View {
        HStack(spacing: 5) {
            mark
            Text(label)
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(CraftColor.selection, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(CraftColor.hairline)
        )
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder private var mark: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 12, height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        } else if let source = sources.first {
            Image(systemName: source.symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
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
    var onOpen: (ChatSource) -> Void
    @State private var page = 0
    @State private var icon: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onOpen(current)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    pagerMark
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title)
                            .font(CraftFont.section)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let subtitle {
                            Text(subtitle)
                                .font(CraftFont.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
            Image(systemName: current.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var current: ChatSource {
        sources[min(page, sources.count - 1)]
    }

    private var subtitle: String? {
        if current.kind == .url { return current.host }
        return current.kind.rawValue.localizedCapitalized
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
        let font = NSFont.systemFont(ofSize: 11)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = ceil(6 + 12 + 5 + textSize.width + 6)
        let height: CGFloat = 16
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            let markRect = NSRect(x: 6, y: (height - 12) / 2, width: 12, height: 12)
            if let icon {
                icon.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
            } else if let symbol = first?.symbol {
                let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                symbolImage?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))?.draw(
                    in: markRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 0.7
                )
            }

            (text as NSString).draw(
                in: NSRect(x: 23, y: (height - textSize.height) / 2, width: textSize.width, height: textSize.height),
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
        bounds = CGRect(x: 3, y: -3, width: drawn.size.width, height: drawn.size.height)
    }
}
