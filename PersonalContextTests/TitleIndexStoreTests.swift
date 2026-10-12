import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class TitleIndexStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    func testPersistWritesTitlesWithoutBodies() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "A long summary")
        context.insert(project)
        let note = Note(content: String(repeating: "body ", count: 200), project: project, title: "Launch note")
        context.insert(note)
        try context.persist()

        let rows = TitleIndexStore.titles(kind: .note, projectID: project.id, in: context)
        XCTAssertEqual(rows.map(\.title), ["Launch note"])
        XCTAssertEqual(rows.first?.projectID, project.id)
    }

    func testPinsLiveInTheStoreAndOldOnesMoveIn() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let note = Note(content: "body", project: project, title: "Launch note")
        context.insert(note)
        let thread = ProjectThread(title: "Auth", kind: .feature, project: project)
        context.insert(thread)
        try context.persist()

        let space = UUID()
        PinStore.toggle(.space, space, in: context)
        PinStore.toggle(.note, note.id, in: context)
        try context.persist()
        XCTAssertEqual(PinStore.all(in: context).compactMap(\.kind), [.space, .note])

        PinStore.toggle(.space, space, in: context)
        try context.persist()
        XCTAssertEqual(PinStore.all(in: context).compactMap(\.targetID), [note.id])

        let old = [note.id, thread.id, project.id, UUID()].map { $0.uuidString.lowercased() }
        PinStore.adopt(old, in: context)
        try context.persist()
        let pins = PinStore.all(in: context)
        XCTAssertEqual(Set(pins.compactMap(\.targetID)), [note.id, thread.id], "a pin already there is kept once; a project or a missing record is left out")
        XCTAssertEqual(pins.first { $0.targetID == thread.id }?.kind, .track)
    }

    func testRenameUpdatesTheTitleRow() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let thread = ProjectThread(title: "Auth", kind: .feature, project: project)
        context.insert(thread)
        try context.persist()

        thread.title = "Sessions"
        thread.updatedAt = .now
        try context.persist()

        XCTAssertEqual(TitleIndexStore.row(thread.id, in: context)?.title, "Sessions")
    }

    func testDeleteRemovesTheTitleRow() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let decision = Decision(title: "Ship Monday", decision: "Yes", project: project)
        context.insert(decision)
        try context.persist()
        XCTAssertNotNil(TitleIndexStore.row(decision.id, in: context))

        context.delete(decision)
        try context.persist()
        XCTAssertNil(TitleIndexStore.row(decision.id, in: context))
    }

    func testChildWriteBumpsProjectUpdatedAt() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        project.updatedAt = Date(timeIntervalSince1970: 1)
        context.insert(project)
        try context.persist()

        let note = Note(content: "later", project: project, title: "Later")
        note.updatedAt = Date(timeIntervalSince1970: 50)
        context.insert(note)
        try context.persist()

        XCTAssertEqual(TitleIndexStore.row(project.id, in: context)?.updatedAt, Date(timeIntervalSince1970: 50))
    }

    func testTrackTreeUsesParentLinks() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let product = ProjectThread(title: "Product", kind: .direction, project: project)
        product.createdAt = Date(timeIntervalSince1970: 1)
        context.insert(product)
        let auth = ProjectThread(title: "Auth", kind: .feature, project: project, parent: product)
        auth.createdAt = Date(timeIntervalSince1970: 2)
        context.insert(auth)
        try context.persist()

        let tree = TitleIndexStore.trackTree(from: TitleIndexStore.titles(kind: .track, projectID: project.id, in: context))
        XCTAssertEqual(tree.map(\.title), ["Product"])
        XCTAssertEqual(tree.first?.children.map(\.title), ["Auth"])
    }
}
