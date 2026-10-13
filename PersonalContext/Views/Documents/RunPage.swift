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
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        RunStatusBadge(status: run.status)
                        Text(metaText)
                            .font(CraftFont.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .findHighlight(.status)

                    actions
                        .padding(.top, 16)

                    if !run.statusDetail.isEmpty,
                       run.status == .failed || run.status == .cancelled || run.status == .couldNot {
                        reason
                            .padding(.top, 20)
                    }

                    if showsResult {
                        section("Result") { result }
                    }

                    section("Prompt") {
                        Text(run.brief)
                            .font(CraftFont.body)
                            .textSelection(.enabled)
                            .findHighlight(.body)
                            .findAnchor(.body)
                        Text(originSentence)
                            .font(CraftFont.caption)
                            .foregroundStyle(.tertiary)
                            .findHighlight(.source)
                    }

                    section("History") { history }
                }
                .frame(maxWidth: DocumentMeasure.proseWidth, alignment: .leading)
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

    private var showsResult: Bool {
        run.status == .succeeded || (run.status.isTerminal && !run.resultSummary.isEmpty)
    }

    private var workerName: String {
        TalkProvider(rawValue: run.providerID)?.title ?? LocalAgent(rawValue: run.providerID)?.title ?? run.providerID
    }

    /// What sits beside the status: what it is doing or when it ended, then who did it.
    private var metaText: String {
        var parts: [String] = []
        if run.status.isActive, let label = app.runCoordinator.waitLabel(for: run.id) {
            parts.append(label)
        } else if run.status.isActive, let headline = app.browser.headline(for: run.id) {
            parts.append(headline)
        } else {
            parts.append(timeLabel)
        }
        parts.append(workerName)
        if !run.modelID.isEmpty {
            parts.append(app.modelName(for: run.modelID, providerID: run.providerID))
        }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        "\(run.status.label) · \(metaText)"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.top, 28)
    }

    /// Why it did not finish, set apart so it is read before anything else.
    private var reason: some View {
        let tint: Color = run.status == .failed ? .red : run.status == .couldNot ? .orange : .secondary
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: run.status == .cancelled ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(run.statusDetail)
                .font(CraftFont.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tint.opacity(0.3)))
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
        VStack(alignment: .leading, spacing: 5) {
            ForEach(run.history) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.at.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .frame(width: 60, alignment: .leading)
                    Text(event.kind == .browser ? (event.detail.isEmpty ? "Browser" : event.detail) : event.kind.label)
                        .foregroundStyle(.secondary)
                    if event.kind != .browser, !event.detail.isEmpty {
                        Text(event.detail)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 12) {
            if run.resultSummary.isEmpty {
                Text("Finished with no summary.")
                    .font(CraftFont.chatBody)
                    .foregroundStyle(.secondary)
            } else {
                AssistantMarkdown(text: run.resultSummary)
                    .textSelection(.enabled)
            }
            if !run.resultLinks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(run.resultLinks) { link in
                        RunActionButton(
                            title: link.label.isEmpty ? link.url : link.label,
                            symbol: symbol(for: link)
                        ) { open(link) }
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if run.status.isActive {
                RunActionButton(title: "Cancel", symbol: "stop.fill") { app.cancelRun(run) }
            } else {
                RunActionButton(title: "Retry…", symbol: "arrow.clockwise") { app.retryRun(run) }
            }
            if let task = run.task {
                RunActionButton(title: "Open Task", symbol: "checklist") { app.selectTask(task.id) }
            }
            if let chat = run.originChat {
                RunActionButton(title: "Open Chat", symbol: "bubble.left") { app.open(chat) }
            }
            if !run.status.isActive {
                RunActionButton(title: "Delete", symbol: "trash", isDestructive: true) { confirmDelete = true }
            }
            Spacer(minLength: 0)
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
        if ChatObjectLink.isAppScheme(url.scheme), let source = ChatObjectLink.parse(url, title: link.label) {
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

/// The Run's result at a glance: a tinted capsule with an icon and the word.
struct RunStatusBadge: View {
    var status: RunStatus

    private var symbol: String {
        switch status {
        case .queued: "clock"
        case .running, .waiting: "circle.dotted"
        case .succeeded: "checkmark"
        case .couldNot: "questionmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        }
    }

    private var tint: Color {
        switch status {
        case .succeeded: .green
        case .couldNot: .orange
        case .failed: .red
        case .running, .waiting: .blue
        case .queued, .cancelled: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text(status.label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A button on the Run page that looks like one.
private struct RunActionButton: View {
    var title: String
    var symbol: String
    var isDestructive = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(hovering ? CraftColor.selection : CraftColor.elevated, in: Capsule())
            .overlay(Capsule().stroke(CraftColor.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
