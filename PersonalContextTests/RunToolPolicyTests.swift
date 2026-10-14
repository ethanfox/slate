import XCTest
@testable import Membrae

final class RunToolPolicyTests: XCTestCase {
    func testRunToolsOfferedAndWithheld() {
        let policy = RunToolPolicy(runID: UUID(), spaceID: UUID(), assignedTaskID: nil, allowCode: true)
        XCTAssertFalse(policy.allows("complete_task"))
        XCTAssertFalse(policy.allows("mark_for_deletion"))
        XCTAssertFalse(policy.allows("create_space"))
        XCTAssertTrue(policy.allows("update_space"))
        XCTAssertTrue(policy.allows("create_note"))
        XCTAssertTrue(policy.allows("create_task"))
        XCTAssertTrue(policy.allows("finish_run"))
        XCTAssertFalse(policy.allowedNames(from: ["complete_task", "create_note"]).contains("complete_task"))
    }

    func testARunWritesStepsOnlyOnItself() {
        let runID = UUID()
        let policy = RunToolPolicy(runID: runID, spaceID: nil, assignedTaskID: nil, allowCode: false)
        XCTAssertTrue(policy.allows("set_run_steps"))
        let prepared = policy.preparedArguments("set_run_steps", ["run_id": UUID().uuidString, "steps": []])
        XCTAssertEqual(prepared["run_id"] as? String, runID.uuidString)
        XCTAssertFalse(RunToolPolicy.chat(spaceID: nil).allows("set_run_steps"))
    }

    func testOutsideASpaceHasNoMembraeWrites() {
        let policy = RunToolPolicy(runID: UUID(), spaceID: nil, assignedTaskID: nil, allowCode: false)
        XCTAssertFalse(policy.allows("create_note"))
        XCTAssertFalse(policy.allows("project_read_file"))
        XCTAssertTrue(policy.allows("finish_run"))
    }

    func testChatWithNoSpaceFilesAnywhere() {
        let policy = RunToolPolicy.chat(spaceID: nil)
        XCTAssertTrue(policy.allows("create_note"))
        XCTAssertTrue(policy.allows("create_task"))
        XCTAssertTrue(policy.allows("create_space_record"))
        XCTAssertTrue(policy.allows("create_decision"))
        let projectID = UUID().uuidString
        XCTAssertNoThrow(try policy.permitsCall("create_note", arguments: ["space_id": projectID]).get())
        XCTAssertEqual(policy.preparedArguments("create_note", ["space_id": projectID])["space_id"] as? String, projectID)
    }

    func testChatInASpaceStaysInIt() {
        let projectID = UUID()
        let policy = RunToolPolicy.chat(spaceID: projectID)
        XCTAssertThrowsError(try policy.permitsCall("create_note", arguments: ["space_id": UUID().uuidString]).get())
        XCTAssertEqual(policy.preparedArguments("create_note", [:])["space_id"] as? String, projectID.uuidString)
        XCTAssertEqual(policy.preparedArguments("create_space_record", ["space_id": "x"])["space_id"] as? String, projectID.uuidString)
        XCTAssertNil(policy.preparedArguments("list_spaces", [:])["space_id"])
        XCTAssertNil(policy.preparedArguments("create_space", ["name": "x"])["space_id"])
    }

    func testRunCompletesOnlyTheTaskItWasStartedFrom() {
        let taskID = UUID()
        let policy = RunToolPolicy(runID: UUID(), spaceID: UUID(), assignedTaskID: taskID, allowCode: false)
        XCTAssertTrue(policy.allows("complete_task"))
        XCTAssertNoThrow(try policy.permitsCall("complete_task", arguments: ["task_id": taskID.uuidString]).get())
        XCTAssertThrowsError(try policy.permitsCall("complete_task", arguments: ["task_id": UUID().uuidString]).get())
        XCTAssertNoThrow(try policy.permitsCall("update_task", arguments: [
            "task_id": taskID.uuidString,
            "status": "done"
        ]).get())
    }

    func testRejectsOtherSpace() {
        let projectID = UUID()
        let policy = RunToolPolicy(runID: UUID(), spaceID: projectID, assignedTaskID: nil, allowCode: false)
        let denied = policy.permitsCall("create_note", arguments: [
            "space_id": UUID().uuidString,
            "content": "nope"
        ])
        XCTAssertThrowsError(try denied.get())
    }

    func testAnOldClientsProjectIDIsReadAsTheSpaceID() {
        let policy = RunToolPolicy.chat(spaceID: nil)
        let prepared = policy.preparedArguments("create_note", ["project_id": "abc", "content": "x"])
        XCTAssertEqual(prepared["space_id"] as? String, "abc")
        XCTAssertNil(prepared["project_id"])
    }

    func testInjectsRunSource() {
        let runID = UUID()
        let projectID = UUID()
        let policy = RunToolPolicy(runID: runID, spaceID: projectID, assignedTaskID: nil, allowCode: false)
        let prepared = policy.preparedArguments("create_note", ["content": "Hello"])
        XCTAssertEqual(prepared["source"] as? String, "membrae://run/\(runID.uuidString)")
        XCTAssertEqual(prepared["space_id"] as? String, projectID.uuidString)
    }

    func testRunFollowsTheSpaceThePromptNames() {
        let own = UUID()
        var policy = RunToolPolicy(runID: UUID(), spaceID: own, assignedTaskID: nil, allowCode: false)
        policy.allowOtherSpaces = true
        let other = UUID().uuidString
        XCTAssertNoThrow(try policy.permitsCall("create_note", arguments: ["space_id": other]).get())
        XCTAssertEqual(policy.preparedArguments("create_note", ["space_id": other])["space_id"] as? String, other)
        XCTAssertEqual(policy.preparedArguments("create_note", [:])["space_id"] as? String, own.uuidString)
    }

    @MainActor
    func testFinishRunCanSayItCouldNot() async throws {
        let gateway = RunGateway(
            policy: RunToolPolicy(runID: UUID(), spaceID: nil, assignedTaskID: nil, allowCode: false),
            inner: MembraeToolGateway(includeMembraeTools: false, includeProjectTools: false, mcp: nil)
        )
        _ = try await gateway.execute(
            name: "finish_run",
            arguments: ["summary": "Nothing changed.", "outcome": "could_not", "reason": "I cannot change code."]
        )
        XCTAssertEqual(gateway.finishCouldNot, "I cannot change code.")
        _ = try await gateway.execute(name: "finish_run", arguments: ["summary": "Done."])
        XCTAssertNil(gateway.finishCouldNot)
    }

    func testCouldNotIsItsOwnResult() {
        XCTAssertTrue(RunStatus.couldNot.isTerminal)
        XCTAssertFalse(RunStatus.couldNot.isActive)
        XCTAssertEqual(RunStatus.couldNot.label, "Couldn’t do it")
    }
}
