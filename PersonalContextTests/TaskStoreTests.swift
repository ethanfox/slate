import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class TaskStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    func testExistingCompletionMapsToWorkflow() throws {
        let open = AgendaItem(kind: .task, eventKitID: "", title: "Open")
        let done = AgendaItem(kind: .task, eventKitID: "", title: "Done")
        done.isCompleted = true
        context.insert(open)
        context.insert(done)
        try context.save()
        XCTAssertEqual(open.workflowStatus, .ready)
        XCTAssertEqual(done.workflowStatus, .done)
    }

    func testNextIsUniquePerProject() throws {
        let harbor = Project(name: "Harbor", symbol: "folder", summary: "")
        let pin = Project(name: "PIN", symbol: "folder", summary: "")
        let a = task("A", in: harbor)
        let b = task("B", in: harbor)
        let c = task("C", in: pin)
        try TaskStore.setNext(a, in: context)
        try TaskStore.setNext(b, in: context)
        try TaskStore.setNext(c, in: context)
        XCTAssertFalse(a.isNext)
        XCTAssertTrue(b.isNext)
        XCTAssertTrue(c.isNext)
    }

    func testNextRequiresActiveProject() throws {
        let inbox = AgendaItem(kind: .task, eventKitID: "", title: "Inbox")
        context.insert(inbox)
        XCTAssertThrowsError(try TaskStore.setNext(inbox, in: context))
        let paused = Project(name: "Parked", symbol: "folder", summary: "")
        paused.status = .paused
        let parked = task("Parked", in: paused)
        XCTAssertThrowsError(try TaskStore.setNext(parked, in: context))
    }

    func testBlockerCycleRejected() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        let a = task("A", in: project)
        let b = task("B", in: project)
        try TaskStore.addBlocker(a, to: b, in: context)
        XCTAssertEqual(b.workflowStatus, .blocked)
        XCTAssertThrowsError(try TaskStore.addBlocker(b, to: a, in: context))
    }

    func testRepeatCompleteWritesHistoryAndUndoRollsDue() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        let item = task("Weekly", in: project)
        let firstDue = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        item.due = firstDue
        item.repeatRule = .weekly
        try context.save()
        TaskStore.toggleComplete(item, in: context)
        XCTAssertEqual(item.workflowStatus, .ready)
        XCTAssertEqual(item.completions.count, 1)
        XCTAssertEqual(item.due, item.repeatRule.nextDue(after: firstDue))
        let completion = try XCTUnwrap(item.completions.first)
        try TaskStore.undoLatestCompletion(completion, in: context)
        XCTAssertEqual(item.due, firstDue)
        XCTAssertTrue(item.completions.isEmpty)
    }

    func testOlderCompletionDeleteDoesNotRollDue() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        let item = task("Weekly", in: project)
        let firstDue = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        item.due = firstDue
        item.repeatRule = .weekly
        TaskStore.toggleComplete(item, in: context)
        let first = try XCTUnwrap(TaskStore.latestCompletion(for: item))
        TaskStore.toggleComplete(item, in: context)
        let secondDue = item.due
        try TaskStore.deleteCompletion(first, in: context)
        XCTAssertEqual(item.due, secondDue)
        XCTAssertEqual(item.completions.count, 1)
    }

    func testTaskLinksManyNotes() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        let item = task("Ship Runs", in: project)
        let spec = Note(content: "Product spec", project: project, title: "Spec")
        let runtime = Note(content: "Runtime spec", project: project, title: "Runtime")
        context.insert(spec)
        context.insert(runtime)
        AssociationService.applyLink(note: spec, onto: item)
        AssociationService.applyLink(note: runtime, onto: item)
        try context.save()
        XCTAssertEqual(Set(item.liveNotes.map(\.id)), [spec.id, runtime.id])
        AssociationService.unlink(noteID: spec.id, from: item, in: context)
        try context.save()
        XCTAssertEqual(Set(item.liveNotes.map(\.id)), [runtime.id])
    }

    func testDeleteTaskLeavesCompletions() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        let item = task("Weekly", in: project)
        item.due = .now
        item.repeatRule = .daily
        TaskStore.toggleComplete(item, in: context)
        XCTAssertEqual(project.taskCompletions.count, 1)
        TaskStore.delete(item, in: context)
        XCTAssertEqual(project.taskCompletions.count, 1)
        XCTAssertNil(project.taskCompletions.first?.parentTask)
    }

    func testTasksOnTrackIncludeDescendantsWhenAsked() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        let parent = ProjectThread(title: "Auth", kind: .feature, project: project)
        let child = ProjectThread(title: "Tokens", kind: .problem, project: project, parent: parent)
        let onParent = task("Parent work", in: project)
        let onChild = task("Child work", in: project)
        let other = task("Other", in: project)
        AssociationService.applyLink(thread: parent, onto: onParent)
        AssociationService.applyLink(thread: child, onto: onChild)
        try context.save()

        let direct = TaskStore.tasks(on: parent, includingDescendants: false)
        XCTAssertEqual(Set(direct.map(\.title)), ["Parent work"])

        let withChildren = TaskStore.tasks(on: parent, includingDescendants: true)
        XCTAssertEqual(Set(withChildren.map(\.title)), ["Parent work", "Child work"])
        XCTAssertFalse(withChildren.contains { $0.id == other.id })
    }

    private func task(_ title: String, in project: Project) -> AgendaItem {
        let item = AgendaItem(kind: .task, eventKitID: "", title: title)
        context.insert(project)
        context.insert(item)
        item.project = project
        return item
    }
}
