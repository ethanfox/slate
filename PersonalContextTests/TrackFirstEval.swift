import Foundation
import SwiftData
@testable import Membrae

@MainActor
enum TrackFirstEval {
    struct Call: Equatable {
        var name: String
        var arguments: [String: Any]
        var output: String
        var milliseconds: Double
        var bytes: Int

        static func == (lhs: Call, rhs: Call) -> Bool {
            lhs.name == rhs.name && lhs.output == rhs.output
        }
    }

    struct Run {
        var id: String
        var title: String
        var answer: String
        var calls: [Call]
        var score: Score
        var toolMs: Double
        var inferenceMs: Double
        var totalMs: Double
        var retrievedBytes: Int
        var authBody: String
        var tasks: [(title: String, tracks: [UUID])]
    }

    struct Score {
        var correctness: Int
        var objectChoice: Int
        var linkage: Int
        var scope: Int
        var persistence: Int
        var evidence: Int
        var hardFailures: [String]

        var total: Int {
            correctness + objectChoice + linkage + scope + persistence + evidence
        }

        var failed: Bool { !hardFailures.isEmpty }
    }

    struct Scenario {
        var id: String
        var title: String
        var focused: Focus
        var prompts: [String]
        var includeProjectTools: Bool
        var prepare: ((HarborEvalFixture.Seed, ModelContext) throws -> Void)? = nil
        var betweenTurns: ((HarborEvalFixture.Seed, ModelContext) throws -> Void)? = nil

        enum Focus {
            case auth
            case project
        }
    }

    static let vendorExcerpt = "VENDOR_EXCERPT_RETRY_BACKOFF"

    static let scenarios: [Scenario] = [
        Scenario(
            id: "1",
            title: "Edit the actual spec",
            focused: .auth,
            prompts: ["Add that sign-in must work offline."],
            includeProjectTools: false
        ),
        Scenario(
            id: "2",
            title: "Turn discussion into work",
            focused: .auth,
            prompts: ["Make offline sign-in a task."],
            includeProjectTools: false
        ),
        Scenario(
            id: "3",
            title: "Separate evidence from authority",
            focused: .auth,
            prompts: ["Vendor docs say we need hosted accounts. Should we change Auth?"],
            includeProjectTools: false
        ),
        Scenario(
            id: "4",
            title: "Include child work",
            focused: .auth,
            prompts: ["What's left to do under Auth, including its subtracks?"],
            includeProjectTools: false
        ),
        Scenario(
            id: "5",
            title: "Stay scoped",
            focused: .auth,
            prompts: ["What's blocking this?"],
            includeProjectTools: false
        ),
        Scenario(
            id: "6",
            title: "Refresh between turns",
            focused: .auth,
            prompts: [
                "What are the Auth requirements?",
                "What are the requirements now?"
            ],
            includeProjectTools: false,
            betweenTurns: { seed, context in
                seed.auth.body = HarborEvalFixture.authBodyWithOffline
                try context.save()
            }
        ),
        Scenario(
            id: "7",
            title: "Save actual reference material",
            focused: .auth,
            prompts: ["Save this vendor documentation excerpt for reference under Auth: \(vendorExcerpt)"],
            includeProjectTools: false
        ),
        Scenario(
            id: "8",
            title: "Record a real decision",
            focused: .auth,
            prompts: ["We've decided to keep local sessions because offline access is required. Record that under Auth."],
            includeProjectTools: false
        ),
        Scenario(
            id: "9",
            title: "Review code against the spec",
            focused: .auth,
            prompts: ["Review the sign-in changes against Auth. Don't edit anything."],
            includeProjectTools: true,
            prepare: { seed, context in
                seed.auth.body = HarborEvalFixture.authBodyWithOffline
                try context.save()
            }
        ),
        Scenario(
            id: "10",
            title: "Recover from an ambiguous location",
            focused: .project,
            prompts: ["Add retry handling to the spec."],
            includeProjectTools: false
        )
    ]

    static func runAll(model: String, repeats: Int = 1, ids: [String] = []) async throws -> [Run] {
        let selected = ids.isEmpty ? scenarios : scenarios.filter { ids.contains($0.id) }
        var results: [Run] = []
        for scenario in selected {
            for _ in 0..<max(1, repeats) {
                results.append(try await run(scenario, model: model))
            }
        }
        return results
    }

