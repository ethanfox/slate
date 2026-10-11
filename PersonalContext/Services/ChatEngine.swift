import Foundation
import Observation

/// One conversation session's execution owner. Applies provider events to a canonical turn.
@MainActor
@Observable
final class ChatEngine {
    private(set) var entries: [ChatEntry] = []
    private(set) var isGenerating = false
    private(set) var error: Error?
    private(set) var pendingMetadata = ChatTurnMetadata()
    var provider: any ChatProvider
    var model: String
    var onChange: (() -> Void)?
    var onFinish: (() -> Void)?
    var traceObjectID = ""
    var traceRuntime = "-"

    private var history: [TalkMessage] = []
    private let stream = StreamWork()
    private var generationID = 0
    private var removedMessageIDs: [UUID] = []
    private var activeAssistantID: UUID?
    private var rawText = ""
    private var turn = ChatTurnState()

    init(provider: any ChatProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    /// Text convenience. Same validation as `send(_ submission:)`.
    @discardableResult
    func send(_ text: String) -> Bool {
        send(ChatSubmission(text: text))
    }

    @discardableResult
    func send(_ submission: ChatSubmission, options: ChatTurnOptions = ChatTurnOptions()) -> Bool {
        guard !isGenerating else { return false }
        guard submission.hasContent else { return false }

        let text = submission.trimmedText
        error = nil
        let userID = UUID()
        var content: [TalkContent] = []
        if !text.isEmpty {
            content.append(.text(text))
        }
        content.append(contentsOf: submission.attachments.map { .attachment($0) })
        entries.append(.userMessage(.init(id: userID, text: text, attachments: submission.attachments)))
        history.append(TalkMessage(id: userID, role: .user, content: content))
        noteChange()
        startGeneration(options: options, userID: userID)
        return true
    }

    func failValidation(_ error: Error) {
        self.error = error
        noteChange()
    }

    func cancel() {
        guard isGenerating else { return }
        stream.cancel()
        generationID += 1
        turn.failRunningTools()
        finishTurn(cancelled: true, streamError: nil)
    }

    func loadSnapshot(entries: [ChatEntry], history: [TalkMessage]) {
        stream.cancel()
        generationID += 1
        isGenerating = false
        error = nil
        activeAssistantID = nil
        rawText = ""
        turn = ChatTurnState()
        pendingMetadata = ChatTurnMetadata()
        removedMessageIDs = []
        self.entries = entries
        self.history = history
        noteChange()
    }

    func takeRemovedIDs() -> [UUID] {
        let ids = removedMessageIDs
        removedMessageIDs = []
        return ids
    }

    /// Adopts store messages that this session does not already own. Live entries win on ID collision.
    func mergeFromStore(entries: [ChatEntry], history: [TalkMessage]) {
        var merged = entries.map { store in
            guard let id = store.messageID, let live = self.entries.first(where: { $0.messageID == id }) else {
                return store
            }
            return live
        }
        merged.append(contentsOf: self.entries.filter { entry in
            guard let id = entry.messageID else { return true }
            return !entries.contains { $0.messageID == id }
        })
        var mergedHistory = history.map { store in
            self.history.first(where: { $0.id == store.id }) ?? store
        }
        mergedHistory.append(contentsOf: self.history.filter { live in
            !history.contains { $0.id == live.id }
        })
        self.entries = merged
        self.history = mergedHistory
        noteChange()
    }

    var providerHistory: [TalkMessage] { history }

    var currentTurn: ChatTurnState { turn }

    func takeMetadata() -> ChatTurnMetadata {
        let value = pendingMetadata
        pendingMetadata = ChatTurnMetadata()
        return value
    }

    private func startGeneration(options: ChatTurnOptions, userID: UUID) {
        stream.cancel()
        generationID += 1
        let myGeneration = generationID
        isGenerating = true
        error = nil
        activeAssistantID = nil
        rawText = ""
        pendingMetadata = ChatTurnMetadata()
        turn.begin(userID: userID)
        ensureAssistant()
        DraftTrace.streamStart(object: traceObjectID, runtime: traceRuntime, model: model)
        noteChange()

        let events = provider.stream(
            messages: history,
            model: model,
            options: options
        )
        stream.task = Task { [weak self] in
            do {
                for try await event in events {
                    try Task.checkCancellation()
                    await MainActor.run { [weak self] in
                        guard let self, self.generationID == myGeneration else { return }
                        self.handle(event)
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self, self.generationID == myGeneration else { return }
                    self.finishTurn(cancelled: false, streamError: nil)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generationID == myGeneration else { return }
                    self.finishTurn(cancelled: false, streamError: error)
                }
            }
        }
    }

    private func handle(_ event: ChatStreamEvent) {
        switch event {
        case .text(let text):
            guard applyIncomingText(text) else { return }
            ensureAssistant()
            publishTurn(streaming: true)
        case .reasoning(let text):
            turn.markThinking(text)
            ensureAssistant()
            publishTurn(streaming: true)
        case .wait(let state):
            turn.waitState = state
            ensureAssistant()
            publishTurn(streaming: true)
        case .status(let status):
            turn.applyStatus(status)
            ensureAssistant()
            publishTurn(streaming: true)
        case .tool(let name, let status, let id, let detail, let sources):
            turn.applyTool(name: name, status: status, id: id, detail: detail, sources: sources)
            ensureAssistant()
            publishTurn(streaming: true)
        case .sources(let sources):
            turn.mergeSources(sources)
            ensureAssistant()
            publishTurn(streaming: true)
        case .metadata(let metadata):
            if let id = metadata.externalSessionID { pendingMetadata.externalSessionID = id }
            if let title = metadata.title { pendingMetadata.title = title }
            if let snapshot = metadata.contextSnapshot { pendingMetadata.contextSnapshot = snapshot }
            noteChange()
        case .completeRunningTools:
            turn.completeRunningTools()
            publishTurn(streaming: true)
        case .failRunningTools:
            turn.failRunningTools()
            publishTurn(streaming: true)
        case .done:
            break
        }
    }

    private func finishTurn(cancelled: Bool, streamError: Error?) {
        guard isGenerating else { return }
        stream.task = nil
        if cancelled || streamError != nil {
            turn.failRunningTools()
        } else {
            turn.completeRunningTools()
        }
        turn.finish()
        let text = visibleReplyText
        if let assistantID = activeAssistantID {
            if text.isEmpty, turn.tools.isEmpty, turn.thinking.isEmpty {
                entries.removeAll { entry in
                    if case .aiMessage(let assistant) = entry { return assistant.id == assistantID }
                    return false
                }
                removedMessageIDs.append(assistantID)
            } else {
                updateAssistant(id: assistantID) { assistant in
                    assistant = turn.published(onto: assistant, text: text, streaming: false)
                }
                if !text.isEmpty, !history.contains(where: { $0.id == assistantID }) {
                    history.append(TalkMessage(id: assistantID, role: .assistant, text: text))
                }
            }
        }

        if text.isEmpty {
            if cancelled {
                markLastUser(cancelled: true)
            } else {
                markLastUser(failed: true)
            }
        }

        if let streamError, text.isEmpty {
            error = streamError
            let message = (streamError as? LocalizedError)?.errorDescription ?? streamError.localizedDescription
            entries.append(.activity(.init(id: UUID(), text: "⚠️ \(message)", isError: true)))
        } else if !cancelled && text.isEmpty {
            entries.append(
                .activity(.init(id: UUID(), text: "⚠️ \(provider.zeroResponseMessage)", isError: true))
            )
        }

        rawText = ""
        activeAssistantID = nil
        isGenerating = false
        noteChange()
        onFinish?()
    }

    private func markLastUser(cancelled: Bool = false, failed: Bool = false) {
        guard let last = history.last, last.role == .user else { return }
        history.removeLast()
        for index in entries.indices {
            guard case .userMessage(var user) = entries[index], user.id == last.id else { continue }
            user.isCancelled = cancelled
            user.isFailed = failed
            entries[index] = .userMessage(user)
            break
        }
    }

    private var visibleReplyText: String {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        return turn.joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func applyIncomingText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if !rawText.isEmpty, text.hasPrefix(rawText) {
            let delta = String(text.dropFirst(rawText.count))
            rawText = text
            if !delta.isEmpty { turn.appendContinuation(delta) }
            return !delta.isEmpty
        }
        if !rawText.isEmpty, rawText.hasPrefix(text) {
            return false
        }
        rawText += text
        turn.appendText(text)
        return true
    }

    private func ensureAssistant() {
        guard activeAssistantID == nil else { return }
        let id = UUID()
        activeAssistantID = id
        var assistant = ChatEntry.Assistant(id: id, text: "", isStreaming: true)
        assistant = turn.published(onto: assistant, text: rawText, streaming: true)
        entries.append(.aiMessage(assistant))
    }

    private func publishTurn(streaming: Bool) {
        guard let id = activeAssistantID else { return }
        updateAssistant(id: id) { assistant in
            assistant = turn.published(onto: assistant, text: rawText, streaming: streaming)
        }
        noteChange()
    }

    private func updateAssistant(id: UUID, mutate: (inout ChatEntry.Assistant) -> Void) {
        for index in entries.indices {
            guard case .aiMessage(var assistant) = entries[index], assistant.id == id else { continue }
            mutate(&assistant)
            entries[index] = .aiMessage(assistant)
            return
        }
    }

    private func noteChange() {
        onChange?()
    }
}

private final class StreamWork: @unchecked Sendable {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
