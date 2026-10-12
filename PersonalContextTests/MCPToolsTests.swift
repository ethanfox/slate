import SwiftData
import XCTest
@testable import Membrae

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
        XCTAssertNil(body["tracks"])
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
                "include": ["decisions", "tracks", "notes", "tasks"]
            ],
            container: container
        ))
        let decisions = try XCTUnwrap(body["decisions"] as? [[String: Any]])
        let threads = try XCTUnwrap(body["tracks"] as? [[String: Any]])
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
            arguments: ["project_id": seed.project.id.uuidString, "include": ["tracks"]],
            container: container
        ))
        let threads = try XCTUnwrap(body["tracks"] as? [[String: Any]])
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

        let body = try object(Tools.call("get_track", arguments: ["track_id": seed.auth.id.uuidString], container: container))
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

        let body = try object(Tools.call("get_track", arguments: ["track_id": seed.auth.id.uuidString], container: container))
        let notes = try XCTUnwrap(body["notes"] as? [[String: Any]])
        let oauth = try XCTUnwrap(notes.first { $0["title"] as? String == "OAuth vendor reference" })
        XCTAssertNil(oauth["content"])
        let preview = try XCTUnwrap(oauth["preview"] as? String)
        XCTAssertTrue(preview.contains(HarborEvalFixture.vendorLead))
        XCTAssertFalse(preview.contains(HarborEvalFixture.vendorTail))
    }

    func testListChatsOmitsArchivedAndGetChatReturnsTranscript() throws {
        let seed = HarborEvalFixture.seed(in: context)
        let chat = Conversation(title: "Auth review", providerID: "cursor", project: seed.project)
        chat.thread = seed.auth
        let user = ChatMessage(role: .user, content: "What did we decide about sessions?")
        let assistant = ChatMessage(role: .assistant, content: "Keep the local session.")
        chat.messages = [user, assistant]
        let archived = Conversation(title: "Old scratch", providerID: "cursor", project: seed.project)
        archived.isArchived = true
        archived.messages = [ChatMessage(role: .user, content: "hidden")]
        context.insert(chat)
        context.insert(archived)
        try context.save()

        let listed = try array(Tools.call(
            "list_chats",
            arguments: ["project_id": seed.project.id.uuidString],
            container: container
        ))
        XCTAssertEqual(listed.compactMap { $0["title"] as? String }, ["Auth review"])
        XCTAssertNil(listed.first?["messages"])
        XCTAssertEqual(listed.first?["preview"] as? String, "Keep the local session.")

        let onAuth = try array(Tools.call(
            "list_chats",
            arguments: ["project_id": seed.project.id.uuidString, "track_id": seed.auth.id.uuidString],
            container: container
        ))
        XCTAssertEqual(onAuth.count, 1)

        let body = try object(Tools.call("get_chat", arguments: ["chat_id": chat.id.uuidString], container: container))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant"])
        XCTAssertEqual(messages.map { $0["content"] as? String }, [
            "What did we decide about sessions?",
            "Keep the local session."
        ])
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

        let thread = try object(Tools.call("get_track", arguments: ["track_id": seed.auth.id.uuidString], container: container))
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
            "update_track",
            arguments: [
                "track_id": seed.auth.id.uuidString,
                "body": "",
                "append_to_body": "Sign-in must work offline."
            ],
            container: container
        ))

        let body = try object(Tools.call("get_track", arguments: ["track_id": seed.auth.id.uuidString], container: container))
        let text = try XCTUnwrap(body["body"] as? String)
        XCTAssertTrue(text.contains("local session store"))
        XCTAssertTrue(text.contains("Sign-in must work offline."))
    }

    func testAppendToBodyPreservesExistingSpec() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        _ = try object(Tools.call(
            "update_track",
            arguments: [
                "track_id": seed.auth.id.uuidString,
                "append_to_body": "Sign-in must work offline."
            ],
            container: container
        ))

        let body = try object(Tools.call("get_track", arguments: ["track_id": seed.auth.id.uuidString], container: container))
        let text = try XCTUnwrap(body["body"] as? String)
        XCTAssertTrue(text.contains("local session store"))
        XCTAssertTrue(text.contains("Sign-in must work offline."))
        XCTAssertTrue(text.hasPrefix(HarborEvalFixture.authBody))
    }

    func testUpdateThreadPreservesAssociations() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        _ = try object(Tools.call(
            "update_track",
            arguments: [
                "track_id": seed.auth.id.uuidString,
                "body": HarborEvalFixture.authBody + " Sign-in must work offline."
            ],
            container: container
        ))

        let body = try object(Tools.call("get_track", arguments: ["track_id": seed.auth.id.uuidString], container: container))
        XCTAssertTrue((body["body"] as? String)?.contains("Sign-in must work offline.") == true)
        XCTAssertTrue((body["body"] as? String)?.contains("local session store") == true)
        let tasks = try XCTUnwrap(body["tasks"] as? [[String: Any]])
        XCTAssertEqual(Set(tasks.compactMap { $0["title"] as? String }), ["Ship sign-in", "Fix refresh after wake"])
        let decisions = try XCTUnwrap(body["decisions"] as? [[String: Any]])
        XCTAssertEqual(decisions.first?["id"] as? String, seed.decision.id.uuidString)
        let notes = try XCTUnwrap(body["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.first?["id"] as? String, seed.oauthNote.id.uuidString)
    }

    func testTagToolsCreateAssignAndRemove() throws {
        let seed = HarborEvalFixture.seed(in: context)
        try context.save()

        let created = try object(Tools.call(
            "create_tag",
            arguments: ["name": "Dock", "color": "terracotta"],
            container: container
        ))
        XCTAssertEqual(created["name"] as? String, "Dock")
        XCTAssertEqual(created["color"] as? String, "terracotta")
        let tagID = try XCTUnwrap(created["id"] as? String)

        let listed = try array(Tools.call("list_tags", arguments: [:], container: container))
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["id"] as? String, tagID)

        _ = try object(Tools.call(
            "assign_tag",
            arguments: [
                "tag_id": tagID,
                "record_type": "note",
                "record_id": seed.oauthNote.id.uuidString
            ],
            container: container
        ))
        let note = try object(Tools.call("get_note", arguments: ["note_id": seed.oauthNote.id.uuidString], container: container))
        let tags = try XCTUnwrap(note["tags"] as? [[String: Any]])
        XCTAssertEqual(tags.first?["name"] as? String, "Dock")

        _ = try object(Tools.call(
            "remove_tag",
            arguments: [
                "tag_id": tagID,
                "record_type": "note",
                "record_id": seed.oauthNote.id.uuidString
            ],
            container: container
        ))
        let cleared = try object(Tools.call("get_note", arguments: ["note_id": seed.oauthNote.id.uuidString], container: container))
        XCTAssertEqual((cleared["tags"] as? [[String: Any]])?.count, 0)
    }

    func testCreateTagRejectsUnknownColor() throws {
        let result = Tools.call(
            "create_tag",
            arguments: ["name": "Dock", "color": "neon"],
            container: container
        )
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testUpdateTagMergesCollidingNames() throws {
        let seed = HarborEvalFixture.seed(in: context)
        let dock = try XCTUnwrap(TagStore.create(named: "Dock", color: .terracotta, in: context))
        let marina = try XCTUnwrap(TagStore.create(named: "Marina", color: .sea, in: context))
        seed.oauthNote.tags = [marina]
        try context.save()

        let body = try object(Tools.call(
            "update_tag",
            arguments: ["tag_id": marina.id.uuidString, "name": "dock"],
            container: container
        ))
        XCTAssertEqual(body["id"] as? String, dock.id.uuidString)
        let note = try object(Tools.call("get_note", arguments: ["note_id": seed.oauthNote.id.uuidString], container: container))
        let tags = try XCTUnwrap(note["tags"] as? [[String: Any]])
        XCTAssertEqual(tags.first?["id"] as? String, dock.id.uuidString)
    }

    private func object(_ result: [String: Any]) throws -> [String: Any] {
        XCTAssertNil(result["isError"], result["content"].debugDescription)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(in: result).utf8)) as? [String: Any])
    }

    private func array(_ result: [String: Any]) throws -> [[String: Any]] {
        XCTAssertNil(result["isError"], result["content"].debugDescription)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(in: result).utf8)) as? [[String: Any]])
    }

    func testSourcesLiveInTheLibraryAndLinkToProjects() throws {
        func sources(_ arguments: [String: Any] = [:]) throws -> [[String: Any]] {
            let data = Data(try text(in: Tools.call("list_sources", arguments: arguments, container: container)).utf8)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        }
        let harbor = try object(Tools.call("create_project", arguments: ["name": "Harbor"], container: container))
        let kiln = try object(Tools.call("create_project", arguments: ["name": "Kiln"], container: container))
        let harborID = try XCTUnwrap(harbor["id"] as? String)
        let kilnID = try XCTUnwrap(kiln["id"] as? String)

        let saved = try object(Tools.call(
            "create_source",
            arguments: ["url": "https://example.com/tides", "title": "Tide tables", "text": "Spring tides peak at new moon.", "project_ids": [harborID]],
            container: container
        ))
        let sourceID = try XCTUnwrap(saved["id"] as? String)
        XCTAssertEqual(saved["project_ids"] as? [String], [harborID])

        let again = try object(Tools.call(
            "create_source",
            arguments: ["url": "https://example.com/tides", "summary": "When the tide is highest.", "project_ids": [kilnID]],
            container: container
        ))
        XCTAssertEqual(again["id"] as? String, sourceID, "the same address is one source")
        XCTAssertEqual(Set(again["project_ids"] as? [String] ?? []), [harborID, kilnID])

        XCTAssertEqual(try sources().count, 1, "the Library is not scoped to a project")
        XCTAssertEqual(try sources(["query": "new moon"]).count, 1, "the saved text is searched")
        XCTAssertEqual(try sources(["query": "volcano"]).count, 0)
        XCTAssertEqual(try sources(["linked_to": kilnID]).count, 1)
        let full = try object(Tools.call("get_source", arguments: ["source_id": sourceID], container: container))
        XCTAssertEqual(full["text"] as? String, "Spring tides peak at new moon.")

        _ = try object(Tools.call("update_source", arguments: ["source_id": sourceID, "title": "Tides", "read": true], container: container))
        let log = try ModelContext(container).fetch(FetchDescriptor<AgentAction>(sortBy: [SortDescriptor(\.createdAt)]))
        let edit = try XCTUnwrap(log.last { $0.tool == "update_source" })
        try Tools.undo(edit.id, container: container)
        let restored = try object(Tools.call("get_source", arguments: ["source_id": sourceID], container: container))
        XCTAssertEqual(restored["title"] as? String, "Tide tables")
        XCTAssertEqual(restored["read"] as? Bool, false)

        let added = try XCTUnwrap(log.first { $0.tool == "create_source" })
        XCTAssertEqual(added.sentence, "Saved “Tide tables” to the Library")
        try Tools.undo(added.id, container: container)
        XCTAssertEqual(try sources().count, 0)
    }

    func testAPageIsReducedToItsReadableText() {
        let html = """
        <html><head><title>Ignored &amp; plain</title><meta property="og:title" content="Tide tables &amp; charts">
        <style>p { color: red }</style></head>
        <body><nav>Home | About</nav><article><h1>Tides</h1><p>Spring tides peak at&nbsp;new moon.</p>
        <script>track()</script><p>Neap tides don&#39;t.</p></article><footer>Copyright</footer></body></html>
        """
        let page = SourceFetcher.readable(html: html)
        XCTAssertEqual(page.title, "Tide tables & charts")
        XCTAssertEqual(page.text, "Tides\nSpring tides peak at new moon.\nNeap tides don't.")
        XCTAssertNotNil(SourceFetcher.link(in: "  https://example.com/a?b=1 "))
        XCTAssertNil(SourceFetcher.link(in: "read https://example.com later"))
        XCTAssertNil(SourceFetcher.link(in: "example"))
    }

    func testAnAgentDeleteIsLoggedAndCanBeTakenBack() throws {
        let seed = HarborEvalFixture.seed(in: context)
        let child = ProjectThread(title: "Passkeys", kind: .topic, project: seed.project, parent: seed.auth)
        context.insert(child)
        let chat = Conversation(title: "Scratch", providerID: "cursor", project: seed.project)
        context.insert(chat)
        let message = ChatMessage(role: .user, content: "hello")
        context.insert(message)
        message.conversation = chat
        try context.save()

        func log() throws -> [AgentAction] {
            try ModelContext(container).fetch(FetchDescriptor<AgentAction>(sortBy: [SortDescriptor(\.createdAt)]))
        }
        func read(_ tool: String, _ key: String, _ id: String) -> [String: Any] {
            Tools.call(tool, arguments: [key: id], container: container)
        }
        func delete(_ type: String, _ id: String, origin: ActionOrigin = ActionOrigin()) -> [String: Any] {
            Tools.call("delete_record", arguments: ["target_type": type, "target_id": id], container: container, announce: false, origin: origin)
        }
        func ids(_ value: Any?) -> Set<String> {
            Set((value as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        }

        let noteID = seed.oauthNote.id.uuidString
        let note = try object(read("get_note", "note_id", noteID))
        _ = try object(delete("note", noteID))
        XCTAssertEqual(read("get_note", "note_id", noteID)["isError"] as? Bool, true)
        let removed = try XCTUnwrap(try log().last)
        XCTAssertEqual(removed.sentence, "Deleted note “\(note["title"] as? String ?? "")”")
        XCTAssertEqual(removed.projectIDString.lowercased(), seed.project.id.uuidString.lowercased())
        XCTAssertTrue(removed.canUndo)
        try Tools.undo(removed.id, container: container)
        let noteBack = try object(read("get_note", "note_id", noteID))
        for key in ["title", "content", "source", "track_id"] {
            XCTAssertEqual(noteBack[key] as? String, note[key] as? String, key)
        }
        XCTAssertThrowsError(try Tools.undo(removed.id, container: container), "a delete is taken back once")
        XCTAssertEqual(try log().count, 1, "taking a delete back is not itself logged")

        let taskID = seed.shipSignIn.id.uuidString
        let task = try object(read("get_task", "task_id", taskID))
        _ = try object(delete("task", taskID))
        XCTAssertEqual(read("get_task", "task_id", taskID)["isError"] as? Bool, true)
        try Tools.undo(try XCTUnwrap(try log().last).id, container: container)
        let taskBack = try object(read("get_task", "task_id", taskID))
        XCTAssertEqual(taskBack["title"] as? String, task["title"] as? String)
        XCTAssertEqual(taskBack["status"] as? String, task["status"] as? String)
        XCTAssertEqual(ids(taskBack["tracks"]), ids(task["tracks"]))

        let decisionID = seed.decision.id.uuidString
        let decision = try object(read("get_decision", "decision_id", decisionID))
        _ = try object(delete("decision", decisionID))
        try Tools.undo(try XCTUnwrap(try log().last).id, container: container)
        let decisionBack = try object(read("get_decision", "decision_id", decisionID))
        for key in ["title", "decision", "rationale", "status", "created_at"] {
            XCTAssertEqual(decisionBack[key] as? String, decision[key] as? String, key)
        }

        XCTAssertEqual(delete("track", seed.auth.id.uuidString)["isError"] as? Bool, true, "a track with tracks under it stays")
        let childID = child.id.uuidString
        _ = try object(delete("track", childID))
        try Tools.undo(try XCTUnwrap(try log().last).id, container: container)
        let childBack = try object(read("get_track", "track_id", childID))
        XCTAssertEqual(childBack["title"] as? String, "Passkeys")
        XCTAssertEqual((childBack["parent_id"] as? String)?.lowercased(), seed.auth.id.uuidString.lowercased())

        let chatID = chat.id.uuidString
        let own = delete("chat", chatID, origin: ActionOrigin(client: "membrae", conversationID: chatID))
        XCTAssertEqual(own["isError"] as? Bool, true, "an agent cannot delete the chat it is in")
        _ = try object(delete("chat", chatID))
        XCTAssertEqual(read("get_chat", "chat_id", chatID)["isError"] as? Bool, true)
        try Tools.undo(try XCTUnwrap(try log().last).id, container: container)
        let chatBack = try object(read("get_chat", "chat_id", chatID))
        XCTAssertEqual(chatBack["title"] as? String, "Scratch")
        XCTAssertEqual(chatBack["message_count"] as? Int, 1)
    }

    private func text(in result: [String: Any]) throws -> String {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }
}
