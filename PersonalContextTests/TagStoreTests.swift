import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class TagStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    func testCreateReturnsExistingCaseInsensitiveName() throws {
        let first = try XCTUnwrap(TagStore.create(named: " Dock ", in: context))
        let second = try XCTUnwrap(TagStore.create(named: "dock", in: context))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(TagStore.all(in: context).count, 1)
    }

    func testRenameRefusesACollidingName() throws {
        let dock = try XCTUnwrap(TagStore.create(named: "Dock", in: context))
        let marina = try XCTUnwrap(TagStore.create(named: "Marina", in: context))
        XCTAssertFalse(TagStore.rename(marina, to: "dock", in: context))
        XCTAssertEqual(marina.name, "Marina")
        XCTAssertEqual(TagStore.all(in: context).count, 2)
        XCTAssertEqual(dock.name, "Dock")
    }

    func testMergeRewritesEveryObjectKindAndDropsTheSource() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        let survivor = tag("Dock", created: 1)
        let source = tag("dock", created: 2)
        let track = ProjectThread(title: "Marina", kind: .topic, project: project)
        track.tags = [source]
        let note = Note(content: "Slips", project: project, title: "Dock notes")
        note.tags = [source]
        let decision = Decision(title: "Keep the slips", decision: "Keep them numbered.", project: project)
        decision.tags = [source]
        let chat = Conversation(title: "Harbor chat", providerID: "cursor", project: project)
        chat.tags = [source]
        let item = AgendaItem(kind: .task, eventKitID: "", title: "Paint the dock")
        item.tags = [source]
        context.insert(project)
        try context.save()

        TagStore.merge(source, into: survivor, in: context)

        XCTAssertEqual(TagStore.all(in: context).map(\.id), [survivor.id])
        XCTAssertEqual(Set(track.tags.map(\.id)), [survivor.id])
        XCTAssertEqual(Set(note.tags.map(\.id)), [survivor.id])
        XCTAssertEqual(Set(decision.tags.map(\.id)), [survivor.id])
        XCTAssertEqual(Set(chat.tags.map(\.id)), [survivor.id])
        XCTAssertEqual(Set(item.tags.map(\.id)), [survivor.id])
    }

    func testMergeDoesNotDuplicateASurvivorAlreadyOnTheObject() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        let survivor = tag("Dock", created: 1)
        let source = tag("dock", created: 2)
        let note = Note(content: "Both", project: project, title: "Both")
        note.tags = [survivor, source]
        context.insert(project)
        try context.save()

        TagStore.merge(source, into: survivor, in: context)

        XCTAssertEqual(note.tags.map(\.id), [survivor.id])
    }

    func testCreateKeepsAnExistingColorWhenTheNameCollides() throws {
        let first = try XCTUnwrap(TagStore.create(named: "Dock", color: .terracotta, in: context))
        let second = try XCTUnwrap(TagStore.create(named: "dock", color: .sea, in: context))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.swatch, .terracotta)
    }

    func testAssignAndRemoveOnANote() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        let note = Note(content: "Slips", project: project, title: "Dock notes")
        let tag = try XCTUnwrap(TagStore.create(named: "Dock", color: .moss, in: context))
        context.insert(project)
        try context.save()

        try TagStore.assign(tag, to: .note, id: note.id, in: context)
        XCTAssertEqual(note.tags.map(\.id), [tag.id])

        try TagStore.assign(tag, to: .note, id: note.id, in: context)
        XCTAssertEqual(note.tags.map(\.id), [tag.id])

        try TagStore.remove(tag, from: .note, id: note.id, in: context)
        XCTAssertTrue(note.tags.isEmpty)
    }

    func testAssignRejectsAMissingRecord() throws {
        let tag = try XCTUnwrap(TagStore.create(named: "Dock", in: context))
        XCTAssertThrowsError(try TagStore.assign(tag, to: .task, id: UUID(), in: context))
    }

    func testStorePrepareMergesDuplicateNamesAndKeepsAssignments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        let survivorID: UUID
        let noteTitle = "Dock notes"
        let trackTitle = "Marina"
        let bothTitle = "Both"
        do {
            let seeded = try Store.open(url: url)
            let context = seeded.mainContext
            let project = Project(name: "Harbor", symbol: "folder", summary: "")
            let older = Tag(name: "Dock")
            older.createdAt = Date(timeIntervalSince1970: 1)
            let newer = Tag(name: "dock")
            newer.createdAt = Date(timeIntervalSince1970: 2)
            let note = Note(content: "Slips", project: project, title: noteTitle)
            note.tags = [older]
            let track = ProjectThread(title: trackTitle, kind: .topic, project: project)
            track.tags = [newer]
            let both = Note(content: "Shared", project: project, title: bothTitle)
            both.tags = [older, newer]
            context.insert(project)
            context.insert(older)
            context.insert(newer)
            try context.save()
            survivorID = older.id
        }

        let migrated = try Store.open(url: url)
        let context = migrated.mainContext
        let tags = try context.fetch(FetchDescriptor<Tag>())
        XCTAssertEqual(tags.map(\.id), [survivorID])
        let note = try XCTUnwrap(try context.fetch(FetchDescriptor<Note>()).first { $0.title == noteTitle })
        let track = try XCTUnwrap(try context.fetch(FetchDescriptor<ProjectThread>()).first { $0.title == trackTitle })
        let both = try XCTUnwrap(try context.fetch(FetchDescriptor<Note>()).first { $0.title == bothTitle })
        XCTAssertEqual(Set(note.tags.map(\.id)), [survivorID])
        XCTAssertEqual(Set(track.tags.map(\.id)), [survivorID])
        XCTAssertEqual(Set(both.tags.map(\.id)), [survivorID])
    }

    func testChipFitShowsAllWhenWidthAllows() {
        let names = ["Dock", "Marina"]
        let needed = TagChipMetrics.width(for: "Dock", size: .compact)
            + TagChipMetrics.spacing
            + TagChipMetrics.width(for: "Marina", size: .compact)
        XCTAssertEqual(
            TagChipMetrics.fit(names, in: needed, size: .compact),
            TagChipMetrics.Plan(visibleCount: 2, overflows: false)
        )
    }

    func testChipFitKeepsWhatFitsAndMarksOverflow() {
        let first = TagChipMetrics.width(for: "Dock", size: .compact)
        let available = first + TagChipMetrics.spacing + TagChipMetrics.overflowWidth
        let plan = TagChipMetrics.fit(["Dock", "Architecture"], in: available, size: .compact)
        XCTAssertEqual(plan.visibleCount, 1)
        XCTAssertTrue(plan.overflows)
    }

    func testChipFitFallsBackToIconWhenNothingFits() {
        let plan = TagChipMetrics.fit(["Architecture", "Maintenance"], in: 24, size: .compact)
        XCTAssertEqual(plan.visibleCount, 0)
        XCTAssertTrue(plan.overflows)
    }

    private func tag(_ name: String, created: TimeInterval) -> Tag {
        let tag = Tag(name: name)
        tag.createdAt = Date(timeIntervalSince1970: created)
        context.insert(tag)
        return tag
    }
}
