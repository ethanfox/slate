import SwiftData
import SwiftUI

struct ThreadPage: View {
    @Bindable var thread: ProjectThread
    var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        DocumentPage {
            if let parent = thread.parent {
                Button {
                    app.selectedThread = parent.id
                } label: {
                    Label(parent.title.isEmpty ? "Untitled" : parent.title, systemImage: "arrow.turn.left.up")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }

            DocumentTitle(text: $thread.title)

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
                linked
            }
            .padding(.top, 8)

            TextField("One-line summary", text: $thread.summary, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            MarkdownEditor(text: $thread.body)
                .padding(.top, 16)

            if !thread.children.isEmpty {
                DocumentSection("Sub-tracks") {
                    ForEach(thread.orderedChildren) { child in
                        RecordRow(
                            systemImage: child.kind.symbol,
                            title: child.title.isEmpty ? "Untitled" : child.title,
                            subtitle: plainPreview(child.summary.isEmpty ? child.body : child.summary),
                            meta: "\(child.status.label) · \(child.updatedAt.relativeLabel)"
                        ) {
                            app.selectedThread = child.id
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
                            app.selectedDecision = decision.id
                            app.tabs[project.id] = .decisions
                        }
                    }
                }
            }
            if !thread.notes.isEmpty {
                Section("Notes") {
                    ForEach(thread.notes) { note in
                        Button(note.displayTitle) {
                            app.selectedNote = note.id
                            app.tabs[project.id] = .notes
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
        app.selectedThread = child.id
    }
}
