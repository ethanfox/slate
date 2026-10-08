import SwiftUI

struct PropertyPill<Content: View>: View {
    var title: String
    var systemImage: String
    var field: ObjectFind.Field? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.objectFind) private var find
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
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(minWidth: 28, minHeight: 28)
            .background(Capsule().fill(pillFill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering = $0 }
        .modifier(FindAnchorIfNeeded(field: field))
    }

    private var pillFill: Color {
        if let field, let mark = find?.mark(for: field), mark != .none {
            return mark.fill
        }
        return hovering ? CraftColor.hover : .clear
    }
}
