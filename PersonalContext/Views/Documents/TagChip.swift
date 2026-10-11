import AppKit
import SwiftUI

enum TagChipSize {
    case compact
    case regular

    var font: Font {
        switch self {
        case .compact: CraftFont.caption
        case .regular: .system(size: 12)
        }
    }

    var height: CGFloat {
        switch self {
        case .compact: 20
        case .regular: 24
        }
    }

    var horizontal: CGFloat {
        switch self {
        case .compact: 7
        case .regular: 8
        }
    }
}

struct TagChip: View {
    var tag: Tag
    var size: TagChipSize = .regular
    var selected = false
    var onRemove: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Text(tag.displayName)
                .font(size.font)
                .lineLimit(1)
            if let onRemove {
                Button("Remove \(tag.displayName)", systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .font(.system(size: size == .compact ? 8 : 9, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.7))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .help("Remove \(tag.displayName)")
            }
        }
        .foregroundStyle(ink)
        .padding(.leading, size.horizontal)
        .padding(.trailing, onRemove == nil ? size.horizontal : size.horizontal - 2)
        .frame(height: size.height)
        .background(Capsule().fill(fill))
        .fixedSize()
        .accessibilityLabel(tag.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "")
    }

    private var fill: Color {
        Color(hex: tag.swatch.hex).opacity(selected ? 0.28 : 0.16)
    }

    private var ink: Color {
        Color(hex: colorScheme == .dark ? tag.swatch.inkDarkHex : tag.swatch.inkLightHex)
    }
}

enum TagChipMetrics {
    static let spacing: CGFloat = 4
    static let overflowWidth: CGFloat = 20

    struct Plan: Equatable {
        var visibleCount: Int
        var overflows: Bool
    }

    static func width(for name: String, size: TagChipSize) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size == .compact ? 11 : 12)
        let text = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        return text + size.horizontal * 2
    }

    static func fit(_ names: [String], in available: CGFloat, size: TagChipSize) -> Plan {
        if names.isEmpty { return Plan(visibleCount: 0, overflows: false) }
        if available <= 0 { return Plan(visibleCount: 0, overflows: true) }
        let widths = names.map { width(for: $0, size: size) }
        let total = widths.enumerated().reduce(CGFloat.zero) { sum, item in
            sum + item.element + (item.offset == 0 ? 0 : spacing)
        }
        if total <= available {
            return Plan(visibleCount: names.count, overflows: false)
        }
        var used: CGFloat = 0
        var count = 0
        for width in widths {
            let next = count == 0 ? width : used + spacing + width
            if next + spacing + overflowWidth <= available {
                used = next
                count += 1
            } else {
                break
            }
        }
        return Plan(visibleCount: count, overflows: true)
    }
}

struct CardTagStrip: View {
    var tags: [Tag]
    var size: TagChipSize = .compact

    @State private var width: CGFloat = 0
    @State private var hovering = false

    var body: some View {
        if !ordered.isEmpty {
            Color.clear
                .frame(height: size.height)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .overlay(alignment: .leading) {
                    HStack(spacing: TagChipMetrics.spacing) {
                        ForEach(shown) { tag in
                            TagChip(tag: tag, size: size)
                        }
                        if plan.overflows {
                            overflowGlyph
                        }
                    }
                }
        }
    }

    private var ordered: [Tag] {
        tags.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var plan: TagChipMetrics.Plan {
        TagChipMetrics.fit(ordered.map(\.displayName), in: width, size: size)
    }

    private var shown: [Tag] {
        Array(ordered.prefix(plan.visibleCount))
    }

    private var overflowGlyph: some View {
        Image(systemName: "tag")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: TagChipMetrics.overflowWidth, height: size.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .popover(isPresented: $hovering, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ordered) { tag in
                        TagChip(tag: tag, size: .compact)
                    }
                }
                .padding(10)
                .frame(minWidth: 140, alignment: .leading)
            }
            .accessibilityLabel(ordered.map(\.displayName).joined(separator: ", "))
    }
}

struct TagColorWell: View {
    var selection: TagSwatch
    var onPick: (TagSwatch) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TagSwatch.allCases) { swatch in
                Button {
                    onPick(swatch)
                } label: {
                    Circle()
                        .fill(Color(hex: swatch.hex))
                        .frame(width: 16, height: 16)
                        .overlay {
                            if selection == swatch {
                                Circle()
                                    .strokeBorder(.white, lineWidth: 2)
                            }
                        }
                        .overlay {
                            Circle().strokeBorder(CraftColor.hairline, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .help(swatch.label)
                .accessibilityLabel(swatch.label)
                .accessibilityAddTraits(selection == swatch ? .isSelected : [])
            }
        }
    }
}
