import SwiftData
import SwiftUI

struct DecisionPage: View {
    @Bindable var decision: Decision
    var project: Project

    var body: some View {
        DocumentPage {
            DocumentTitle(text: $decision.title)
            HStack(spacing: 6) {
                PropertyPill(title: decision.status.label, systemImage: decision.status == .active ? "checkmark.seal" : "xmark.seal") {
                    ForEach(DecisionStatus.allCases) { status in
                        Button(status.label) {
                            decision.status = status
                            if status == .active { decision.supersededByID = nil }
                            project.touch()
                        }
                    }
                }
                if decision.status == .superseded {
                    PropertyPill(title: supersededTitle, systemImage: "arrow.right") {
                        Button("None") { decision.supersededByID = nil }
                        ForEach(project.decisions.filter { $0.id != decision.id }) { other in
                            Button(other.title.isEmpty ? "Untitled" : other.title) { decision.supersededByID = other.id }
                        }
                    }
                }
                PropertyPill(title: decision.thread.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "No track", systemImage: TrackStyle.symbol) {
                    Button("No track") { decision.thread = nil; project.touch() }
                    ForEach(project.threads.sorted { $0.title < $1.title }) { thread in
                        Button(thread.title.isEmpty ? "Untitled" : thread.title) { decision.thread = thread; project.touch() }
                    }
                }
                TagField(tags: decision.tags) { decision.tags = $0; project.touch() }
                Spacer()
                Text(decision.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
            MarkdownEditor(text: $decision.decision, placeholder: "What was decided")
                .padding(.top, 16)
            DocumentSection("Why") {
                MarkdownEditor(text: $decision.rationale, placeholder: "The reasoning behind it")
            }
        }
        .onChange(of: decision.title) { _, _ in project.touch() }
        .onChange(of: decision.decision) { _, _ in project.touch() }
        .onChange(of: decision.rationale) { _, _ in project.touch() }
    }

    private var supersededTitle: String {
        guard let id = decision.supersededByID, let other = project.decisions.first(where: { $0.id == id }) else {
            return "Replaced by…"
        }
        return other.title.isEmpty ? "Untitled" : other.title
    }
}
