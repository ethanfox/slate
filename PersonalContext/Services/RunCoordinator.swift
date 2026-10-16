import Foundation
import SwiftData

struct RunningRun: Equatable, Identifiable {
    var id: UUID
    var label: String
}

@MainActor
@Observable
final class RunCoordinator {
    private(set) var running: [RunningRun] = []
    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    @ObservationIgnored private weak var app: AppModel?

    private struct Job {
        var task: Task<Void, Never>
        var process: RunCursorProcess?
        var local: LocalAgentProcess?
    }

    func attach(_ app: AppModel) {
        self.app = app
    }

    /// A message the user sent while the worker was on its turn. It goes the moment the turn ends.
    private(set) var queued: [UUID: String] = [:]
    /// The message a worker is writing right now, as far as it has got.
    private(set) var drafts: [UUID: String] = [:]
    @ObservationIgnored private var interrupting: Set<UUID> = []

    func recover(in context: ModelContext) {
        running = []
        jobs = [:]
        // A session whose worker is still running outside the app, because the app restarted under it,
        // is picked back up rather than written off.
        var reattached: Set<UUID> = []
        for run in RunStore.activeRuns(in: context) where run.status == .running && run.isSession && WorkerRelay.isAlive(run.workerID) {
            guard let agent = LocalAgent(rawValue: run.providerID) else { continue }
            let id = run.id
            reattached.insert(id)
            setWait(id, "Picking the turn back up")
            let task = Task { [weak self] in
                guard let self else { return }
                await self.reattachSession(id, agent: agent, workerID: run.workerID)
            }
            jobs[id] = Job(task: task, process: nil)
        }
        RunStore.recoverAbandoned(in: context, except: reattached)
    }

