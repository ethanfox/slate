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

    func testFirstSpaceVisitLandsOnOverview() {
        let project = UUID()
        let tab = SpaceViewMemory.windowTab(spaceID: project, tab: nil, memory: nil)
        XCTAssertEqual(tab.destination, .space(project))
        XCTAssertEqual(tab.section, .overview)
        XCTAssertNil(tab.selectedThread)
        XCTAssertNil(tab.selectedNote)
        XCTAssertNil(tab.selectedConversation)
    }

    func testSidebarOpenAlwaysLandsOnTheSpacePage() {
        let project = UUID()
        let memory = SpaceViewMemory(tab: .runs, thread: UUID(), note: nil, decision: nil, conversation: nil, run: UUID())
        let tab = SpaceViewMemory.windowTab(spaceID: project, tab: nil, memory: memory)
        XCTAssertEqual(tab.section, .overview)
        XCTAssertNil(tab.selectedThread)
        XCTAssertNil(tab.selectedRun)
        let tracks = SpaceViewMemory.windowTab(spaceID: project, tab: .threads, memory: memory)
        XCTAssertEqual(tracks.section, .threads)
        XCTAssertNil(tracks.selectedThread, "a section opens on its list, not on what was open last")
    }

    func testExplicitTabDoesNotCarryAnotherSectionSelection() {
        let memory = SpaceViewMemory(tab: .threads, thread: UUID(), note: UUID(), decision: nil, conversation: nil, run: nil)
        let tab = SpaceViewMemory.windowTab(spaceID: UUID(), tab: .overview, memory: memory)
        XCTAssertEqual(tab.section, .overview)
        XCTAssertNil(tab.selectedThread)
        XCTAssertNil(tab.selectedNote)
    }

    @MainActor
    func testTabsSavedBeforeSpacesWereOneThingStillOpen() throws {
        let id = UUID()
        let old = Data("""
        {"tabs":[{"id":"\(UUID().uuidString)","destination":{"project":{"_0":"\(id.uuidString)"}},"projectTab":"tasks"},{"id":"\(UUID().uuidString)","destination":{"projects":{}},"projectTab":"chat"}],"selectedID":"\(UUID().uuidString)","projectViews":{}}
        """.utf8)
        let decoded = try JSONDecoder().decode([String: AnyDecodable].self, from: AppModel.spaceTabJSON(old))
        XCTAssertNotNil(decoded["spaceViews"])
        let tabs = try JSONDecoder().decode(TabsOnly.self, from: AppModel.spaceTabJSON(old)).tabs
        XCTAssertEqual(tabs.map(\.destination), [.space(id), .spaces])
        XCTAssertEqual(tabs.map(\.section), [.tasks, .chat])
    }

    private struct TabsOnly: Decodable { var tabs: [WindowTab] }
    private struct AnyDecodable: Decodable {}

    func testSpaceViewMemoryRoundTripsBySpaceID() throws {
        let id = UUID()
        let memory = SpaceViewMemory(
            tab: .chat,
            thread: nil,
            note: nil,
            decision: nil,
            conversation: id,
            run: nil
        )
        let data = try JSONEncoder().encode([id: memory])
        let decoded = try JSONDecoder().decode([UUID: SpaceViewMemory].self, from: data)
        XCTAssertEqual(decoded[id], memory)
    }
}
