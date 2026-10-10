import Foundation
import Observation

/// Slate-owned chat session. Owns submission, provider streaming, and turn lifecycle.
@MainActor
@Observable
final class ChatEngine {
    private(set) var entries: [ChatEntry] = []
    private(set) var isGenerating = false
    private(set) var error: Error?
    var provider: any ChatProvider
    var model: String
    var onChange: (() -> Void)?
    var traceObjectID = ""
    var traceRuntime = "-"

    private var history: [TalkMessage] = []
    private let stream = StreamWork()
    private var generationID = 0
    private var activeAssistantID: UUID?
    private var rawText = ""

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
        startGeneration(options: options)
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
        finishTurn(cancelled: true, streamError: nil)
    }

    func loadSnapshot(entries: [ChatEntry], history: [TalkMessage]) {
        stream.cancel()
        generationID += 1
        isGenerating = false
        error = nil
        activeAssistantID = nil
        rawText = ""
        self.entries = entries
        self.history = history
        noteChange()
    }

    var providerHistory: [TalkMessage] { history }

    private func startGeneration(options: ChatTurnOptions) {
        stream.cancel()
        generationID += 1
        let myGeneration = generationID
        isGenerating = true
        error = nil
        activeAssistantID = nil
        rawText = ""
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
            rawText += text
            ensureAssistant()
            appendAssistant(text)
        case .done:
            break
        }
    }

    private func finishTurn(cancelled: Bool, streamError: Error?) {
        stream.task = nil
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let assistantID = activeAssistantID {
            if text.isEmpty {
                entries.removeAll { entry in
                    if case .aiMessage(let assistant) = entry { return assistant.id == assistantID }
                    return false
                }
            } else {
                updateAssistant(id: assistantID) { assistant in
                    assistant.text = rawText
                    assistant.isStreaming = false
                }
                history.append(TalkMessage(id: assistantID, role: .assistant, text: rawText))
            }
        }

        if text.isEmpty {
            if cancelled {
                markLastUser(cancelled: true)
            } else {
                markLastUser(failed: true)
            }
        }

        if let streamError {
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

    private func ensureAssistant() {
        guard activeAssistantID == nil else { return }
        let id = UUID()
        activeAssistantID = id
        entries.append(.aiMessage(.init(id: id, text: "", isStreaming: true)))
    }

    private func appendAssistant(_ text: String) {
        guard let id = activeAssistantID else { return }
        updateAssistant(id: id) { $0.text += text }
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
