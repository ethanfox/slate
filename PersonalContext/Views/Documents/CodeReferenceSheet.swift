import SwiftData
import SwiftUI

struct CodeReferenceSheet: View {
    var attachmentID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @Query private var attachments: [CodeAttachment]
    @Query private var runs: [AgentRun]

    private var attachment: CodeAttachment? {
        attachments.first { $0.id == attachmentID }
    }

    private var reference: CodeReference? {
        attachment.flatMap { CodeReferenceStore.published(on: $0, in: context) }
    }

    private var originatingRun: AgentRun? {
        guard let id = reference?.originatingRunID else { return nil }
        return runs.first { $0.id == id } ?? RunStore.run(id, in: context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(CraftFont.title)
            if let reference {
                Text(statusLine(reference))
                    .font(CraftFont.section)
                    .foregroundStyle(.secondary)
                if !reference.coverageNotes.isEmpty {
                    Text(reference.coverageNotes)
                        .font(CraftFont.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(CodeReferenceStore.sortedEntries(on: reference, in: context), id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.title)
                            .font(CraftFont.section)
                        Text(renderedMarkdown(entry.body))
                            .font(CraftFont.body)
                            .textSelection(.enabled)
                        if !entry.sourceLocations.isEmpty {
                            Text(entry.sourceLocations.map(locationLine).joined(separator: "\n"))
                                .font(CraftFont.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 8)
                }
            } else {
                Text("No published architecture reference yet.")
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if let originatingRun {
                    Button("Open Run") {
                        modalDismiss()
                        app.open(originatingRun)
                    }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                }
                Spacer()
                Button("Done") { modalDismiss() }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
            }
        }
    }

    private var title: String {
        let name = attachment.map { $0.title.isEmpty ? $0.locator : $0.title } ?? "Repository"
        return "\(name) reference"
    }

    private func statusLine(_ reference: CodeReference) -> String {
        var parts = [
            CodeReferenceStore.coverageLabel(reference),
            "rev \(reference.revision)"
        ]
        if !reference.sourceRevision.isEmpty {
            parts.append(String(reference.sourceRevision.prefix(12)))
        }
        if reference.sourceFreshness != .unknown {
            parts.append(reference.sourceFreshness.label)
        }
        parts.append(reference.lastUpdatedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    private func locationLine(_ location: CodeSourceLocation) -> String {
        var parts = [location.path]
        if let declaration = location.declaration, !declaration.isEmpty {
            parts.append(declaration)
        }
        if let hash = location.contentHash, !hash.isEmpty {
            parts.append(String(hash.suffix(8)))
        }
        return parts.joined(separator: " · ")
    }
}
