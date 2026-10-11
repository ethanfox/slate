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
