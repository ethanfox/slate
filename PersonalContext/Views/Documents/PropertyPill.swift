import SwiftUI

struct PropertyPill<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(minWidth: 28, minHeight: 28)
            .background(Capsule().fill(hovering ? CraftColor.hover : Color.clear))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}