    static func run(_ scenario: Scenario, model: String) async throws -> Run {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let context = container.mainContext
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()
        if let prepare = scenario.prepare {
            try prepare(seed, context)
        }
        let baselineAuth = seed.auth.body
        let codeRoot = scenario.includeProjectTools ? try makeSignInFixture() : nil
        defer { if let codeRoot { try? FileManager.default.removeItem(at: codeRoot) } }

        var answer = ""
        var calls: [Call] = []
        var toolMs = 0.0
        var inferenceMs = 0.0
        let started = Date()
        let focused = scenario.focused == .auth ? seed.auth : nil

        for (index, prompt) in scenario.prompts.enumerated() {
            if index > 0, let between = scenario.betweenTurns {
                try between(seed, context)
            }
            let turn = try await completeTurn(
                prompt: prompt,
                opening: index == 0,
                project: seed.project,
                focused: focused,
                container: container,
                model: model,
                codeRoot: codeRoot
            )
            answer = turn.answer
            calls.append(contentsOf: turn.calls)
            toolMs += turn.toolMs
            inferenceMs += turn.inferenceMs
        }

        let score = score(scenario, seed: seed, container: container, answer: answer, calls: calls, baselineAuth: baselineAuth)
        let state = State(seed: seed, container: container, baselineAuth: baselineAuth)
        return Run(
            id: scenario.id,
            title: scenario.title,
            answer: answer,
            calls: calls,
            score: score,
            toolMs: toolMs,
            inferenceMs: inferenceMs,
            totalMs: Date().timeIntervalSince(started) * 1000,
            retrievedBytes: calls.reduce(0) { $0 + $1.bytes },
            authBody: state.authBody,
            tasks: state.tasks
        )
    }

