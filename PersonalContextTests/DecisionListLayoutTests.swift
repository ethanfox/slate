import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class DecisionListLayoutTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    func testGroupsActiveByTrackOrderWithNoTrackLast() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let product = track("Product", in: project, at: Date(timeIntervalSince1970: 1))
        let auth = track("Auth", in: project, parent: product, at: Date(timeIntervalSince1970: 2))
        let billing = track("Billing", in: project, at: Date(timeIntervalSince1970: 3))
        let older = decision("Older auth", in: project, track: auth, at: Date(timeIntervalSince1970: 10))
        let newer = decision("Newer auth", in: project, track: auth, at: Date(timeIntervalSince1970: 20))
        let loose = decision("Loose", in: project, at: Date(timeIntervalSince1970: 30))
        _ = decision("Bill it", in: project, track: billing, at: Date(timeIntervalSince1970: 15))
        _ = decision("Product call", in: project, track: product, at: Date(timeIntervalSince1970: 12))
        try context.save()

        let layout = DecisionListLayout.snapshot(decisions: project.decisions, roots: project.rootThreads, query: "")

        XCTAssertEqual(layout.active.map(\.title), ["Product", "Auth", "Billing", "No track"])
        XCTAssertEqual(layout.active[1].decisions.map(\.title), ["Newer auth", "Older auth"])
        XCTAssertEqual(layout.active[1].decisions.map(\.id), [newer.id, older.id])
        XCTAssertEqual(layout.active.last?.decisions.map(\.id), [loose.id])
        XCTAssertTrue(layout.history.isEmpty)
        XCTAssertFalse(layout.revealsHistory)
    }

    func testHistoryUsesTheSameGroupingAndStaysUnrevealed() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let auth = track("Auth", in: project, at: Date(timeIntervalSince1970: 1))
        let old = decision("Old rule", in: project, track: auth, at: Date(timeIntervalSince1970: 5))
        old.status = .superseded
        let olderLoose = decision("Older loose", in: project, at: Date(timeIntervalSince1970: 4))
        olderLoose.status = .superseded
        _ = decision("Current", in: project, track: auth, at: Date(timeIntervalSince1970: 8))
        try context.save()

        let layout = DecisionListLayout.snapshot(decisions: project.decisions, roots: project.rootThreads, query: "")

        XCTAssertEqual(layout.active.map(\.title), ["Auth"])
        XCTAssertEqual(layout.history.map(\.title), ["Auth", "No track"])
        XCTAssertEqual(layout.history[0].decisions.map(\.title), ["Old rule"])
        XCTAssertEqual(layout.historyCount, 2)
        XCTAssertFalse(layout.revealsHistory)
    }

    func testSearchRevealsMatchingHistoryGroups() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let auth = track("Auth", in: project, at: Date(timeIntervalSince1970: 1))
        let billing = track("Billing", in: project, at: Date(timeIntervalSince1970: 2))
        let replaced = decision("Session cookie", in: project, track: auth, at: Date(timeIntervalSince1970: 5))
        replaced.status = .superseded
        replaced.rationale = "Prefer tokens"
        let other = decision("Invoice mail", in: project, track: billing, at: Date(timeIntervalSince1970: 6))
        other.status = .superseded
        _ = decision("Token session", in: project, track: auth, at: Date(timeIntervalSince1970: 7))
        try context.save()

        let layout = DecisionListLayout.snapshot(
            decisions: project.decisions,
            roots: project.rootThreads,
            query: "token"
        )

        XCTAssertEqual(layout.active.map(\.title), ["Auth"])
        XCTAssertEqual(layout.active[0].decisions.map(\.title), ["Token session"])
        XCTAssertTrue(layout.revealsHistory)
        XCTAssertEqual(layout.history.map(\.title), ["Auth"])
        XCTAssertEqual(layout.history[0].decisions.map(\.title), ["Session cookie"])
        XCTAssertEqual(layout.revealedHistoryGroupIDs, [layout.history[0].id])
        XCTAssertEqual(layout.historyCount, 1)
    }

    func testSearchMatchesTagsAndIgnoresBlankQueries() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let tagged = decision("Launch window", in: project, at: Date(timeIntervalSince1970: 2))
        let tag = Tag(name: "Café")
        context.insert(tag)
        tagged.tags = [tag]
        let hidden = decision("Hidden", in: project, at: Date(timeIntervalSince1970: 3))
        hidden.status = .superseded
        try context.save()

        let blank = DecisionListLayout.snapshot(
            decisions: project.decisions,
            roots: project.rootThreads,
            query: "   "
        )
        XCTAssertEqual(blank.active[0].decisions.map(\.title), ["Launch window"])
        XCTAssertFalse(blank.revealsHistory)

        let hit = DecisionListLayout.snapshot(
            decisions: project.decisions,
            roots: project.rootThreads,
            query: "cafe"
        )
        XCTAssertEqual(hit.active.flatMap(\.decisions).map(\.title), ["Launch window"])
        XCTAssertTrue(hit.history.isEmpty)
        XCTAssertFalse(hit.revealsHistory)
    }

    func testDoesNotDropOldActiveDecisions() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let ancient = decision("Still current", in: project, at: Date(timeIntervalSince1970: 1))
        try context.save()

        let layout = DecisionListLayout.snapshot(decisions: project.decisions, roots: project.rootThreads, query: "")
        XCTAssertEqual(layout.active.flatMap(\.decisions).map(\.id), [ancient.id])
        XCTAssertEqual(ancient.status, .active)
    }

    private func track(
        _ title: String,
        in project: Project,
        parent: ProjectThread? = nil,
        at date: Date
    ) -> ProjectThread {
        let thread = ProjectThread(title: title, kind: .feature, project: project, parent: parent)
        thread.createdAt = date
        context.insert(thread)
        return thread
    }

    private func decision(
        _ title: String,
        in project: Project,
        track: ProjectThread? = nil,
        at date: Date
    ) -> Decision {
        let item = Decision(title: title, decision: title, project: project, thread: track)
        item.createdAt = date
        context.insert(item)
        return item
    }
}
