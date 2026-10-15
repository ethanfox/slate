import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class RunStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    func testAWorkerWritesAndTicksOffItsSteps() throws {
        let run = try RunStore.enqueue(draft(origin: .workspace, brief: "Tidy up"), in: context)
        func set(_ steps: [[String: Any]]) -> [String: Any] {
            Tools.call("set_run_steps", arguments: ["run_id": run.id.uuidString, "steps": steps], container: container, announce: false)
        }
        // The tool writes through its own context, as the helper does, so read the Run back fresh.
        let id = run.id
        func saved() -> [RunStep] { RunStore.run(id, in: ModelContext(container))?.steps ?? [] }
        XCTAssertNil(set([["title": " Read the notes "], ["title": "Write the summary"], ["title": ""]])["isError"])
        XCTAssertEqual(saved(), [RunStep(title: "Read the notes", done: false), RunStep(title: "Write the summary", done: false)])
        XCTAssertNil(set([["title": "Read the notes", "done": true], ["title": "Write the summary"]])["isError"])
        XCTAssertEqual(saved().map(\.done), [true, false])
        let tooMany = (0...RunStep.limit).map { ["title": "Step \($0)"] }
        XCTAssertEqual(set(tooMany)["isError"] as? Bool, true)
        XCTAssertEqual(saved().count, 2)
    }

    func testFourOriginsPersist() throws {
        let project = project("Harbor")
        let task = task("Write it", in: project)
        let chat = Conversation(providerID: "cursor", modelID: "auto", project: project)
        context.insert(chat)
        let workspace = try RunStore.enqueue(draft(origin: .workspace, brief: "Look around"), in: context)
        let fromProject = try RunStore.enqueue(draft(origin: .project, brief: "From project", project: project), in: context)
        let fromTask = try RunStore.enqueue(draft(origin: .task, brief: "From task", project: project, task: task), in: context)
        let fromChat = try RunStore.enqueue(
            draft(origin: .chat, brief: "From chat", project: project, chat: chat),
            in: context
        )
        XCTAssertEqual(workspace.origin, .workspace)
        XCTAssertEqual(fromProject.origin, .project)
        XCTAssertEqual(fromTask.origin, .task)
        XCTAssertEqual(fromChat.originChat?.id, chat.id)
        XCTAssertEqual(workspace.history.first?.kind, .queued)
    }

    func testTaskDoorRejectsSecondActive() throws {
        let project = project("Harbor")
        let item = task("Write it", in: project)
        _ = try RunStore.enqueue(draft(origin: .task, brief: "First", project: project, task: item), in: context)
        XCTAssertThrowsError(
            try RunStore.enqueue(draft(origin: .task, brief: "Second", project: project, task: item), in: context)
        ) { error in
            XCTAssertEqual(error as? RunStoreError, .taskHasActiveRun)
        }
    }

    func testUnprojectedEnqueue() throws {
        let run = try RunStore.enqueue(draft(origin: .workspace, brief: "No project"), in: context)
        XCTAssertNil(run.project)
        XCTAssertEqual(run.title, "No project")
    }

    func testTitleFromBriefFirstLine() throws {
        let run = try RunStore.enqueue(
            draft(origin: .workspace, brief: "  First line that is quite long and should clip after eighty characters total xxxx extra\nSecond"),
            in: context
        )
        XCTAssertEqual(run.title.count, 80)
        XCTAssertFalse(run.title.contains("\n"))
    }

    func testQuitRecovery() throws {
        let run = try RunStore.enqueue(draft(origin: .workspace, brief: "Live"), in: context)
        try RunStore.transition(run, to: .running, in: context)
        RunStore.recoverAbandoned(in: context)
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.history.last?.kind, .quit)
        XCTAssertEqual(run.statusDetail, RunStore.quitDetail)
    }

    func testASessionIsBoundToItsTrackAndSurvivesAQuitMidTurn() throws {
        let harbor = project("Harbor")
        let sync = ProjectThread(title: "Sync", kind: .feature, project: harbor)
        context.insert(sync)
        var pending = draft(origin: .project, brief: "Start on this track", project: harbor, provider: "claude-code")
        pending.trackID = sync.id
        let session = try RunStore.enqueue(pending, in: context)
        XCTAssertTrue(session.isSession)
        XCTAssertEqual(session.trackID, sync.id)
        XCTAssertEqual(session.title, "Session · Sync")
        XCTAssertEqual(RunStore.session(for: sync.id, in: context)?.id, session.id)

        // Cut off mid-turn with a worker session to resume: waits for the user instead of failing.
        try RunStore.transition(session, to: .running, in: context)
        session.externalID = "claude-session-1"
        RunStore.recoverAbandoned(in: context)
        XCTAssertEqual(session.status, .waiting)
        XCTAssertEqual(session.history.last?.kind, .quit)
        XCTAssertEqual(session.statusDetail, RunStore.quitMidTurnDetail)
        XCTAssertEqual(RunStore.session(for: sync.id, in: context)?.id, session.id)

        // Starting again from this session keeps it on the track.
        XCTAssertEqual(RunStore.retryDraft(from: session).trackID, sync.id)

        // One cut off before its worker ever answered has nothing to resume, so it fails like any Run.
        var fresh = draft(origin: .project, brief: "Start again", project: harbor, provider: "claude-code")
        fresh.trackID = sync.id
        try RunStore.cancel(session, in: context)
        let second = try RunStore.enqueue(fresh, in: context)
        try RunStore.transition(second, to: .running, in: context)
        RunStore.recoverAbandoned(in: context)
        XCTAssertEqual(second.status, .failed)
    }

    func testQueuedSurvivesRecoverAbandoned() throws {
        let run = try RunStore.enqueue(draft(origin: .workspace, brief: "Not started yet"), in: context)
        RunStore.recoverAbandoned(in: context)
        XCTAssertEqual(run.status, .queued)
        XCTAssertNotEqual(run.statusDetail, RunStore.quitDetail)
    }

    func testDeleteTaskNullifies() throws {
        let project = project("Harbor")
        let item = task("Write it", in: project)
        let run = try RunStore.enqueue(draft(origin: .task, brief: "Do it", project: project, task: item), in: context)
        try RunStore.transition(run, to: .running, in: context)
        try RunStore.succeed(run, summary: "Done", links: [], in: context)
        TaskStore.delete(item, in: context)
        XCTAssertNil(run.task)
        XCTAssertEqual(run.titleSnapshot, "Write it")
    }

    func testDeleteProjectRemovesRuns() throws {
        let project = project("Harbor")
        let run = try RunStore.enqueue(draft(origin: .project, brief: "Work", project: project), in: context)
        let id = run.id
        context.delete(project)
        try context.save()
        XCTAssertNil(RunStore.run(id, in: context))
    }

    func testRetryIsNewRow() throws {
        let first = try RunStore.enqueue(draft(origin: .workspace, brief: "Once"), in: context)
        try RunStore.transition(first, to: .running, in: context)
        try RunStore.fail(first, detail: "Broke", in: context)
        let draft = RunStore.retryDraft(from: first)
        let second = try RunStore.enqueue(draft, in: context)
        XCTAssertEqual(second.retryOf?.id, first.id)
        XCTAssertEqual(second.brief, first.brief)
        XCTAssertEqual(second.origin, first.origin)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(first.status, .failed)
    }

    func testChatGPTEnqueueWithoutWeb() throws {
        let run = try RunStore.enqueue(
            draft(origin: .workspace, brief: "Just text", provider: "chatgpt"),
            in: context
        )
        XCTAssertEqual(run.providerID, "chatgpt")
        XCTAssertEqual(run.status, .queued)
    }

    func testRefetchAfterReopenFindsTheSameRun() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("membrae-run-reopen-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let configuration = ModelConfiguration(schema: Store.schema, url: url)
        let original = try ModelContainer(for: Store.schema, configurations: configuration)
        let run = try RunStore.enqueue(draft(origin: .workspace, brief: "Index this"), in: original.mainContext)
        let id = run.id
        try RunStore.transition(run, to: .running, in: original.mainContext)
        let reopened = try ModelContainer(for: Store.schema, configurations: configuration)
        let found = try XCTUnwrap(RunStore.run(id, in: reopened.mainContext))
        XCTAssertEqual(found.id, id)
        XCTAssertEqual(found.brief, "Index this")
        XCTAssertEqual(found.status, .running)
        try RunStore.succeed(found, summary: "Published", links: [], in: reopened.mainContext)
        XCTAssertEqual(found.status, .succeeded)
    }

    func testCannotDeleteActive() throws {
        let run = try RunStore.enqueue(draft(origin: .workspace, brief: "Live"), in: context)
        XCTAssertThrowsError(try RunStore.deleteTerminal(run, in: context))
        try RunStore.transition(run, to: .running, in: context)
        try RunStore.cancel(run, in: context)
        try RunStore.deleteTerminal(run, in: context)
        XCTAssertTrue(RunStore.runs(in: context).isEmpty)
    }

    private func project(_ name: String) -> Project {
        let project = Project(name: name, symbol: "folder", summary: "")
        context.insert(project)
        return project
    }

    private func task(_ title: String, in project: Project) -> AgendaItem {
        let item = AgendaItem(kind: .task, eventKitID: "", title: title)
        context.insert(item)
        item.project = project
        return item
    }

    private func draft(
        origin: RunOrigin,
        brief: String,
        project: Project? = nil,
        task: AgendaItem? = nil,
        chat: Conversation? = nil,
        provider: String = "cursor"
    ) -> NewRunDraft {
        NewRunDraft.blank(
            origin: origin,
            projectID: project?.id,
            taskID: task?.id,
            originChatID: chat?.id,
            brief: brief,
            providerID: provider,
            modelID: "auto"
        )
    }
}
