import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class StoreSyncTests: XCTestCase {
    override func tearDown() {
        MCPStoreSession.reset()
        super.tearDown()
    }

    func testFileStampChangesAfterWrite() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try Store.open(url: url)
        let before = StoreFileStamp(url: url)
        container.mainContext.insert(Project(name: "Harbor", symbol: "folder", summary: ""))
        try container.mainContext.save()
        XCTAssertNotEqual(before, StoreFileStamp(url: url))
    }

    func testSessionReusesContainerUntilStoreFileChanges() throws {
        MCPStoreSession.reset()
        let url = temporaryStoreURL()
        defer {
            MCPStoreSession.reset()
            try? FileManager.default.removeItem(at: url)
        }

        let seed = try Store.open(url: url)
        seed.mainContext.insert(Project(name: "Harbor", symbol: "folder", summary: ""))
        try seed.mainContext.save()

        let first = try MCPStoreSession.container(at: url)
        XCTAssertTrue(try MCPStoreSession.container(at: url) === first)

        let writer = try Store.open(url: url, mode: .reopen)
        writer.mainContext.insert(Project(name: "Later", symbol: "folder", summary: ""))
        try writer.mainContext.save()

        let reopened = try MCPStoreSession.container(at: url)
        XCTAssertFalse(reopened === first)
    }

    func testReopenSkipsPrepareAndStillReadsRows() throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try Store.open(url: url)
        writer.mainContext.insert(Project(name: "Harbor", symbol: "folder", summary: ""))
        try writer.mainContext.save()

        let reader = try Store.open(url: url, mode: .reopen)
        let names = try reader.mainContext.fetch(FetchDescriptor<Project>()).map(\.name)
        XCTAssertEqual(names, ["Harbor"])
    }

    func testGatewayWritesThroughTheLiveStore() async throws {
        let container = try ModelContainer(
            for: Store.schema,
            configurations: ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        )
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        container.mainContext.insert(project)
        try container.mainContext.save()

        let gateway = MembraeToolGateway(
            includeMembraeTools: true,
            includeProjectTools: false,
            mcp: nil,
            store: container
        )
        let tools = try await gateway.definitions()
        XCTAssertTrue(tools.contains { $0["name"] as? String == "list_projects" })

        let listed = try await gateway.execute(name: "list_projects", arguments: [:])
        XCTAssertTrue(listed.contains("Harbor"), listed)

        _ = try await gateway.execute(
            name: "create_note",
            arguments: ["project_id": project.id.uuidString, "content": "From chat"]
        )
        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        XCTAssertTrue(notes.contains { $0.content == "From chat" })
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).store")
    }
}
