import XCTest
@testable import Slate

final class ObjectFindTests: XCTestCase {
    func testMatchesTextAndMetadata() {
        let matches = ObjectFind.matches(
            query: "harbor",
            in: [
                (.title, "Harbor notes"),
                (.tags, "marina, dock"),
                (.body, "Keep the harbor lights on."),
            ]
        )
        XCTAssertEqual(matches.map(\.field), [.title, .body])
        XCTAssertEqual(matches[0].range.location, 0)
        XCTAssertEqual(matches[1].range.location, 9)
    }

    func testMatchesAreCaseAndDiacriticInsensitive() {
        let matches = ObjectFind.matches(
            query: "cafe",
            in: [(.body, "The Café is open.")]
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].field, .body)
    }

    func testEmptyQueryHasNoMatches() {
        let matches = ObjectFind.matches(
            query: "   ",
            in: [(.title, "Harbor"), (.body, "Harbor")]
        )
        XCTAssertTrue(matches.isEmpty)
    }

    @MainActor
    func testSessionStepsThroughMatchesAndReportsField() {
        let session = ObjectFindSession()
        session.attach(UUID())
        session.setFields([
            (.tags, "urgent"),
            (.body, "This is urgent work."),
        ])
        session.open()
        session.setQuery("urgent")

        XCTAssertEqual(session.matches.count, 2)
        XCTAssertEqual(session.current?.field, .tags)
        XCTAssertEqual(session.status, "Tags · 1 of 2")

        session.next()
        XCTAssertEqual(session.current?.field, .body)
        XCTAssertEqual(session.status, "Text · 2 of 2")

        session.next()
        XCTAssertEqual(session.current?.field, .tags)

        session.previous()
        XCTAssertEqual(session.current?.field, .body)
    }

    @MainActor
    func testToggleHidesOpenFind() {
        let session = ObjectFindSession()
        session.attach(UUID())
        session.toggle()
        XCTAssertTrue(session.isOpen)
        session.setQuery("harbor")
        session.toggle()
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(session.query, "")
    }

    @MainActor
    func testDetachClosesFind() {
        let session = ObjectFindSession()
        let id = UUID()
        session.attach(id)
        session.open()
        session.setQuery("hi")
        XCTAssertTrue(session.isOpen)
        session.detach(id)
        XCTAssertFalse(session.isOpen)
        XCTAssertFalse(session.isAvailable)
        XCTAssertEqual(session.query, "")
    }
}
