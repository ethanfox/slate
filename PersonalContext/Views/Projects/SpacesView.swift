import SwiftData
import SwiftUI

/// Every Space, as a table or as cards.
struct SpacesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TitleIndex> { $0.kindRaw == "space" })
    private var spaces: [TitleIndex]
    @State private var pendingDelete: TitleIndex?
    @State private var sort = SpaceSort.updated
    @State private var sortAscending = false

    private var ordered: [TitleIndex] {
        spaces.sorted { lhs, rhs in
            let left = app.isPinned(lhs.id)
            let right = app.isPinned(rhs.id)
            if left != right { return left && !right }
            return sortAscending ? compare(lhs, rhs) : compare(rhs, lhs)
        }
    }

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 0) {
                    if ordered.isEmpty {
                        EmptyLine(text: "Make a Space for each part of your life or work.")
                    } else if app.spacesLayout == .table {
                        SpacesTable(
                            spaces: ordered,
                            sort: sort,
                            sortAscending: sortAscending,
                            onSort: sortBy,
                            onOpen: { app.openSpace($0.id) },
                            onOpenNewTab: { app.openSpace($0.id, newTab: true) },
                            onEdit: edit,
                            onPin: pin,
                            isPinned: { app.isPinned($0.id) },
                            onDelete: { pendingDelete = $0 }
                        )
                    } else {
                        cards
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear { NavTrace.event("spaces appear count=\(spaces.count)") }
        .alert(
            "Delete \(pendingDelete?.displayTitle ?? "this Space")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete {
                    app.deleteSpace(row.id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(SpaceDeletion.message)
        }
    }

    private var cards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], alignment: .leading, spacing: 16) {
            ForEach(ordered) { space in
                Button {
                    app.openSpace(space.id)
                } label: {
                    SpaceListCard(row: space, isPinned: app.isPinned(space.id))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    menu(space)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(_ space: TitleIndex) -> some View {
        Button {
            edit(space)
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        Button {
            app.openSpace(space.id, newTab: true)
        } label: {
            Label("Open in New Tab", systemImage: "plus.square.on.square")
        }
        Button {
            pin(space)
        } label: {
            Label(app.isPinned(space.id) ? "Unpin" : "Pin", systemImage: app.isPinned(space.id) ? "pin.slash" : "pin")
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = space
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func sortBy(_ field: SpaceSort) {
        if sort == field {
            sortAscending.toggle()
        } else {
            sort = field
            sortAscending = field == .name
        }
    }

    private func edit(_ row: TitleIndex) {
        if let space = TitleIndexStore.project(row.id, in: context) {
            app.showSpaceSettings(space)
        }
    }

    private func pin(_ row: TitleIndex) {
        app.togglePin(.space, row.id)
    }

    private func compare(_ lhs: TitleIndex, _ rhs: TitleIndex) -> Bool {
        switch sort {
        case .name:
            lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        case .status:
            lhs.spaceStatus.label.localizedCaseInsensitiveCompare(rhs.spaceStatus.label) == .orderedAscending
        case .updated:
            lhs.updatedAt < rhs.updatedAt
        case .created:
            lhs.createdAt < rhs.createdAt
        }
    }
}

private struct SpacesTable: View {
    var spaces: [TitleIndex]
    var sort: SpaceSort
    var sortAscending: Bool
    var onSort: (SpaceSort) -> Void
    var onOpen: (TitleIndex) -> Void
    var onOpenNewTab: (TitleIndex) -> Void
    var onEdit: (TitleIndex) -> Void
    var onPin: (TitleIndex) -> Void
    var isPinned: (TitleIndex) -> Bool
    var onDelete: (TitleIndex) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                header(.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                header(.status)
                    .frame(width: 88, alignment: .leading)
                header(.updated)
                    .frame(width: 110, alignment: .trailing)
                header(.created)
                    .frame(width: 110, alignment: .trailing)
            }
            .padding(.bottom, 8)

            Hairline()

            ForEach(spaces) { space in
                Button {
                    onOpen(space)
                } label: {
                    SpaceTableRow(space: space, isPinned: isPinned(space))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        onEdit(space)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button {
                        onOpenNewTab(space)
                    } label: {
                        Label("Open in New Tab", systemImage: "plus.square.on.square")
                    }
                    Button {
                        onPin(space)
                    } label: {
                        Label(isPinned(space) ? "Unpin" : "Pin", systemImage: isPinned(space) ? "pin.slash" : "pin")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDelete(space)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func header(_ field: SpaceSort) -> some View {
        Button {
            onSort(field)
        } label: {
            HStack(spacing: 4) {
                Text(field.label)
                if sort == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .font(CraftFont.caption)
        .foregroundStyle(.secondary)
        .help("Sort by \(field.label)")
    }
}

private struct SpaceTableRow: View {
    var space: TitleIndex
    var isPinned: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: space.symbol.isEmpty ? TitleIndexKind.space.symbol : space.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(space.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(space.spaceStatus.label)
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)

            Text(space.updatedAt.relativeLabel)
                .font(CraftFont.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .trailing)

            Text(space.createdAt.relativeLabel)
                .font(CraftFont.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? CraftColor.hover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }
}

private struct SpaceListCard: View {
    var row: TitleIndex
    var isPinned: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: row.symbol.isEmpty ? TitleIndexKind.space.symbol : row.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                Spacer(minLength: 0)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(row.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("\(row.spaceStatus.label) · \(row.updatedAt.relativeLabel)")
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? CraftColor.selection : CraftColor.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CraftColor.hairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
    }
}
