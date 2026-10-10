import SwiftData
import XCTest
@testable import Slate

@MainActor
final class ChatEngineTests: XCTestCase {
    func testEmptyAndWhitespaceSubmissionsAreRejected() {
        let engine = ChatEngine(provider: ScriptedChatProvider(chunks: ["ok"]), model: "m")
        XCTAssertFalse(engine.send(""))
        XCTAssertFalse(engine.send("   \n"))
        XCTAssertFalse(engine.send(ChatSubmission(text: "")))
        XCTAssertTrue(engine.entries.isEmpty)
        XCTAssertFalse(engine.isGenerating)
    }

    func testAttachmentOnlySubmissionIsAcceptedByTheEngine() async {
        let engine = ChatEngine(provider: ScriptedChatProvider(chunks: ["saw it"]), model: "m")
        let attachment = ChatAttachmentRef(id: UUID(), kind: .image, filename: "shot.png", mimeType: "image/png")
        let submission = ChatSubmission(text: "", attachments: [attachment])
        XCTAssertTrue(submission.hasContent)
        XCTAssertTrue(engine.send(submission))
        await waitUntilIdle(engine)
        XCTAssertEqual(engine.providerHistory.first?.attachments, [attachment])
        XCTAssertEqual(assistantTexts(in: engine), ["saw it"])
    }

    func testTextTurnStreamsAndCompletesInOrder() async {
        let recorder = StreamRecorder()
        let engine = ChatEngine(
            provider: ScriptedChatProvider(chunks: ["Hel", "lo"], recorder: recorder),
            model: "m"
        )
        XCTAssertTrue(engine.send("Hi"))
        await waitUntilIdle(engine)
        XCTAssertEqual(userTexts(in: engine), ["Hi"])
        XCTAssertEqual(assistantTexts(in: engine), ["Hello"])
        XCTAssertEqual(engine.providerHistory.map(\.role), [.user, .assistant])
        XCTAssertEqual(engine.providerHistory.map(\.text), ["Hi", "Hello"])
        XCTAssertEqual(recorder.models, ["m"])
        XCTAssertEqual(recorder.turns.first?.map(\.text), ["Hi"])
    }

    func testSecondTurnIncludesPriorContext() async {
        let recorder = StreamRecorder()
        let engine = ChatEngine(
            provider: ScriptedChatProvider(chunks: ["A", "B"], recorder: recorder),
            model: "m"
        )
        XCTAssertTrue(engine.send("one"))
        await waitUntilIdle(engine)
        XCTAssertTrue(engine.send("two"))
        await waitUntilIdle(engine)
        XCTAssertEqual(recorder.turns.count, 2)
        XCTAssertEqual(recorder.turns[0].map(\.text), ["one"])
        XCTAssertEqual(recorder.turns[1].map(\.text), ["one", "AB", "two"])
        XCTAssertEqual(recorder.turns[1].map(\.role), [.user, .assistant, .user])
    }

    func testToolMessagesStayInSubsequentContext() async {
        let recorder = StreamRecorder()
        let engine = ChatEngine(
            provider: ScriptedChatProvider(chunks: ["done"], recorder: recorder),
            model: "m"
        )
        let userID = UUID()
        let assistantID = UUID()
        engine.loadSnapshot(
            entries: [
                .userMessage(.init(id: userID, text: "list tasks")),
                .aiMessage(.init(id: assistantID, text: "working", isStreaming: false))
            ],
            history: [
                TalkMessage(id: userID, role: .user, text: "list tasks"),
                TalkMessage(
                    id: assistantID,
                    role: .assistant,
                    content: [.text("working")],
                    toolCalls: [TalkToolCall(id: "1", name: "list_tasks", arguments: "{}")]
                ),
                TalkMessage(id: UUID(), role: .tool, content: [.text("[]")], toolCallID: "1")
            ]
        )
        XCTAssertTrue(engine.send("now summarize"))
        await waitUntilIdle(engine)
        XCTAssertEqual(recorder.turns.last?.map(\.role), [.user, .assistant, .tool, .user])
        XCTAssertEqual(recorder.turns.last?.last?.text, "now summarize")
        XCTAssertEqual(recorder.turns.last?[1].toolCalls?.first?.name, "list_tasks")
        XCTAssertEqual(recorder.turns.last?[2].toolCallID, "1")
    }

