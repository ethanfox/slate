import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class ImportToolsTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainer(for: Store.schema, configurations: ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true))
    }

    func testInitializeAdvertisesPluginVersion() throws {
        var metadata = emptyMetadata()
        let response = ImportToolHost.handle(
            rpc: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
            client: "ChatGPT",
            container: container,
            metadata: &metadata
        )
        let info = (response["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "membrae-import")
        XCTAssertEqual(info?["version"] as? String, "1.2.0")
    }

    func testServerDiscoverAdvertisesChatGPTVersion() throws {
        var metadata = emptyMetadata()
        let response = ImportToolHost.handle(
            rpc: [
                "jsonrpc": "2.0",
                "id": "openai-mcp-discover",
                "method": "server/discover",
                "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]
            ],
            client: "ChatGPT",
            container: container,
            metadata: &metadata
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["supportedVersions"] as? [String], [
            "2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"
        ])
        let info = (result["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["version"] as? String, "1.2.0")
    }

    func testToolsListIncludesTitles() throws {
        var metadata = emptyMetadata()
        let response = ImportToolHost.handle(
            rpc: ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]],
            client: "ChatGPT",
            container: container,
            metadata: &metadata
        )
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ImportToolHost.allowed)
        XCTAssertEqual(tools.compactMap { $0["title"] as? String }, [
            "List Spaces", "Create Space", "Create track", "Create note", "Create decision", "Save what you know about me"
        ])
    }

    func testSaveAboutUserFilesFactsUnderTheClient() throws {
        var metadata = emptyMetadata()
        let saved = try object(ImportToolHost.handle(
            rpc: call("save_about_user", ["facts": [
                ["text": "Works late most nights", "category": "work"],
                ["text": "  "],
                ["text": "Prefers short answers"]
            ]]),
            client: "ChatGPT",
            container: container,
            metadata: &metadata
        ))
        XCTAssertEqual(saved["saved"] as? Int, 2)
        let facts = FactStore.all(in: ModelContext(container))
        XCTAssertEqual(facts.map(\.text), ["Works late most nights", "Prefers short answers"])
        XCTAssertEqual(facts.map(\.origin), ["ChatGPT", "ChatGPT"])
        XCTAssertEqual(facts.first?.category, "work")
        XCTAssertEqual(facts.first?.source, .agent)

        let empty = ImportToolHost.handle(
            rpc: call("save_about_user", ["facts": [] as [Any]]),
            client: "ChatGPT",
            container: container,
            metadata: &metadata
        )
        XCTAssertTrue(((empty["result"] as? [String: Any])?["isError"] as? Bool) ?? false)
    }

    func testListSpacesReturnsIdentityOnly() throws {
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        try container.mainContext.save()
        var metadata = emptyMetadata()
        let response = ImportToolHost.handle(
            rpc: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_spaces", "arguments": [:]]],
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

    func testCreateSpaceThenNote() throws {
        var metadata = emptyMetadata()
        let created = try object(ImportToolHost.handle(
            rpc: call("create_space", ["name": "From ChatGPT", "summary": "Imported"]),
            client: "ChatGPT",
            container: container,
            metadata: &metadata
        ))
        XCTAssertEqual(created["name"] as? String, "From ChatGPT")
        let projectID = try XCTUnwrap(created["id"] as? String)
        let note = try object(ImportToolHost.handle(
            rpc: call("create_note", ["space_id": projectID, "content": "First note"]),
            client: "ChatGPT",
            container: container,
            metadata: &metadata
        ))
        XCTAssertEqual(note["space_id"] as? String, projectID)
    }

    func testAConnectorThatCachedTheOldNamesStillWorks() throws {
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        try container.mainContext.save()
        var metadata = emptyMetadata()
        let listed = try decodeList(ImportToolHost.handle(
            rpc: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_projects", "arguments": [:]]],
            client: "Claude", container: container, metadata: &metadata
        ))
        XCTAssertEqual(listed.first?["name"] as? String, "Harbor")
        let track = try object(ImportToolHost.handle(
            rpc: call("create_track", ["project_id": seed.project.id.uuidString, "title": "Old client"]),
            client: "Claude", container: container, metadata: &metadata
        ))
        XCTAssertEqual(track["space_id"] as? String, seed.project.id.uuidString)
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
                "space_id": seed.project.id.uuidString,
                "content": "secret",
                "track_id": seed.auth.id.uuidString,
                "source": "the-model"
            ]),
            client: "Claude",
            container: container,
            metadata: &metadata
        )
        XCTAssertTrue(((forbidden["result"] as? [String: Any])?["isError"] as? Bool) ?? false)

        let created = ImportToolHost.handle(
            rpc: call("create_track", [
                "space_id": seed.project.id.uuidString,
                "title": "From Claude"
            ]),
            client: "Claude",
            container: container,
            metadata: &metadata
        )
        let thread = try object(created)
        let note = try object(ImportToolHost.handle(
            rpc: call("create_note", [
                "space_id": seed.project.id.uuidString,
                "content": "Filed from the chat",
                "track_id": thread["id"] as? String ?? "",
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
            "space_id": seed.project.id.uuidString,
            "content": "Same payload"
        ]
        _ = ImportToolHost.handle(rpc: call("create_note", arguments), client: "Imported", container: container, metadata: &metadata)
        _ = ImportToolHost.handle(rpc: call("create_note", arguments), client: "Imported", container: container, metadata: &metadata)
        let notes = try container.mainContext.fetch(FetchDescriptor<Note>()).filter { $0.content == "Same payload" }
        XCTAssertEqual(notes.count, 1)
    }

    func testOAuthApprovalBuildsCompleteURL() {
        let request = ImportOAuthRequest.parse(query: [
            "client_id": "dcr_ab",
            "redirect_uri": "https://chatgpt.com/connector_platform_oauth_redirect",
            "code_challenge": "challenge",
            "state": "abc",
            "resource": "https://mcp.membrae.com/mcp",
            "complete": "https://mcp.membrae.com/oauth/complete"
        ])
        XCTAssertEqual(request?.clientID, "dcr_ab")
        XCTAssertEqual(
            request?.completeURL(ticket: "tkt_1")?.absoluteString,
            "https://mcp.membrae.com/oauth/complete?ticket=tkt_1"
        )
        XCTAssertNil(ImportOAuthRequest.parse(query: ["client_id": "x"]))
    }

    func testSupersedesIsRejected() throws {
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        try container.mainContext.save()
        var metadata = emptyMetadata()
        let response = ImportToolHost.handle(
            rpc: call("create_decision", [
                "space_id": seed.project.id.uuidString,
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
