import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class ImportToolsTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainer(for: Store.schema, configurations: ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true))
    }

    func testListProjectsReturnsIdentityOnly() throws {
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        try container.mainContext.save()
        var metadata = emptyMetadata()
        let response = ImportToolHost.handle(
            rpc: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_projects", "arguments": [:]]],
            client: "Claude",
            container: container,
            metadata: &metadata
        )
        let projects = try decodeList(response)
        XCTAssertEqual(projects.first?["id"] as? String, seed.project.id.uuidString)
        XCTAssertEqual(projects.first?["name"] as? String, "Harbor")
        XCTAssertNotNil(projects.first?["summary"])
        XCTAssertNil(projects.first?["current_direction"])
        XCTAssertNil(projects.first?["counts"])
        XCTAssertNil(projects.first?["status"])
    }

    func testForbiddenToolIsRejected() throws {
        var metadata = emptyMetadata()
        let response = ImportToolHost.handle(
            rpc: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_note", "arguments": [:]]],
            client: "Claude",
            container: container,
            metadata: &metadata
        )
        XCTAssertTrue(((response["result"] as? [String: Any])?["isError"] as? Bool) ?? false)
    }

    func testNoteRequiresImportedTrackAndIgnoresSource() throws {
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        try container.mainContext.save()
        var metadata = emptyMetadata()
        let forbidden = ImportToolHost.handle(
            rpc: call("create_note", [
                "project_id": seed.project.id.uuidString,
                "content": "secret",
                "thread_id": seed.auth.id.uuidString,
                "source": "the-model"
            ]),
            client: "Claude",
            container: container,
            metadata: &metadata
        )
        XCTAssertTrue(((forbidden["result"] as? [String: Any])?["isError"] as? Bool) ?? false)

        let created = ImportToolHost.handle(
            rpc: call("create_thread", [
                "project_id": seed.project.id.uuidString,
                "title": "From Claude"
            ]),
            client: "Claude",
            container: container,
            metadata: &metadata
        )
        let thread = try object(created)
        let note = try object(ImportToolHost.handle(
            rpc: call("create_note", [
                "project_id": seed.project.id.uuidString,
                "content": "Filed from the chat",
                "thread_id": thread["id"] as? String ?? "",
                "source": "the-model"
            ]),
            client: "Claude",
            container: container,
            metadata: &metadata
        ))
        XCTAssertEqual(note["source"] as? String, "Claude")
        XCTAssertEqual(note["content"] as? String, "Filed from the chat")
    }

    func testRetryDedupDoesNotCreateASecondNote() throws {
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        try container.mainContext.save()
        var metadata = emptyMetadata()
        let arguments: [String: Any] = [
            "project_id": seed.project.id.uuidString,
            "content": "Same payload"
        ]
        _ = ImportToolHost.handle(rpc: call("create_note", arguments), client: "Imported", container: container, metadata: &metadata)
        _ = ImportToolHost.handle(rpc: call("create_note", arguments), client: "Imported", container: container, metadata: &metadata)
        let notes = try container.mainContext.fetch(FetchDescriptor<Note>()).filter { $0.content == "Same payload" }
        XCTAssertEqual(notes.count, 1)
    }

    func testSupersedesIsRejected() throws {
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        try container.mainContext.save()
        var metadata = emptyMetadata()
        let response = ImportToolHost.handle(
            rpc: call("create_decision", [
                "project_id": seed.project.id.uuidString,
                "title": "No",
                "decision": "Nope",
                "supersedes_id": seed.decision.id.uuidString
            ]),
            client: "Claude",
            container: container,
            metadata: &metadata
        )
        let text = ((response["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(text, "Import cannot replace an existing decision. Create a new one.")
    }

    private func emptyMetadata() -> ImportKeyMetadata {
        ImportKeyMetadata(
            createdAt: .now,
            expiresAt: .now.addingTimeInterval(86400),
            lastFour: "abcd",
            createdTrackIDs: [],
            lastImport: nil,
            lastExpiredAt: nil,
            lastOfflineError: nil,
            dedup: []
        )
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
    }

    private func decodeList(_ response: [String: Any]) throws -> [[String: Any]] {
        let text = try XCTUnwrap(((response["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    private func object(_ response: [String: Any]) throws -> [String: Any] {
        let text = try XCTUnwrap(((response["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