    func testDuplicateSendIsIgnoredWhileGenerating() async {
        let provider = GatedChatProvider()
        let engine = ChatEngine(provider: provider, model: "m")
        XCTAssertTrue(engine.send("first"))
        XCTAssertTrue(engine.isGenerating)
        XCTAssertFalse(engine.send("second"))
        XCTAssertEqual(userTexts(in: engine), ["first"])
        provider.release("ok")
        await waitUntilIdle(engine)
        XCTAssertEqual(assistantTexts(in: engine), ["ok"])
    }

    func testCancelDropsUnansweredUserAndIgnoresLateEvents() async {
        let provider = GatedChatProvider()
        let engine = ChatEngine(provider: provider, model: "m")
        XCTAssertTrue(engine.send("stop me"))
        engine.cancel()
        XCTAssertFalse(engine.isGenerating)
        XCTAssertEqual(engine.providerHistory.count, 0)
        if case .userMessage(let user) = engine.entries.last {
            XCTAssertTrue(user.isCancelled)
            XCTAssertEqual(user.text, "stop me")
        } else {
            XCTFail("expected cancelled user")
        }
        provider.release("late")
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(assistantTexts(in: engine).contains("late"))
        XCTAssertFalse(engine.isGenerating)
    }

    func testCancelKeepsPartialAssistantText() async {
        let provider = GatedChatProvider()
        let engine = ChatEngine(provider: provider, model: "m")
        XCTAssertTrue(engine.send("go"))
        provider.emit("partial")
        let painted = Date().addingTimeInterval(1)
        while assistantTexts(in: engine).isEmpty, Date() < painted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        engine.cancel()
        provider.release("ignored")
        XCTAssertEqual(assistantTexts(in: engine), ["partial"])
        XCTAssertEqual(engine.providerHistory.map(\.role), [.user, .assistant])
        XCTAssertFalse(engine.entries.contains { entry in
            if case .userMessage(let user) = entry { return user.isCancelled || user.isFailed }
            return false
        })
    }

    func testProviderFailureMarksUserFailedAndAllowsRetry() async {
        let engine = ChatEngine(provider: FailingChatProvider(message: "nope"), model: "m")
        XCTAssertTrue(engine.send("please"))
        await waitUntilIdle(engine)
        XCTAssertEqual(engine.error?.localizedDescription, "nope")
        XCTAssertEqual(engine.providerHistory.count, 0)
        if case .userMessage(let user) = engine.entries.first {
            XCTAssertTrue(user.isFailed)
        } else {
            XCTFail("expected failed user")
        }
        engine.provider = ScriptedChatProvider(chunks: ["recovered"])
        XCTAssertTrue(engine.send("please"))
        await waitUntilIdle(engine)
        XCTAssertEqual(assistantTexts(in: engine), ["recovered"])
        XCTAssertNil(engine.error)
    }

    func testRuntimeReloadsExistingConversationAndPersistsNewTurn() async throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let conversation = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test")
        let user = ChatMessage(id: UUID(), role: .user, content: "old question")
        let assistant = ChatMessage(id: UUID(), role: .assistant, content: "old answer")
        conversation.messages = [user, assistant]
        container.mainContext.insert(conversation)
        try container.mainContext.save()

        let runtime = ChatRuntime(
            conversation: conversation,
            project: nil,
            provider: ScriptedChatProvider(chunks: ["new answer"])
        )
        XCTAssertEqual(userTexts(in: runtime.session), ["old question"])
        XCTAssertEqual(assistantTexts(in: runtime.session), ["old answer"])

        XCTAssertTrue(runtime.send("new question"))
        await waitUntilIdle(runtime.session)
        runtime.persist()

        let stored = conversation.orderedMessages
        XCTAssertEqual(stored.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(stored.map(\.content), ["old question", "old answer", "new question", "new answer"])
    }

