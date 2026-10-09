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
    }

    func attach(_ app: AppModel) {
        self.app = app
    }

    func recover(in context: ModelContext) {
        RunStore.recoverAbandoned(in: context)
        running = []
        jobs = [:]
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
            await self.perform(id, in: context)
        }
        jobs[id] = Job(task: task, process: nil)
    }

    func cancel(_ run: AgentRun, in context: ModelContext) {
        jobs[run.id]?.task.cancel()
        jobs[run.id]?.process?.stop()
        try? RunStore.cancel(run, in: context)
        clear(run.id)
    }

    func waitLabel(for id: UUID) -> String? {
        running.first { $0.id == id }?.label
    }

    private func perform(_ id: UUID, in context: ModelContext) async {
        guard let run = RunStore.run(id, in: context), let app else { return }
        do {
            try Task.checkCancellation()
            try validateProvider(run, app: app)
            if run.providerID == TalkProvider.chatgpt.rawValue {
                try await runChatGPT(run, app: app, context: context)
            } else {
                try await runCursor(run, app: app, context: context)
            }
        } catch is CancellationError {
            if let run = RunStore.run(id, in: context), run.status.isActive {
                try? RunStore.cancel(run, in: context)
            }
            clear(id)
        } catch {
            if let run = RunStore.run(id, in: context), run.status.isActive {
                try? RunStore.fail(run, detail: error.localizedDescription, in: context)
            }
            clear(id)
        }
    }

    private func runChatGPT(_ run: AgentRun, app: AppModel, context: ModelContext) async throws {
        let policy = policy(for: run)
        let roots = try await selectedRoots(for: run)
        let gateway = RunGateway(
            policy: policy,
            inner: SlateToolGateway(
                roots: roots,
                includeSlateTools: policy.allowsSlateWrites,
                includeProjectTools: policy.allowCode,
                consult: nil,
                mcp: policy.allowsSlateWrites ? .shared : nil
            )
        )
        let prompt = RunPrompt.body(brief: run.brief, project: run.project)
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
                setWait(run.id, label)
            case .text(let text):
                lastText += text
                setWait(run.id, ChatWaitState.writing.label)
            case .citation:
                break
            }
        }
        try finish(run, gateway: gateway, lastText: lastText, extra: [], roots: roots, in: context)
    }

    private func runCursor(_ run: AgentRun, app: AppModel, context: ModelContext) async throws {
        guard let apiKey = app.apiKey, !apiKey.isEmpty else {
            throw CursorAPIError(status: 0, message: "Add a Cursor API key in Settings.")
        }
        guard let mcp = Bundle.main.url(forAuxiliaryExecutable: "slate-mcp") else {
            throw CursorAPIError(status: 0, message: "The Slate MCP is missing from the app.")
        }
        let policy = policy(for: run)
        let roots = try await selectedRoots(for: run)
        let store = context.container.configurations.first?.url
        let folder = store?.deletingLastPathComponent().appendingPathComponent("Agent", isDirectory: true)
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let workspace = roots.count == 1
            ? roots[0].path
            : (roots.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path } ?? folder?.path ?? NSTemporaryDirectory())
        let listed = policy.allowsSlateWrites
            ? policy.allowedNames(from: RunToolPolicy.slateCatalog)
            : []
        let request = RunnerRequest(
            apiKey: apiKey,
            env: ProcessInfo.processInfo.environment,
            agentId: nil,
            name: run.displayTitle,
            text: RunPrompt.body(brief: run.brief, project: run.project),
            model: run.modelID,
            cwd: workspace,
            mcpCommand: mcp.path,
            codeRoots: roots,
            includeSlateTools: policy.allowsSlateWrites,
            includeProjectTools: policy.allowCode,
            includeWorkerTool: false,
            includeFinishRun: true,
            allowedTools: listed,
            runtime: run.pathRaw,
            cloudRepos: cloudRepos(for: run.project),
            codeSnapshots: policy.allowCode && run.pathRaw == WorkerPath.local.rawValue
                ? ProjectCodeWorkspace.remoteSnapshots(for: run.project, storeURL: store)
                : []
        )
        let process = RunCursorProcess()
        if var job = jobs[run.id] {
            job.process = process
            jobs[run.id] = job
        }
        let gateway = RunGateway(
            policy: policy,
            inner: SlateToolGateway(
                roots: roots,
                includeSlateTools: false,
                includeProjectTools: false,
                consult: nil,
                mcp: nil
            )
        )
        var lastText = ""
        var citations: [RunResultLink] = []
        for try await event in try process.start(request) {
            try Task.checkCancellation()
            if let label = RunWaitLabel.forCursor(event) {
                setWait(run.id, label)
            }
            if event.type == "text", let text = event.text, !text.isEmpty {
                lastText += text
            }
            if event.type == "host_tool", event.name == RunToolPolicy.finishRun, let id = event.id {
                let arguments = Self.hostArguments(event)
                do {
                    _ = try await gateway.execute(name: RunToolPolicy.finishRun, arguments: arguments)
                    process.replyToHostTool(id: id, text: "{\"ok\":true}")
                } catch {
                    process.replyToHostTool(id: id, error: error.localizedDescription)
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
        try finish(run, gateway: gateway, lastText: lastText, extra: citations, roots: roots, in: context)
    }

    private func finish(
        _ run: AgentRun,
        gateway: RunGateway,
        lastText: String,
        extra: [RunResultLink],
        roots: [ProjectCodeRoot],
        in context: ModelContext
    ) throws {
        guard run.status.isActive else { return }
        let summary: String
        if let finish = gateway.finishSummary, !finish.isEmpty {
            summary = finish
        } else {
            let trimmed = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
            summary = trimmed.isEmpty ? "Finished with no summary." : trimmed
        }
        var links = gateway.journal
        for link in gateway.finishLinks + extra where !links.contains(where: { $0.url == link.url }) {
            if link.kind == .file, !RunLinkSafety.fileAllowed(link.url, roots: roots) { continue }
            if !RunLinkSafety.allows(link.url) { continue }
            links.append(link)
        }
        try RunStore.succeed(run, summary: summary, links: links, in: context)
        clear(run.id)
    }

    private func policy(for run: AgentRun) -> RunToolPolicy {
        RunToolPolicy(
            runID: run.id,
            projectID: run.project?.id,
            assignedTaskID: run.task?.id,
            allowCode: run.project != nil && !run.repositoryLocators.isEmpty
        )
    }

    private func selectedRoots(for run: AgentRun) async throws -> [ProjectCodeRoot] {
        guard let project = run.project, !run.repositoryLocators.isEmpty else { return [] }
        let store = run.modelContext?.container.configurations.first?.url
        let prepared = try await ProjectCodeWorkspace.prepare(for: project, storeURL: store)
        return prepared.filter { root in
            run.repositoryLocators.contains { locator in
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
        jobs[id] = nil
        running.removeAll { $0.id == id }
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
    static let slateCatalog = [
        "list_projects", "get_project",
        "list_tasks", "get_task", "create_task", "update_task",
        "list_completions", "get_completion",
        "list_decisions", "get_decision", "create_decision", "update_decision",
        "list_threads", "get_thread", "create_thread", "update_thread",
        "list_notes", "get_note", "create_note", "update_note",
        "list_runs", "get_run"
    ]
}
