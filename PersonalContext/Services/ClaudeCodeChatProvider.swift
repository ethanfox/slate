import Foundation

/// Claude Code as a chat model, on the user's own install and login. Debug builds only, until Anthropic says
/// whether an app may run a user's Claude Code subscription this way.
///
/// Each message is one turn of a Claude Code conversation that Membrae resumes, so it keeps what it knew.
/// It can read and file into Membrae and search the web; it cannot change files or run commands.
struct ClaudeCodeChatProvider: ChatProvider {
    let id = TalkProvider.claudeCode.rawValue
    let name = "Claude Code"
    let workspace: ChatWorkspace

    var zeroResponseMessage: String { "Claude Code didn’t return a reply." }

    /// Claude Code's own names for its models.
    static let models: [(id: String, name: String)] = [
        (id: "sonnet", name: "Sonnet"),
        (id: "opus", name: "Opus"),
        (id: "haiku", name: "Haiku")
    ]

    func attach(conversation: Conversation, project: Project?) {
        workspace.attach(conversation: conversation, project: project)
    }

    func stream(
        messages: [TalkMessage],
        model: String,
        options: ChatTurnOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let workspace = workspace
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let process = LocalAgentProcess()
                do {
                    guard let executable = LocalAgent.claudeCode.locate() else {
                        throw LocalAgentError("Claude Code is not installed on this Mac.")
                    }
                    let request = Self.request(messages: messages, model: model, workspace: workspace)
                    continuation.yield(.metadata(request.metadata))
                    continuation.yield(.wait(.starting))
                    var streamedThisMessage = false
                    var wroteText = false
                    var needsBreak = false
                    var toolRunning = false
                    func write(_ text: String) {
                        if toolRunning {
                            continuation.yield(.completeRunningTools)
                            toolRunning = false
                        }
                        if needsBreak, wroteText {
                            continuation.yield(.text("\n\n"))
                        }
                        needsBreak = false
                        wroteText = true
                        continuation.yield(.text(text))
                    }
                    for try await event in try process.start(.claudeCode, executable: executable, request: request.agent) {
                        try Task.checkCancellation()
                        switch event {
                        case .textDelta(let piece):
                            streamedThisMessage = true
                            write(piece)
                        case .text(let text):
                            // A message that came without its pieces is written whole.
                            if !streamedThisMessage { write(text) }
                            streamedThisMessage = false
                            needsBreak = true
                        case .activity(let label):
                            if label == "Thinking" {
                                continuation.yield(.wait(.thinking))
                                continue
                            }
                            if toolRunning { continuation.yield(.completeRunningTools) }
                            toolRunning = true
                            needsBreak = true
                            continuation.yield(.tool(name: label, status: "running", id: UUID().uuidString, detail: nil, sources: []))
                        case .session(let session):
                            continuation.yield(.metadata(ChatTurnMetadata(externalSessionID: session)))
                        case .finished(let summary, _):
                            if !wroteText, !summary.isEmpty { write(summary) }
                        case .usage:
                            break
                        case .failed(let message):
                            throw LocalAgentError(message)
                        }
                    }
                    process.stop()
                    continuation.yield(.completeRunningTools)
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    process.stop()
                    continuation.yield(.failRunningTools)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor
    private static func request(messages: [TalkMessage], model: String, workspace: ChatWorkspace) -> (agent: LocalAgentRequest, metadata: ChatTurnMetadata) {
        let conversation = workspace.conversation
        let last = messages.last(where: { $0.role == .user })
        var text = last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let turn = workspace.prepareTurn(userText: text)
        // Files go by path: Claude Code runs on this Mac and opens them itself.
        if let context = conversation.modelContext, let last, !last.attachments.isEmpty {
            let store = FileStore.default(context: context)
            let paths = last.attachments.compactMap { ref in store.asset(id: ref.id).map { store.resolve($0).path } }
            if !paths.isEmpty {
                text += (text.isEmpty ? "" : "\n\n") + "Attached files:\n" + paths.map { "- \($0)" }.joined(separator: "\n")
            }
        }
        let session = conversation.externalSessionID
        // A chat that began with another model brings its earlier messages along the first time.
        if session.isEmpty, let earlier = TalkMessage.conversationTranscript(messages) {
            text = "Our conversation so far:\n\n\(earlier)\n\nMy message now:\n\n\(text)"
        }
        let folder = conversation.modelContext?.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("Agent", isDirectory: true)
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let tools = RunToolPolicy.chat(spaceID: workspace.project?.id).allowedNames(from: RunToolPolicy.membraeCatalog)
        let agent = LocalAgentRequest(
            prompt: text,
            directory: folder?.path ?? NSTemporaryDirectory(),
            allowEdits: false,
            mcpCommand: Bundle.main.url(forAuxiliaryExecutable: "membrae-mcp")?.path,
            membraeTools: tools,
            runID: "",
            resumeSessionID: session.isEmpty ? nil : session,
            chatOnly: true,
            model: model,
            systemPrompt: turn.prompt
        )
        return (agent, turn.metadata)
    }
}
