import SwiftData
import SwiftUI

struct NotePage: View {
    @Bindable var note: Note
    var project: Project

    var body: some View {
        DocumentPage {
            DocumentTitle(text: $note.title)
            HStack(spacing: 6) {
                PropertyPill(title: note.thread.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "No track", systemImage: TrackStyle.symbol) {
                    Button("No track") { note.thread = nil; touch() }
                    ForEach(project.threads.sorted { $0.title < $1.title }) { thread in
                        Button(thread.title.isEmpty ? "Untitled" : thread.title) { note.thread = thread; touch() }
                    }
                }
                TagField(tags: note.tags) { note.tags = $0; touch() }
                if !note.source.isEmpty {
                    Text(note.source)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 4)
                }
                Spacer()
                Text(note.updatedAt.relativeLabel)
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
            MarkdownEditor(text: $note.content)
                .padding(.top, 16)

            AgendaLinkedSection(items: note.agendaNoteLinks.compactMap(\.item))
        }
        .onChange(of: note.title) { _, _ in touch() }
        .onChange(of: note.content) { _, _ in touch() }
    }

    private func touch() {
        note.updatedAt = .now
        project.touch()
    }
}
