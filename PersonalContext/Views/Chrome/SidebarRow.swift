import SwiftUI

struct SidebarRow: View {
    var title: String
    var systemImage: String
    var isSelected: Bool
    var showsPin = false

    @Environment(\.appearsActive) private var appearsActive
    @State private var hovering = false

    private var iconColor: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.primary) }
        if appearsActive { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tertiary)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(CraftFont.sidebarIcon)
                .frame(width: 18, height: 18)
                .foregroundStyle(iconColor)
            Text(title)
                .font(CraftFont.sidebar)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
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
    }
}
