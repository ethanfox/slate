import SwiftData
import SwiftUI

struct SettingsTagsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \ProjectThread.updatedAt, order: .reverse) private var tracks: [ProjectThread]
    @State private var newName = ""
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var pendingDelete: Tag?

    var body: some View {
        SettingsPage {
            SettingsGroup("Tags") {
                if tags.isEmpty {
                    SettingsRow {
                        Text("No tags yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                        if index > 0 { Hairline().padding(.horizontal, 16) }
                        tagRow(tag)
                    }
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    TextField("New tag", text: $newName)
                        .textFieldStyle(.plain)
                    Button("Add") { add() }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !deleted.isEmpty {
                SettingsGroup("Deleted") {
                    ForEach(Array(deleted.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline().padding(.horizontal, 16) }
                        deletedRow(row)
                    }
                }
            }
        }
        .alert("Rename Tag", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { saveRename() }
            Button("Cancel", role: .cancel) { renameID = nil }
        }
        .alert("Delete this tag?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let tag = pendingDelete { TagStore.delete(tag, in: context) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It’s removed from every object.")
        }
    }

    private var deleted: [DeletedAssociation] {
        return AssociationService.deletedEntries(eventKitIDs: app.eventKit.knownAgendaIDs, in: context)
    }

    private func tagRow(_ tag: Tag) -> some View {
        SettingsRow {
            Image(systemName: tag.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(tag.displayName)
            Spacer(minLength: 16)
            Button("Rename") {
                renameID = tag.id
                renameText = tag.name
            }
            Button("Delete", role: .destructive) { pendingDelete = tag }
        }
    }

    private func deletedRow(_ row: DeletedAssociation) -> some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(row.detail)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Menu("Resolve") {
                if let link = row.noteLink {
                    Button("Drop link") {
                        AssociationService.dropLink(link, from: row.item, in: context)
                        try? context.save()
                    }
                    Menu("Replace with…") {
                        ForEach(notes) { note in
                            Button(note.displayTitle) {
                                _ = AssociationService.replaceNote(link, with: note, on: row.item, in: context)
                                try? context.save()
                            }
                        }
                    }
                } else if let link = row.trackLink {
                    Button("Drop link") {
                        AssociationService.dropLink(link, from: row.item, in: context)
                        try? context.save()
                    }
                    Menu("Replace with…") {
                        ForEach(tracks) { thread in
                            Button(thread.title.isEmpty ? "Untitled" : thread.title) {
                                _ = AssociationService.replaceTrack(link, with: thread, on: row.item, in: context)
                                try? context.save()
                            }
                        }
                    }
                } else {
                    Button("Delete Membrae record", role: .destructive) {
                        context.delete(row.item)
                        try? context.save()
                    }
                }
            }
        }
    }

    private func add() {
        _ = TagStore.create(named: newName, in: context)
        newName = ""
    }

    private func saveRename() {
        guard let id = renameID, let tag = tags.first(where: { $0.id == id }) else { return }
        if !TagStore.rename(tag, to: renameText, in: context) {
            app.flash("A tag with that name already exists.")
        }
        renameID = nil
    }
}