    static func score(
        _ scenario: Scenario,
        seed: HarborEvalFixture.Seed,
        container: ModelContainer,
        answer: String,
        calls: [Call],
        baselineAuth: String? = nil
    ) -> Score {
        let state = State(seed: seed, container: container, baselineAuth: baselineAuth)
        let lower = answer.lowercased()
        var hard: [String] = []
        var correctness = 0
        var objects = 0
        var linkage = 0
        var scope = 2
        var persistence = 0
        var evidence = 2

        if calls.contains(where: { $0.name == "get_note" && $0.output.contains(HarborEvalFixture.billingSentinel) })
            || answer.contains(HarborEvalFixture.billingSentinel) {
            scope = 0
            hard.append("Retrieved unrelated Billing note content.")
        }
        if state.billingChanged {
            hard.append("Wrote the Billing track.")
        }

        switch scenario.id {
        case "1":
            let kept = state.authBody.contains("local session store")
            let added = state.authBody.lowercased().contains("offline")
            let wroteNoteInstead = !added && state.notes.contains { $0.content.lowercased().contains("offline") }
            correctness = kept && added ? 2 : 0
            objects = added && kept ? 2 : 0
            linkage = added && kept ? 2 : 0
            persistence = added && kept ? 2 : 0
            if !kept { hard.append("Lost existing Auth spec content.") }
            if state.authTracks != 1 { hard.append("Created a duplicate Auth track.") }
            if !added { hard.append("Did not save offline onto the Auth body.") }
            if wroteNoteInstead { hard.append("Wrote a spec note instead of the track.") }
        case "2":
            let tasks = state.tasks.filter { $0.title.lowercased().contains("offline") }
            let linked = tasks.contains { $0.tracks.contains(seed.auth.id) }
            let unlinked = tasks.contains { $0.tracks.isEmpty }
            correctness = linked ? 2 : (tasks.isEmpty ? 0 : 1)
            objects = linked ? 2 : 0
            linkage = linked ? 2 : 0
            persistence = linked ? 2 : 0
            if unlinked || (tasks.isEmpty && state.notes.contains { $0.content.lowercased().contains("offline") }) {
                hard.append("Created work without a governing Auth track.")
            }
            if tasks.isEmpty { hard.append("Did not create an offline sign-in task.") }
        case "3":
            let decisionHeld = state.decisions.contains { $0.id == seed.decision.id && $0.text.contains("local session") }
            let hosted = state.decisions.contains { $0.status == "active" && $0.text.lowercased().contains("hosted") }
            let explains = lower.contains("vendor") || lower.contains("note") || lower.contains("sample")
            let conflict = lower.contains("decision") || lower.contains("keep") || lower.contains("local")
            correctness = decisionHeld && !hosted && explains ? 2 : 1
            objects = decisionHeld && !hosted ? 2 : 0
            linkage = 2
            persistence = state.authBody == HarborEvalFixture.authBody && decisionHeld && !hosted ? 2 : 0
            if !decisionHeld || hosted { hard.append("Treated vendor reference as product authority.") }
            if !explains || !conflict { correctness = min(correctness, 1) }
        case "4":
            let mentionsShip = lower.contains("ship sign-in")
            let mentionsRefresh = lower.contains("refresh")
            let mentionsBlocked = lower.contains("block")
            let mentionsBilling = lower.contains("billing") || lower.contains("invoice")
            correctness = mentionsShip && mentionsRefresh && mentionsBlocked ? 2 : (mentionsShip || mentionsRefresh ? 1 : 0)
            objects = mentionsShip && mentionsRefresh ? 2 : 0
            linkage = mentionsRefresh && (lower.contains("token") || lower.contains("child") || lower.contains("sub")) ? 2 : 1
            persistence = state.unchangedWork ? 2 : 0
            if mentionsBilling { scope = 0 }
            if !state.unchangedWork { hard.append("Mutated records on a read-only question.") }
        case "5":
            let seesBlock = lower.contains("refresh") && lower.contains("block")
            correctness = seesBlock ? 2 : 0
            objects = seesBlock ? 2 : 0
            linkage = seesBlock ? 2 : 0
            persistence = state.unchangedWork ? 2 : 0
            if !seesBlock { hard.append("Missed the blocked Tokens work.") }
            if !state.unchangedWork { hard.append("Mutated records on a read-only question.") }
        case "6":
            let seesOffline = lower.contains("offline")
            correctness = seesOffline ? 2 : 0
            objects = 2
            linkage = 2
            persistence = 2
            evidence = seesOffline ? 2 : 0
            if !seesOffline { hard.append("Repeated a stale Auth body.") }
        case "7":
            let note = state.notes.first { $0.content.contains(vendorExcerpt) }
            let specHeld = state.authBody == HarborEvalFixture.authBody
            correctness = note != nil && specHeld ? 2 : 0
            objects = note != nil && specHeld ? 2 : 0
            linkage = note?.thread == seed.auth.id ? 2 : 0
            persistence = note != nil && specHeld ? 2 : 0
            if !specHeld { hard.append("Appended reference material onto the Auth spec.") }
            if note == nil { hard.append("Did not save the vendor excerpt as a note.") }
            if note != nil && note?.thread != seed.auth.id { hard.append("Saved the note off Auth.") }
        case "8":
            let active = state.decisions.filter { $0.status == "active" && $0.thread == seed.auth.id }
            let local = active.filter { $0.text.lowercased().contains("local") }
            let hosted = active.contains { $0.text.lowercased().contains("hosted") }
            correctness = !local.isEmpty && !hosted ? 2 : 0
            objects = !local.isEmpty ? 2 : 0
            linkage = local.contains { $0.thread == seed.auth.id } ? 2 : 0
            persistence = !local.isEmpty && local.count <= 2 && !hosted ? 2 : 0
            if local.isEmpty { hard.append("Did not record the decision.") }
            if hosted { hard.append("Invented conflicting policy.") }
            if state.notes.contains(where: { $0.content.lowercased().contains("offline") }) && local.isEmpty {
                hard.append("Saved only a note.")
            }
        case "9":
            let hosted = lower.contains("hosted")
            let network = lower.contains("offline")
                || lower.contains("urlsession")
                || lower.contains("network")
                || lower.contains("accounts.harbor")
            let evidenceHit = answer.contains("SignIn.swift")
                || lower.contains("urlsession")
                || lower.contains("line ")
            let hostedFinding = hosted && evidenceHit
            let offlineFinding = network && evidenceHit
            correctness = hostedFinding && offlineFinding ? 2 : (hostedFinding || offlineFinding ? 1 : 0)
            objects = 2
            linkage = 2
            persistence = state.unchangedWork ? 2 : 0
            evidence = evidenceHit ? 2 : 0
            if !state.unchangedWork { hard.append("Mutated records or implied a save on a review.") }
            if !hostedFinding { hard.append("Missed the hosted-account conflict.") }
            if !offlineFinding { hard.append("Missed the offline/network conflict.") }
        case "10":
            let asks = lower.contains("which") || lower.contains("auth") && lower.contains("billing") || lower.contains("?")
            let wrote = state.authBody != HarborEvalFixture.authBody || state.billingChanged
            correctness = asks && !wrote ? 2 : 0
            objects = !wrote ? 2 : 0
            linkage = !wrote ? 2 : 0
            persistence = !wrote ? 2 : 0
            if wrote { hard.append("Wrote a spec without resolving which track.") }
        default:
            break
        }

        return Score(
            correctness: correctness,
            objectChoice: objects,
            linkage: linkage,
            scope: scope,
            persistence: persistence,
            evidence: evidence,
            hardFailures: hard
        )
    }

