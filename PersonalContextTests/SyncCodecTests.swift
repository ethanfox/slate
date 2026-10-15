import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class SyncCodecTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
        ChangeLog.origin = "app"
        ChangeLog.isRecording = true
    }

    private func makeSpace(_ name: String, synced: Bool) throws -> Project {
        let space = Project(name: name, symbol: "folder", summary: "")
        space.isSynced = synced
        context.insert(space)
        try context.persist()
        return space
    }

    func testEveryStoredPropertyHasAKeyPath() throws {
        let space = try makeSpace("Harbor", synced: false)
        let paths = SyncCodec.keyPaths(of: space)
        let entity = try XCTUnwrap(SyncCodec.entity(of: space))
        for attribute in entity.attributes {
            XCTAssertNotNil(paths[attribute.name], "no key path for Project.\(attribute.name)")
        }
        XCTAssertNotNil(paths["isSynced"])
    }

    func testNoteTravelsWithFieldsAndLinks() throws {
        let space = try makeSpace("Harbor", synced: true)
        let track = ProjectThread(title: "Auth", kind: .feature, project: space)
        context.insert(track)
        let note = Note(content: "The body", project: space, title: "Launch note", thread: track)
        context.insert(note)
        try context.persist()

        let record = SyncCodec.record(note)
        XCTAssertEqual(record.kind, "note")
        XCTAssertEqual(record.id, SpaceJSON.key(note.id))
        XCTAssertEqual(record.spaceID, SpaceJSON.key(space.id))
        XCTAssertEqual(record.fields["title"], .string("Launch note"))
        XCTAssertEqual(record.fields["content"], .string("The body"))
        let created = try XCTUnwrap(record.fields["createdAt"]?.text.flatMap(SyncCodec.dates.date))
        XCTAssertEqual(created.timeIntervalSince1970, note.createdAt.timeIntervalSince1970, accuracy: 0.001, "dates travel to the millisecond")
        XCTAssertEqual(record.links["project"], .one(SpaceJSON.key(space.id)))
        XCTAssertEqual(record.links["thread"], .one(SpaceJSON.key(track.id)))

        // The wire form is stable: decoding and encoding again gives the same bytes.
        let data = try SyncCodec.json.encode(record)
        let back = try SyncCodec.jsonDecoder.decode(SyncRecord.self, from: data)
        XCTAssertEqual(try SyncCodec.json.encode(back), data)
        XCTAssertEqual(back.fields, record.fields)
        XCTAssertEqual(back.links, record.links)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"space_id\""))
    }

    func testOutgoingPassesOverLocalSpaces() throws {
        let synced = try makeSpace("Harbor", synced: true)
        let local = try makeSpace("Diary", synced: false)
        let kept = Note(content: "a", project: synced, title: "Kept")
        let skipped = Note(content: "b", project: local, title: "Skipped")
        let tag = Tag(name: "urgent")
        context.insert(kept)
        context.insert(skipped)
        context.insert(tag)
        try context.persist()

        let (records, through) = SyncPlanner.outgoing(after: 0, in: context)
        let ids = Set(records.map(\.id))
        XCTAssertTrue(ids.contains(SpaceJSON.key(kept.id)))
        XCTAssertTrue(ids.contains(SpaceJSON.key(synced.id)))
        XCTAssertTrue(ids.contains(SpaceJSON.key(tag.id)), "a tag belongs to the user, so it goes up once any Space is synced")
        XCTAssertFalse(ids.contains(SpaceJSON.key(skipped.id)))
        XCTAssertFalse(ids.contains(SpaceJSON.key(local.id)))
        XCTAssertEqual(through, ChangeLog.latestSequence(in: context), "the cursor moves past what was passed over")
    }

    func testDeletionTravelsAsATombstone() throws {
        let space = try makeSpace("Harbor", synced: true)
        let note = Note(content: "a", project: space, title: "Gone")
        context.insert(note)
        try context.persist()
        let id = note.id
        context.delete(note)
        try context.persist()

        let (records, _) = SyncPlanner.outgoing(after: 0, in: context)
        let tombstone = try XCTUnwrap(records.first { $0.id == SpaceJSON.key(id) })
        XCTAssertTrue(tombstone.isDeleted)
        XCTAssertEqual(tombstone.kind, "note")
        XCTAssertTrue(tombstone.fields.isEmpty)
    }

    func testIncomingCreatesUpdatesAndDeletes() throws {
        let space = try makeSpace("Harbor", synced: true)
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_780_000_000)
        var incoming = SyncRecord(
            kind: "note", id: SpaceJSON.key(id), spaceID: SpaceJSON.key(space.id), isDeleted: false,
            sequence: 1, changedAt: .now, origin: "ChatGPT",
            fields: [
                "id": .string(SpaceJSON.key(id)),
                "title": .string("From the web"),
                "content": .string("Written with the Mac off"),
                "source": .string(""),
                "createdAt": .string(SyncCodec.dates.string(from: created)),
                "updatedAt": .string(SyncCodec.dates.string(from: created))
            ],
            links: ["project": .one(SpaceJSON.key(space.id))]
        )
        XCTAssertEqual(SyncCodec.apply(incoming, unsentAfter: 0, in: context), .applied)
        try context.persist()
        let note = try XCTUnwrap(ChangeKind.note.find(id, in: context) as? Note)
        XCTAssertEqual(note.title, "From the web")
        XCTAssertEqual(note.project?.id, space.id)
        XCTAssertEqual(note.createdAt, created)
        XCTAssertEqual(TitleIndexStore.row(id, in: context)?.title, "From the web", "the index sees it like any other write")

        incoming.fields["title"] = .string("Renamed on the web")
        incoming.changedAt = .now
        XCTAssertEqual(SyncCodec.apply(incoming, unsentAfter: ChangeLog.latestSequence(in: context), in: context), .applied)
        try context.persist()
        XCTAssertEqual(note.title, "Renamed on the web")

        incoming.isDeleted = true
        incoming.changedAt = .now
        XCTAssertEqual(SyncCodec.apply(incoming, unsentAfter: ChangeLog.latestSequence(in: context), in: context), .deleted)
        try context.persist()
        XCTAssertNil(ChangeKind.note.find(id, in: context))
        XCTAssertEqual(ChangeLog.row(for: id, in: context)?.isDeletion, true)
    }

    func testLaterEditWinsAndTheOtherShowsInLately() throws {
        let space = try makeSpace("Harbor", synced: true)
        let note = Note(content: "a", project: space, title: "Mine")
        context.insert(note)
        try context.persist()
        let pushed = ChangeLog.latestSequence(in: context)

        // An edit here that has not gone up yet.
        note.title = "Mine, edited here"
        note.updatedAt = .now
        try context.persist()
        let localChangedAt = try XCTUnwrap(ChangeLog.row(for: note.id, in: context)?.changedAt)

        var incoming = SyncCodec.record(note)
        incoming.fields["title"] = .string("Theirs, edited earlier")
        incoming.origin = "Claude"
        incoming.changedAt = localChangedAt.addingTimeInterval(-60)
        XCTAssertEqual(SyncPlanner.apply([incoming], unsentAfter: pushed, in: context), 0)
        try context.persist()
        XCTAssertEqual(note.title, "Mine, edited here", "the later edit, made here, is kept")
        let lately = AgentActionStore.recent(in: context, spaceID: space.id, count: 5)
        XCTAssertEqual(lately.first?.client, "Claude")
        XCTAssertEqual(lately.first?.targetID, note.id)

        incoming.fields["title"] = .string("Theirs, edited later")
        incoming.changedAt = localChangedAt.addingTimeInterval(60)
        XCTAssertEqual(SyncPlanner.apply([incoming], unsentAfter: pushed, in: context), 1)
        try context.persist()
        XCTAssertEqual(note.title, "Theirs, edited later", "the later edit, made elsewhere, wins")
    }

    func testTurningSyncOnSendsWhatIsAlreadyThere() throws {
        let space = try makeSpace("Harbor", synced: false)
        let note = Note(content: "a", project: space, title: "Old")
        context.insert(note)
        try context.persist()
        let before = ChangeLog.latestSequence(in: context)

        try SpaceStore.setSynced(true, on: space, in: context)
        let (records, _) = SyncPlanner.outgoing(after: before, in: context)
        let ids = Set(records.map(\.id))
        XCTAssertTrue(ids.contains(SpaceJSON.key(note.id)), "a record written before sync was on is sent")
        XCTAssertTrue(ids.contains(SpaceJSON.key(space.id)))
    }
}
