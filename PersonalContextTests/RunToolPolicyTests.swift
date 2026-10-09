import XCTest
@testable import Slate

final class RunToolPolicyTests: XCTestCase {
    func testOmitsCompleteTask() {
        let policy = RunToolPolicy(runID: UUID(), projectID: UUID(), assignedTaskID: UUID(), allowCode: true)
        XCTAssertFalse(policy.allows("complete_task"))
        XCTAssertFalse(policy.allows("mark_for_deletion"))
        XCTAssertFalse(policy.allows("update_project"))
        XCTAssertTrue(policy.allows("create_note"))
        XCTAssertTrue(policy.allows("create_task"))
        XCTAssertTrue(policy.allows("finish_run"))
        XCTAssertFalse(policy.allowedNames(from: ["complete_task", "create_note"]).contains("complete_task"))
    }

    func testUnprojectedHasNoSlateWrites() {
        let policy = RunToolPolicy(runID: UUID(), projectID: nil, assignedTaskID: nil, allowCode: false)
        XCTAssertFalse(policy.allows("create_note"))
        XCTAssertFalse(policy.allows("project_read_file"))
        XCTAssertTrue(policy.allows("finish_run"))
    }

    func testRejectsCompletingAssignedTask() {
        let taskID = UUID()
        let policy = RunToolPolicy(runID: UUID(), projectID: UUID(), assignedTaskID: taskID, allowCode: false)
        let denied = policy.permitsCall("update_task", arguments: [
            "task_id": taskID.uuidString,
            "status": "done"
        ])
        XCTAssertThrowsError(try denied.get())
        let ok = policy.permitsCall("update_task", arguments: [
            "task_id": UUID().uuidString,
            "title": "Follow up"
        ])
        XCTAssertNoThrow(try ok.get())
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

    func testIndexingIsScopedAndReadOnlyForSource() {
        let attachmentID = UUID()
        let policy = RunToolPolicy.indexing(runID: UUID(), projectID: UUID(), attachmentID: attachmentID)
        XCTAssertTrue(policy.allows("project_read_file"))
        XCTAssertTrue(policy.allows("upsert_code_reference_entry"))
        XCTAssertFalse(policy.allows("create_note"))
        XCTAssertFalse(policy.allows("list_notes"))
        XCTAssertFalse(policy.allows("project_write_file"))
        XCTAssertThrowsError(try policy.permitsCall("create_note", arguments: ["content": "no"]).get())
        XCTAssertThrowsError(try policy.permitsCall("upsert_code_reference_entry", arguments: [
            "attachment_id": UUID().uuidString
        ]).get())
    }

    func testInjectsRunSource() {
        let runID = UUID()
        let projectID = UUID()
        let policy = RunToolPolicy(runID: runID, projectID: projectID, assignedTaskID: nil, allowCode: false)
        let prepared = policy.preparedArguments("create_note", ["content": "Hello"])
        XCTAssertEqual(prepared["source"] as? String, "slate://run/\(runID.uuidString)")
        XCTAssertEqual(prepared["project_id"] as? String, projectID.uuidString)
    }
}
