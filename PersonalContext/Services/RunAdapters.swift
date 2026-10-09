import Foundation

enum RunLiveEvent {
    case wait(String)
    case text(String)
    case citation(url: String, title: String)
}

@MainActor
final class RunCursorProcess {
    private var process: Process?
    private var processInput: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var events: AsyncThrowingStream<RunnerEvent, Error>.Continuation?

    func start(_ request: RunnerRequest) throws -> AsyncThrowingStream<RunnerEvent, Error> {
        stop()
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
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        let exits = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        self.process = process
        self.processInput = input.fileHandleForWriting
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: payload)
        return AsyncThrowingStream { continuation in
            self.events = continuation
            self.readerTask = Task.detached { [weak self] in
                var sawEnd = false
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        guard let event = try? JSONDecoder().decode(RunnerEvent.self, from: Data(line.utf8)) else { continue }
                        if event.type == "result" || event.type == "error" { sawEnd = true }
                        await self?.yield(event)
                    }
                } catch {
                    await self?.fail(error)
                }
                var status: Int32 = 0
                for await code in exits { status = code }
                await self?.died(status: status, sawEnd: sawEnd)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
    }

    func replyToHostTool(id: String, text: String? = nil, error: String? = nil) {
        guard let processInput else { return }
        var payload: [String: String] = ["type": "host_tool_result", "id": id]
        if let text { payload["text"] = text }
        if let error { payload["error"] = error }
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        try? processInput.write(contentsOf: data)
    }

    func stop() {
        events?.finish()
        events = nil
        readerTask?.cancel()
        readerTask = nil
        try? processInput?.close()
        processInput = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func yield(_ event: RunnerEvent) {
        events?.yield(event)
        if event.type == "result" || event.type == "error" {
            events?.finish()
            events = nil
        }
    }

    private func fail(_ error: Error) {
        events?.finish(throwing: error)
        events = nil
    }

    private func died(status: Int32, sawEnd: Bool) {
        if events != nil, !sawEnd, status != 0, status != 130 {
            fail(CursorAPIError(status: 0, message: "The agent stopped unexpectedly (exit \(status))."))
        } else {
            events?.finish()
            events = nil
        }
        processInput = nil
        process = nil
        readerTask = nil
    }
}

enum RunChatGPT {
    static func stream(
        instructions: String,
        userText: String,
        model: String,
        gateway: RunGateway
    ) -> AsyncThrowingStream<RunLiveEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var coalescer = StreamTextCoalescer()
                    let tools = try await gateway.definitions()
                    try await AgentRuntime.run(
                        instructions: instructions,
                        input: [["role": "user", "content": userText]],
                        tools: tools,
                        maxRounds: ChatGPTProvider.maxToolRounds,
                        transport: ChatGPTTransport(model: model),
                        gateway: gateway,
                        onEvent: { event in
                            switch event {
                            case .text(let delta):
                                if let chunk = coalescer.push(delta) {
                                    continuation.yield(.text(chunk))
                                }
                            case .thinking:
                                continuation.yield(.wait(ChatWaitState.thinking.label))
                            case .callStarted(let call), .callFinished(let call, _):
                                continuation.yield(.wait(RunWaitLabel.forTool(call.name)))
                            }
                        }
                    )
                    if let leftover = coalescer.take() {
                        continuation.yield(.text(leftover))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
            }
        }
    }
}

enum RunWaitLabel {
    static func forTool(_ name: String) -> String {
        switch name {
        case "webSearch": return "Searching the web"
        case "webFetch": return "Fetching a page"
        case "create_note", "update_note": return "Writing a note"
        case RunToolPolicy.finishRun: return ChatWaitState.writing.label
        default:
            return ChatToolActivity.title(for: name, status: .running)
        }
    }

    static func forCursor(_ event: RunnerEvent) -> String? {
        if event.type == "tool", let name = event.name {
            return forTool(name)
        }
        switch event.type {
        case "status" where event.status?.uppercased() == "CREATING":
            return ChatWaitState.starting.label
        case "thinking":
            return ChatWaitState.thinking.label
        case "text":
            return ChatWaitState.writing.label
        default:
            return nil
        }
    }
}

enum RunPrompt {
    static func closeInstruction(hasProject: Bool) -> String {
        if hasProject {
            return "Do the job with the tools you have. Call finish_run with a short summary when you are done. Do not complete the assigned task."
        }
        return "Do the job. Call finish_run with a short summary when you are done. You have no project to write into."
    }

    static func body(brief: String, project: Project?) -> String {
        let context = project.map(ContextBuilder.identity(for:)) ?? ""
        let close = closeInstruction(hasProject: project != nil)
        if context.isEmpty {
            return "\(close)\n\n\(brief)"
        }
        return "\(context)\n\n\(close)\n\n\(brief)"
    }
}
