import SwiftData
import SwiftUI

struct DecisionPage: View {
    @Bindable var decision: Decision
    var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        DeletionChrome(
            mark: DeletionMarks.existing(for: decision.id, in: project),
            deleteTitle: "Delete this decision?",
            onKeep: keepMark,
            onConfirmDelete: deleteMarked
        ) {
        DocumentPage {
            DocumentTitle(text: $decision.title)
            TagBar(tags: decision.tags) { decision.tags = $0; project.touch() }
                .padding(.top, 8)
            HStack(spacing: 6) {
                PropertyPill(title: decision.status.label, systemImage: decision.status == .active ? "checkmark.seal" : "xmark.seal", field: .status) {
                    ForEach(DecisionStatus.allCases) { status in
                        Button(status.label) {
                            decision.status = status
                            if status == .active { decision.supersededByID = nil }
                            project.touch()
                        }
                    }
                }
                if decision.status == .superseded {
                    PropertyPill(
                        title: supersededTitle,
                        systemImage: "arrow.right",
                        field: .superseded,
                        onOpen: supersededDecision.map { other in { app.open(other) } }
                    ) {
                        Button("None") { decision.supersededByID = nil }
                        ForEach(project.decisions.filter { $0.id != decision.id }) { other in
                            Button(other.title.isEmpty ? "Untitled" : other.title) { decision.supersededByID = other.id }
                        }
                    }
                }
                PropertyPill(
                    title: decision.thread.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "No track",
                    systemImage: TrackStyle.symbol,
                    field: .track,
                    onOpen: decision.thread.map { thread in { app.open(thread) } }
                ) {
                    Button("No track") { decision.thread = nil; project.touch() }
                    ForEach(project.threads.sorted { $0.title < $1.title }) { thread in
                        Button(thread.title.isEmpty ? "Untitled" : thread.title) { decision.thread = thread; project.touch() }
                    }
                }
                Spacer()
                Text(decision.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                    .findHighlight(.date)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            MarkdownEditor(text: $decision.decision, placeholder: "What was decided", findField: .body, traceKind: "decision", traceObjectID: decision.id.uuidString)
                .padding(.top, 16)
                .findAnchor(.body)
            DocumentSection("Why") {
                MarkdownEditor(text: $decision.rationale, placeholder: "The reasoning behind it", findField: .rationale, traceKind: "decision-rationale", traceObjectID: decision.id.uuidString)
                    .findAnchor(.rationale)
            }
        }
        }
        .objectFindable(id: decision.id, fields: findFields)
        .onChange(of: decision.title) { _, _ in project.touch() }
        .onChange(of: decision.decision) { _, _ in project.touch() }
        .onChange(of: decision.rationale) { _, _ in project.touch() }
    }

    private var findFields: [(ObjectFind.Field, String)] {
        [
            (.title, decision.title),
            (.status, decision.status.label),
            (.superseded, decision.status == .superseded ? supersededTitle : ""),
            (.track, decision.thread.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "No track"),
            (.tags, decision.tags.map(\.displayName).joined(separator: ", ")),
            (.date, decision.createdAt.formatted(date: .abbreviated, time: .omitted)),
            (.body, decision.decision),
            (.rationale, decision.rationale),
        ]
    }

    private func keepMark() {
        guard let mark = DeletionMarks.existing(for: decision.id, in: project) else { return }
        DeletionMarks.keep(mark, in: context)
        project.touch()
        try? context.save()
    }

    private func deleteMarked() {
        if app.selectedDecision == decision.id { app.selectedDecision = nil }
        DeletionMarks.remove(targetingIDs: [decision.id], in: context)
        context.delete(decision)
        project.touch()
        try? context.save()
    }

    private var supersededDecision: Decision? {
        guard let id = decision.supersededByID else { return nil }
        return project.decisions.first { $0.id == id }
    }

    private var supersededTitle: String {
        guard let other = supersededDecision else { return "Replaced by…" }
        return other.title.isEmpty ? "Untitled" : other.title
    }
}
