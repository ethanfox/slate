import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class RecordChangeTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
        ChangeLog.origin = "app"
        ChangeLog.isRecording = true
    }

    func testEveryStoredModelIsTracked() {
        let exempt = [ObjectIdentifier(TitleIndex.self), ObjectIdentifier(RecordChange.self)]
        for model in Store.models where !exempt.contains(ObjectIdentifier(model)) {
            XCTAssertTrue(model is any ChangeTracked.Type, "\(model) is stored but its changes are not recorded")
        }
    }

    func testInsertEditAndDeleteMoveOneRow() throws {
        let space = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(space)
        let note = Note(content: "body", project: space, title: "Launch note")
        context.insert(note)
        try context.persist()

        let written = try XCTUnwrap(ChangeLog.row(for: note.id, in: context))
        XCTAssertEqual(written.kind, .note)
        XCTAssertEqual(written.spaceID, space.id)
        XCTAssertFalse(written.isDeletion)
        XCTAssertEqual(written.origin, "app")
        let first = written.sequence
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(ChangeLog.row(for: space.id, in: context)?.kind, .space)

        note.title = "Launch plan"
        note.updatedAt = .now
        try context.persist()
        let edited = try XCTUnwrap(ChangeLog.row(for: note.id, in: context))
        XCTAssertGreaterThan(edited.sequence, first, "an edit moves the row to a new sequence")
        XCTAssertFalse(edited.isDeletion)
        // The same row is moved again below, so keep the number rather than the row.
        let editedSequence = edited.sequence

        context.delete(note)
        try context.persist()
        let deleted = try XCTUnwrap(ChangeLog.row(for: note.id, in: context))
        XCTAssertTrue(deleted.isDeletion, "a deletion keeps the row as a tombstone")
        XCTAssertGreaterThan(deleted.sequence, editedSequence)

        let rows = ChangeLog.changes(after: 0, in: context)
        XCTAssertEqual(rows.filter { $0.targetID == note.id }.count, 1, "one row per record")
        XCTAssertEqual(rows.map(\.sequence), rows.map(\.sequence).sorted())
        XCTAssertEqual(Set(rows.map(\.sequence)).count, rows.count, "two rows never share a sequence")
        XCTAssertEqual(ChangeLog.count(in: context), rows.count)
    }

    func testDeletedTrackTakesItsStops() throws {
        let space = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(space)
        let track = ProjectThread(title: "Auth", kind: .feature, project: space)
        context.insert(track)
        let stop = TrackStop(title: "Passkeys", order: 0, thread: track)
        context.insert(stop)
        try context.persist()
        XCTAssertEqual(ChangeLog.row(for: stop.id, in: context)?.kind, .stop)
        XCTAssertEqual(ChangeLog.row(for: stop.id, in: context)?.spaceID, space.id)

        let stopID = stop.id
        context.delete(track)
        try context.persist()
        XCTAssertEqual(ChangeLog.row(for: track.id, in: context)?.isDeletion, true)
        XCTAssertEqual(ChangeLog.row(for: stopID, in: context)?.isDeletion, true, "a deleted track takes its stops")
    }

    func testDeletedSpaceMarksEverythingInside() throws {
        let space = Project(name: "Recipes", symbol: "folder", summary: "")
        context.insert(space)
        let note = Note(content: "body", project: space, title: "Sourdough")
        context.insert(note)
        let type = SpaceType(spaceID: space.id, key: "recipe", name: "Recipes", role: .object, schema: SpaceSchema(), origin: .user)
        context.insert(type)
        let record = SpaceRecord(type: type, title: "Focaccia", values: [:])
        context.insert(record)
        try context.persist()

        let spaceID = space.id
        let noteID = note.id
        let recordID = record.id
        try SpaceStore.delete(space, in: context)

        for id in [spaceID, noteID, recordID] {
            XCTAssertEqual(ChangeLog.row(for: id, in: context)?.isDeletion, true, "\(id) should be marked deleted")
        }
        XCTAssertFalse(ChangeLog.changes(after: 0, in: context).contains { $0.spaceID == spaceID && !$0.isDeletion })
    }

    func testWithoutRecordingRecordsNothing() throws {
        let space = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(space)
        try ChangeLog.withoutRecording {
            try context.persist()
        }
        XCTAssertEqual(ChangeLog.count(in: context), 0)
        XCTAssertTrue(ChangeLog.isRecording, "recording comes back on afterwards")

        space.name = "Harbour"
        try context.persist()
        XCTAssertEqual(ChangeLog.row(for: space.id, in: context)?.kind, .space)
    }

    func testOriginNamesTheWriter() throws {
        let space = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(space)
        try ChangeLog.recording(as: "Cursor") {
            try context.persist()
        }
        XCTAssertEqual(ChangeLog.row(for: space.id, in: context)?.origin, "Cursor")
        XCTAssertEqual(ChangeLog.origin, "app", "the writer's name lasts only for the call")

        let result = Tools.call(
            "create_note",
            arguments: ["space_id": space.id.uuidString, "title": "From Claude", "content": "body"],
            container: container,
            announce: false,
            origin: ActionOrigin(client: "Claude")
        )
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(result)")
        let latest = try XCTUnwrap(ChangeLog.latest(in: ModelContext(container)))
        XCTAssertEqual(latest.origin, "Claude")
    }
}
