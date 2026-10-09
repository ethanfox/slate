import SwiftData
import XCTest
@testable import Slate

@MainActor
final class MCPToolsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    func testGetProjectIsLeanByDefault() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let body = try object(Tools.call("get_project", arguments: ["project_id": seed.project.id.uuidString], container: container))
        XCTAssertEqual(body["name"] as? String, "Harbor")
        XCTAssertNil(body["decisions"])
        XCTAssertNil(body["threads"])
        XCTAssertNil(body["notes"])
        XCTAssertNil(body["tasks"])
        XCTAssertNil(body["deletion_marks"])
        XCTAssertEqual((body["attachments"] as? [[String: Any]])?.count, 0)
        let contextText = try XCTUnwrap(body["context"] as? String)
        XCTAssertTrue(contextText.contains("Harbor"))
        XCTAssertFalse(contextText.contains("Active decisions"))
        XCTAssertFalse(contextText.contains(HarborEvalFixture.vendorTail))
        XCTAssertFalse(contextText.contains(HarborEvalFixture.billingSentinel))
        XCTAssertFalse(contextText.contains("Ship sign-in"))
    }

    func testGetProjectIncludeAddsBoundedLists() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let body = try object(Tools.call(
            "get_project",
            arguments: [
                "project_id": seed.project.id.uuidString,
                "include": ["decisions", "threads", "notes", "tasks"]
            ],
            container: container
        ))
        let decisions = try XCTUnwrap(body["decisions"] as? [[String: Any]])
        let threads = try XCTUnwrap(body["threads"] as? [[String: Any]])
        let notes = try XCTUnwrap(body["notes"] as? [[String: Any]])
        let tasks = try XCTUnwrap(body["tasks"] as? [[String: Any]])
        XCTAssertEqual(decisions.first?["title"] as? String, "Keep the Mac session")
        XCTAssertEqual(Set(threads.compactMap { $0["title"] as? String }), ["Auth", "Tokens", "Billing"])
        XCTAssertTrue(notes.contains { $0["title"] as? String == "OAuth vendor reference" })
        XCTAssertTrue(notes.allSatisfy { $0["content"] == nil })
        XCTAssertEqual(
            Set(tasks.compactMap { $0["title"] as? String }),
            ["Ship sign-in", "Fix refresh after wake", "Retry invoice webhooks"]
        )
        let signIn = try XCTUnwrap(tasks.first { $0["title"] as? String == "Ship sign-in" })
        let taskTracks = try XCTUnwrap(signIn["tracks"] as? [[String: Any]])
        XCTAssertEqual(taskTracks.first?["title"] as? String, "Auth")
    }

    func testGetProjectIncludeThreadsOmitsBodies() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let body = try object(Tools.call(
            "get_project",
            arguments: ["project_id": seed.project.id.uuidString, "include": ["threads"]],
            container: container
        ))
        let threads = try XCTUnwrap(body["threads"] as? [[String: Any]])
        XCTAssertTrue(threads.contains { $0["title"] as? String == "Auth" })
        XCTAssertTrue(threads.allSatisfy { $0["body"] == nil })
        XCTAssertFalse(threads.contains { ($0["summary"] as? String)?.contains(HarborEvalFixture.authBody) == true })
    }

    func testGetProjectRejectsUnknownInclude() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let result = Tools.call(
            "get_project",
            arguments: ["project_id": seed.project.id.uuidString, "include": ["everything"]],
            container: container
        )
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testGetThreadReturnsLinkedWorkAndChildSummaries() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let body = try object(Tools.call("get_thread", arguments: ["thread_id": seed.auth.id.uuidString], container: container))
        XCTAssertEqual(body["body"] as? String, HarborEvalFixture.authBody)
        let tasks = try XCTUnwrap(body["tasks"] as? [[String: Any]])
        XCTAssertEqual(Set(tasks.compactMap { $0["title"] as? String }), ["Ship sign-in", "Fix refresh after wake"])
        XCTAssertFalse(tasks.contains { $0["title"] as? String == "Retry invoice webhooks" })
        let children = try XCTUnwrap(body["children"] as? [[String: Any]])
        XCTAssertEqual(children.first?["title"] as? String, "Tokens")
        XCTAssertEqual(children.first?["kind"] as? String, "problem")
        XCTAssertEqual(children.first?["summary"] as? String, "Refresh is flaky")
        let decisions = try XCTUnwrap(body["decisions"] as? [[String: Any]])
        XCTAssertEqual(decisions.first?["title"] as? String, "Keep the Mac session")
    }

    func testGetThreadNotePreviewsOmitContent() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let body = try object(Tools.call("get_thread", arguments: ["thread_id": seed.auth.id.uuidString], container: container))
        let notes = try XCTUnwrap(body["notes"] as? [[String: Any]])
        let oauth = try XCTUnwrap(notes.first { $0["title"] as? String == "OAuth vendor reference" })
        XCTAssertNil(oauth["content"])
        let preview = try XCTUnwrap(oauth["preview"] as? String)
        XCTAssertTrue(preview.contains(HarborEvalFixture.vendorLead))
        XCTAssertFalse(preview.contains(HarborEvalFixture.vendorTail))
    }

    func testGetNoteReturnsFullReferenceContent() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let body = try object(Tools.call("get_note", arguments: ["note_id": seed.oauthNote.id.uuidString], container: container))
        XCTAssertEqual(body["content"] as? String, HarborEvalFixture.vendorContent)
        XCTAssertTrue((body["content"] as? String)?.contains(HarborEvalFixture.vendorTail) == true)
    }

    func testListTasksTrackFilterHonorsDescendants() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let direct = try array(Tools.call(
            "list_tasks",
            arguments: ["track_id": seed.auth.id.uuidString],
            container: container
        ))
        XCTAssertEqual(direct.compactMap { $0["title"] as? String }, ["Ship sign-in"])

        let withChildren = try array(Tools.call(
            "list_tasks",
            arguments: ["track_id": seed.auth.id.uuidString, "include_descendants": true],
            container: container
        ))
        XCTAssertEqual(Set(withChildren.compactMap { $0["title"] as? String }), ["Ship sign-in", "Fix refresh after wake"])
        XCTAssertFalse(withChildren.contains { $0["title"] as? String == "Retry invoice webhooks" })
    }

    func testListTasksOnTrackExcludesUnrelatedWork() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let billing = try array(Tools.call(
            "list_tasks",
            arguments: ["track_id": seed.billing.id.uuidString],
            container: container
        ))
        XCTAssertEqual(billing.compactMap { $0["title"] as? String }, ["Retry invoice webhooks"])
        XCTAssertFalse(billing.contains { $0["title"] as? String == "Ship sign-in" })
    }

    func testTaskLinkedToParentAndChildAppearsOnce() throws {
        let seed = HarborEvalFixture.seed(in: context)
        AssociationService.applyLink(thread: seed.tokens, onto: seed.shipSignIn)
        try context.save()

        let thread = try object(Tools.call("get_thread", arguments: ["thread_id": seed.auth.id.uuidString], container: container))
        let threadTasks = try XCTUnwrap(thread["tasks"] as? [[String: Any]])
        XCTAssertEqual(threadTasks.filter { $0["title"] as? String == "Ship sign-in" }.count, 1)

        let listed = try array(Tools.call(
            "list_tasks",
            arguments: ["track_id": seed.auth.id.uuidString, "include_descendants": true],
            container: container
        ))
        XCTAssertEqual(listed.filter { $0["title"] as? String == "Ship sign-in" }.count, 1)
    }

    func testCreateTaskIsVisibleFromAFreshContext() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let created = try object(Tools.call(
            "create_task",
            arguments: [
                "title": "Offline sign-in",
                "project_id": seed.project.id.uuidString,
                "track_ids": [seed.auth.id.uuidString]
            ],
            container: container
        ))
        XCTAssertEqual(created["title"] as? String, "Offline sign-in")

        let other = ModelContext(container)
        other.autosaveEnabled = false
        let projectID = seed.project.id
        let titles = TaskStore.tasks(in: other).filter { $0.project?.id == projectID }.map(\.displayTitle)
        XCTAssertTrue(titles.contains("Offline sign-in"))
    }

    func testEmptyBodyDoesNotWipeWhenAppending() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        _ = try object(Tools.call(
            "update_thread",
            arguments: [
                "thread_id": seed.auth.id.uuidString,
                "body": "",
                "append_to_body": "Sign-in must work offline."
            ],
            container: container
        ))

        let body = try object(Tools.call("get_thread", arguments: ["thread_id": seed.auth.id.uuidString], container: container))
        let text = try XCTUnwrap(body["body"] as? String)
        XCTAssertTrue(text.contains("local session store"))
        XCTAssertTrue(text.contains("Sign-in must work offline."))
    }

    func testAppendToBodyPreservesExistingSpec() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        _ = try object(Tools.call(
            "update_thread",
            arguments: [
                "thread_id": seed.auth.id.uuidString,
                "append_to_body": "Sign-in must work offline."
            ],
            container: container
        ))

        let body = try object(Tools.call("get_thread", arguments: ["thread_id": seed.auth.id.uuidString], container: container))
        let text = try XCTUnwrap(body["body"] as? String)
        XCTAssertTrue(text.contains("local session store"))
        XCTAssertTrue(text.contains("Sign-in must work offline."))
        XCTAssertTrue(text.hasPrefix(HarborEvalFixture.authBody))
    }

    func testUpdateThreadPreservesAssociations() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        _ = try object(Tools.call(
            "update_thread",
            arguments: [
                "thread_id": seed.auth.id.uuidString,
                "body": HarborEvalFixture.authBody + " Sign-in must work offline."
            ],
            container: container
        ))

        let body = try object(Tools.call("get_thread", arguments: ["thread_id": seed.auth.id.uuidString], container: container))
        XCTAssertTrue((body["body"] as? String)?.contains("Sign-in must work offline.") == true)
        XCTAssertTrue((body["body"] as? String)?.contains("local session store") == true)
        let tasks = try XCTUnwrap(body["tasks"] as? [[String: Any]])
        XCTAssertEqual(Set(tasks.compactMap { $0["title"] as? String }), ["Ship sign-in", "Fix refresh after wake"])
        let decisions = try XCTUnwrap(body["decisions"] as? [[String: Any]])
        XCTAssertEqual(decisions.first?["id"] as? String, seed.decision.id.uuidString)
        let notes = try XCTUnwrap(body["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.first?["id"] as? String, seed.oauthNote.id.uuidString)
    }

    private func object(_ result: [String: Any]) throws -> [String: Any] {
        XCTAssertNil(result["isError"], result["content"].debugDescription)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(in: result).utf8)) as? [String: Any])
    }

    private func array(_ result: [String: Any]) throws -> [[String: Any]] {
        XCTAssertNil(result["isError"], result["content"].debugDescription)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(in: result).utf8)) as? [[String: Any]])
    }

    private func text(in result: [String: Any]) throws -> String {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }
}