    func testRuntimeSkipsFailedUserWhenPersisting() async throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let conversation = Conversation(providerID: "none", modelID: "")
        container.mainContext.insert(conversation)
        let runtime = ChatRuntime(
            conversation: conversation,
            project: nil,
            provider: FailingChatProvider(message: "down")
        )
        XCTAssertTrue(runtime.send("lost"))
        await waitUntilIdle(runtime.session)
        runtime.persist()
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertEqual(runtime.lastUserText, "lost")
    }

    func testDraftSurvivesReattachAndStaysIsolated() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let first = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test")
        let second = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test")
        container.mainContext.insert(first)
        container.mainContext.insert(second)

        let runtimeA = ChatRuntime(
            conversation: first,
            project: nil,
            provider: ScriptedChatProvider(chunks: ["ok"])
        )
        let runtimeB = ChatRuntime(
            conversation: second,
            project: nil,
            provider: ScriptedChatProvider(chunks: ["ok"])
        )
        runtimeA.draft = "keep A"
        runtimeB.draft = "keep B"

        runtimeA.reattach(in: container.mainContext)
        runtimeB.reattach(in: container.mainContext)
        runtimeA.persist()

        XCTAssertEqual(runtimeA.draft, "keep A")
        XCTAssertEqual(runtimeB.draft, "keep B")
        XCTAssertFalse(first.messages.contains { $0.content == "keep A" })

        runtimeB.draft = ""
        XCTAssertEqual(runtimeA.draft, "keep A")
        XCTAssertEqual(runtimeB.draft, "")
    }

    func testSendDoesNotClearThisOrAnotherDraft() async throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let first = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test")
        let second = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test")
        container.mainContext.insert(first)
        container.mainContext.insert(second)

        let runtimeA = ChatRuntime(
            conversation: first,
            project: nil,
            provider: ScriptedChatProvider(chunks: ["ok"])
        )
        let runtimeB = ChatRuntime(
            conversation: second,
            project: nil,
            provider: ScriptedChatProvider(chunks: ["ok"])
        )
        runtimeA.draft = "unsent A"
        runtimeB.draft = "unsent B"

        XCTAssertTrue(runtimeA.send("go"))
        await waitUntilIdle(runtimeA.session)
        XCTAssertEqual(runtimeA.draft, "unsent A")
        XCTAssertEqual(runtimeB.draft, "unsent B")
    }

    private func waitUntilIdle(_ engine: ChatEngine, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while engine.isGenerating, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(engine.isGenerating, file: file, line: line)
    }

    private func userTexts(in engine: ChatEngine) -> [String] {
        engine.entries.compactMap { entry in
            if case .userMessage(let user) = entry, !user.isCancelled, !user.isFailed { return user.text }
            return nil
        }
    }

    private func assistantTexts(in engine: ChatEngine) -> [String] {
        engine.entries.compactMap { entry in
            if case .aiMessage(let assistant) = entry { return assistant.text }
            return nil
        }
    }
}

private final class StreamRecorder: @unchecked Sendable {
    var turns: [[TalkMessage]] = []
    var models: [String] = []
}

private struct ScriptedChatProvider: ChatProvider {
    var id = "script"
    var name = "Script"
    var zeroResponseMessage = "No reply."
    var chunks: [String]
    var recorder: StreamRecorder?

    func stream(
        messages: [TalkMessage],
        model: String,
        options: ChatTurnOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let chunks = chunks
        let recorder = recorder
        return AsyncThrowingStream { continuation in
            recorder?.turns.append(messages)
            recorder?.models.append(model)
            for chunk in chunks {
                continuation.yield(.text(chunk))
            }
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

private struct FailingChatProvider: ChatProvider, Error, LocalizedError {
    var id = "fail"
    var name = "Fail"
    var zeroResponseMessage = "No reply."
    var message: String
    var errorDescription: String? { message }

    func stream(
        messages: [TalkMessage],
        model: String,
        options: ChatTurnOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let failure = self
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: failure)
        }
    }
}

private final class GatedChatProvider: ChatProvider, @unchecked Sendable {
    var id = "gated"
    var name = "Gated"
    var zeroResponseMessage = "No reply."
    private var continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation?

    func stream(
        messages: [TalkMessage],
        model: String,
        options: ChatTurnOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func emit(_ text: String) {
        continuation?.yield(.text(text))
    }

    func release(_ text: String) {
        if !text.isEmpty {
            continuation?.yield(.text(text))
        }
        continuation?.yield(.done)
        continuation?.finish()
        continuation = nil
    }
}
