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
    var onChange: ([Tag]) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var catalog: [Tag]
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        PropertyPill(title: label, systemImage: "tag") {
            if catalog.isEmpty {
                Button("New Tag…") { creating = true }
            } else {
                ForEach(catalog) { tag in
                    Button {
                        toggle(tag)
                    } label: {
                        Label(tag.displayName, systemImage: selectedIDs.contains(tag.id) ? "checkmark" : tag.symbol)
                    }
                }
                Divider()
                Button("New Tag…") { creating = true }
            }
        }
        .alert("New Tag", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Add") { add() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private var selectedIDs: Set<UUID> { Set(tags.map(\.id)) }

    private var label: String {
        if tags.isEmpty { return "Tags" }
        return tags.map(\.displayName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: ", ")
    }

    private func toggle(_ tag: Tag) {
        var next = tags
        if let index = next.firstIndex(where: { $0.id == tag.id }) {
            next.remove(at: index)
        } else {
            next.append(tag)
        }
        onChange(next)
    }

    private func add() {
        guard let tag = TagStore.create(named: newName, in: context) else { return }
        newName = ""
        if !selectedIDs.contains(tag.id) {
            onChange(tags + [tag])
        }
    }
}