    static func report(_ runs: [Run]) -> String {
        var lines = ["Track-first eval"]
        for run in runs {
            let mark = run.score.failed ? "FAIL" : "ok"
            lines.append(
                "\(mark) \(run.id) \(run.title)  \(run.score.total)/12  tools=\(run.calls.count)  infer=\(Int(run.inferenceMs))ms  tool=\(Int(run.toolMs))ms  bytes=\(run.retrievedBytes)"
            )
            for failure in run.score.hardFailures {
                lines.append("  hard: \(failure)")
            }
            // Scenario 9 is read-only review: keep the call trace even on a clean
            // score so extra retrieval (5–13 tools) stays visible.
            if run.score.failed || run.id == "9" {
                lines.append("  answer: \(clip(run.answer, 400))")
                if run.score.failed {
                    lines.append("  auth: \(clip(run.authBody, 300))")
                    if run.tasks.isEmpty {
                        lines.append("  tasks: none")
                    }
                    for task in run.tasks {
                        let tracks = task.tracks.map(\.uuidString).joined(separator: ",")
                        lines.append("  task: \(task.title) tracks=\(tracks)")
                    }
                }
                for call in run.calls {
                    lines.append("  call: \(call.name) \(json(call.arguments))")
                    lines.append("  out: \(clip(call.output, 400))")
                }
            }
        }
        let failed = runs.filter(\.score.failed).count
        lines.append("\(runs.count - failed)/\(runs.count) clean")
        return lines.joined(separator: "\n")
    }

    private struct Turn {
        var answer: String
        var calls: [Call]
        var toolMs: Double
        var inferenceMs: Double
    }

    private struct State {
        var authBody: String
        var authTracks: Int
        var billingChanged: Bool
        var notes: [(id: UUID, title: String, content: String, thread: UUID?)]
        var decisions: [(id: UUID, text: String, status: String, thread: UUID?)]
        var tasks: [(title: String, tracks: [UUID])]
        var unchangedWork: Bool

        init(seed: HarborEvalFixture.Seed, container: ModelContainer, baselineAuth: String? = nil) {
            let context = ModelContext(container)
            let threads = (try? context.fetch(FetchDescriptor<ProjectThread>())) ?? []
            let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
            let decisions = (try? context.fetch(FetchDescriptor<Decision>())) ?? []
            let projectID = seed.project.id
            let tasks = TaskStore.tasks(in: context).filter { $0.project?.id == projectID }
            authBody = threads.first { $0.id == seed.auth.id }?.body ?? ""
            authTracks = threads.filter { $0.title == "Auth" }.count
            billingChanged = threads.first { $0.id == seed.billing.id }?.body != "Retry failed invoice webhooks."
            self.notes = notes.map { ($0.id, $0.displayTitle, $0.content, $0.thread?.id) }
            self.decisions = decisions.map { ($0.id, $0.decision, $0.status.rawValue, $0.thread?.id) }
            self.tasks = tasks.map { ($0.displayTitle, $0.liveTracks.map(\.id)) }
            let authSame = authBody == (baselineAuth ?? HarborEvalFixture.authBody)
            let tokenSame = threads.first { $0.id == seed.tokens.id }?.body == HarborEvalFixture.tokensBody
            let taskTitles = Set(tasks.map(\.displayTitle))
            unchangedWork = authSame && tokenSame && !billingChanged
                && notes.count == 2
                && decisions.count == 1
                && taskTitles == ["Ship sign-in", "Fix refresh after wake", "Retry invoice webhooks"]
        }
    }

