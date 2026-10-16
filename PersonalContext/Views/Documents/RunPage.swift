import AppKit
import SwiftData
import SwiftUI

struct RunPage: View {
    @Bindable var run: AgentRun
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var confirmDelete = false
    /// The session's unsent message lives on the app, so leaving the tab keeps it.
    private var replyText: String {
        get { app.sessionDraftText[run.id] ?? "" }
        nonmutating set { app.sessionDraftText[run.id] = newValue.isEmpty ? nil : newValue }
    }
    private var attachments: [ComposerAttachment] {
        get { app.sessionDraftAttachments[run.id] ?? [] }
        nonmutating set { app.sessionDraftAttachments[run.id] = newValue.isEmpty ? nil : newValue }
    }
    private var replyTextBinding: Binding<String> {
        Binding(get: { replyText }, set: { replyText = $0 })
    }
    private var attachmentsBinding: Binding<[ComposerAttachment]> {
        Binding(get: { attachments }, set: { attachments = $0 })
    }

    var body: some View {
        if run.isSession {
            sessionBody
        } else {
            jobBody
        }
    }

    /// A session: the conversation down the middle, the user's turn at the bottom, the track's stops beside it.
    private var sessionBody: some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 10) {
                                    RunStatusBadge(status: run.status)
                                    Text(metaText)
                                        .font(CraftFont.body)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    if run.status.isActive {
                                        RunActionButton(title: "End Session", symbol: "stop.fill") { app.cancelRun(run) }
                                    } else {
                                        RunActionButton(title: "Start Again", symbol: "arrow.clockwise") { app.retryRun(run) }
                                        RunActionButton(title: "Delete", symbol: "trash", isDestructive: true) { confirmDelete = true }
                                    }
                                }
                                .findHighlight(.status)

                                if !run.statusDetail.isEmpty, run.status == .failed || run.status == .cancelled {
                                    reason
                                        .padding(.top, 16)
                                }

                                SessionTranscript(
                                    run: run,
                                    waitLabel: app.runCoordinator.waitLabel(for: run.id),
                                    draft: app.runCoordinator.drafts[run.id]
                                )
                                .padding(.top, 24)
                                Color.clear
                                    .frame(height: 1)
                                    .id("end")
                            }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 24)
                            .frame(maxWidth: DocumentMeasure.proseWidth, alignment: .leading)
                        }
                        .scrollContentBackground(.hidden)
                        .onChange(of: run.historyJSON) { _, _ in
                            withAnimation(Motion.quick) { proxy.scrollTo("end", anchor: .bottom) }
                        }
                        .onChange(of: app.runCoordinator.drafts[run.id]?.count ?? 0) { _, _ in
                            proxy.scrollTo("end", anchor: .bottom)
                        }
                        .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if run.status.isActive {
                                composer
                                    .padding(.horizontal, 32)
                                    .padding(.top, 12)
                                    .padding(.bottom, 24)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(CraftColor.hairline)
                    .frame(width: 1)
                SessionStops(run: run)
                    .frame(width: 280)
            }
        }
        .objectFindable(id: run.id, fields: findFields)
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? RunStore.deleteTerminal(run, in: context)
            }
        } message: {
            Text("The transcript is removed from this Mac. What it changed and filed stays.")
        }
    }

    /// The user's turn, in the chats' own composer. Sending on the worker's turn queues; Stop ends the turn.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if run.statusDetail == RunStore.quitMidTurnDetail {
                HStack(spacing: 10) {
                    Text("Membrae quit while the worker was mid-turn. What it had finished is kept; the rest was not done.")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Carry On") {
                        app.runCoordinator.reply(
                            "Membrae quit while you were mid-turn. First say in a few lines what you had finished and what was cut off, then carry on.",
                            to: run, in: context
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 4)
            }
            if let queued = app.runCoordinator.queued[run.id] {
                QueuedMessageBubble(
                    text: queued.text,
                    attachments: queued.attachments,
                    onSendNow: { app.runCoordinator.interrupt(run) },
                    onClear: { app.runCoordinator.clearQueued(for: run.id) }
                )
                .padding(.horizontal, 4)
            }
            ChatInput(
                text: replyTextBinding,
                modelID: .constant(""),
                providerID: .constant(run.providerID),
                allowsProviderChange: false,
                placeholder: run.status == .waiting ? "Your turn. Tell it what to do next." : "It goes when the turn ends, or stop the turn to send it now.",
                isGenerating: run.status == .running,
                onSend: send,
                composerOwnerID: run.id,
                attachments: attachmentsBinding,
                onStop: { app.runCoordinator.interrupt(run) },
                draftKind: "session",
                draftObjectID: run.id.uuidString,
                allowsSendWhileGenerating: true
            )
        }
    }

    /// The same submission every chat makes. The coordinator hands the worker each attached file by path.
    private func send(_ submission: ChatSubmission) -> Bool {
        let text = submission.trimmedText
        guard !text.isEmpty || !submission.attachments.isEmpty else { return false }
        if run.status == .waiting {
            app.runCoordinator.reply(text, attachments: submission.attachments, to: run, in: context)
        } else {
            app.runCoordinator.queue(text, attachments: submission.attachments, for: run)
        }
        attachments = []
        return true
    }

    private var jobBody: some View {
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

                    if run.status == .waiting, !run.externalID.isEmpty {
                        replyBox
                            .padding(.top, 20)
                    }

                    if showsResult {
                        section("Result") { result }
                    }

                    if run.history.contains(where: \.kind.isTranscript) {
                        section(run.status.isActive ? "Working" : "What it did") { transcript }
                    }

                    if !run.steps.isEmpty {
                        section("Steps") { steps }
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
            let name = run.project?.displayName ?? "a deleted Space"
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
            ForEach(run.history.filter { !$0.kind.isTranscript }) { event in
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

    /// What the worker said and did, in order, with the user's replies between.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(run.history.filter(\.kind.isTranscript)) { event in
                switch event.kind {
                case .said:
                    AssistantMarkdown(text: event.detail)
                        .textSelection(.enabled)
                case .reply:
                    Text(event.detail)
                        .font(CraftFont.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(CraftColor.selection, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                default:
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10))
                        Text(event.detail)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            if run.status == .running, let label = app.runCoordinator.waitLabel(for: run.id) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The worker stopped to ask something. The reply carries on the same session.
    private var replyBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(workerName) is waiting for your answer")
                .font(.system(size: 13, weight: .semibold))
            if !run.resultSummary.isEmpty {
                AssistantMarkdown(text: run.resultSummary)
                    .textSelection(.enabled)
            }
            TextField("Your answer", text: replyTextBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CraftFont.body)
                .lineLimit(2...8)
                .padding(10)
                .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(CraftColor.hairline))
            HStack(spacing: 8) {
                Button("Send Answer") {
                    app.runCoordinator.reply(replyText, to: run, in: context)
                    replyText = ""
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("⌘↩")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CraftColor.hairline))
    }

    /// The worker's own plan, ticked off as it goes.
    private var steps: some View {
        let all = run.steps
        // While it works, the first step not yet done is the one in hand.
        let current = run.status.isTerminal ? nil : all.firstIndex { !$0.done }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(all.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: step.done ? "checkmark.circle.fill" : index == current ? "circle.dotted" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(step.done ? Color.green : index == current ? Color.primary : Color.secondary.opacity(0.5))
                        .frame(width: 16)
                    Text(step.title)
                        .font(CraftFont.body)
                        .foregroundStyle(step.done ? .secondary : .primary)
                        .fontWeight(index == current ? .medium : .regular)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.title), \(step.done ? "done" : index == current ? "in progress" : "not started")")
            }
            Text("\(all.filter(\.done).count) of \(all.count) done")
                .font(CraftFont.caption)
                .foregroundStyle(.tertiary)
        }
        .animation(.snappy(duration: 0.25), value: all)
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
            Text("Start a run for this Space from the toolbar.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(32)
    }
}


