import SwiftUI

struct SidebarRow: View {
    var title: String
    var systemImage: String
    var mark: BrandMark? = nil
    var isSelected: Bool
    var showsPin = false
    var badge = 0
    var isBusy = false
    var isMarkedForDeletion = false

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var iconColor: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.primary) }
        if appearsActive { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tertiary)
    }

    private var busyTint: Color {
        if isSelected { return Color.primary }
        if appearsActive { return Color.secondary }
        return Color(nsColor: .tertiaryLabelColor)
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isBusy, !reduceMotion {
                    ProgressView()
                        .controlSize(.small)
                        .tint(busyTint)
                } else if isBusy {
                    Image(systemName: "ellipsis")
                        .font(CraftFont.sidebarIcon)
                        .foregroundStyle(iconColor)
                } else if isMarkedForDeletion {
                    Image(systemName: "xmark.octagon")
                        .font(CraftFont.sidebarIcon)
                        .foregroundStyle(.red)
                } else if let mark {
                    BrandMarkImage(mark: mark, size: 16)
                        .foregroundStyle(iconColor)
                } else {
                    Image(systemName: systemImage)
                        .font(CraftFont.sidebarIcon)
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(CraftFont.sidebar)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if badge > 0 {
                Text("\(badge)")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(badge) due")
            }
            if showsPin {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? CraftColor.selection : Color.clear)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(!isSelected && hovering ? CraftColor.hover : Color.clear)
                .animation(Motion.hover, value: hovering)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityValue(isMarkedForDeletion ? "Marked for deletion" : "")
    }
}
