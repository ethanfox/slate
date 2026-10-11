import SwiftData
import SwiftUI

struct InheritMark: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Image(systemName: "link")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(app.accent.color)
            .accessibilityLabel("Inherited")
            .help("Inherited")
    }
}

struct TagField: View {
    var tags: [Tag]
    var size: TagChipSize = .regular
    var onChange: ([Tag]) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var catalog: [Tag]
    @State private var creating = false
    @State private var newName = ""
    @State private var newColor: TagSwatch = .slate

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ordered) { tag in
                TagChip(tag: tag, size: size, onRemove: { toggle(tag) })
            }
            addMenu
        }
        .modifier(FindAnchorIfNeeded(field: .tags))
        .alert("New Tag", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Add") { add() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private var ordered: [Tag] {
        tags.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedIDs: Set<UUID> { Set(tags.map(\.id)) }

    private var addMenu: some View {
        Menu {
            if catalog.isEmpty {
                Button("New Tag…") { beginCreate() }
            } else {
                ForEach(catalog) { tag in
                    Button {
                        toggle(tag)
                    } label: {
                        Label(tag.displayName, systemImage: selectedIDs.contains(tag.id) ? "checkmark" : "tag")
                    }
                }
                Divider()
                Button("New Tag…") { beginCreate() }
            }
        } label: {
            if tags.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "tag")
                        .font(.system(size: 11))
                    Text("Tags")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(minWidth: 28, minHeight: size == .compact ? 20 : 28)
                .background(Capsule().fill(CraftColor.hover.opacity(0.001)))
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size.height, height: size.height)
                    .background(Capsule().strokeBorder(CraftColor.hairline))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Add tag")
        .accessibilityLabel("Add tag")
    }

    private func beginCreate() {
        newColor = TagSwatch.nextUnused(among: catalog)
        creating = true
    }

    private func toggle(_ tag: Tag) {
        var next = tags
        if let index = next.firstIndex(where: { $0.id == tag.id }) {
            next.remove(at: index)
        } else {
            next.append(tag)
        }
        onChange(next)
        TagStore.persist(context)
    }

    private func add() {
        guard let tag = TagStore.create(named: newName, color: newColor, in: context) else { return }
        newName = ""
        if !selectedIDs.contains(tag.id) {
            onChange(tags + [tag])
            TagStore.persist(context)
        }
    }
}
