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
                    var session = try await ChatGPTSignIn.validSession()
                    let tools = try await gateway.definitions()
                    var input: [[String: Any]] = [
                        ["role": "user", "content": userText]
                    ]
                    var coalescer = StreamTextCoalescer()
                    for round in 0...ChatGPTProvider.maxToolRounds {
                        let roundTools = ChatGPTProvider.toolsForRound(round, tools: tools)
                        let payload = ChatGPTProvider.inferenceBody(
                            model: model,
                            instructions: instructions,
                            input: input,
                            tools: roundTools
                        )
                        let bytes = try await ChatGPTProvider.openAuthorizedStream(session: &session, payload: payload)
                        var calls: [Call] = []
                        var replay: [[String: Any]] = []
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            guard line.hasPrefix("data:") else { continue }
                            let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            guard raw != "[DONE]", let data = raw.data(using: .utf8),
                                  let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let type = event["type"] as? String else { continue }
                            switch type {
                            case "response.output_text.delta":
                                guard let delta = event["delta"] as? String, !delta.isEmpty else { continue }
                                if let chunk = coalescer.push(delta) {
                                    continuation.yield(.text(chunk))
                                }
                            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                                continuation.yield(.wait(ChatWaitState.thinking.label))
                            case "response.output_item.added", "response.output_item.done":
                                guard let item = event["item"] as? [String: Any] else { continue }
                                if type == "response.output_item.done" {
                                    replay.append(ChatGPTProvider.replayItem(item))
                                }
                                guard let call = Call.parse(item) else { continue }
                                if let index = calls.firstIndex(where: { $0.id == call.id }) {
                                    if type == "response.output_item.done" { calls[index] = call }
                                } else {
                                    calls.append(call)
                                }
                                continuation.yield(.wait(RunWaitLabel.forTool(call.name)))
                            case "response.failed", "error":
                                throw ChatGPTAuthError(
                                    ChatGPTProvider.apiError(from: event) ?? "ChatGPT could not complete the response."
                                )
                            default:
                                continue
                            }
                        }
                        if let leftover = coalescer.take() {
                            continuation.yield(.text(leftover))
                        }
                        if calls.isEmpty || roundTools.isEmpty { break }
                        input.append(contentsOf: replay)
                        for call in calls {
                            continuation.yield(.wait(RunWaitLabel.forTool(call.name)))
                            let output: String
                            do {
                                output = try await gateway.execute(name: call.name, arguments: call.arguments)
                            } catch {
                                output = "Error: \(error.localizedDescription)"
                            }
                            input.append([
                                "type": "function_call_output",
                                "call_id": call.id,
                                "output": output
                            ])
                        }
                    }
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

    private struct Call {
        var id: String
        var name: String
        var arguments: [String: Any]

        static func parse(_ item: [String: Any]) -> Call? {
            guard item["type"] as? String == "function_call",
                  let name = item["name"] as? String,
                  let callID = item["call_id"] as? String
            else { return nil }
            return Call(id: callID, name: name, arguments: arguments(from: item["arguments"]))
        }

        private static func arguments(from raw: Any?) -> [String: Any] {
            if let arguments = raw as? [String: Any] { return arguments }
            guard let string = raw as? String,
                  let data = string.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return arguments
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
