import AppKit
import SwiftData
import SwiftUI

struct RunPage: View {
    @Bindable var run: AgentRun
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            DocumentPage {
                statusLine
                    .padding(.bottom, 8)
                    .findHighlight(.status)
                Text(originSentence)
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
                    .findHighlight(.source)
                Text(run.brief)
                    .font(CraftFont.body)
                    .textSelection(.enabled)
                    .padding(.top, 20)
                    .findHighlight(.body)
                    .findAnchor(.body)
                history
                    .padding(.top, 28)
                if run.status == .failed || run.status == .cancelled, !run.statusDetail.isEmpty {
                    Text(run.statusDetail)
                        .font(CraftFont.body)
                        .foregroundStyle(.red)
                        .padding(.top, 28)
                }
                if run.status == .succeeded || ((run.status == .failed || run.status == .cancelled) && !run.resultSummary.isEmpty) {
                    receipt
                        .padding(.top, 28)
                }
                actions
                    .padding(.top, 28)
            }
        }
        .objectFindable(id: run.id, fields: findFields)
        .confirmationDialog("Delete this run?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? RunStore.deleteTerminal(run, in: context)
            }
        } message: {
            Text("It’s removed from this Mac. Notes and tasks it created stay.")
        }
    }

    private var titleBar: some View {
        Text(run.displayTitle)
            .font(CraftFont.title)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .frame(height: 52)
            .background(CraftColor.canvas)
            .overlay(alignment: .bottom) { Hairline() }
            .accessibilityAddTraits(.isHeader)
            .findHighlight(.title)
    }

    private var statusLine: some View {
        Text(statusText)
            .font(CraftFont.section)
            .foregroundStyle(.secondary)
    }

    private var statusText: String {
        var parts = [run.status.label]
        if run.status.isActive, let label = app.runCoordinator.waitLabel(for: run.id) {
            parts.append(label)
        } else {
            parts.append(timeLabel)
        }
        parts.append(TalkProvider(rawValue: run.providerID)?.title ?? run.providerID)
        if !run.modelID.isEmpty {
            parts.append(app.modelName(for: run.modelID, providerID: run.providerID))
        }
        return parts.joined(separator: " · ")
    }

    private var timeLabel: String {
        if let finished = run.finishedAt {
            return finished.formatted(date: .abbreviated, time: .shortened)
        }
        if let started = run.startedAt {
            let seconds = Int(Date.now.timeIntervalSince(started))
            if seconds < 60 { return "\(seconds)s" }
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return run.createdAt.relativeLabel
    }

    private var originSentence: String {
        let date = run.createdAt.formatted(date: .abbreviated, time: .omitted)
        switch run.origin {
        case .workspace:
            return "Started from Runs, \(date)."
        case .project:
            let name = run.project?.displayName ?? "a deleted project"
            return "Started from \(name), \(date)."
        case .task:
            if let task = run.task {
                return "Started from \(task.displayTitle), \(date)."
            }
            let snapshot = run.titleSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
            return snapshot.isEmpty ? "Started from a deleted task, \(date)." : "Started from \(snapshot), \(date)."
        case .chat:
            if let chat = run.originChat {
                let title = chat.title.isEmpty ? "Chat" : chat.title
                return "Started from \(title), \(date)."
            }
            return "Started from a deleted chat, \(date)."
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(CraftFont.section)
            ForEach(run.history) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.at.formatted(date: .omitted, time: .shortened))
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .leading)
                    Text(event.kind.rawValue.capitalized)
                        .font(CraftFont.body)
                    if !event.detail.isEmpty {
                        Text(event.detail)
                            .font(CraftFont.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var receipt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Receipt")
                .font(CraftFont.section)
            Text(run.resultSummary.isEmpty ? "Finished with no summary." : run.resultSummary)
                .font(CraftFont.body)
                .textSelection(.enabled)
            ForEach(run.resultLinks) { link in
                Button {
                    open(link)
                } label: {
                    Label(link.label.isEmpty ? link.url : link.label, systemImage: symbol(for: link))
                        .font(CraftFont.body)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            if run.status.isActive {
                Button("Cancel") { app.cancelRun(run) }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
            } else {
                Button("Retry…") { app.retryRun(run) }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                Button("Delete", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .foregroundStyle(.red)
            }
            if let task = run.task {
                Button("Open Task") { app.selectTask(task.id) }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
            }
            if let chat = run.originChat {
                Button("Open Chat") { app.open(chat) }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
            }
            if run.purpose == .indexRepository, let attachmentID = run.indexedAttachmentID {
                Button("View Reference") { app.present(.inspectCodeReference(attachmentID)) }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
            }
            Spacer()
        }
    }

    private var findFields: [(ObjectFind.Field, String)] {
        [
            (.title, run.displayTitle),
            (.source, originSentence),
            (.body, run.brief),
            (.status, statusText),
            (.date, run.history.map { "\($0.kind.rawValue) \($0.detail)" }.joined(separator: " ")),
            (.linked, run.resultSummary + " " + run.resultLinks.map(\.url).joined(separator: " "))
        ]
    }

    private func symbol(for link: RunResultLink) -> String {
        switch link.kind {
        case .document: "doc"
        case .file: "doc.text"
        case .pullRequest: "arrow.triangle.pull"
        case .link: "link"
        }
    }

    private func open(_ link: RunResultLink) {
        guard let url = URL(string: link.url) else { return }
        if link.kind == .file {
            guard RunLinkSafety.fileAllowed(link.url, roots: ProjectCodeWorkspace.localRoots(for: run.project)) else { return }
        }
        if url.scheme?.lowercased() == "slate", url.host == "code-reference",
           let attachmentID = run.indexedAttachmentID {
            app.present(.inspectCodeReference(attachmentID))
            return
        }
        if url.scheme?.lowercased() == "slate", let source = ChatObjectLink.parse(url, title: link.label) {
            source.open(app: app, context: context)
            return
        }
        if url.scheme?.lowercased() == "https" {
            openURL(url)
        }
        if url.scheme?.lowercased() == "file" {
            NSWorkspace.shared.open(url)
        }
    }
}

struct RunHost: View {
    var id: UUID
    @Query private var runs: [AgentRun]

    var body: some View {
        if let run = runs.first(where: { $0.id == id }) {
            RunPage(run: run)
        } else {
            ScrollView {
                PageBody {
                    EmptyLine(text: "This run is no longer here.")
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

struct ProjectRunsEmpty: View {
    var project: Project
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No runs yet.")
                .font(CraftFont.title)
            Text("Start a run for this project from the toolbar.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(32)
    }
}
