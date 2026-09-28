import SwiftData
import SwiftUI

struct ThreadBranch: View {
    var thread: ProjectThread
    var depth: Int
    var selectedID: UUID?
    @Binding var collapsed: Set<UUID>
    var onSelect: (UUID) -> Void
    var onCreateChild: (ProjectThread) -> Void
    var onDelete: (ProjectThread) -> Void
    @Environment(\.appearsActive) private var appearsActive
    @State private var hovering = false

    private var iconColor: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.primary) }
        if appearsActive { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tertiary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if !collapsed.contains(thread.id) {
                ForEach(thread.orderedChildren) { child in
                    ThreadBranch(
                        thread: child,
                        depth: depth + 1,
                        selectedID: selectedID,
                        collapsed: $collapsed,
                        onSelect: onSelect,
                        onCreateChild: onCreateChild,
                        onDelete: onDelete
                    )
                }
            }
        }
    }

    private var isSelected: Bool { selectedID == thread.id }

    private var row: some View {
        HStack(spacing: 4) {
            disclosure
            Button {
                onSelect(thread.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: thread.kind.symbol)
                        .font(CraftFont.sidebarIcon)
                        .foregroundStyle(iconColor)
                        .frame(width: 18)
                    Text(thread.title.isEmpty ? "Untitled" : thread.title)
                        .font(CraftFont.sidebar)
                        .lineLimit(1)
                        .foregroundStyle(thread.status.isCurrent ? Color.primary : Color.secondary)
                    Spacer(minLength: 0)
                }
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? CraftColor.selection : (hovering ? CraftColor.hover : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("New Sub-thread") { onCreateChild(thread) }
                Button("Delete", role: .destructive) { onDelete(thread) }
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 2)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var disclosure: some View {
        if thread.children.isEmpty {
            Color.clear.frame(width: 28, height: 28)
        } else {
            Button {
                if collapsed.contains(thread.id) {
                    collapsed.remove(thread.id)
                } else {
                    collapsed.insert(thread.id)
                }
            } label: {
                Image(systemName: collapsed.contains(thread.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }
}
