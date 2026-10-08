import SwiftData
import SwiftUI

struct ThreadBranch: View {
    var thread: ProjectThread
    var depth: Int
    var selectedID: UUID?
    @Binding var collapsed: Set<UUID>
    @Binding var expandedCompleted: Set<UUID>
    var markedIDs: Set<UUID>
    var onSelect: (UUID) -> Void
    var onCreateChild: (ProjectThread) -> Void
    var onKeep: (ProjectThread) -> Void
    var onDelete: (ProjectThread) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.appearsActive) private var appearsActive
    @State private var hovering = false

    private var iconColor: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.primary) }
        if appearsActive { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tertiary)
    }

    private var openChildren: [ProjectThread] {
        thread.orderedChildren.filter { $0.status != .completed }
    }

    private var completedChildren: [ProjectThread] {
        thread.orderedChildren.filter { $0.status == .completed }
    }

    private var showsChildren: Bool { !thread.children.isEmpty }
    private var childrenVisible: Bool { !collapsed.contains(thread.id) }
    private var completedVisible: Bool { expandedCompleted.contains(thread.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if childrenVisible {
                ForEach(openChildren) { child in
                    ThreadBranch(
                        thread: child,
                        depth: depth + 1,
                        selectedID: selectedID,
                        collapsed: $collapsed,
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
                                thread: child,
                                depth: depth + 1,
                                selectedID: selectedID,
                                collapsed: $collapsed,
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

    private var isSelected: Bool { selectedID == thread.id }

    private var isMarked: Bool { markedIDs.contains(thread.id) }

    private var rowSymbol: String {
        if isMarked { return "xmark.octagon" }
        return thread.status == .completed ? ThreadStatus.completed.symbol : thread.kind.symbol
    }

    private var row: some View {
        HStack(spacing: 4) {
            disclosure
            Button {
                onSelect(thread.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: rowSymbol)
                        .font(CraftFont.sidebarIcon)
                        .foregroundStyle(isMarked ? AnyShapeStyle(.red) : iconColor)
                        .frame(width: 18)
                    Text(thread.title.isEmpty ? "Untitled" : thread.title)
                        .font(CraftFont.sidebar)
                        .lineLimit(1)
                        .foregroundStyle(thread.status.isCurrent ? Color.primary : Color.secondary)
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
                    app.present(.editThread(thread))
                } label: {
                    Label("Edit…", systemImage: "pencil")
                }
                Button {
                    onCreateChild(thread)
                } label: {
                    Label("New Sub-track", systemImage: "plus")
                }
                Divider()
                if isMarked {
                    Button {
                        onKeep(thread)
                    } label: {
                        Label("Keep", systemImage: "arrow.uturn.backward")
                    }
                }
                Button(role: .destructive) {
                    onDelete(thread)
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
            .accessibilityLabel(thread.title.isEmpty ? "Untitled" : thread.title)
            .accessibilityValue(childrenVisible ? "Expanded" : "Collapsed")
        }
    }

    private func toggleCollapsed() {
        if collapsed.contains(thread.id) {
            collapsed.remove(thread.id)
        } else {
            collapsed.insert(thread.id)
        }
    }

    private func toggleCompleted() {
        if expandedCompleted.contains(thread.id) {
            expandedCompleted.remove(thread.id)
        } else {
            expandedCompleted.insert(thread.id)
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
