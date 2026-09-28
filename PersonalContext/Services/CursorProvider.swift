import AIChatCore
import Foundation
import Observation

struct RunnerRequest: Encodable, Sendable {
    var apiKey: String
    var env: [String: String]
    var agentId: String?
    var name: String
    var text: String
    var model: String
    var cwd: String
    var mcpCommand: String
}

struct RunnerEvent: Decodable, Sendable {
    var type: String
    var agentId: String?
    var text: String?
    var name: String?
    var status: String?
    var error: String?
    var message: String?
}

@MainActor
@Observable
final class CursorConversationBridge {
    var conversation: Conversation
    var project: Project?
    private(set) var changes: [String] = []
    @ObservationIgnored private var process: Process?

    init(conversation: Conversation, project: Project?) {
        self.conversation = conversation
        self.project = project
    }

    func prepare(userText: String, apiKey: String) throws -> RunnerRequest {
        guard let mcp = Bundle.main.url(forAuxiliaryExecutable: "slate-mcp") else {
            throw CursorAPIError(status: 0, message: "The Slate MCP is missing from the app.")
        }
        guard let store = conversation.modelContext?.container.configurations.first?.url else {
            throw CursorAPIError(status: 0, message: "Couldn’t find the knowledge base on disk.")
        }
        let folder = store.deletingLastPathComponent().appendingPathComponent("Agent", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let opening = conversation.cursorAgentId.isEmpty
        ChatTrace.event("prepare conversation=\(conversation.id) opening=\(opening) agent=\(conversation.cursorAgentId) model=\(conversation.model) project=\(project?.name ?? "none") textChars=\(userText.count)")
        changes = []
        if conversation.title == "New chat" || conversation.title.isEmpty {
            conversation.title = conversationTitle(from: userText)
        }
        let focused = conversation.thread
        let context = project.map { ContextBuilder.package(for: $0, focusedThread: focused) } ?? ""
        if opening {
            conversation.contextSnapshot = context
        }
        conversation.updatedAt = .now
        project?.touch()
        try? conversation.modelContext?.save()
        return RunnerRequest(
            apiKey: apiKey,
            env: ProcessInfo.processInfo.environment,
            agentId: opening ? nil : conversation.cursorAgentId,
            name: conversation.title,
            text: ContextBuilder.prompt(userText: userText, context: context, opening: opening, focusedThread: focused),
            model: conversation.model,
            cwd: folder.path,
            mcpCommand: mcp.path
        )
    }

    func run(_ request: RunnerRequest) throws -> AsyncThrowingStream<RunnerEvent, Error> {
        guard let node = Bundle.main.url(forAuxiliaryExecutable: "slate-node"),
              let runner = Bundle.main.url(forResource: "runner", withExtension: "mjs", subdirectory: "runner") else {
            throw CursorAPIError(status: 0, message: "The agent runner is missing from the app.")
        }
        let process = Process()
        process.executableURL = node
        process.arguments = [runner.path]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            ChatTrace.event("runner stderr: \(ChatTrace.clip(String(decoding: data, as: UTF8.self), 8000))")
        }
        let exits = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        self.process = process
        ChatTrace.event("runner started pid=\(process.processIdentifier) resume=\(request.agentId != nil)")
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
        try input.fileHandleForWriting.close()

        let reader = output.fileHandleForReading
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    var sawEnd = false
                    for try await line in reader.bytes.lines {
                        guard let event = try? JSONDecoder().decode(RunnerEvent.self, from: Data(line.utf8)) else { continue }
                        if event.type == "result" || event.type == "error" { sawEnd = true }
                        continuation.yield(event)
                    }
                    var status: Int32 = 0
                    for await code in exits { status = code }
                    ChatTrace.event("runner exited status=\(status)")
                    if !sawEnd, status != 0, status != 130 {
                        throw CursorAPIError(status: 0, message: "The agent stopped unexpectedly (exit \(status)).")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func agentStarted(_ id: String) {
        guard conversation.cursorAgentId != id else { return }
        ChatTrace.event("agent id=\(id)")
        conversation.cursorAgentId = id
        try? conversation.modelContext?.save()
    }

    func toolFinished(name: String, status: String) {
        ChatTrace.event("tool \(name) status=\(status)")
        guard let label = Self.label(tool: name, failed: status == "error") else { return }
        changes.append(label)
    }

    func stop() {
        guard let process, process.isRunning else { return }
        ChatTrace.event("runner stop pid=\(process.processIdentifier)")
        process.terminate()
    }

    func finished() {
        process = nil
    }

    private static func label(tool: String, failed: Bool) -> String? {
        for (prefix, done, attempt) in [("create_", "Added", "add"), ("update_", "Updated", "update")] {
            guard let range = tool.range(of: prefix) else { continue }
            let noun = tool[range.upperBound...].replacingOccurrences(of: "_", with: " ")
            return failed ? "Couldn’t \(attempt) \(noun)" : "\(done) \(noun)"
        }
        return nil
    }
}

struct CursorChatProvider: ChatProvider {
    let id = "cursor"
    let name = "Cursor"
    let bridge: CursorConversationBridge

    var zeroResponseMessage: String { "Cursor didn’t return a reply." }

    func stream(
        messages: [AIChatCore.ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let userText = messages.last(where: { $0.role == .user })?.content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n") ?? ""
        let bridge = bridge

        ChatTrace.event("provider.stream model=\(model) messages=\(messages.count) userChars=\(userText.count)")
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                defer { bridge.finished() }
                do {
                    guard let apiKey = KeychainStore.read() else {
                        throw CursorAPIError(status: 0, message: "Add a Cursor API key in Settings.")
                    }
                    let request = try bridge.prepare(userText: userText, apiKey: apiKey)
                    var emitted = false
                    var agentID: String?
                    for try await event in try bridge.run(request) {
                        switch event.type {
                        case "agent":
                            agentID = event.agentId
                        case "text":
                            if let text = event.text, !text.isEmpty {
                                emitted = true
                                continuation.yield(.text(text))
                            }
                        case "thinking":
                            if let text = event.text { continuation.yield(.reasoning(text)) }
                        case "tool":
                            bridge.toolFinished(name: event.name ?? "", status: event.status ?? "")
                        case "result":
                            if !emitted, let text = event.text, !text.isEmpty {
                                emitted = true
                                continuation.yield(.text(text))
                            }
                            if event.status?.lowercased() == "error" {
                                throw CursorAPIError(status: 0, message: event.error ?? "The run failed.")
                            }
                            if let agentID { bridge.agentStarted(agentID) }
                        case "error":
                            throw CursorAPIError(status: 0, message: event.message ?? "The run failed.")
                        default:
                            break
                        }
                    }
                    ChatTrace.event("provider.stream complete emitted=\(emitted)")
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    ChatTrace.event("provider.stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { @MainActor in bridge.stop() }
            }
        }
    }

    func complete(
        messages: [AIChatCore.ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult {
        throw CursorAPIError(status: 0, message: "Cursor conversations stream only.")
    }
}
