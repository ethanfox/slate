import Foundation
import SwiftData
@testable import Slate

@MainActor
enum CodeIndexEval {
    struct Entry {
        var key: String
        var title: String
        var body: String
        var paths: [String]
    }

    struct Result {
        var published: Bool
        var coverage: String
        var entries: [Entry]
        var realPaths: Int
        var missingPaths: [String]
        var gapsDisclosed: Bool
        var notes: [String]
        var hardFailures: [String]
        var answer: String
        var calls: [TrackFirstEval.Call]
        var traceURL: URL?
    }

    static var isRequested: Bool {
        let value = ProcessInfo.processInfo.environment["SLATE_EVAL_INDEX"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_SLATE_EVAL_INDEX"]
            ?? ""
        return value == "1" || value.lowercased() == "true"
    }

    static func run(model: String, repoPath: String) async throws -> Result {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let context = container.mainContext
        let project = Project(name: "Slate", symbol: "note.text", summary: "Native Mac knowledge base.")
        context.insert(project)
        let attachment = CodeAttachment(kind: .folder, title: "PC-OS", locator: repoPath, project: project)
        context.insert(attachment)
        try context.save()

        let draft = RepositoryIndex.draft(
            for: attachment,
            project: project,
            providerID: "chatgpt",
            modelID: model
        )
        let run = try RunStore.enqueue(draft, in: context)
        try RunStore.transition(run, to: .running, in: context)
        _ = try CodeReferenceStore.beginStaging(
            for: attachment,
            run: run,
            fingerprint: RepositoryIndex.fingerprint(at: repoPath),
            in: context
        )

        let policy = RunToolPolicy.indexing(runID: run.id, projectID: project.id, attachmentID: attachment.id)
        let inner = SlateToolGateway(
            roots: [.init(title: attachment.title, locator: attachment.locator, path: repoPath)],
            includeSlateTools: false,
            includeProjectTools: true
        )
        let tools = (try await inner.definitions() + Tools.definitions.map { tool in
            [
                "type": "function",
                "name": tool["name"] as? String ?? "",
                "description": tool["description"] as? String ?? "",
                "parameters": tool["inputSchema"] as? [String: Any] ?? ["type": "object"]
            ]
        }).filter { tool in
            guard let name = tool["name"] as? String else { return false }
            return policy.allows(name)
        }
        let eval = EvalToolGateway(container: container, project: inner, tools: tools)
        let gateway = RunGateway(policy: policy, inner: eval)
        let transport = TimingTransport(inner: ChatGPTTransport(model: model))
        var answer = ""
        var calls: [TrackFirstEval.Call] = []
        var toolStart = Date()

        try await AgentRuntime.run(
            instructions: RepositoryIndex.prompt(
                brief: run.brief,
                project: project,
                attachmentTitle: attachment.title
            ),
            input: [["role": "user", "content": run.brief]],
            tools: try await gateway.definitions(),
            maxRounds: ChatGPTProvider.maxToolRounds,
            transport: transport,
            gateway: gateway,
            onEvent: { event in
                switch event {
                case .text(let delta):
                    answer += delta
                case .callStarted:
                    toolStart = Date()
                case .callFinished(let call, let output):
                    calls.append(TrackFirstEval.Call(
                        name: call.name,
                        arguments: call.arguments,
                        output: output,
                        milliseconds: Date().timeIntervalSince(toolStart) * 1000,
                        bytes: output.utf8.count
                    ))
                case .thinking:
                    break
                }
            }
        )

        var hard: [String] = []
        var notes: [String] = []
        do {
            _ = try CodeReferenceStore.publishIfValid(
                run: run,
                rootPath: repoPath,
                currentFingerprint: RepositoryIndex.fingerprint(at: repoPath),
                in: context
            )
        } catch {
            hard.append("Publication failed: \(error.localizedDescription)")
        }

        let published = CodeReferenceStore.published(on: attachment, in: context)
        let entries = (published.map { CodeReferenceStore.sortedEntries(on: $0, in: context) } ?? []).map {
            Entry(key: $0.key, title: $0.title, body: $0.body, paths: $0.sourceLocations.map(\.path))
        }
        var missing: [String] = []
        var real = 0
        for path in entries.flatMap(\.paths) {
            let url = URL(fileURLWithPath: repoPath).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                real += 1
            } else {
                missing.append(path)
            }
        }
        if published == nil { hard.append("No published reference.") }
        if entries.isEmpty { hard.append("No entries.") }
        if !missing.isEmpty { hard.append("Missing paths: \(missing.joined(separator: ", "))") }

        let known = ["AgentRuntime", "RunStore", "RunToolPolicy", "RunCoordinator", "Store.swift", "Tools.swift"]
        let blob = entries.map { $0.title + $0.body + $0.paths.joined() }.joined()
        let hits = known.filter { blob.contains($0) }
        if hits.count < 2 {
            notes.append("Few known Slate components were named. Hits: \(hits.joined(separator: ", ")).")
        } else {
            notes.append("Named known components: \(hits.joined(separator: ", ")).")
        }
        let gaps = published?.coverageNotes ?? ""
        let gapsDisclosed = published?.coverage != .complete || !gaps.isEmpty
        if published?.coverage == .complete && gaps.isEmpty {
            notes.append("Marked complete with no disclosed gaps.")
        }
        notes.append("Use the reference on a focused implementation question and compare against source. Do not score by entry count alone.")

        let trace = writeTrace(
            answer: answer,
            calls: calls,
            published: published,
            notes: notes
        )
        return Result(
            published: published != nil,
            coverage: published?.coverage.rawValue ?? "",
            entries: entries,
            realPaths: real,
            missingPaths: missing,
            gapsDisclosed: gapsDisclosed,
            notes: notes,
            hardFailures: hard,
            answer: answer,
            calls: calls,
            traceURL: trace
        )
    }

    static func report(_ result: Result) -> String {
        var lines = [
            "published=\(result.published) coverage=\(result.coverage) entries=\(result.entries.count) realPaths=\(result.realPaths)"
        ]
        for note in result.notes { lines.append("note: \(note)") }
        for failure in result.hardFailures { lines.append("hard: \(failure)") }
        for entry in result.entries {
            lines.append("entry: \(entry.key) \(entry.title) paths=\(entry.paths.joined(separator: ","))")
        }
        if let trace = result.traceURL {
            lines.append("trace: \(trace.path)")
        }
        return lines.joined(separator: "\n")
    }

    private static func writeTrace(
        answer: String,
        calls: [TrackFirstEval.Call],
        published: CodeReference?,
        notes: [String]
    ) -> URL? {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("PersonalContextTests/Scenarios/code-index-traces", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")).json")
        let payload: [String: Any] = [
            "answer": answer,
            "notes": notes,
            "calls": calls.map { ["name": $0.name, "output": $0.output] },
            "coverage": published?.coverage.rawValue ?? "",
            "coverage_notes": published?.coverageNotes ?? "",
            "entries": [] as [[String: Any]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        try? data.write(to: url)
        return url
    }
}
