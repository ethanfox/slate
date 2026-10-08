import AIChatCore
import Foundation

struct ChatGPTProvider: ChatProvider {
    let id = "chatgpt"
    let name = "ChatGPT"
    let bridge: CursorConversationBridge
    var includeSlateTools = true
    var includeProjectTools = true

    var zeroResponseMessage: String { "ChatGPT didn’t return a reply." }

    func stream(
        messages: [AIChatCore.ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let bridge = bridge
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                defer { bridge.finished() }
                do {
                    guard !model.isEmpty else {
                        throw ChatGPTAuthError("Choose a ChatGPT model in Settings.")
                    }
                    let session = try await ChatGPTSignIn.validSession()
                    let userText = Self.text(from: messages.last(where: { $0.role == .user }))
                    let instructions = bridge.prepareProviderTurn(
                        userText: userText,
                        includeSlateTools: includeSlateTools
                    )
                    let roots = includeProjectTools ? try await bridge.prepareCodeRoots() : []
                    let gateway = SlateToolGateway(
                        roots: roots,
                        includeSlateTools: includeSlateTools,
                        includeProjectTools: includeProjectTools
                    )
                    let tools = try await gateway.definitions()
                    var input: [[String: Any]] = messages.map(Self.responseInput)
                    var emitted = false
                    for round in 0..<8 {
                        let payload = Self.inferenceBody(
                            model: model,
                            instructions: instructions,
                            input: input,
                            tools: tools
                        )
                        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
                        request.httpMethod = "POST"
                        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                        ChatTrace.event("chatgpt request model=\(model) tools=\(tools.count) input=\(input.count)")

                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard (200..<300).contains(status) else {
                            var data = Data()
                            for try await byte in bytes { data.append(byte) }
                            let detail = Self.apiError(from: data)
                            ChatTrace.event("chatgpt http \(status): \(ChatTrace.clip(detail ?? String(data: data, encoding: .utf8) ?? "", 800))")
                            throw ChatGPTAuthError(detail ?? "ChatGPT request failed (\(status)).")
                        }

                        var calls: [FunctionCall] = []
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
                                emitted = true
                                bridge.appendText(delta)
                                continuation.yield(.text(delta))
                                await Task.yield()
                            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                                bridge.markThinking(event["delta"] as? String)
                            case "response.output_item.done":
                                if let item = event["item"] as? [String: Any] {
                                    replay.append(Self.replayItem(item))
                                    if item["type"] as? String == "function_call",
                                       let name = item["name"] as? String,
                                       let callID = item["call_id"] as? String {
                                        calls.append(FunctionCall(
                                            id: callID,
                                            name: name,
                                            arguments: Self.arguments(from: item["arguments"])
                                        ))
                                    }
                                }
                            case "response.failed", "error":
                                throw ChatGPTAuthError(Self.apiError(from: event) ?? "ChatGPT could not complete the response.")
                            default:
                                continue
                            }
                        }
                        if calls.isEmpty { break }
                        input.append(contentsOf: replay)
                        for call in calls {
                            bridge.applyTool(name: call.name, status: "running", id: call.id)
                            do {
                                let result = try await gateway.execute(name: call.name, arguments: call.arguments)
                                bridge.applyTool(
                                    name: call.name,
                                    status: "completed",
                                    id: call.id,
                                    sources: Self.sources(tool: call.name, result: result)
                                )
                                input.append([
                                    "type": "function_call_output",
                                    "call_id": call.id,
                                    "output": result
                                ])
                            } catch {
                                bridge.applyTool(name: call.name, status: "error", id: call.id, detail: error.localizedDescription)
                                input.append([
                                    "type": "function_call_output",
                                    "call_id": call.id,
                                    "output": "Error: \(error.localizedDescription)"
                                ])
                            }
                        }
                        if round == 7 {
                            throw ChatGPTAuthError("ChatGPT exceeded the tool-call limit.")
                        }
                    }
                    bridge.completeRunningTools()
                    if !emitted {
                        bridge.debugLog.add("chatgpt stream completed without text")
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch is CancellationError {
                    bridge.stop()
                    continuation.finish()
                } catch {
                    bridge.failRunningTools()
                    ChatTrace.event("chatgpt stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
            }
        }
    }

    func complete(
        messages: [AIChatCore.ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult {
        throw ChatGPTAuthError("ChatGPT conversations stream only.")
    }

    static func inferenceBody(
        model: String,
        instructions: String,
        input: [[String: Any]],
        tools: [[String: Any]]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "store": false,
            "stream": true
        ]
        if !tools.isEmpty {
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        }
        return payload
    }

    private static func responseInput(_ message: AIChatCore.ChatMessage) -> [String: Any] {
        [
            "role": message.role == .assistant ? "assistant" : "user",
            "content": text(from: message)
        ]
    }

    static func replayItem(_ item: [String: Any]) -> [String: Any] {
        var replay = item
        replay.removeValue(forKey: "id")
        replay.removeValue(forKey: "status")
        return replay
    }

    private static func text(from message: AIChatCore.ChatMessage?) -> String {
        guard let message else { return "" }
        return message.content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    static func apiError(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = apiError(from: object) {
            return message
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            var raw = line.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("data:") {
                raw = raw.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
            guard let lineData = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = apiError(from: object)
            else { continue }
            return message
        }
        let clipped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.isEmpty ? nil : String(clipped.prefix(400))
    }

    static func apiError(from object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            return structuredError(error)
        }
        if let response = object["response"] as? [String: Any],
           let error = response["error"] as? [String: Any] {
            return structuredError(error)
        }
        if let detail = object["detail"] as? String, !detail.isEmpty {
            return detail
        }
        return object["message"] as? String
    }

    private static func structuredError(_ error: [String: Any]) -> String? {
        let message = error["message"] as? String
        let code = error["code"] as? String
        let param = error["param"] as? String
        var parts: [String] = []
        if let message, !message.isEmpty { parts.append(message) }
        if let code, !code.isEmpty, message?.contains(code) != true { parts.append(code) }
        if let param, !param.isEmpty { parts.append("param: \(param)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func arguments(from raw: Any?) -> [String: Any] {
        if let arguments = raw as? [String: Any] { return arguments }
        guard let string = raw as? String,
              let data = string.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return arguments
    }

    private static func sources(tool: String, result: String) -> [RunnerSource]? {
        let lower = tool.lowercased()
        let kind: String
        if lower.contains("decision") {
            kind = "decision"
        } else if lower.contains("thread") {
            kind = "thread"
        } else if lower.contains("note") {
            kind = "note"
        } else if lower.contains("project") && !lower.hasPrefix("project_") {
            kind = "project"
        } else {
            return nil
        }
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let records = sourceRecords(from: object)
        guard !records.isEmpty else { return nil }
        return records.prefix(lower.hasPrefix("get_") ? 1 : 8).map { record in
            RunnerSource(
                id: record.id,
                title: record.title,
                url: record.id.map { "slate://\(kind)/\($0)" },
                kind: kind,
                pin: lower.hasPrefix("get_")
            )
        }
    }

    private static func sourceRecords(from value: Any) -> [(id: String?, title: String)] {
        if let items = value as? [Any] {
            return items.flatMap(sourceRecords)
        }
        guard let object = value as? [String: Any] else { return [] }
        let id = object["id"] as? String
        let title = object["title"] as? String ?? object["name"] as? String
        if let title { return [(id, title)] }
        return object.values.flatMap(sourceRecords)
    }

    private struct FunctionCall {
        var id: String
        var name: String
        var arguments: [String: Any]
    }
}

struct UnavailableChatProvider: ChatProvider {
    let id: String
    let name: String
    let message: String

    var zeroResponseMessage: String { message }

    func stream(
        messages: [AIChatCore.ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ChatGPTAuthError(message))
        }
    }

    func complete(
        messages: [AIChatCore.ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult {
        throw ChatGPTAuthError(message)
    }
}
