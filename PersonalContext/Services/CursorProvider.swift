import AIChatCore
import Foundation

@MainActor
final class CursorConversationBridge {
    let conversation: Conversation
    let project: Project?
    private(set) var currentRunID = ""

    init(conversation: Conversation, project: Project?) {
        self.conversation = conversation
        self.project = project
    }

    func prepare(userText: String) -> (agentID: String, prompt: String, name: String, model: String) {
        let opening = conversation.cursorAgentId.isEmpty
        ChatTrace.event("prepare conversation=\(conversation.id) opening=\(opening) agent=\(conversation.cursorAgentId) model=\(conversation.model) project=\(project?.name ?? "none") textChars=\(userText.count)")
        if conversation.title == "New chat" || conversation.title.isEmpty {
            conversation.title = conversationTitle(from: userText)
        }
        var context = ""
        if opening, let project {
            context = ContextBuilder.package(for: project)
            conversation.contextSnapshot = context
        }
        conversation.updatedAt = .now
        project?.touch()
        return (
            conversation.cursorAgentId,
            ContextBuilder.prompt(userText: userText, context: context, opening: opening),
            conversation.title,
            conversation.model
        )
    }

    func agentCreated(id: String, url: String?) {
        ChatTrace.event("agentCreated id=\(id) url=\(url ?? "")")
        conversation.cursorAgentId = id
        conversation.cursorURL = url ?? ""
        try? conversation.modelContext?.save()
    }

    func runStarted(_ id: String) {
        ChatTrace.event("runStarted id=\(id)")
        currentRunID = id
    }

    func runFinished() {
        ChatTrace.event("runFinished id=\(currentRunID)")
        currentRunID = ""
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
            let task = Task {
                guard let apiKey = KeychainStore.read() else {
                    ChatTrace.event("provider.stream abort: no API key")
                    continuation.finish(throwing: CursorAPIError(status: 0, message: "Add a Cursor API key in Settings."))
                    return
                }
                ChatTrace.event("provider.stream keyPresent=true")
                let client = CursorClient(apiKey: apiKey)
                let plan = await bridge.prepare(userText: userText)
                var agentID = plan.agentID
                var runID = ""
                do {
                    if agentID.isEmpty {
                        let created = try await client.createAgent(name: plan.name, prompt: plan.prompt, modelID: plan.model)
                        agentID = created.agent.id
                        runID = created.run.id
                        await bridge.agentCreated(id: agentID, url: created.agent.url)
                    } else {
                        runID = try await client.createRun(agentID: agentID, prompt: plan.prompt).id
                    }
                    await bridge.runStarted(runID)

                    var emitted = false
                    streamLoop: for try await event in client.stream(agentID: agentID, runID: runID) {
                        switch event {
                        case .assistant(let text):
                            emitted = true
                            continuation.yield(.text(text))
                        case .thinking(let text):
                            continuation.yield(.reasoning(text))
                        case .result(let status, let text):
                            if !emitted, let text, !text.isEmpty {
                                emitted = true
                                continuation.yield(.text(text))
                            }
                            if status == "ERROR" {
                                throw CursorAPIError(status: 0, message: "The run failed.")
                            }
                            break streamLoop
                        case .error(let message):
                            if Self.isTransientStreamError(message) {
                                ChatTrace.event("transient stream drop: \(message)")
                                break streamLoop
                            }
                            throw CursorAPIError(status: 0, message: message)
                        case .done:
                            break streamLoop
                        case .status, .tool:
                            break
                        }
                    }
                    if !emitted {
                        let finished = try await client.waitForRun(agentID: agentID, runID: runID)
                        if let text = finished.result, !text.isEmpty {
                            ChatTrace.event("provider.stream polled result chars=\(text.count) status=\(finished.status)")
                            continuation.yield(.text(text))
                            emitted = true
                        } else if finished.status.uppercased() == "ERROR" {
                            throw CursorAPIError(status: 0, message: "The run failed.")
                        }
                    }
                    ChatTrace.event("provider.stream complete emitted=\(emitted)")
                    await bridge.runFinished()
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    ChatTrace.event("provider.stream error: \(error.localizedDescription)")
                    await bridge.runFinished()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { @MainActor in
                    let agentID = bridge.conversation.cursorAgentId
                    let runID = bridge.currentRunID
                    bridge.runFinished()
                    guard !agentID.isEmpty, !runID.isEmpty, let apiKey = KeychainStore.read() else { return }
                    try? await CursorClient(apiKey: apiKey).cancel(agentID: agentID, runID: runID)
                }
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

    private static func isTransientStreamError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("stream_unavailable")
            || lower.contains("no longer available")
            || lower.contains("stream_expired")
    }
}
