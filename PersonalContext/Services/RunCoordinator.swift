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
        startQueuedIndexing(in: context)
    }

    private func startQueuedIndexing(in context: ModelContext) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        for run in RunStore.runs(in: context) where run.status == .queued && run.purpose == .indexRepository {
            start(run, in: context)
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

    func cancel(_ run: AgentRun, in context: ModelContext) {
        let id = run.id
        jobs[id]?.task.cancel()
        jobs[id]?.process?.stop()
        try? RunStore.cancel(run, in: context)
        clear(id)
    }

    func waitLabel(for id: UUID) -> String? {
        running.first { $0.id == id }?.label
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

    private func perform(_ id: UUID) async {
        guard let run = resolvedRun(id), let app else { return }
        do {
            try Task.checkCancellation()
            try validateProvider(run, app: app)
            if run.providerID == TalkProvider.chatgpt.rawValue {
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
        }
    }

    private func runChatGPT(_ id: UUID, app _: AppModel) async throws {
        guard let run = resolvedRun(id) else { return }
        let policy = policy(for: run)
        let roots = try await selectedRoots(for: run)
        guard let run = resolvedRun(id), let context = liveContext() else { return }
        try prepareIndex(run, roots: roots, in: context)
        let includeSlate = policy.allowsSlateWrites || policy.allowCodeReferenceWrite
        let gateway = RunGateway(
            policy: policy,
            inner: SlateToolGateway(
                roots: roots,
                includeSlateTools: includeSlate,
                includeProjectTools: policy.allowCode,
                consult: nil,
                mcp: includeSlate ? .shared : nil,
                indexingRunID: run.purpose == .indexRepository ? run.id : nil,
                storeURL: context.container.configurations.first?.url
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
        guard let mcp = Bundle.main.url(forAuxiliaryExecutable: "slate-mcp") else {
            throw CursorAPIError(status: 0, message: "The Slate MCP is missing from the app.")
        }
        guard let run = resolvedRun(id) else { return }
        let policy = policy(for: run)
        let roots = try await selectedRoots(for: run)
        guard let run = resolvedRun(id), let context = liveContext() else { return }
        try prepareIndex(run, roots: roots, in: context)
        let store = context.container.configurations.first?.url
        let folder = store?.deletingLastPathComponent().appendingPathComponent("Agent", isDirectory: true)
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let workspace: String
        if run.purpose == .indexRepository {
            workspace = folder?.path ?? NSTemporaryDirectory()
        } else if roots.count == 1 {
            workspace = roots[0].path
        } else {
            workspace = roots.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path } ?? folder?.path ?? NSTemporaryDirectory()
        }
        let includeSlate = policy.allowsSlateWrites || policy.allowCodeReferenceWrite
        let catalog = run.purpose == .indexRepository
            ? RunToolPolicy.indexingCatalog
            : RunToolPolicy.slateCatalog
        let listed = includeSlate ? policy.allowedNames(from: catalog) : []
        let request = RunnerRequest(
            apiKey: apiKey,
            env: ProcessInfo.processInfo.environment,
            agentId: nil,
            name: run.displayTitle,
            text: RunPrompt.body(brief: run.brief, project: run.project, run: run),
            model: run.modelID,
            cwd: workspace,
            mcpCommand: mcp.path,
            codeRoots: roots,
            includeSlateTools: includeSlate,
            includeProjectTools: policy.allowCode,
            includeWorkerTool: false,
            includeFinishRun: true,
            allowedTools: listed,
            runtime: run.purpose == .indexRepository ? WorkerPath.local.rawValue : run.pathRaw,
            cloudRepos: run.purpose == .indexRepository ? [] : cloudRepos(for: run.project),
            codeSnapshots: policy.allowCode && (run.purpose == .indexRepository || run.pathRaw == WorkerPath.local.rawValue)
                ? ProjectCodeWorkspace.remoteSnapshots(for: run.project, storeURL: store)
                : [],
            readProvenancePath: run.purpose == .indexRepository
                ? CodeReadProvenance.fileURL(runID: run.id, storeURL: store).path
                : ""
        )
        let process = RunCursorProcess()
        if var job = jobs[id] {
            job.process = process
            jobs[id] = job
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

    private func finish(
        _ id: UUID,
        gateway: RunGateway,
        lastText: String,
        extra: [RunResultLink],
        roots: [ProjectCodeRoot]
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
        try finish(run, gateway: gateway, lastText: lastText, extra: extra, roots: roots, in: context)
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
        var extra = extra
        let workerSummary: String
        if let finish = gateway.finishSummary, !finish.isEmpty {
            workerSummary = finish
        } else {
            workerSummary = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if run.purpose == .indexRepository {
            do {
                let published = try publishIndex(run, roots: roots, in: context)
                extra.append(
                    RunResultLink(
                        label: "Code reference",
                        url: "slate://code-reference/\(published.id.uuidString)",
                        kind: .document
                    )
                )
            } catch {
                try RunStore.failUnpublishedIndex(
                    run,
                    workerSummary: workerSummary,
                    detail: error.localizedDescription,
                    in: context
                )
                clear(run.id)
                return
            }
        }
        let summary = workerSummary.isEmpty ? "Finished with no summary." : workerSummary
        var links = gateway.journal
        for link in extra + gateway.finishLinks where !links.contains(where: { $0.url == link.url }) {
            if link.kind == .file, !RunLinkSafety.fileAllowed(link.url, roots: roots) { continue }
            if !RunLinkSafety.allows(link.url) { continue }
            links.append(link)
        }
        try RunStore.succeed(run, summary: summary, links: links, in: context)
        clear(run.id)
    }

    private func policy(for run: AgentRun) -> RunToolPolicy {
        RunToolPolicy.effective(for: run)
    }

    private func prepareIndex(_ run: AgentRun, roots: [ProjectCodeRoot], in context: ModelContext) throws {
        guard run.purpose == .indexRepository else { return }
        guard let attachmentID = run.indexedAttachmentID,
              let attachment = CodeReferenceStore.attachment(attachmentID, in: context)
        else {
            throw CodeReferenceError.attachmentNotFound
        }
        let path = roots.first?.path ?? CodeReferenceStore.rootPath(
            for: attachment,
            storeURL: context.container.configurations.first?.url
        ) ?? attachment.locator
        _ = try CodeReferenceStore.beginStaging(
            for: attachment,
            run: run,
            fingerprint: RepositoryIndex.fingerprint(at: path),
            in: context
        )
    }

    private func publishIndex(_ run: AgentRun, roots: [ProjectCodeRoot], in context: ModelContext) throws -> CodeReference {
        guard let attachmentID = run.indexedAttachmentID,
              let attachment = CodeReferenceStore.attachment(attachmentID, in: context)
        else {
            throw CodeReferenceError.attachmentNotFound
        }
        let path = roots.first?.path ?? CodeReferenceStore.rootPath(
            for: attachment,
            storeURL: context.container.configurations.first?.url
        )
        guard let path else { throw CodeReferenceError.pathMissing(attachment.locator) }
        return try CodeReferenceStore.publishIfValid(
            run: run,
            rootPath: path,
            currentFingerprint: RepositoryIndex.fingerprint(at: path),
            in: context
        )
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
        "list_runs", "get_run",
        "list_code_references", "get_code_reference_entry"
    ]

    static let indexingCatalog = [
        "list_projects", "get_project",
        "list_code_references", "get_code_reference_entry",
        "upsert_code_reference_entry", "set_code_reference_meta"
    ]
}