/// The track's stops beside a session: where it stands, and a click to send the worker there.
private struct SessionStops: View {
    var run: AgentRun

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    private var track: ProjectThread? {
        run.trackID.flatMap { TitleIndexStore.thread($0, in: context) }
    }

    var body: some View {
        if let track {
            let stops = track.orderedStops
            let current = TaskStore.currentStop(on: track)
            let done = stops.filter(\.isDone).count
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        app.open(track, newTab: false)
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(track.color.tint).frame(width: 8, height: 8)
                            Text(LaneModel.title(track))
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open the track")
                    Text(stops.isEmpty ? "No stops yet" : "\(done) of \(stops.count) done")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(stops) { stop in
                            row(stop, isCurrent: current?.id == stop.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .scrollContentBackground(.hidden)
                if track.hasBranch {
                    Hairline()
                    MergeButton(track: track, disabled: run.status == .running)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            Text("The track is gone.")
                .font(CraftFont.body)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ stop: TrackStop, isCurrent: Bool) -> some View {
        Button {
            steer(to: stop)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                TaskGlyph(state: stop.isDone ? .done : isCurrent ? .inProgress : .open)
                    .padding(.top, 2)
                Text(stop.displayTitle)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(stop.isDone ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(run.status == .waiting ? "Send the worker to this stop" : "Wait for your turn to send the worker here")
        .contextMenu {
            Button(stop.isDone ? "Mark Not Done" : "Mark Done") {
                StopStore.setDone(!stop.isDone, on: stop, in: context)
            }
            Button("Open in Tracks") { app.open(stop, newTab: false) }
        }
    }

    private func steer(to stop: TrackStop) {
        guard run.status == .waiting else {
            app.flash("The worker is still on its turn. Click the stop when it is yours.")
            return
        }
        app.runCoordinator.reply("Work on the stop \"\(stop.displayTitle)\" now (id \(stop.id.uuidString)).", to: run, in: context)
    }
}


/// A session's conversation: what the worker said, its steps folded into one line per stretch of work, the user's
/// turns, the commits each turn made, and what each turn cost.
private struct SessionTranscript: View {
    var run: AgentRun
    var waitLabel: String?
    /// What the worker is writing right now.
    var draft: String?

    @Environment(AppModel.self) private var app

    private enum Item: Identifiable {
        case said(RunEvent)
        case reply(RunEvent)
        case commits(RunEvent)
        case turn(RunEvent)
        case work([RunEvent])

        var id: UUID {
            switch self {
            case .said(let event), .reply(let event), .commits(let event), .turn(let event): event.id
            case .work(let events): events.first?.id ?? UUID()
            }
        }
    }

    private var items: [Item] {
        var items: [Item] = []
        var steps: [RunEvent] = []
        func flush() {
            if !steps.isEmpty { items.append(.work(steps)); steps = [] }
        }
        for event in run.history where event.kind.isTranscript {
            switch event.kind {
            case .step: steps.append(event)
            case .said: flush(); items.append(.said(event))
            case .reply: flush(); items.append(.reply(event))
            case .commits: flush(); items.append(.commits(event))
            case .turn: flush(); items.append(.turn(event))
            default: break
            }
        }
        flush()
        return items
    }

    var body: some View {
        let items = items
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                switch item {
                case .said(let event):
                    AssistantMarkdown(text: event.detail)
                        .textSelection(.enabled)
                case .reply(let event):
                    UserMessageBubble(message: ChatEntry.User(id: event.id, text: event.detail, attachments: event.attachments))
                        .padding(.top, 10)
                case .commits(let event):
                    commits(event.detail)
                case .turn(let event):
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Turn · \(event.detail)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Hairline()
                    }
                case .work(let events):
                    let live = run.status == .running && index == items.count - 1
                    WorkFold(steps: events, live: live, label: live ? waitLabel : nil, since: live ? events.last?.at : nil)
                }
            }
            if let draft, !draft.isEmpty {
                AssistantMarkdown(text: draft, streaming: true)
                    .textSelection(.enabled)
            }
            if run.status == .running, let waitLabel, (draft ?? "").isEmpty, !(items.last.map { if case .work = $0 { return true } else { return false } } ?? false) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(waitLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func commits(_ text: String) -> some View {
        let lines = text.split(separator: "\n").map(String.init)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                Text(lines.count == 1 ? "Committed" : "Committed \(lines.count) times")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CraftColor.hairline))
    }
}

/// A stretch of the worker's steps as one line, opened on click.
private struct WorkFold: View {
    var steps: [RunEvent]
    var live: Bool
    var label: String?
    /// When the live step began, so the row shows how long it has been going.
    var since: Date?

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Motion.quick) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if live {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    if live {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            let seconds = since.map { Int(timeline.date.timeIntervalSince($0)) } ?? 0
                            Text((label ?? steps.last?.detail ?? "Working") + (seconds >= 5 ? " · \(seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s")" : ""))
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        Text("Worked · \(steps.count) step\(steps.count == 1 ? "" : "s")")
                            .font(.system(size: 12))
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(steps) { step in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10))
                        Text(step.detail)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 14)
                }
            }
        }
    }
}
