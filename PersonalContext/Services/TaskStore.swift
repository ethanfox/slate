import Foundation
import SwiftData

enum TaskStoreError: LocalizedError {
    case notATask
    case nextRequiresActiveProject
    case nextNotEligible
    case selfLink
    case duplicateBlocker
    case cycle
    case notLatestCompletion

    var errorDescription: String? {
        switch self {
        case .notATask: "That record is not a Membrae task."
        case .nextRequiresActiveProject: "Next needs an active project."
        case .nextNotEligible: "Only Ready or In Progress tasks can be Next."
        case .selfLink: "A task cannot block itself."
        case .duplicateBlocker: "That blocker is already linked."
        case .cycle: "That blocker would create a cycle."
        case .notLatestCompletion: "Only the latest completion can be undone."
        }
    }
}

enum TaskStore {
    static func tasks(in context: ModelContext, project: Project? = nil) -> [AgendaItem] {
        let kind = AgendaKind.task.rawValue
        if let project {
            return project.agendaItems.filter { $0.kindRaw == kind }
        }
        let descriptor = FetchDescriptor<AgendaItem>(
            predicate: #Predicate { $0.kindRaw == kind },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func tasks(on track: ProjectThread, includingDescendants: Bool) -> [AgendaItem] {
        AgendaStore.items(on: track, includingChildren: includingDescendants)
            .filter { $0.kind == .task }
            .sorted(by: boardSort)
    }

    static func nextTask(in project: Project) -> AgendaItem? {
        project.agendaItems.first { $0.kind == .task && $0.isNext }
    }

    static func setStatus(_ status: TaskWorkflowStatus, on item: AgendaItem, in context: ModelContext) {
        guard item.kind == .task else { return }
        applyStatus(status, on: item)
        if status == .done || status == .blocked {
            item.isNext = false
        }
        item.touch()
        if let project = item.project { project.touch() }
        reconcileDependents(of: item, in: context)
        save(context)
    }

    static func setNext(_ item: AgendaItem, in context: ModelContext) throws {
        guard item.kind == .task else { throw TaskStoreError.notATask }
        guard item.canBeNext else {
            throw item.project == nil || item.project?.status != .active
                ? TaskStoreError.nextRequiresActiveProject
                : TaskStoreError.nextNotEligible
        }
        guard let project = item.project else { throw TaskStoreError.nextRequiresActiveProject }
        for other in project.agendaItems where other.kind == .task && other.isNext && other.id != item.id {
            other.isNext = false
            other.touch()
        }
        item.isNext = true
        item.touch()
        project.touch()
        save(context)
    }

    static func clearNext(on item: AgendaItem, in context: ModelContext) {
        guard item.isNext else { return }
        item.isNext = false
        item.touch()
        item.project?.touch()
        save(context)
    }

    static func setBlockedReason(_ reason: String, on item: AgendaItem, in context: ModelContext) {
        guard item.kind == .task else { return }
        item.blockedReason = reason
        reconcileBlockers(for: item, in: context, save: false)
        item.touch()
        item.project?.touch()
        save(context)
    }

    static func addBlocker(_ blocking: AgendaItem, to item: AgendaItem, in context: ModelContext) throws {
        guard item.kind == .task, blocking.kind == .task else { throw TaskStoreError.notATask }
        if blocking.id == item.id { throw TaskStoreError.selfLink }
        if item.blockerLinks.contains(where: { $0.blockingTask?.id == blocking.id }) {
            throw TaskStoreError.duplicateBlocker
        }
        if wouldCycle(blocking: blocking, blocked: item) { throw TaskStoreError.cycle }
        let link = TaskDependency(blocked: item, blocking: blocking)
        context.insert(link)
        if !blocking.isCompleted {
            applyStatus(.blocked, on: item)
            item.isNext = false
        }
        item.touch()
        item.project?.touch()
        save(context)
    }

    static func removeBlocker(_ blocking: AgendaItem, from item: AgendaItem, in context: ModelContext) {
        for link in item.blockerLinks where link.blockingTask?.id == blocking.id {
            context.delete(link)
        }
        reconcileBlockers(for: item, in: context, save: false)
        item.touch()
        item.project?.touch()
        save(context)
    }

    static func toggleComplete(_ item: AgendaItem, in context: ModelContext) {
        guard item.kind == .task else {
            AgendaStore.toggleCompleteLegacy(item, in: context)
            return
        }
        if item.isCompleted {
            applyStatus(.ready, on: item)
            item.touch()
            item.project?.touch()
            reconcileDependents(of: item, in: context)
            save(context)
            return
        }
        if item.repeatRule.advances, item.due != nil {
            completeRepeating(item, in: context)
            return
        }
        applyStatus(.done, on: item)
        item.isNext = false
        item.touch()
        item.project?.touch()
        reconcileDependents(of: item, in: context)
        save(context)
    }

    static func completeRepeating(_ item: AgendaItem, in context: ModelContext) {
        guard item.kind == .task, let due = item.due, item.repeatRule.advances else {
            setStatus(.done, on: item, in: context)
            return
        }
        let completion = TaskCompletion(parent: item, occurredDue: due)
        context.insert(completion)
        item.due = item.repeatRule.nextDue(after: due)
        applyStatus(.ready, on: item)
        if item.isNext, !item.canBeNext { item.isNext = false }
        item.touch()
        item.project?.touch()
        reconcileDependents(of: item, in: context)
        save(context)
    }

    static func latestCompletion(for item: AgendaItem) -> TaskCompletion? {
        item.completions.max { lhs, rhs in
            if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
            return lhs.createdAt < rhs.createdAt
        }
    }

    static func isLatest(_ completion: TaskCompletion) -> Bool {
        guard let parent = completion.parentTask else { return false }
        return latestCompletion(for: parent)?.id == completion.id
    }

    static func undoLatestCompletion(_ completion: TaskCompletion, in context: ModelContext) throws {
        guard let parent = completion.parentTask else {
            context.delete(completion)
            save(context)
            return
        }
        guard isLatest(completion) else { throw TaskStoreError.notLatestCompletion }
        if let occurred = completion.occurredDue {
            parent.due = occurred
        }
        context.delete(completion)
        applyStatus(.ready, on: parent)
        parent.touch()
        parent.project?.touch()
        save(context)
    }

    static func deleteCompletion(_ completion: TaskCompletion, in context: ModelContext) throws {
        if completion.parentTask != nil, isLatest(completion) {
            try undoLatestCompletion(completion, in: context)
            return
        }
        let project = completion.project
        context.delete(completion)
        project?.touch()
        save(context)
    }

    static func reconcileBlockers(for item: AgendaItem, in context: ModelContext, save persist: Bool = true) {
        guard item.kind == .task else { return }
        let hasBlockers = !item.unresolvedBlockers.isEmpty
        let hasReason = !item.blockedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasBlockers || hasReason {
            if item.workflowStatus != .done {
                applyStatus(.blocked, on: item)
                item.isNext = false
            }
        } else if item.workflowStatus == .blocked {
            applyStatus(.ready, on: item)
        }
        item.touch()
        if persist { save(context) }
    }

    static func delete(_ item: AgendaItem, in context: ModelContext) {
        let dependents = item.blockingLinks.compactMap(\.blockedTask)
        item.isNext = false
        context.delete(item)
        for dependent in dependents {
            reconcileBlockers(for: dependent, in: context, save: false)
        }
        save(context)
    }

    static func didChangeProject(on item: AgendaItem, in context: ModelContext) {
        guard item.kind == .task else { return }
        if !item.canBeNext, item.isNext {
            item.isNext = false
            item.touch()
        }
        save(context)
    }

    static func syncProjectStatus(_ project: Project, in context: ModelContext) {
        guard project.status != .active else { return }
        var changed = false
        for item in project.agendaItems where item.kind == .task && item.isNext {
            item.isNext = false
            item.touch()
            changed = true
        }
        if changed {
            project.touch()
            save(context)
        }
    }

    static func boardSort(_ lhs: AgendaItem, _ rhs: AgendaItem) -> Bool {
        if lhs.isNext != rhs.isNext { return lhs.isNext }
        switch (lhs.due, rhs.due) {
        case let (left?, right?):
            if left != right { return left < right }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private static func applyStatus(_ status: TaskWorkflowStatus, on item: AgendaItem) {
        item.workflowStatusRaw = status.rawValue
        item.isCompleted = status == .done
    }

    private static func reconcileDependents(of item: AgendaItem, in context: ModelContext) {
        for link in item.blockingLinks {
            if let dependent = link.blockedTask {
                reconcileBlockers(for: dependent, in: context, save: false)
            }
        }
    }

    private static func wouldCycle(blocking: AgendaItem, blocked: AgendaItem) -> Bool {
        var stack = blocking.blockerLinks.compactMap(\.blockingTask)
        var visited: Set<UUID> = [blocking.id]
        while let current = stack.popLast() {
            if current.id == blocked.id { return true }
            guard visited.insert(current.id).inserted else { continue }
            stack.append(contentsOf: current.blockerLinks.compactMap(\.blockingTask))
        }
        return false
    }

    private static func save(_ context: ModelContext) {
        try? context.save()
    }
}
