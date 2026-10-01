import SwiftData
import SwiftUI

struct AssociationFields: View {
    @Bindable var item: AgendaItem
    var onConflict: (AssociationConflict, @escaping () -> Void) -> Void

    @Query(sort: \Project.name) private var projects: [Project]
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @State private var creatingNote = false
    @State private var newNoteTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let project = item.project {
                AssociationOpenRow(
                    title: "Project",
                    name: project.displayName,
                    symbol: projectIcon(project),
                    inherited: item.projectIsInherited,
                    onOpen: { reveal(project) },
                    onClear: clearProject
                )
            } else {
                ModalControlRow("Project") { projectMenu }
            }

            if item.liveTracks.isEmpty {
                ModalControlRow("Tracks") { trackMenu }
            } else {
                ForEach(Array(item.liveTracks.enumerated()), id: \.element.id) { index, thread in
                    AssociationOpenRow(
                        title: index == 0 ? "Tracks" : "",
                        name: threadTitle(thread),
                        symbol: thread.kind.symbol,
                        inherited: item.trackLinks.contains { $0.threadID == thread.id && $0.isInherited },
                        onOpen: { reveal(thread) },
                        onClear: { unlink(thread) }
                    )
                }
            }

            if item.liveNotes.isEmpty {
                ModalControlRow("Linked notes") { noteMenu }
            } else {
                ForEach(Array(item.liveNotes.enumerated()), id: \.element.id) { index, note in
                    AssociationOpenRow(
                        title: index == 0 ? "Linked notes" : "",
                        name: note.displayTitle,
                        symbol: "note.text",
                        onOpen: { reveal(note) },
                        onClear: { unlink(note) }
                    )
                }
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

    private var projectMenu: some View {
        Menu {
            ForEach(projects) { project in
                Button {
                    AssociationService.assignUserProject(project, on: item)
                    try? context.save()
                } label: {
                    Label(project.displayName, systemImage: projectIcon(project))
                }
            }
        } label: {
            Text("None")
                .foregroundStyle(.primary)
        }
        .fixedSize()
        .accessibilityLabel("Choose project")
    }

    private var trackMenu: some View {
        Menu {
            ForEach(tracksInScope) { thread in
                Button {
                    toggle(thread)
                } label: {
                    trackLabel(thread)
                }
            }
        } label: {
            Text("None")
                .foregroundStyle(.primary)
        }
        .fixedSize()
        .accessibilityLabel("Choose tracks")
    }

    private var noteMenu: some View {
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
            Text("None")
                .foregroundStyle(.primary)
        }
        .fixedSize()
        .accessibilityLabel("Choose notes")
    }

    private var tracksInScope: [ProjectThread] {
        var pool = item.project?.threads ?? projects.flatMap(\.threads)
        for thread in item.liveTracks where !pool.contains(where: { $0.id == thread.id }) {
            pool.append(thread)
        }
        return pool.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var notesInScope: [Note] {
        var pool = item.project?.notes ?? projects.flatMap(\.notes)
        for note in item.liveNotes where !pool.contains(where: { $0.id == note.id }) {
            pool.append(note)
        }
        return pool.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    private var linkedNoteIDs: Set<UUID> { Set(item.noteLinks.map(\.noteID)) }

    private func threadTitle(_ thread: ProjectThread) -> String {
        thread.title.isEmpty ? "Untitled" : thread.title
    }

    private func trackLabel(_ thread: ProjectThread) -> some View {
        let linked = item.trackLinks.contains { $0.threadID == thread.id }
        return Label(thread.title.isEmpty ? "Untitled" : thread.title, systemImage: linked ? "checkmark" : TrackStyle.symbol)
    }

    private func reveal(_ project: Project) {
        modalDismiss()
        app.open(project, tab: .overview)
    }

    private func reveal(_ thread: ProjectThread) {
        modalDismiss()
        app.open(thread)
    }

    private func reveal(_ note: Note) {
        modalDismiss()
        app.open(note)
    }

    private func projectIcon(_ project: Project) -> String {
        project.symbol.isEmpty ? "square.stack" : project.symbol
    }

    private func clearProject() {
        AssociationService.clearProject(from: item)
        try? context.save()
    }

    private func unlink(_ thread: ProjectThread) {
        AssociationService.unlink(threadID: thread.id, from: item, in: context)
        try? context.save()
    }

    private func unlink(_ note: Note) {
        AssociationService.unlink(noteID: note.id, from: item, in: context)
        try? context.save()
    }

    private func toggle(_ thread: ProjectThread) {
        if item.trackLinks.contains(where: { $0.threadID == thread.id }) {
            AssociationService.unlink(threadID: thread.id, from: item, in: context)
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
            AssociationService.unlink(noteID: note.id, from: item, in: context)
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

private struct AssociationOpenRow: View {
    var title: String
    var name: String
    var symbol: String?
    var inherited = false
    var onOpen: () -> Void
    var onClear: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack {
                    Text(title)
                        .font(CraftFont.body)
                    Spacer(minLength: 16)
                    if inherited { InheritMark() }
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text(name)
                        .font(CraftFont.body)
                        .underline()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(CraftFont.caption)
                        .foregroundStyle(hovering ? .secondary : .tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? CraftColor.hover : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(name)")
            .accessibilityLabel("Open \(name)")
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clear")
            .accessibilityLabel("Clear \(name)")
        }
    }
}
