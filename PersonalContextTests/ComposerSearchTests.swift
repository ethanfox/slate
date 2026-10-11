import SwiftData
import XCTest
@testable import Membrae

final class ComposerSearchTests: XCTestCase {
    func testParseSearchLeavesOrdinaryText() {
        let parsed = ComposerQuery.parse("universal composer")
        XCTAssertEqual(parsed.token, .search)
        XCTAssertEqual(parsed.prefix, "universal composer")
        XCTAssertEqual(parsed.tokenQuery, "")
    }

    func testParseMentionTakesTheTrailingAtToken() {
        let parsed = ComposerQuery.parse("How should search work in @univer")
        XCTAssertEqual(parsed.token, .mention)
        XCTAssertEqual(parsed.tokenQuery, "univer")
        XCTAssertEqual(parsed.prefix, "How should search work in ")
    }

    func testParseTagTakesTheTrailingHashToken() {
        let parsed = ComposerQuery.parse("composer#u")
        XCTAssertEqual(parsed.token, .tag)
        XCTAssertEqual(parsed.tokenQuery, "u")
        XCTAssertEqual(parsed.prefix, "composer")
    }

    func testEmailStaysSearch() {
        XCTAssertEqual(ComposerQuery.parse("write hello@membrae.com").token, .search)
    }

    func testLaterTriggerWins() {
        let mention = ComposerQuery.parse("ask #ux @tr")
        XCTAssertEqual(mention.token, .mention)
        XCTAssertEqual(mention.tokenQuery, "tr")
        let tag = ComposerQuery.parse("ask @track #u")
        XCTAssertEqual(tag.token, .tag)
        XCTAssertEqual(tag.tokenQuery, "u")
    }

    func testExcerptCentersTheHit() {
        let excerpt = ComposerSearch.excerpt(
            query: "composer",
            in: "Find knowledge with the Universal Composer without leaving the page."
        )
        XCTAssertTrue(excerpt.localizedStandardContains("composer"))
    }

    func testScorePrefersTitleMatches() {
        let title = ComposerSearch.score(query: "composer", title: "Universal Composer", body: "")
        let body = ComposerSearch.score(query: "composer", title: "Tags", body: "retrieved from the composer")
        XCTAssertGreaterThan(title, body)
    }

