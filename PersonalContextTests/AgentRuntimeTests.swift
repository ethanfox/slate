import XCTest
@testable import Slate

final class AgentRuntimeTests: XCTestCase {
    func testDeniedToolNeverReachesInnerGateway() async throws {
        let inner = RecordingGateway()
        let gateway = await MainActor.run {
            RunGateway(
                policy: RunToolPolicy(
                    runID: UUID(),
                    projectID: UUID(),
                    assignedTaskID: nil,
                    allowCode: false
                ),
                inner: inner
            )
        }
        let transport = ScriptedTransport(turns: [
            AgentModelTurn(
                calls: [AgentProposedCall(id: "1", name: "complete_task", arguments: ["task_id": UUID().uuidString])],
                replay: []
            ),
            AgentModelTurn(calls: [], replay: [])
        ])
        var outputs: [String] = []
        try await AgentRuntime.run(
            instructions: "",
            input: [["role": "user", "content": "done"]],
            tools: [["type": "function", "name": "complete_task"]],
            maxRounds: 2,
            transport: transport,
            gateway: gateway,
            onEvent: { event in
                if case .callFinished(_, let output) = event {
                    outputs.append(output)
                }
            }
        )
        XCTAssertTrue(inner.executed.isEmpty)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertTrue(outputs[0].hasPrefix("Error:"))
    }

    func testCancellationPreventsLaterCalls() async throws {
        let gateway = RecordingGateway()
        let transport = ScriptedTransport(turns: [
            AgentModelTurn(
                calls: [
                    AgentProposedCall(id: "1", name: "list_tasks", arguments: [:]),
                    AgentProposedCall(id: "2", name: "create_task", arguments: ["title": "Nope"])
                ],
                replay: []
            )
        ])
        let task = Task {
            try await AgentRuntime.run(
                instructions: "",
                input: [["role": "user", "content": "work"]],
                tools: [["type": "function", "name": "list_tasks"]],
                maxRounds: 2,
                transport: transport,
                gateway: gateway,
                onEvent: { _ in }
            )
        }
        gateway.cancelAfter = 1
        gateway.onExecute = { task.cancel() }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(gateway.executed, ["list_tasks"])
        }
    }

    func testBudgetStopsFurtherToolRounds() async throws {
        let gateway = RecordingGateway()
        let transport = ScriptedTransport(turns: [
            AgentModelTurn(
                calls: [AgentProposedCall(id: "1", name: "list_tasks", arguments: [:])],
                replay: []
            ),
            AgentModelTurn(
                calls: [AgentProposedCall(id: "2", name: "create_task", arguments: ["title": "Extra"])],
                replay: []
            )
        ])
        try await AgentRuntime.run(
            instructions: "",
            input: [["role": "user", "content": "look"]],
            tools: [["type": "function", "name": "list_tasks"]],
            maxRounds: 1,
            transport: transport,
            gateway: gateway,
            onEvent: { _ in }
        )
        XCTAssertEqual(gateway.executed, ["list_tasks"])
        XCTAssertEqual(transport.toolCounts, [1, 0])
    }

    func testChatAndRunAdaptersShareRuntimeBudgetAndGateway() {
        XCTAssertEqual(
            AgentRuntime.toolsForRound(0, tools: [["name": "a"]], maxRounds: 8).count,
            ChatGPTProvider.toolsForRound(0, tools: [["name": "a"]]).count
        )
        XCTAssertEqual(
            AgentRuntime.toolsForRound(8, tools: [["name": "a"]], maxRounds: 8).count,
            ChatGPTProvider.toolsForRound(8, tools: [["name": "a"]]).count
        )
        XCTAssertEqual(ChatGPTProvider.maxToolRounds, 8)
    }

    func testChatPolicyAllowsUserWritesAndStillRejectsOtherProjects() async throws {
        let projectID = UUID()
        let inner = RecordingGateway()
        let gateway = await MainActor.run {
            RunGateway(policy: .chat(projectID: projectID), inner: inner, includeFinishRun: false)
        }
        let policy = await MainActor.run { gateway.policy }
        XCTAssertTrue(policy.allows("complete_task"))
        XCTAssertTrue(policy.allows("create_task"))
        XCTAssertThrowsError(
            try policy.permitsCall(
                "create_note",
                arguments: ["project_id": UUID().uuidString, "content": "nope"]
            ).get()
        )
        do {
            _ = try await gateway.execute(
                name: "create_note",
                arguments: ["project_id": UUID().uuidString, "content": "nope"]
            )
            XCTFail("Cross-project write should fail")
        } catch {
            XCTAssertTrue(inner.executed.isEmpty)
        }
    }
}

final class RecordingGateway: AgentToolGateway, @unchecked Sendable {
    private(set) var executed: [String] = []
    var cancelAfter = Int.max
    var onExecute: (() -> Void)?

    func definitions() async throws -> [[String: Any]] { [] }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        executed.append(name)
        onExecute?()
        if executed.count >= cancelAfter {
            try Task.checkCancellation()
        }
        return "{\"ok\":true}"
    }
}

final class ScriptedTransport: AgentModelTransport, @unchecked Sendable {
    private var turns: [AgentModelTurn]
    private(set) var toolCounts: [Int] = []

    init(turns: [AgentModelTurn]) {
        self.turns = turns
    }

    func complete(
        instructions: String,
        input: [[String: Any]],
        tools: [[String: Any]],
        onText: (String) async -> Void,
        onThinking: (String?) async -> Void
    ) async throws -> AgentModelTurn {
        toolCounts.append(tools.count)
        if turns.isEmpty {
            return AgentModelTurn(calls: [], replay: [])
        }
        return turns.removeFirst()
    }
}
