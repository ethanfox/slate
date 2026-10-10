import SwiftUI

struct PropertyPill<Content: View>: View {
    var title: String
    var systemImage: String
    var field: ObjectFind.Field? = nil
    var onOpen: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.objectFind) private var find
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
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
                .padding(.leading, 9)
                .padding(.trailing, onOpen == nil ? 9 : 5)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .tint(.secondary)

            if let onOpen {
                Button("Open \(title)", systemImage: "arrow.up.right", action: onOpen)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .help("Open \(title)")
                    .padding(.trailing, 2)
            }
        }
        .foregroundStyle(.secondary)
        .background(Capsule().fill(pillFill))
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .modifier(FindAnchorIfNeeded(field: field))
    }

    private var pillFill: Color {
        if let field, let mark = find?.mark(for: field), mark != .none {
            return mark.fill
        }
        return hovering ? CraftColor.hover : .clear
    }
}