    @MainActor
    func testRecordsHonorTagFiltersAndScope() throws {
        let container = try ModelContainer(
            for: Store.schema,
            configurations: ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let membrae = Project(name: "Membrae", symbol: "folder", summary: "Knowledge base")
        let atlas = Project(name: "Atlas", symbol: "map", summary: "Maps")
        context.insert(membrae)
        context.insert(atlas)
        let tag = Tag(name: "UX")
        context.insert(tag)
        let composer = ProjectThread(title: "Universal Composer", kind: .feature, project: membrae)
        composer.summary = "Find knowledge and ask without leaving."
        composer.tags = [tag]
        context.insert(composer)
        let other = ProjectThread(title: "Universal Composer", kind: .topic, project: atlas)
        other.summary = "A different composer."
        context.insert(other)
        try context.save()

        let workspace = ComposerSearch.records(query: "composer", scope: .workspace, tags: [], in: context)
        XCTAssertEqual(Set(workspace.map(\.projectID)), [membrae.id, atlas.id])

        let tagged = ComposerSearch.records(query: "composer", scope: .workspace, tags: [tag.id], in: context)
        XCTAssertEqual(tagged.map(\.recordID), [composer.id])

        let scoped = ComposerSearch.records(query: "composer", scope: .project(atlas.id), tags: [], in: context)
        XCTAssertEqual(scoped.map(\.recordID), [other.id])
    }

    @MainActor
    func testTagListingAndResolve() throws {
        let container = try ModelContainer(
            for: Store.schema,
            configurations: ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let project = Project(name: "Membrae", symbol: "folder", summary: "")
        context.insert(project)
        let tag = Tag(name: "UX")
        context.insert(tag)
        let thread = ProjectThread(title: "Composer", kind: .feature, project: project)
        thread.body = "Search titles and bodies."
        thread.tags = [tag]
        context.insert(thread)
        try context.save()

        let tags = ComposerSearch.tags(query: "u", in: context)
        XCTAssertEqual(tags.map(\.title), ["UX"])
        XCTAssertEqual(tags.first?.kind, .tag)

        let hit = ComposerSearch.records(query: "titles", scope: .workspace, tags: [], in: context).first
        XCTAssertEqual(hit?.kind, .track)
        XCTAssertEqual(ComposerSearch.resolve(hit!, in: context), "Search titles and bodies.")
    }
}

@MainActor
final class ComposerSessionTests: XCTestCase {
    func testEnterOpensInSearchAndInsertsOnMention() throws {
        let container = try ModelContainer(
            for: Store.schema,
            configurations: ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let project = Project(name: "Membrae", symbol: "folder", summary: "")
        context.insert(project)
        let thread = ProjectThread(title: "Universal Composer", kind: .feature, project: project)
        thread.summary = "Find knowledge"
        context.insert(thread)
        try context.save()

        let session = ComposerSession()
        session.query = "composer"
        session.refresh(in: context)
        XCTAssertEqual(session.defaultAction.id, ComposerAction.open.id)
        XCTAssertEqual(session.highlighted?.recordID, thread.id)

        session.query = "ask @univer"
        session.refresh(in: context)
        XCTAssertEqual(session.parsed.token, .mention)
        XCTAssertEqual(session.defaultAction.id, ComposerAction.insert.id)
        session.insertMention(context: context)
        XCTAssertEqual(session.mentions.map(\.recordID), [thread.id])
        XCTAssertEqual(session.query, "ask ")
        XCTAssertEqual(session.scope, .project(project.id))
    }

    func testHashAddsATagFilter() throws {
        let container = try ModelContainer(
            for: Store.schema,
            configurations: ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let tag = Tag(name: "UX")
        context.insert(tag)
        try context.save()

        let session = ComposerSession()
        session.query = "#u"
        session.refresh(in: context)
        XCTAssertEqual(session.defaultAction.id, ComposerAction.insert.id)
        session.insertTag(context: context)
        XCTAssertEqual(session.tagFilters.map(\.name), ["UX"])
        XCTAssertEqual(session.query, "")
        XCTAssertTrue(session.popTrailingChip(context: context))
        XCTAssertTrue(session.tagFilters.isEmpty)
    }

    func testCloseClearsTheSession() {
        let session = ComposerSession()
        session.isOpen = true
        session.query = "composer"
        session.mentions = [
            ComposerHit(
                id: "track:1",
                kind: .track,
                title: "Composer",
                owner: "Membrae",
                excerpt: "",
                symbol: TrackStyle.symbol,
                recordID: UUID(),
                projectID: UUID()
            )
        ]
        session.close()
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(session.query, "")
        XCTAssertTrue(session.mentions.isEmpty)
    }

    func testQuestionMarkAsksInsteadOfOpening() {
        let session = ComposerSession()
        session.query = "How should search work?"
        XCTAssertTrue(session.shouldAsk)
        XCTAssertEqual(session.defaultAction.id, ComposerAction.ask.id)
    }

    func testClosingActionsRestoresFieldFocus() {
        let session = ComposerSession()
        session.isOpen = true
        session.results = [
            ComposerHit(
                id: "track:1",
                kind: .track,
                title: "Composer",
                owner: "Membrae",
                excerpt: "",
                symbol: TrackStyle.symbol,
                recordID: UUID(),
                projectID: UUID()
            )
        ]
        let before = session.focusNonce
        session.openActions()
        XCTAssertEqual(session.popup, .actions)
        session.toggle()
        XCTAssertEqual(session.popup, .none)
        XCTAssertGreaterThan(session.focusNonce, before)
    }

    func testFocusLossDoesNotCloseActions() {
        let session = ComposerSession()
        session.isOpen = true
        session.query = "composer"
        session.openActions()
        session.setField("composer", context: nil)
        XCTAssertEqual(session.popup, .actions)
        session.setField("composer x", context: nil)
        XCTAssertEqual(session.popup, .none)
    }
}
