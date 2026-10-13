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

    func testNextComesFromTheActiveTrack() throws {
        let harbor = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(harbor)
        let sync = ProjectThread(title: "Sync", kind: .feature, project: harbor)
        let other = ProjectThread(title: "Other", kind: .feature, project: harbor)
        context.insert(sync)
        context.insert(other)
        let elsewhere = task("Elsewhere", in: harbor)
        _ = AssociationService.link(thread: other, onto: elsewhere)
        try TaskStore.setNext(elsewhere, in: context)
        let first = task("First", in: harbor)
        let second = task("Second", in: harbor)
        second.createdAt = first.createdAt.addingTimeInterval(1)
        _ = AssociationService.link(thread: sync, onto: first)
        _ = AssociationService.link(thread: sync, onto: second)
        try context.save()

        TaskStore.setActiveTrack(sync, on: harbor, in: context)
        XCTAssertEqual(TaskStore.nextTask(in: harbor)?.id, first.id)
        XCTAssertFalse(TaskStore.isNext(elsewhere))
        XCTAssertThrowsError(try TaskStore.setNext(second, in: context))

        TaskStore.setStatus(.done, on: first, in: context)
        XCTAssertEqual(TaskStore.nextTask(in: harbor)?.id, second.id)

        TaskStore.setActiveTrack(nil, on: harbor, in: context)
        XCTAssertNil(TaskStore.nextTask(in: harbor))
    }

    func testNextFollowsTheOrderOfStops() throws {
        let harbor = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(harbor)
        let sync = ProjectThread(title: "Sync", kind: .feature, project: harbor)
        context.insert(sync)
        let early = task("Made first, on the second stop", in: harbor)
        let late = task("Made second, on the first stop", in: harbor)
        late.createdAt = early.createdAt.addingTimeInterval(1)
        let loose = task("On no stop", in: harbor)
        _ = AssociationService.link(thread: sync, onto: loose)
        let log = StopStore.add("Change log", to: sync, in: context)
        let database = StopStore.add("Database", to: sync, in: context)
        StopStore.assign(late, to: log, in: context)
        StopStore.assign(early, to: database, in: context)
        TaskStore.setActiveTrack(sync, on: harbor, in: context)

        XCTAssertEqual(early.liveTracks.map(\.id), [sync.id])
        XCTAssertEqual(TaskStore.nextTask(in: harbor)?.id, late.id)

        StopStore.move(database, by: -1, in: context)
        XCTAssertEqual(sync.orderedStops.map(\.title), ["Database", "Change log"])
        XCTAssertEqual(TaskStore.nextTask(in: harbor)?.id, early.id)

        StopStore.setDone(true, on: database, in: context)
        XCTAssertEqual(TaskStore.nextTask(in: harbor)?.id, late.id)

        try StopStore.replace(on: sync, with: [
            StopEntry(id: nil, title: "Controls", body: nil, isDone: nil),
            StopEntry(id: log.id, title: "", body: "Every write and delete.", isDone: nil)
        ], in: context)
        XCTAssertEqual(sync.orderedStops.map(\.title), ["Controls", "Change log"])
        XCTAssertEqual(log.body, "Every write and delete.")
        XCTAssertNil(early.stop)
        XCTAssertEqual(late.stop?.id, log.id)
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

    func testTodaySplitsOverdueAndDueToday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
        let harbor = Project(name: "Harbor", symbol: "folder", summary: "")
        let overdue = task("Late", in: harbor)
        overdue.due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))
        let today = task("Now", in: harbor)
        today.due = now
        let later = task("Later", in: harbor)
        later.due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))
        let inbox = AgendaItem(kind: .task, eventKitID: "", title: "Loose")
        context.insert(inbox)
        let sections = TasksLayout.sections(from: [overdue, today, later, inbox], filter: .today, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.id), ["overdue", "today"])
        XCTAssertEqual(sections[0].items.map(\.title), ["Late"])
        XCTAssertEqual(sections[1].items.map(\.title), ["Now"])
    }

    func testInboxIsUnassignedOpenTasks() {
        let harbor = Project(name: "Harbor", symbol: "folder", summary: "")
        let assigned = task("Assigned", in: harbor)
        let loose = AgendaItem(kind: .task, eventKitID: "", title: "Loose")
        let done = AgendaItem(kind: .task, eventKitID: "", title: "Done")
        done.isCompleted = true
        context.insert(loose)
        context.insert(done)
        let sections = TasksLayout.sections(from: [assigned, loose, done], filter: .inbox)
        XCTAssertEqual(sections.map(\.id), ["inbox"])
        XCTAssertEqual(sections[0].items.map(\.title), ["Loose"])
    }

    func testUpcomingGroupsByDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
        let harbor = Project(name: "Harbor", symbol: "folder", summary: "")
        let tomorrow = task("Tomorrow", in: harbor)
        tomorrow.due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11))
        let wednesday = task("Wednesday", in: harbor)
        wednesday.due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))
        let far = task("Far", in: harbor)
        far.due = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))
        let sections = TasksLayout.sections(from: [tomorrow, wednesday, far], filter: .upcoming, now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].title, "Tomorrow")
        XCTAssertEqual(sections[0].items.map(\.title), ["Tomorrow"])
        XCTAssertEqual(sections[1].items.map(\.title), ["Wednesday"])
    }

    func testAttentionReminderIncludesFlaggedAndDue() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
        let due = ReminderItem(id: "1", title: "Pay", listID: "h", listName: "House", due: calendar.date(from: DateComponents(year: 2026, month: 10, day: 9)), isCompleted: false)
        let flagged = ReminderItem(id: "2", title: "Call", listID: "p", listName: "Personal", due: nil, isCompleted: false, isFlagged: true)
        let later = ReminderItem(id: "3", title: "Dinner", listID: "p", listName: "Personal", due: calendar.date(from: DateComponents(year: 2026, month: 10, day: 14)), isCompleted: false)
        XCTAssertTrue(ReminderItem.isAttention(due, now: now, calendar: calendar))
        XCTAssertTrue(ReminderItem.isAttention(flagged, now: now, calendar: calendar))
        XCTAssertFalse(ReminderItem.isAttention(later, now: now, calendar: calendar))
    }

    func testCompactDueLabels() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9))!
        let todayTime = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 16, minute: 30))!
        XCTAssertEqual(TaskDue.compact(yesterday, now: now, calendar: calendar), "Yesterday")
        let todayAllDay = calendar.startOfDay(for: now)
        XCTAssertEqual(TaskDue.compact(todayTime, hideIfToday: true, hasTime: true, now: now, calendar: calendar), todayTime.formatted(date: .omitted, time: .shortened))
        XCTAssertEqual(TaskDue.compact(todayAllDay, hideIfToday: true, now: now, calendar: calendar), "")
    }

    private func task(_ title: String, in project: Project) -> AgendaItem {
        let item = AgendaItem(kind: .task, eventKitID: "", title: title)
        context.insert(project)
        context.insert(item)
        item.project = project
        return item
    }
}
