import SwiftData
import SwiftUI

struct AssociationFields: View {
    @Bindable var item: AgendaItem
    var onConflict: (AssociationConflict, @escaping () -> Void) -> Void

    @Query(sort: \Project.name) private var projects: [Project]
    @Environment(\.modelContext) private var context
    @State private var creatingNote = false
    @State private var newNoteTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModalControlRow("Project") {
                HStack(spacing: 6) {
                    if item.projectIsInherited { InheritMark() }
                    Picker("Project", selection: projectBinding) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(projects) { project in
                            Text(project.displayName).tag(Optional(project.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            ModalControlRow("Tracks") {
                Menu {
                    if tracksInScope.isEmpty {
                        Button("No tracks") {}
                            .disabled(true)
                    } else {
                        ForEach(tracksInScope) { thread in
                            Button {
                                toggle(thread)
                            } label: {
                                trackLabel(thread)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if item.trackLinks.contains(where: \.isInherited) { InheritMark() }
                        Text(trackTitle)
                            .foregroundStyle(.primary)
                    }
                }
                .fixedSize()
            }

            ModalControlRow("Linked notes") {
                Menu {
                    Button("New Note…") { creatingNote = true }
                    if !notesInScope.isEmpty {
                        Divider()
                        ForEach(notesInScope) { note in
                            Button {
                                toggle(note)
                            } label: {
                                Label(note.displayTitle, systemImage: linkedNoteIDs.contains(note.id) ? "checkmark" : "note.text")
                            }
                        }
                    }
                } label: {
                    Text(noteTitle)
                        .foregroundStyle(.primary)
                }
                .fixedSize()
            }

            HStack(alignment: .center, spacing: 8) {
                Text("Tags")
                    .font(CraftFont.body)
                Spacer(minLength: 16)
                TagField(tags: item.tags) { AssociationService.apply(tags: $0, to: item) }
            }
            .frame(minHeight: 28)
        }
        .alert("New Note", isPresented: $creatingNote) {
            TextField("Title", text: $newNoteTitle)
            Button("Create") { createNote() }
            Button("Cancel", role: .cancel) { newNoteTitle = "" }
        } message: {
            if item.project == nil {
                Text("Pick a project first.")
            }
        }
    }

    private var projectBinding: Binding<UUID?> {
        Binding(
            get: { item.project?.id },
            set: { id in
                AssociationService.assignUserProject(projects.first { $0.id == id }, on: item)
                try? context.save()
            }
        )
    }

    private var tracksInScope: [ProjectThread] {
        let pool = item.project?.threads ?? projects.flatMap(\.threads)
        return pool.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var notesInScope: [Note] {
        let pool = item.project?.notes ?? projects.flatMap(\.notes)
        return pool.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    private var linkedNoteIDs: Set<UUID> { Set(item.noteLinks.map(\.noteID)) }

    private var trackTitle: String {
        let names = item.liveTracks.map { $0.title.isEmpty ? "Untitled" : $0.title }
        if names.isEmpty { return "None" }
        return names.joined(separator: ", ")
    }

    private var noteTitle: String {
        let names = item.liveNotes.map(\.displayTitle)
        if names.isEmpty { return "None" }
        return names.joined(separator: ", ")
    }

    private func trackLabel(_ thread: ProjectThread) -> some View {
        let linked = item.trackLinks.contains { $0.threadID == thread.id }
        return Label(thread.title.isEmpty ? "Untitled" : thread.title, systemImage: linked ? "checkmark" : TrackStyle.symbol)
    }

    private func toggle(_ thread: ProjectThread) {
        if item.trackLinks.contains(where: { $0.threadID == thread.id }) {
            AssociationService.unlink(threadID: thread.id, from: item)
            try? context.save()
            return
        }
        if let conflict = AssociationService.link(thread: thread, onto: item) {
            onConflict(conflict) {
                AssociationService.switchProject(conflict.incoming, on: item)
                AssociationService.applyLink(thread: thread, onto: item)
                try? context.save()
            }
            return
        }
        try? context.save()
    }

    private func toggle(_ note: Note) {
        if linkedNoteIDs.contains(note.id) {
            AssociationService.unlink(noteID: note.id, from: item)
            try? context.save()
            return
        }
        if let conflict = AssociationService.link(note: note, onto: item) {
            onConflict(conflict) {
                AssociationService.switchProject(conflict.incoming, on: item)
                AssociationService.applyLink(note: note, onto: item)
                try? context.save()
            }
            return
        }
        try? context.save()
    }

    private func createNote() {
        guard let project = item.project else { return }
        let title = newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        newNoteTitle = ""
        let note = Note(content: "", project: project, title: title)
        context.insert(note)
        AssociationService.applyLink(note: note, onto: item)
        project.touch()
        try? context.save()
    }
}
