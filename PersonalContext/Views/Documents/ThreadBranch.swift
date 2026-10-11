import SwiftData
import SwiftUI

struct ThreadBranch: View {
    var node: TrackNode
    var depth: Int
    var selectedID: UUID?
    @Binding var expanded: Set<UUID>
    @Binding var expandedCompleted: Set<UUID>
    var markedIDs: Set<UUID>
    var onSelect: (UUID) -> Void
    var onCreateChild: (UUID) -> Void
    var onKeep: (UUID) -> Void
    var onDelete: (UUID) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.appearsActive) private var appearsActive
    @State private var hovering = false

    private var iconColor: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.primary) }
        if appearsActive { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tertiary)
    }

    private var openChildren: [TrackNode] {
        node.children.filter { $0.status != .completed }
    }

    private var completedChildren: [TrackNode] {
        node.children.filter { $0.status == .completed }
    }

    private var showsChildren: Bool { !node.children.isEmpty }
    private var childrenVisible: Bool { expanded.contains(node.id) }
    private var completedVisible: Bool { expandedCompleted.contains(node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if childrenVisible {
                ForEach(openChildren) { child in
                    ThreadBranch(
                        node: child,
                        depth: depth + 1,
                        selectedID: selectedID,
                        expanded: $expanded,
                        expandedCompleted: $expandedCompleted,
                        markedIDs: markedIDs,
                        onSelect: onSelect,
                        onCreateChild: onCreateChild,
                        onKeep: onKeep,
                        onDelete: onDelete
                    )
                }
                if !completedChildren.isEmpty {
                    CompletedTracksHeader(
                        count: completedChildren.count,
                        isExpanded: completedVisible,
                        indent: CGFloat(depth + 1) * ProjectColumnMetrics.subtrackIndent + 2,
                        onToggle: toggleCompleted
                    )
                    if completedVisible {
                        ForEach(completedChildren) { child in
                            ThreadBranch(
                                node: child,
                                depth: depth + 1,
                                selectedID: selectedID,
                                expanded: $expanded,
                                expandedCompleted: $expandedCompleted,
                                markedIDs: markedIDs,
                                onSelect: onSelect,
                                onCreateChild: onCreateChild,
                                onKeep: onKeep,
                                onDelete: onDelete
                            )
                        }
                    }
                }
            }
        }
    }

    private var isSelected: Bool { selectedID == node.id }

    private var isMarked: Bool { markedIDs.contains(node.id) }

    private var rowSymbol: String {
        if isMarked { return "xmark.octagon" }
        return node.status == .completed ? ThreadStatus.completed.symbol : node.kind.symbol
    }

    private var row: some View {
        HStack(spacing: 4) {
            disclosure
            Button {
                onSelect(node.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: rowSymbol)
                        .font(CraftFont.sidebarIcon)
                        .foregroundStyle(isMarked ? AnyShapeStyle(.red) : iconColor)
                        .frame(width: 18)
                    Text(node.title)
                        .font(CraftFont.sidebar)
                        .lineLimit(1)
                        .foregroundStyle(node.status.isCurrent ? Color.primary : Color.secondary)
                    Spacer(minLength: 0)
                }
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? CraftColor.selection : Color.clear)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(!isSelected && hovering ? CraftColor.hover : Color.clear)
                        .animation(Motion.hover, value: hovering)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityValue(isMarked ? "Marked for deletion" : "")
            .contextMenu {
                Button {
                    if let thread = TitleIndexStore.thread(node.id, in: context) {
                        app.present(.editThread(thread))
                    }
                } label: {
                    Label("Edit…", systemImage: "pencil")
                }
                Button {
                    if let thread = TitleIndexStore.thread(node.id, in: context) {
                        app.open(thread, newTab: true)
                    }
                } label: {
                    Label("Open in New Tab", systemImage: "plus.square.on.square")
                }
                Button {
                    onCreateChild(node.id)
                } label: {
                    Label("New Sub-track", systemImage: "plus")
                }
                Divider()
                if isMarked {
                    Button {
                        onKeep(node.id)
                    } label: {
                        Label("Keep", systemImage: "arrow.uturn.backward")
                    }
                }
                Button(role: .destructive) {
                    onDelete(node.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .padding(.leading, CGFloat(depth) * ProjectColumnMetrics.subtrackIndent + 2)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var disclosure: some View {
        if !showsChildren {
            Color.clear.frame(width: 28, height: 28)
        } else {
            Button(action: toggleCollapsed) {
                Image(systemName: childrenVisible ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(node.title)
            .accessibilityValue(childrenVisible ? "Expanded" : "Collapsed")
        }
    }

    private func toggleCollapsed() {
        if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
        }
    }

    private func toggleCompleted() {
        if expandedCompleted.contains(node.id) {
            expandedCompleted.remove(node.id)
        } else {
            expandedCompleted.insert(node.id)
        }
    }
}

private struct CompletedTracksHeader: View {
    var count: Int
    var isExpanded: Bool
    var indent: CGFloat
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                Text("Completed")
                    .font(CraftFont.section)
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Completed")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows completed subtracks")
    }
}
