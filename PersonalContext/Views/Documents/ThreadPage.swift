import SwiftData
import SwiftUI

struct ThreadPage: View {
    @Bindable var thread: ProjectThread
    var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        DeletionChrome(
            mark: DeletionMarks.existing(for: thread.id, in: project),
            deleteTitle: "Delete \(thread.title.isEmpty ? "this track" : thread.title)?",
            deleteMessage: "Child tracks are removed too. Notes and decisions stay in the project.",
            onKeep: keepMark,
            onConfirmDelete: deleteMarked
        ) {
        DocumentPage {
            if let parent = thread.parent {
                Button {
                    app.open(parent)
                } label: {
                    Label(parent.title.isEmpty ? "Untitled" : parent.title, systemImage: "arrow.turn.left.up")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }

            DocumentTitle(text: $thread.title)

            TextField("One-line summary", text: $thread.summary, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineLimit(1...4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: 6) {
                PropertyPill(title: thread.kind.label, systemImage: thread.kind.symbol) {
                    ForEach(ThreadKind.allCases) { kind in
                        Button(kind.label, systemImage: kind.symbol) { thread.kind = kind; touch() }
                    }
                }
                PropertyPill(title: thread.status.label, systemImage: thread.status.symbol) {
                    ForEach(ThreadStatus.allCases) { status in
                        Button(status.label, systemImage: status.symbol) { thread.status = status; touch() }
                    }
                }
                PropertyPill(title: thread.parent.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "No parent", systemImage: "arrow.turn.left.up") {
                    Button("No parent") { thread.parent = nil; touch() }
                    ForEach(parentCandidates) { candidate in
                        Button(candidate.title.isEmpty ? "Untitled" : candidate.title) { thread.parent = candidate; touch() }
                    }
                }
                TagField(tags: thread.tags) { thread.tags = $0; touch() }
                linked
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            MarkdownEditor(text: $thread.body, minHeight: 360)
                .padding(.top, 16)

            AgendaLinkedSection(items: AgendaStore.items(on: thread, includingChildren: true)) { item in
                item.liveTracks.first { $0.id != thread.id }?.title
            }

            if !thread.children.isEmpty {
                DocumentSection("Sub-tracks") {
                    ForEach(thread.orderedChildren) { child in
                        RecordRow(
                            systemImage: child.kind.symbol,
                            title: child.title.isEmpty ? "Untitled" : child.title,
                            subtitle: plainPreview(child.summary.isEmpty ? child.body : child.summary),
                            meta: "\(child.status.label) · \(child.updatedAt.relativeLabel)"
                        ) {
                            app.open(child)
                        }
                    }
                }
            }
        }
        }
        .onChange(of: thread.title) { _, _ in touch() }
        .onChange(of: thread.summary) { _, _ in touch() }
        .onChange(of: thread.body) { _, _ in touch() }
    }

    @ViewBuilder
    private var linked: some View {
        let count = thread.decisions.count + thread.notes.count + thread.conversations.count
        PropertyPill(title: count == 0 ? "Link" : "\(count) linked", systemImage: "link") {
            Button("New Sub-track", systemImage: "plus") { createChild() }
            if !thread.decisions.isEmpty {
                Section("Decisions") {
                    ForEach(thread.decisions) { decision in
                        Button(decision.title.isEmpty ? "Untitled" : decision.title) {
                            app.open(decision)
                        }
                    }
                }
            }
            if !thread.notes.isEmpty {
                Section("Notes") {
                    ForEach(thread.notes) { note in
                        Button(note.displayTitle) {
                            app.open(note)
                        }
                    }
                }
            }
            if !thread.conversations.isEmpty {
                Section("Chats") {
                    ForEach(thread.conversations) { conversation in
                        Button(conversation.title) { app.open(conversation) }
                    }
                }
            }
            let candidates = project.conversations.filter { $0.thread?.id != thread.id && !$0.isArchived }
            if !candidates.isEmpty {
                Menu("Link Chat") {
                    ForEach(candidates) { conversation in
                        Button(conversation.title) { conversation.thread = thread; touch() }
                    }
                }
            }
        }
    }

    private var parentCandidates: [ProjectThread] {
        project.threads
            .filter { $0.id != thread.id && !thread.contains($0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func touch() {
        thread.updatedAt = .now
        project.touch()
    }

    private func createChild() {
        let child = ProjectThread(title: "", kind: .feature, project: project, parent: thread)
        context.insert(child)
        touch()
        try? context.save()
        app.open(child)
    }

    private func keepMark() {
        guard let mark = DeletionMarks.existing(for: thread.id, in: project) else { return }
        DeletionMarks.keep(mark, in: context)
        project.touch()
        try? context.save()
    }

    private func deleteMarked() {
        if app.selectedThread == thread.id { app.selectedThread = thread.parent?.id }
        DeletionMarks.remove(targetingIDs: thread.deletionTargetIDs, in: context)
        context.delete(thread)
        project.touch()
        try? context.save()
    }
}
