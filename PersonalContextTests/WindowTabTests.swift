import XCTest
@testable import Membrae

final class WindowTabTests: XCTestCase {
    func testCloseSelectsMostRecentlyViewedRemainingTab() {
        let home = UUID()
        let projects = UUID()
        let chats = UUID()
        let remaining = [home, projects, chats]
        let recency = [home, chats, projects]

        XCTAssertEqual(
            TabRecency.selection(afterClosing: projects, remaining: remaining, recency: recency),
            chats
        )
    }

    func testCloseDoesNotFallBackToArrayNeighbor() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let remaining = [a, c]

        XCTAssertEqual(
            TabRecency.selection(afterClosing: b, remaining: remaining, recency: [a, c, b]),
            c
        )
        XCTAssertEqual(
            TabRecency.selection(afterClosing: b, remaining: remaining, recency: [c, a, b]),
            a
        )
    }

    func testCloseFallsBackToLastRemainingWhenRecencyIsEmpty() {
        let a = UUID()
        let b = UUID()

        XCTAssertEqual(
            TabRecency.selection(afterClosing: a, remaining: [b], recency: []),
            b
        )
        XCTAssertNil(TabRecency.selection(afterClosing: a, remaining: [], recency: [a]))
    }

    func testRememberMovesTabToMostRecent() {
        let a = UUID()
        let b = UUID()
        let c = UUID()

        XCTAssertEqual(TabRecency.remember(c, in: [a, b, c]), [a, b, c])
        XCTAssertEqual(TabRecency.remember(a, in: [a, b, c]), [b, c, a])
    }
}