    /// Queues a message for a session whose worker is mid-turn; it is sent as the next turn when this one ends.
    func queue(_ text: String, for run: AgentRun) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        if run.status == .waiting, let context = liveContext() {
            reply(message, to: run, in: context)
            return
        }
        queued[run.id] = message
    }

    func clearQueued(for id: UUID) {
        queued[id] = nil
    }

    /// Ends the worker's turn now. The session stays; whatever is queued goes next.
    func interrupt(_ run: AgentRun) {
        guard run.isSession, run.status == .running else { return }
        interrupting.insert(run.id)
        jobs[run.id]?.local?.stop()
        jobs[run.id]?.process?.stop()
    }

    /// After a session turn ends: whatever the user queued goes as the next turn.
    private func sendQueued(_ id: UUID) {
        guard let message = queued[id], let context = liveContext(), let run = resolvedRun(id), run.status == .waiting else { return }
        queued[id] = nil
        reply(message, to: run, in: context)
    }

    /// Carries on recording a session turn whose worker outlived a relaunch of the app.
    private func reattachSession(_ id: UUID, agent: LocalAgent, workerID: String) async {
        let process = LocalAgentProcess()
        if var job = jobs[id] {
            job.local = process
            jobs[id] = job
        }
        var lastText = ""
        var lastStep = ""
        var usageLine = ""
        do {
            for try await event in process.reattach(agent, workerID: workerID) {
                try Task.checkCancellation()
                switch event {
                case .activity(let label):
                    setWait(id, label)
                    if label != lastStep {
                        lastStep = label
                        record(id, .step, label)
                    }
                case .textDelta(let piece):
                    drafts[id, default: ""] += piece
                    setWait(id, ChatWaitState.writing.label)
                case .text(let text):
                    lastText = text
                    lastStep = ""
                    drafts[id] = nil
                    setWait(id, ChatWaitState.writing.label)
                    record(id, .said, text)
                case .session(let session):
                    if let context = liveContext(), let live = resolvedRun(id) {
                        live.externalID = session
                        try? context.save()
                    }
                case .finished(let text, _):
                    if !text.isEmpty { lastText = text }
                case .usage(let cost, let input, let output, let duration):
                    usageLine = LocalAgentEvent.usageLine(cost: cost, inputTokens: input, outputTokens: output, durationMs: duration)
                case .failed(let message):
                    throw LocalAgentError(message)
                }
            }
            process.stop()
            guard let context = liveContext(), let live = resolvedRun(id), live.status == .running else { return }
            if !usageLine.isEmpty { live.append(.turn, detail: usageLine) }
            live.resultSummary = lastText
            try RunStore.transition(live, to: .waiting, detail: "Your turn", in: context)
            clear(id)
            sendQueued(id)
        } catch is CancellationError {
            clear(id)
        } catch {
            if let context = liveContext(), let run = resolvedRun(id), run.status.isActive {
                try? RunStore.fail(run, detail: error.localizedDescription, in: context)
            }
            clear(id)
        }
    }

    func start(_ run: AgentRun, in context: ModelContext) {
        guard jobs[run.id] == nil else { return }
        let id = run.id
        setWait(id, ChatWaitState.starting.label)
        do {
            try RunStore.transition(run, to: .running, in: context)
        } catch {
            try? RunStore.fail(run, detail: error.localizedDescription, in: context)
            clear(id)
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(id)
        }
        jobs[id] = Job(task: task, process: nil)
    }

    /// Answers a Run that stopped to ask the user something. The same worker session carries on with the reply.
    func reply(_ text: String, to run: AgentRun, in context: ModelContext) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, run.status == .waiting, jobs[run.id] == nil, !run.externalID.isEmpty else { return }
        let id = run.id
        let session = run.externalID
        setWait(id, ChatWaitState.starting.label)
        run.append(.reply, detail: message)
        do {
            try RunStore.transition(run, to: .running, in: context)
        } catch {
            clear(id)
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(id, resume: (session, message))
        }
        jobs[id] = Job(task: task, process: nil)
    }

    func cancel(_ run: AgentRun, in context: ModelContext) {
        let id = run.id
        jobs[id]?.task.cancel()
        jobs[id]?.process?.stop()
        jobs[id]?.local?.stop()
        try? RunStore.cancel(run, in: context)
        BrowserRuntime.shared.cancel(runID: id)
        clear(id)
    }

    func waitLabel(for id: UUID) -> String? {
        running.first { $0.id == id }?.label
    }

    /// A session's worker is mid-turn. Quitting now would cut it off.
    var hasRunningSessionTurn: Bool {
        jobs.keys.compactMap(resolvedRun).contains { $0.isSession && $0.status == .running }
    }

    /// MCP writes reopen `AppModel.container`. A held `AgentRun` or `ModelContext`
    /// then traps in SwiftData getters (EXC_BREAKPOINT on `id`). Always resolve
    /// from the live container after an await.
    private func liveContext() -> ModelContext? {
        app?.container.mainContext
    }

    private func resolvedRun(_ id: UUID) -> AgentRun? {
        guard let context = liveContext() else { return nil }
        return RunStore.run(id, in: context)
    }

    private func perform(_ id: UUID, resume: (session: String, message: String)? = nil) async {
        guard let run = resolvedRun(id), let app else { return }
        do {
            try Task.checkCancellation()
            try validateProvider(run, app: app)
            if let agent = LocalAgent(rawValue: run.providerID) {
                try await runLocalAgent(id, agent: agent, resume: resume)
            } else if run.providerID == TalkProvider.chatgpt.rawValue {
                try await runChatGPT(id, app: app)
            } else {
                try await runCursor(id, app: app)
            }
        } catch is CancellationError {
            if let context = liveContext(), let run = resolvedRun(id), run.status.isActive {
                try? RunStore.cancel(run, in: context)
            }
            clear(id)
        } catch {
            if let context = liveContext(), let run = resolvedRun(id), run.status.isActive {
                try? RunStore.fail(run, detail: error.localizedDescription, in: context)
            }
            clear(id)
            announce(id)
        }
    }

    private func runChatGPT(_ id: UUID, app _: AppModel) async throws {
        guard let run = resolvedRun(id) else { return }
        let policy = policy(for: run)
        let roots = try await selectedRoots(for: run)
        guard let run = resolvedRun(id), let context = liveContext() else { return }
        let includeMembrae = policy.allowsMembraeWrites
        let gateway = RunGateway(
            policy: policy,
            inner: MembraeToolGateway(
                roots: roots,
                includeMembraeTools: includeMembrae,
                includeProjectTools: policy.allowCode,
                mcp: includeMembrae ? .shared : nil,
                storeURL: context.container.configurations.first?.url,
                store: context.container,
                includeBrowser: policy.allowBrowser,
                runID: run.id
            )
        )
        let prompt = RunPrompt.body(brief: run.brief, project: run.project, run: run)
        let stream = RunChatGPT.stream(
            instructions: prompt,
            userText: run.brief,
            model: run.modelID,
            gateway: gateway
        )
        var lastText = ""
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .wait(let label):
                setWait(id, label)
            case .text(let text):
                lastText += text
                setWait(id, ChatWaitState.writing.label)
            case .citation:
                break
            }
        }
        try await finish(id, gateway: gateway, lastText: lastText, extra: [], roots: roots)
    }

    private func runCursor(_ id: UUID, app: AppModel) async throws {
        guard let apiKey = app.apiKey, !apiKey.isEmpty else {
            throw CursorAPIError(status: 0, message: "Add a Cursor API key in Settings.")
        }
        guard let mcp = Bundle.main.url(forAuxiliaryExecutable: "membrae-mcp") else {
            throw CursorAPIError(status: 0, message: "The Membrae MCP is missing from the app.")
        }
        guard let run = resolvedRun(id) else { return }
        let policy = policy(for: run)
        let roots = try await selectedRoots(for: run)
        guard let run = resolvedRun(id), let context = liveContext() else { return }
        let store = context.container.configurations.first?.url
        let folder = store?.deletingLastPathComponent().appendingPathComponent("Agent", isDirectory: true)
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let workspace: String
        if roots.count == 1 {
            workspace = roots[0].path
        } else {
            workspace = roots.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path } ?? folder?.path ?? NSTemporaryDirectory()
        }
        let includeMembrae = policy.allowsMembraeWrites
        let listed = includeMembrae ? policy.allowedNames(from: RunToolPolicy.generalCatalog(for: run)) : []
        let request = RunnerRequest(
            apiKey: apiKey,
            env: ProcessInfo.processInfo.environment.merging([LocalAgent.runIDVariable: id.uuidString]) { _, new in new },
            agentId: nil,
            name: run.displayTitle,
            text: RunPrompt.body(brief: run.brief, project: run.project, run: run),
            model: run.modelID,
            cwd: workspace,
            mcpCommand: mcp.path,
            codeRoots: roots,
            includeMembraeTools: includeMembrae,
            includeProjectTools: policy.allowCode,
            includeWorkerTool: false,
            includeFinishRun: true,
            allowedTools: listed,
            runtime: run.pathRaw,
            cloudRepos: cloudRepos(for: run.project),
            codeSnapshots: policy.allowCode && run.pathRaw == WorkerPath.local.rawValue
                ? ProjectCodeWorkspace.remoteSnapshots(for: run.project, storeURL: store)
                : [],
            externalTools: policy.allowBrowser ? BrowserTools.providerTools() : []
        )
        let process = RunCursorProcess()
        if var job = jobs[id] {
            job.process = process
            jobs[id] = job
        }
        let gateway = RunGateway(
            policy: policy,
            inner: MembraeToolGateway(
                roots: roots,
                includeMembraeTools: false,
                includeProjectTools: false,
                mcp: nil
            )
        )
        var lastText = ""
        var citations: [RunResultLink] = []
        for try await event in try process.start(request) {
            try Task.checkCancellation()
            if let label = RunWaitLabel.forCursor(event) {
                setWait(id, label)
            }
            if event.type == "text", let text = event.text, !text.isEmpty {
                lastText += text
            }
            if event.type == "host_tool", let toolID = event.id {
                if event.name == "resolve_project_code_roots" {
                    do {
                        process.replyToHostTool(id: toolID, text: try ProjectCodeWorkspace.encodedRoots(roots))
                    } catch {
                        process.replyToHostTool(id: toolID, error: error.localizedDescription)
                    }
                } else if let name = event.name, BrowserTools.isBrowser(name) {
                    do {
                        let output = try await BrowserRuntime.shared.execute(
                            name: name,
                            arguments: Self.hostArguments(event),
                            context: BrowserCallContext(runID: id, projectID: resolvedRun(id)?.project?.id)
                        )
                        process.replyToHostTool(id: toolID, text: output)
                    } catch {
                        process.replyToHostTool(id: toolID, error: error.localizedDescription)
                    }
                } else if event.name == RunToolPolicy.finishRun {
                    let arguments = Self.hostArguments(event)
                    do {
                        _ = try await gateway.execute(name: RunToolPolicy.finishRun, arguments: arguments)
                        process.replyToHostTool(id: toolID, text: "{\"ok\":true}")
                    } catch {
                        process.replyToHostTool(id: toolID, error: error.localizedDescription)
                    }
                }
            }
            if event.type == "error", let message = event.error ?? event.message, !message.isEmpty {
                throw CursorAPIError(status: 0, message: message)
            }
            if let sources = event.sources {
                for source in sources {
                    guard let url = source.url, RunLinkSafety.allows(url) else { continue }
                    citations.append(RunResultLink(label: source.title, url: url, kind: RunLinkSafety.kind(for: url)))
                }
            }
        }
        process.stop()
        try await finish(id, gateway: gateway, lastText: lastText, extra: citations, roots: roots)
    }

    /// Hands the brief to a coding tool on this Mac. The tool does the work under its own rules;
    /// Membrae records what was asked and what came back.
    private func runLocalAgent(_ id: UUID, agent: LocalAgent, resume: (session: String, message: String)? = nil) async throws {
        guard let executable = agent.locate() else {
            throw LocalAgentError("\(agent.title) is not installed on this Mac.")
        }
        guard let run = resolvedRun(id) else { return }
        let policy = policy(for: run)
        // A session works whatever the Space has attached, including a folder attached after it began.
        if run.isSession, let project = run.project, let context = liveContext() {
            let attached = ProjectCodeWorkspace.attachments(on: project).map { $0.locator.isEmpty ? $0.title : $0.locator }
            if !attached.isEmpty, Set(attached) != Set(run.repositoryLocators) {
                run.repositoryLocators = attached
                try? context.save()
            }
        }
        let roots = try await selectedRoots(for: run)
        guard let run = resolvedRun(id), let context = liveContext() else { return }
        let folder = context.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("Agent", isDirectory: true)
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let attachedRepository = roots.first?.path
        let allowEdits = run.allowEdits
        let tools = policy.allowedNames(from: RunToolPolicy.generalCatalog(for: run))
        let track = run.trackID.flatMap { TitleIndexStore.thread($0, in: context) }
        // A session on a track in a git repository works on the track's own branch, in its own worktree
        // beside the repository, so the user's checkout and other tracks are untouched until it merges.
        var checkout: TrackBranches.Checkout?
        if run.isSession, allowEdits, let track, let attachedRepository, await TrackBranches.isRepository(attachedRepository) {
            setWait(id, "Checking out the track's branch")
            let prepared = try await TrackBranches.prepare(track: track, repository: attachedRepository)
            if track.branch != prepared.branch || track.worktreePath != prepared.path {
                track.branch = prepared.branch
                track.worktreePath = prepared.path
                track.baseBranch = prepared.base
                try? context.save()
                record(id, .step, "Working on branch \(prepared.branch) in \(prepared.path)")
            }
            checkout = prepared
        }
        let repository = checkout?.path ?? attachedRepository
        let prompt: String
        if let resume {
            prompt = run.isSession
                ? RunPrompt.sessionTurn(
                    message: resume.message,
                    track: track,
                    extraDirectories: roots.dropFirst().map(\.path),
                    directory: checkout?.path,
                    branch: checkout?.branch
                )
                : resume.message
        } else if run.isSession {
            prompt = RunPrompt.session(
                brief: run.brief,
                track: track,
                project: run.project,
                directory: repository,
                extraDirectories: roots.dropFirst().map(\.path),
                allowEdits: allowEdits,
                hasMembrae: !tools.isEmpty,
                branch: checkout?.branch
            )
        } else {
            prompt = RunPrompt.localAgent(
                brief: run.brief,
                project: run.project,
                directory: repository,
                allowEdits: allowEdits,
                hasMembrae: !tools.isEmpty,
                task: run.task
            )
        }
        let request = LocalAgentRequest(
            prompt: prompt,
            directory: repository ?? folder?.path ?? NSTemporaryDirectory(),
            allowEdits: allowEdits,
            mcpCommand: Bundle.main.url(forAuxiliaryExecutable: "membrae-mcp")?.path,
            membraeTools: tools,
            runID: run.id.uuidString,
            resumeSessionID: resume?.session,
            extraDirectories: roots.dropFirst().map(\.path)
        )
        // The worktree is outside the sandbox, so its history is read through git; an attached folder is read directly.
        let headBefore: String? = if let checkout { await TrackBranches.head(in: checkout.path) } else { nil }
        let before = checkout == nil ? repository.flatMap { try? GitHistory.commits(in: $0, limit: 1) } : nil
        let process = LocalAgentProcess()
        if var job = jobs[id] {
            job.local = process
            jobs[id] = job
        }
        defer {
            if let context = liveContext(), let live = resolvedRun(id), live.workerID != "" {
                live.workerID = ""
                try? context.save()
            }
        }
        var lastText = ""
        var summary = ""
        var refused: [String] = []
        var lastStep = ""
        var usageLine = ""
        let stream = try process.start(agent, executable: executable, request: request)
        if let worker = process.workerID, let context = liveContext(), let live = resolvedRun(id) {
            live.workerID = worker
            try? context.save()
        }
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .activity(let label):
                setWait(id, label)
                // The same step again in a row is one line of the transcript.
                if label != lastStep {
                    lastStep = label
                    record(id, .step, label)
                }
            case .textDelta(let piece):
                drafts[id, default: ""] += piece
                setWait(id, ChatWaitState.writing.label)
            case .text(let text):
                lastText = text
                lastStep = ""
                drafts[id] = nil
                setWait(id, ChatWaitState.writing.label)
                record(id, .said, text)
            case .session(let session):
                if let context = liveContext(), let live = resolvedRun(id) {
                    live.externalID = session
                    try? context.persist()
                }
            case .finished(let text, let names):
                summary = text
                refused = names
            case .usage(let cost, let input, let output, let duration):
                usageLine = LocalAgentEvent.usageLine(cost: cost, inputTokens: input, outputTokens: output, durationMs: duration)
            case .failed(let message):
                throw LocalAgentError(message)
            }
        }
        process.stop()
        let closing = summary.isEmpty ? lastText : summary
        // A session's turn ends with the user's turn, never with the Run finishing.
        if let context = liveContext(), let live = resolvedRun(id), live.isSession {
            if let checkout {
                var commits = await TrackBranches.commits(since: headBefore, in: checkout.path)
                if !commits.isEmpty {
                    // The track's branch goes up after every turn with commits, never main and never by force.
                    if let remote = await TrackBranches.remote(in: checkout.path) {
                        setWait(id, "Pushing \(checkout.branch)")
                        commits.append(await TrackBranches.push(branch: checkout.branch, in: checkout.path, remote: remote))
                    }
                    live.append(.commits, detail: commits.joined(separator: "\n"))
                }
            } else if let repository, let before {
                let commits = Self.commitLines(in: repository, since: before.first?.sha)
                if !commits.isEmpty {
                    live.append(.commits, detail: commits.joined(separator: "\n"))
                }
            }
            let refusal = agent.refusalNote(refused, allowEdits: allowEdits)
            if !refusal.isEmpty { live.append(.step, detail: refusal) }
            if !usageLine.isEmpty { live.append(.turn, detail: usageLine) }
            guard !live.externalID.isEmpty else {
                throw LocalAgentError("\(agent.title) gave no session to carry on. Start the session again.")
            }
            live.resultSummary = closing
            let stopped = interrupting.remove(id) != nil
            try RunStore.transition(live, to: .waiting, detail: stopped ? "Stopped. Your turn." : "Your turn", in: context)
            clear(id)
            sendQueued(id)
            return
        }
        // A worker that ends on a question is waiting for the user, not done. Its session carries on with the reply.
        if refused.isEmpty, Self.asksTheUser(closing),
           let context = liveContext(), let live = resolvedRun(id), !live.externalID.isEmpty {
            live.resultSummary = closing
            try RunStore.transition(live, to: .waiting, detail: "Asked you a question", in: context)
            clear(id)
            announce(id)
            return
        }
        var parts = [summary.isEmpty ? lastText : summary]
        let refusal = agent.refusalNote(refused, allowEdits: allowEdits)
        if let repository, let before {
            let commits = Self.commitLines(in: repository, since: before.first?.sha)
            if !commits.isEmpty {
                parts.append("Commits\n" + commits.map { "- \($0)" }.joined(separator: "\n"))
            }
        }
        let gateway = RunGateway(
            policy: policy,
            inner: MembraeToolGateway(
                roots: roots,
                includeMembraeTools: false,
                includeProjectTools: false,
                mcp: nil
            )
        )
        try await finish(
            id,
            gateway: gateway,
            lastText: parts.filter { !$0.isEmpty }.joined(separator: "\n\n"),
            extra: [],
            roots: roots,
            couldNot: refusal.isEmpty ? nil : refusal
        )
    }

    /// Commits made since `sha`, newest first. A nil `sha` means the repository had none.
    /// Whether a worker's last message ends by asking the user something.
    nonisolated static func asksTheUser(_ text: String) -> Bool {
        let last = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty } ?? ""
        return last.hasSuffix("?")
    }

    /// Adds one line to a Run's transcript, so the Run page shows the work as it happens.
    private func record(_ id: UUID, _ kind: RunEventKind, _ detail: String) {
        guard let context = liveContext(), let run = resolvedRun(id) else { return }
        run.append(kind, detail: detail)
        try? context.persist()
    }

    private static func commitLines(in path: String, since sha: String?) -> [String] {
        guard let commits = try? GitHistory.commits(in: path, limit: 30) else { return [] }
        var lines: [String] = []
        for commit in commits {
            if commit.sha == sha { break }
            lines.append("\(commit.sha.prefix(7)) \(commit.message)")
        }
        return lines
    }

    private func finish(
        _ id: UUID,
        gateway: RunGateway,
        lastText: String,
        extra: [RunResultLink],
        roots: [ProjectCodeRoot],
        couldNot: String? = nil
    ) async throws {
        var run: AgentRun?
        var context: ModelContext?
        for _ in 0..<5 {
            run = resolvedRun(id)
            context = liveContext()
            if run != nil, context != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let run, let context else {
            throw CursorAPIError(status: 0, message: "The run disappeared before it could be published.")
        }
        try finish(run, gateway: gateway, lastText: lastText, extra: extra, roots: roots, couldNot: couldNot, in: context)
    }

    private func finish(
        _ run: AgentRun,
        gateway: RunGateway,
        lastText: String,
        extra: [RunResultLink],
        roots: [ProjectCodeRoot],
        couldNot: String? = nil,
        in context: ModelContext
    ) throws {
        guard run.status.isActive else { return }
        let workerSummary: String
        if let finish = gateway.finishSummary, !finish.isEmpty {
            workerSummary = finish
        } else {
            workerSummary = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let summary = workerSummary.isEmpty ? "Finished with no summary." : workerSummary
        var links = gateway.journal
        for link in extra + gateway.finishLinks where !links.contains(where: { $0.url == link.url }) {
            if link.kind == .file, !RunLinkSafety.fileAllowed(link.url, roots: roots) { continue }
            if !RunLinkSafety.allows(link.url) { continue }
            links.append(link)
        }
        if let reason = couldNot ?? gateway.finishCouldNot {
            try RunStore.couldNot(run, reason: reason, summary: summary, links: links, in: context)
        } else {
            try RunStore.succeed(run, summary: summary, links: links, in: context)
        }
        clear(run.id)
        announce(run.id)
    }

    /// Tells the user a Run ended. Runs are not in the sidebar, so nothing else would.
    private func announce(_ id: UUID) {
        guard let run = resolvedRun(id) else { return }
        app?.postRunNotice(for: run)
    }

    private func policy(for run: AgentRun) -> RunToolPolicy {
        RunToolPolicy.effective(for: run)
    }

    private func selectedRoots(for run: AgentRun) async throws -> [ProjectCodeRoot] {
        guard let project = run.project, !run.repositoryLocators.isEmpty else { return [] }
        let locators = run.repositoryLocators
        let store = liveContext()?.container.configurations.first?.url
        let prepared = try await ProjectCodeWorkspace.prepare(for: project, storeURL: store)
        return prepared.filter { root in
            locators.contains { locator in
                root.locator == locator || root.title == locator || root.path == locator
            }
        }
    }

    private func cloudRepos(for project: Project?) -> [RunnerCloudRepo] {
        guard let project else { return [] }
        return ProjectCodeWorkspace.attachments(on: project).compactMap { attachment in
            switch attachment.kind {
            case .github:
                return RunnerCloudRepo(url: GitHubRemote.url(forLocator: attachment.locator) + ".git")
            default:
                return nil
            }
        }
    }

    private func validateProvider(_ run: AgentRun, app: AppModel) throws {
        if let agent = LocalAgent(rawValue: run.providerID) {
            guard app.isConnected(agent) else {
                throw LocalAgentError("Connect \(agent.title) in Settings.")
            }
            if agent == .codex, !run.allowEdits {
                throw LocalAgentError("Codex can only work from Membrae with its own sandbox off. Start the Run again with “Let it edit files and run commands” turned on.")
            }
            return
        }
        switch TalkProvider(rawValue: run.providerID) {
        case .chatgpt:
            guard app.sources.hasChatGPT else {
                throw ChatGPTAuthError("Connect ChatGPT in Settings.")
            }
            guard !run.modelID.isEmpty else {
                throw ChatGPTAuthError("Choose a ChatGPT model in Settings.")
            }
        case .cursor:
            guard app.hasAPIKey else {
                throw CursorAPIError(status: 0, message: "Add a Cursor API key in Settings.")
            }
        default:
            throw CursorAPIError(status: 0, message: "Choose a provider in Settings.")
        }
    }

    private func setWait(_ id: UUID, _ label: String) {
        if let index = running.firstIndex(where: { $0.id == id }) {
            running[index].label = label
        } else {
            running.append(RunningRun(id: id, label: label))
        }
    }

    private func clear(_ id: UUID) {
        jobs[id]?.process?.stop()
        jobs[id]?.local?.stop()
        jobs[id] = nil
        drafts[id] = nil
        running.removeAll { $0.id == id }
        BrowserRuntime.shared.cancel(runID: id)
    }

    private static func hostArguments(_ event: RunnerEvent) -> [String: Any] {
        for raw in [event.text, event.detail] {
            guard let raw, let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return object
        }
        if let text = event.text, !text.isEmpty {
            return ["summary": text]
        }
        return [:]
    }
}

extension RunToolPolicy {
    /// Every Membrae tool a Run can be handed: the same set a chat has, less what a Run never does.
    static let membraeCatalog = [
        "list_spaces", "get_space", "update_space", "get_space_catalog",
        "list_tasks", "get_task", "create_task", "update_task",
        "list_completions", "get_completion",
        "list_decisions", "get_decision", "create_decision", "update_decision",
        "list_tracks", "get_track", "create_track", "update_track", "set_stops", "mark_stop", "convert_track_to_stop",
        "set_junction", "delete_junction", "merge_tracks",
        "list_notes", "get_note", "create_note", "update_note",
        "list_sources", "get_source", "create_source", "update_source",
        "list_chats", "get_chat",
        "list_tags", "create_tag", "update_tag", "assign_tag", "remove_tag",
        "list_runs", "get_run",
        "get_cleanup_review", "propose_cleanup",
        "set_space_type", "set_space_widget", "set_space_card", "set_space_layout",
        "place_space_widget", "list_space_widgets", "remove_space_widget",
        "list_space_records", "create_space_record", "update_space_record",
        "list_space_events", "log_space_event", "update_space_event"
    ]
}
