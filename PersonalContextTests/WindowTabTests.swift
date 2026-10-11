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

    func testFirstProjectVisitLandsOnOverview() {
        let project = UUID()
        let tab = ProjectViewMemory.windowTab(projectID: project, tab: nil, memory: nil)
        XCTAssertEqual(tab.destination, .project(project))
        XCTAssertEqual(tab.projectTab, .overview)
        XCTAssertNil(tab.selectedThread)
        XCTAssertNil(tab.selectedNote)
        XCTAssertNil(tab.selectedConversation)
    }

    func testSidebarOpenRestoresLastTabAndSelection() {
        let project = UUID()
        let thread = UUID()
        let memory = ProjectViewMemory(tab: .threads, thread: thread, note: nil, decision: nil, conversation: nil, run: nil)
        let tab = ProjectViewMemory.windowTab(projectID: project, tab: nil, memory: memory)
        XCTAssertEqual(tab.projectTab, .threads)
        XCTAssertEqual(tab.selectedThread, thread)
        XCTAssertNil(tab.selectedNote)
    }

    func testExplicitTabDoesNotCarryAnotherSectionSelection() {
        let memory = ProjectViewMemory(tab: .threads, thread: UUID(), note: UUID(), decision: nil, conversation: nil, run: nil)
        let tab = ProjectViewMemory.windowTab(projectID: UUID(), tab: .overview, memory: memory)
        XCTAssertEqual(tab.projectTab, .overview)
        XCTAssertNil(tab.selectedThread)
        XCTAssertNil(tab.selectedNote)
    }

    func testProjectViewMemoryRoundTripsByProjectID() throws {
        let id = UUID()
        let memory = ProjectViewMemory(
            tab: .chat,
            thread: nil,
            note: nil,
            decision: nil,
            conversation: id,
            run: nil
        )
        let data = try JSONEncoder().encode([id: memory])
        let decoded = try JSONDecoder().decode([UUID: ProjectViewMemory].self, from: data)
        XCTAssertEqual(decoded[id], memory)
    }
}
