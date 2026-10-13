import XCTest
@testable import Membrae

final class RunToolPolicyTests: XCTestCase {
    func testRunToolsOfferedAndWithheld() {
        let policy = RunToolPolicy(runID: UUID(), projectID: UUID(), assignedTaskID: nil, allowCode: true)
        XCTAssertFalse(policy.allows("complete_task"))
        XCTAssertFalse(policy.allows("mark_for_deletion"))
        XCTAssertFalse(policy.allows("update_project"))
        XCTAssertTrue(policy.allows("create_note"))
        XCTAssertTrue(policy.allows("create_task"))
        XCTAssertTrue(policy.allows("finish_run"))
        XCTAssertFalse(policy.allowedNames(from: ["complete_task", "create_note"]).contains("complete_task"))
    }

    func testARunWritesStepsOnlyOnItself() {
        let runID = UUID()
        let policy = RunToolPolicy(runID: runID, projectID: nil, assignedTaskID: nil, allowCode: false)
        XCTAssertTrue(policy.allows("set_run_steps"))
        let prepared = policy.preparedArguments("set_run_steps", ["run_id": UUID().uuidString, "steps": []])
        XCTAssertEqual(prepared["run_id"] as? String, runID.uuidString)
        XCTAssertFalse(RunToolPolicy.chat(projectID: nil).allows("set_run_steps"))
    }

    func testUnprojectedHasNoMembraeWrites() {
        let policy = RunToolPolicy(runID: UUID(), projectID: nil, assignedTaskID: nil, allowCode: false)
        XCTAssertFalse(policy.allows("create_note"))
        XCTAssertFalse(policy.allows("project_read_file"))
        XCTAssertTrue(policy.allows("finish_run"))
    }

    func testChatWithNoProjectFilesAnywhere() {
        let policy = RunToolPolicy.chat(projectID: nil)
        XCTAssertTrue(policy.allows("create_note"))
        XCTAssertTrue(policy.allows("create_task"))
        XCTAssertTrue(policy.allows("create_space_record"))
        XCTAssertTrue(policy.allows("create_decision"))
        let projectID = UUID().uuidString
        XCTAssertNoThrow(try policy.permitsCall("create_note", arguments: ["project_id": projectID]).get())
        XCTAssertEqual(policy.preparedArguments("create_note", ["project_id": projectID])["project_id"] as? String, projectID)
    }

    func testChatInAProjectStaysInItButReachesSpaces() {
        let projectID = UUID()
        let policy = RunToolPolicy.chat(projectID: projectID)
        XCTAssertThrowsError(try policy.permitsCall("create_note", arguments: ["project_id": UUID().uuidString]).get())
        XCTAssertEqual(policy.preparedArguments("create_note", [:])["project_id"] as? String, projectID.uuidString)
        XCTAssertNil(policy.preparedArguments("create_space_record", ["space_id": "x"])["project_id"])
        XCTAssertNil(policy.preparedArguments("list_spaces", [:])["project_id"])
    }

    func testRunCompletesOnlyTheTaskItWasStartedFrom() {
        let taskID = UUID()
        let policy = RunToolPolicy(runID: UUID(), projectID: UUID(), assignedTaskID: taskID, allowCode: false)
        XCTAssertTrue(policy.allows("complete_task"))
        XCTAssertNoThrow(try policy.permitsCall("complete_task", arguments: ["task_id": taskID.uuidString]).get())
        XCTAssertThrowsError(try policy.permitsCall("complete_task", arguments: ["task_id": UUID().uuidString]).get())
        XCTAssertNoThrow(try policy.permitsCall("update_task", arguments: [
            "task_id": taskID.uuidString,
            "status": "done"
        ]).get())
    }

    func testRejectsOtherProject() {
        let projectID = UUID()
        let policy = RunToolPolicy(runID: UUID(), projectID: projectID, assignedTaskID: nil, allowCode: false)
        let denied = policy.permitsCall("create_note", arguments: [
            "project_id": UUID().uuidString,
            "content": "nope"
        ])
        XCTAssertThrowsError(try denied.get())
    }

    func testInjectsRunSource() {
        let runID = UUID()
        let projectID = UUID()
        let policy = RunToolPolicy(runID: runID, projectID: projectID, assignedTaskID: nil, allowCode: false)
        let prepared = policy.preparedArguments("create_note", ["content": "Hello"])
        XCTAssertEqual(prepared["source"] as? String, "membrae://run/\(runID.uuidString)")
        XCTAssertEqual(prepared["project_id"] as? String, projectID.uuidString)
    }

    func testRunFollowsTheProjectThePromptNames() {
        let own = UUID()
        var policy = RunToolPolicy(runID: UUID(), projectID: own, assignedTaskID: nil, allowCode: false)
        policy.allowOtherProjects = true
        let other = UUID().uuidString
        XCTAssertNoThrow(try policy.permitsCall("create_note", arguments: ["project_id": other]).get())
        XCTAssertEqual(policy.preparedArguments("create_note", ["project_id": other])["project_id"] as? String, other)
        XCTAssertEqual(policy.preparedArguments("create_note", [:])["project_id"] as? String, own.uuidString)
    }

    @MainActor
    func testFinishRunCanSayItCouldNot() async throws {
        let gateway = RunGateway(
            policy: RunToolPolicy(runID: UUID(), projectID: nil, assignedTaskID: nil, allowCode: false),
            inner: MembraeToolGateway(includeMembraeTools: false, includeProjectTools: false, consult: nil, mcp: nil)
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