    private static func completeTurn(
        prompt: String,
        opening: Bool,
        project: Project,
        focused: ProjectThread?,
        container: ModelContainer,
        model: String,
        codeRoot: URL?
    ) async throws -> Turn {
        let instructions = ContextBuilder.prompt(
            userText: "",
            context: ContextBuilder.identity(for: project),
            opening: opening,
            focusedThread: focused
        )
        var tools = Tools.definitions.map { tool -> [String: Any] in
            [
                "type": "function",
                "name": tool["name"] as? String ?? "",
                "description": tool["description"] as? String ?? "",
                "parameters": tool["inputSchema"] as? [String: Any] ?? ["type": "object"]
            ]
        }
        let projectGateway: MembraeToolGateway?
        if let codeRoot {
            projectGateway = MembraeToolGateway(
                roots: [.init(title: "Harbor", path: codeRoot.path)],
                includeMembraeTools: false
            )
            tools += try await projectGateway!.definitions()
        } else {
            projectGateway = nil
        }
        let gateway = EvalToolGateway(container: container, project: projectGateway, tools: tools)
        let transport = TimingTransport(inner: ChatGPTTransport(model: model))
        var answer = ""
        var calls: [Call] = []
        var toolMs = 0.0
        var toolStart = Date()

        try await AgentRuntime.run(
            instructions: instructions,
            input: [["role": "user", "content": prompt]],
            tools: try await gateway.definitions(),
            maxRounds: ChatGPTProvider.maxToolRounds,
            transport: transport,
            gateway: gateway,
            onEvent: { event in
                switch event {
                case .text(let delta):
                    answer += delta
                case .thinking:
                    break
                case .callStarted:
                    toolStart = Date()
                case .callFinished(let call, let output):
                    let elapsed = Date().timeIntervalSince(toolStart) * 1000
                    toolMs += elapsed
                    calls.append(Call(
                        name: call.name,
                        arguments: call.arguments,
                        output: output,
                        milliseconds: elapsed,
                        bytes: output.utf8.count
                    ))
                }
            }
        )
        return Turn(answer: answer, calls: calls, toolMs: toolMs, inferenceMs: transport.inferenceMs)
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    private static func json(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return clip(text, 240)
    }

    fileprivate static func toolText(_ result: [String: Any]) -> String {
        let content = result["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }

    private static func makeSignInFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        import Foundation

        enum HostedAccountService {
            static func connect() {
                _ = URLSession.shared.dataTask(with: URL(string: "https://accounts.harbor.test/session")!)
            }
        }

        func signIn() {
            HostedAccountService.connect()
        }
        """.write(to: root.appendingPathComponent("SignIn.swift"), atomically: true, encoding: .utf8)
        return root
    }
}

@MainActor
final class EvalToolGateway: AgentToolGateway {
    let container: ModelContainer
    let project: MembraeToolGateway?
    let tools: [[String: Any]]

    init(container: ModelContainer, project: MembraeToolGateway?, tools: [[String: Any]]) {
        self.container = container
        self.project = project
        self.tools = tools
    }

    func definitions() async throws -> [[String: Any]] { tools }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        if name.hasPrefix("project_") {
            guard let project else { return "Error: project tool failed." }
            return try await project.execute(name: name, arguments: arguments)
        }
        return TrackFirstEval.toolText(Tools.call(name, arguments: arguments, container: container))
    }
}

final class TimingTransport: AgentModelTransport {
    let inner: ChatGPTTransport
    private(set) var inferenceMs = 0.0

    init(inner: ChatGPTTransport) {
        self.inner = inner
    }

    func complete(
        instructions: String,
        input: [[String: Any]],
        tools: [[String: Any]],
        onText: (String) async -> Void,
        onThinking: (String?) async -> Void
    ) async throws -> AgentModelTurn {
        let start = Date()
        defer { inferenceMs += Date().timeIntervalSince(start) * 1000 }
        return try await inner.complete(
            instructions: instructions,
            input: input,
            tools: tools,
            onText: onText,
            onThinking: onThinking
        )
    }
}
