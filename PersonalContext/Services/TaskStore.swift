import Foundation
import SwiftData

enum TaskStoreError: LocalizedError {
    case notATask
    case nextRequiresActiveProject
    case nextNotEligible
    case nextFollowsActiveTrack
    case selfLink
    case duplicateBlocker
    case cycle
    case notLatestCompletion

    var errorDescription: String? {
        switch self {
        case .notATask: "That record is not a Membrae task."
        case .nextRequiresActiveProject: "Next needs an active project."
        case .nextNotEligible: "Only Ready or In Progress tasks can be Next."
        case .nextFollowsActiveTrack: "Next comes from the project's active track. Link the task to that track instead."
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

    /// With an active track, the first open task on it that nothing blocks and no junction holds.
    /// Without one, the task marked by hand.
    static func nextTask(in project: Project) -> AgendaItem? {
        guard let track = project.activeTrack else {
            return project.agendaItems.first { $0.kind == .task && $0.isNext }
        }
        return AgendaStore.items(on: track, includingChildren: true)
            .filter { $0.project?.id == project.id && $0.canBeNext && $0.unresolvedBlockers.isEmpty }
            .filter { JunctionStore.holding($0, on: track) == nil }
            .min { lhs, rhs in
                let stops = (stopRank(lhs, on: track), stopRank(rhs, on: track))
                if stops.0 != stops.1 { return stops.0 < stops.1 }
                let started = (lhs.workflowStatus == .inProgress, rhs.workflowStatus == .inProgress)
                if started.0 != started.1 { return started.0 }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Where a task falls in the track's order: its stop's place, or after every stop when it has none.
    private static func stopRank(_ item: AgendaItem, on track: ProjectThread) -> Int {
        guard let stop = item.stop, stop.thread?.id == track.id, !stop.isDone else { return .max }
        return stop.order
    }

    static func isNext(_ item: AgendaItem) -> Bool {
        guard item.kind == .task, let project = item.project else { return false }
        if project.activeTrack == nil { return item.isNext }
        return nextTask(in: project)?.id == item.id
    }

    /// Pass nil to leave the project with no active track.
    static func setActiveTrack(_ track: ProjectThread?, on project: Project, in context: ModelContext) {
        project.activeTrackID = track?.id
        if track != nil {
            for item in project.agendaItems where item.isNext {
                item.isNext = false
            }
        }
        project.touch()
        save(context)
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
        guard project.activeTrack == nil else { throw TaskStoreError.nextFollowsActiveTrack }
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
        let next = (isNext(lhs), isNext(rhs))
        if next.0 != next.1 { return next.0 }
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
        try? context.persist()
    }
}

struct StopEntry {
    var id: UUID?
    var title: String
    var body: String?
    var isDone: Bool?
}

enum StopStore {
    @discardableResult
    static func add(_ title: String, body: String = "", to track: ProjectThread, in context: ModelContext) -> TrackStop {
        let stop = TrackStop(title: title, body: body, order: (track.stops.map(\.order).max() ?? -1) + 1, thread: track)
        context.insert(stop)
        touch(track)
        try? context.persist()
        return stop
    }

    /// Moves a stop earlier (negative) or later in its track.
    static func move(_ stop: TrackStop, by offset: Int, in context: ModelContext) {
        guard let track = stop.thread else { return }
        var ordered = track.orderedStops
        guard let from = ordered.firstIndex(where: { $0.id == stop.id }) else { return }
        let to = min(max(from + offset, 0), ordered.count - 1)
        guard to != from else { return }
        ordered.insert(ordered.remove(at: from), at: to)
        renumber(ordered)
        touch(track)
        try? context.persist()
    }

    static func setDone(_ done: Bool, on stop: TrackStop, in context: ModelContext) {
        stop.isDone = done
        stop.updatedAt = .now
        if let track = stop.thread { touch(track) }
        try? context.persist()
    }

    /// Its tasks stay on the track with no stop.
    static func delete(_ stop: TrackStop, in context: ModelContext) {
        let track = stop.thread
        context.delete(stop)
        if let track {
            renumber(track.orderedStops.filter { $0.id != stop.id })
            touch(track)
        }
        try? context.persist()
    }

    /// Puts a task on a stop, linking it to the stop's track when it is not already. Pass nil to take it off its stop.
    static func assign(_ item: AgendaItem, to stop: TrackStop?, in context: ModelContext) {
        if let stop, let track = stop.thread, !item.liveTracks.contains(where: { $0.id == track.id }) {
            AssociationService.applyLink(thread: track, onto: item)
        }
        item.stop = stop
        item.touch()
        item.project?.touch()
        try? context.persist()
    }

    /// Rewrites a track's stops in the order given. An entry with an id keeps that stop and its tasks;
    /// an entry without one is new; a stop left out is removed and its tasks stay on the track.
    static func replace(on track: ProjectThread, with entries: [StopEntry], in context: ModelContext) throws {
        let existing = Dictionary(uniqueKeysWithValues: track.stops.map { ($0.id, $0) })
        var kept: [TrackStop] = []
        for entry in entries {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = entry.id {
                guard let stop = existing[id] else { throw StopStoreError.notOnTrack(id) }
                guard !kept.contains(where: { $0.id == id }) else { throw StopStoreError.listedTwice(id) }
                if !title.isEmpty { stop.title = title }
                if let body = entry.body { stop.body = body }
                if let done = entry.isDone { stop.isDone = done }
                stop.updatedAt = .now
                kept.append(stop)
            } else {
                guard !title.isEmpty else { throw StopStoreError.untitled }
                let stop = TrackStop(title: title, body: entry.body ?? "", order: kept.count, thread: track)
                stop.isDone = entry.isDone ?? false
                context.insert(stop)
                kept.append(stop)
            }
        }
        let keptIDs = Set(kept.map(\.id))
        for stop in track.stops where !keptIDs.contains(stop.id) {
            context.delete(stop)
        }
        renumber(kept)
        touch(track)
        try? context.persist()
    }

    /// Turns a child track into the last stop on its parent. The stop takes the child's title, and its summary
    /// and body as the stop's text. The child's tasks move onto the stop; its decisions, notes, and chats move
    /// to the parent. The child is then removed.
    @discardableResult
    static func absorb(_ child: ProjectThread, in context: ModelContext) throws -> TrackStop {
        guard let parent = child.parent else { throw StopStoreError.noParent }
        guard child.children.isEmpty else { throw StopStoreError.hasChildren }
        let text = [child.summary, child.body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let stop = TrackStop(
            title: child.title,
            body: text,
            order: (parent.stops.map(\.order).max() ?? -1) + 1,
            thread: parent
        )
        stop.isDone = child.status == .completed || child.status == .rejected
        context.insert(stop)
        // The child's own stops follow it onto the parent.
        for (offset, inner) in child.orderedStops.enumerated() {
            inner.thread = parent
            inner.order = stop.order + 1 + offset
        }
        for item in AgendaStore.items(on: child, includingChildren: false) {
            // Link the parent first, so the task never sits on no track and loses its project.
            if !item.liveTracks.contains(where: { $0.id == parent.id }) {
                AssociationService.applyLink(thread: parent, onto: item)
            }
            AssociationService.unlink(threadID: child.id, from: item, in: context)
            if item.stop == nil { item.stop = stop }
            item.touch()
        }
        for decision in child.decisions { decision.thread = parent }
        for note in child.notes { note.thread = parent }
        for conversation in child.conversations { conversation.thread = parent }
        for tag in child.tags where !parent.tags.contains(where: { $0.id == tag.id }) {
            parent.tags.append(tag)
        }
        if let project = child.project, project.activeTrackID == child.id {
            project.activeTrackID = parent.id
        }
        DeletionMarks.remove(targetingIDs: [child.id], in: context)
        context.delete(child)
        touch(parent)
        try? context.persist()
        return stop
    }

    private static func renumber(_ ordered: [TrackStop]) {
        for (index, stop) in ordered.enumerated() where stop.order != index {
            stop.order = index
        }
    }

    private static func touch(_ track: ProjectThread) {
        track.updatedAt = .now
        track.project?.touch()
    }
}

enum StopStoreError: LocalizedError {
    case notOnTrack(UUID)
    case listedTwice(UUID)
    case untitled
    case noParent
    case hasChildren

    var errorDescription: String? {
        switch self {
        case .notOnTrack(let id): "Stop \(id.uuidString) is not on this track. Leave id out to add a new stop."
        case .listedTwice(let id): "Stop \(id.uuidString) is listed twice."
        case .untitled: "A new stop needs a title."
        case .noParent: "This track is not under another track, so there is nothing to make it a stop on."
        case .hasChildren: "This track has tracks under it. Turn those into stops first."
        }
    }
}

enum ThemeStore {
    /// Puts a track under the theme with this name, making the theme when the project has none by that name.
    /// An empty name takes the track out of its theme. A theme left with no tracks is removed.
    static func setTheme(_ name: String, on track: ProjectThread, in context: ModelContext) {
        guard let project = track.project else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = track.theme
        if trimmed.isEmpty {
            track.theme = nil
        } else if let existing = project.themes.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            track.theme = existing
        } else {
            let theme = TrackTheme(name: trimmed, order: (project.themes.map(\.order).max() ?? -1) + 1, project: project)
            context.insert(theme)
            track.theme = theme
        }
        if let previous, previous.id != track.theme?.id, previous.tracks.allSatisfy({ $0.id == track.id }) {
            context.delete(previous)
        }
        track.updatedAt = .now
        project.touch()
        try? context.persist()
    }

    static func rename(_ theme: TrackTheme, to name: String, in context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        theme.name = trimmed
        theme.project?.touch()
        try? context.persist()
    }
}

struct RequirementEntry {
    var id: UUID?
    var text: String
    var stopID: UUID?
    var taskID: UUID?
    var isChecked: Bool?
}

enum JunctionStore {
    @discardableResult
    static func add(
        _ kind: JunctionKind,
        first: ProjectThread,
        second: ProjectThread,
        heldStop: TrackStop? = nil,
        in context: ModelContext
    ) throws -> TrackJunction {
        try check(kind, first: first, second: second, heldStop: heldStop, ignoring: nil)
        let junction = TrackJunction(kind: kind, first: first, second: second, heldStop: kind == .wait ? heldStop : nil)
        context.insert(junction)
        touch(junction)
        try? context.persist()
        return junction
    }

    static func update(
        _ junction: TrackJunction,
        kind: JunctionKind,
        heldStop: TrackStop?,
        in context: ModelContext
    ) throws {
        guard let first = junction.first, let second = junction.second else { return }
        try check(kind, first: first, second: second, heldStop: heldStop, ignoring: junction)
        junction.kind = kind
        junction.heldStop = kind == .wait ? heldStop : nil
        touch(junction)
        try? context.persist()
    }

    @discardableResult
    static func addRequirement(
        _ text: String,
        stop: TrackStop? = nil,
        task: AgendaItem? = nil,
        to junction: TrackJunction,
        in context: ModelContext
    ) throws -> JunctionRequirement {
        try check(stop: stop, task: task, text: text, on: junction)
        let requirement = JunctionRequirement(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            order: (junction.requirements.map(\.order).max() ?? -1) + 1,
            junction: junction,
            stop: stop,
            task: task
        )
        context.insert(requirement)
        touch(junction)
        try? context.persist()
        return requirement
    }

    /// Only a requirement tied to no stop or task is ticked by hand.
    static func setChecked(_ checked: Bool, on requirement: JunctionRequirement, in context: ModelContext) {
        guard requirement.stop == nil, requirement.task == nil else { return }
        requirement.isChecked = checked
        if let junction = requirement.junction { touch(junction) }
        try? context.persist()
    }

    static func delete(_ requirement: JunctionRequirement, in context: ModelContext) {
        let junction = requirement.junction
        context.delete(requirement)
        if let junction { touch(junction) }
        try? context.persist()
    }

    static func delete(_ junction: TrackJunction, in context: ModelContext) {
        touch(junction)
        context.delete(junction)
        try? context.persist()
    }

    /// Rewrites a junction's requirements in the order given, the way StopStore.replace does for stops.
    static func replaceRequirements(
        on junction: TrackJunction,
        with entries: [RequirementEntry],
        in context: ModelContext
    ) throws {
        let existing = Dictionary(uniqueKeysWithValues: junction.requirements.map { ($0.id, $0) })
        var kept: [JunctionRequirement] = []
        for entry in entries {
            let stop = try entry.stopID.map { id in
                guard let found = try context.fetch(FetchDescriptor<TrackStop>(predicate: #Predicate { $0.id == id })).first else {
                    throw JunctionStoreError.unknownStop(id)
                }
                return found
            }
            let task = try entry.taskID.map { id in
                guard let found = try context.fetch(FetchDescriptor<AgendaItem>(predicate: #Predicate { $0.id == id })).first,
                      found.kind == .task else {
                    throw JunctionStoreError.unknownTask(id)
                }
                return found
            }
            try check(stop: stop, task: task, text: entry.text, on: junction, existing: entry.id.flatMap { existing[$0] })
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let requirement: JunctionRequirement
            if let id = entry.id {
                guard let found = existing[id] else { throw JunctionStoreError.notOnJunction(id) }
                guard !kept.contains(where: { $0.id == id }) else { throw JunctionStoreError.listedTwice(id) }
                requirement = found
                if !text.isEmpty { requirement.text = text }
                if entry.stopID != nil || entry.taskID != nil {
                    requirement.stop = stop
                    requirement.task = task
                }
            } else {
                requirement = JunctionRequirement(text: text, order: kept.count, junction: junction, stop: stop, task: task)
                context.insert(requirement)
            }
            if let checked = entry.isChecked, requirement.stop == nil, requirement.task == nil {
                requirement.isChecked = checked
            }
            kept.append(requirement)
        }
        let keptIDs = Set(kept.map(\.id))
        for requirement in junction.requirements where !keptIDs.contains(requirement.id) {
            context.delete(requirement)
        }
        for (index, requirement) in kept.enumerated() where requirement.order != index {
            requirement.order = index
        }
        touch(junction)
        try? context.persist()
    }

    /// The unmet wait that keeps this task from being worked on yet, if there is one. A wait holds its stop and
    /// every stop after it; tasks on no stop come after every stop, so they are held too.
    static func holding(_ item: AgendaItem, on track: ProjectThread) -> TrackJunction? {
        track.junctionsAsSecond.first { junction in
            guard junction.kind == .wait, !junction.isMet else { return false }
            guard let held = junction.heldStop, held.thread?.id == track.id, !held.isDone else { return true }
            guard let stop = item.stop, stop.thread?.id == track.id else { return true }
            return stop.order >= held.order
        }
    }

    /// Makes the two tracks one, once everything the junction lists has been reconciled. The second track's stops
    /// follow the first's; its tasks, decisions, notes, and chats move to the first. What the second track said, and
    /// what was reconciled, is kept as a note on the first. The second track is then removed.
    @discardableResult
    static func merge(_ junction: TrackJunction, in context: ModelContext) throws -> ProjectThread {
        guard junction.kind == .merge else { throw JunctionStoreError.notAMerge }
        guard let first = junction.first, let second = junction.second, let project = first.project else {
            throw JunctionStoreError.missingTrack
        }
        guard !junction.requirements.isEmpty else { throw JunctionStoreError.nothingToReconcile }
        let unmet = junction.orderedRequirements.filter { !$0.isMet }
        guard unmet.isEmpty else { throw JunctionStoreError.unmet(unmet.map(\.displayText)) }

        var record = [second.summary, second.body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        record.append("Reconciled before merging:\n" + junction.orderedRequirements.map { "- \($0.displayText)" }.joined(separator: "\n"))
        let title = second.title.isEmpty ? "Untitled" : second.title
        context.insert(Note(
            content: record.joined(separator: "\n\n"),
            project: project,
            title: "\(title) (merged into this track)",
            thread: first
        ))

        let base = (first.stops.map(\.order).max() ?? -1) + 1
        for (offset, stop) in second.orderedStops.enumerated() {
            stop.thread = first
            stop.order = base + offset
        }
        for item in AgendaStore.items(on: second, includingChildren: false) {
            // Link the first track before unlinking, so the task never sits on no track and loses its project.
            if !item.liveTracks.contains(where: { $0.id == first.id }) {
                AssociationService.applyLink(thread: first, onto: item)
            }
            AssociationService.unlink(threadID: second.id, from: item, in: context)
            item.touch()
        }
        for decision in second.decisions { decision.thread = first }
        for note in second.notes { note.thread = first }
        for conversation in second.conversations { conversation.thread = first }
        for child in second.children { child.parent = nil }
        for tag in second.tags where !first.tags.contains(where: { $0.id == tag.id }) {
            first.tags.append(tag)
        }
        // Other junctions on the second track now belong to the merged one.
        for other in second.junctions where other.id != junction.id {
            if other.first?.id == second.id { other.first = first }
            if other.second?.id == second.id { other.second = first }
            if other.first?.id == other.second?.id { context.delete(other) }
        }
        if project.activeTrackID == second.id { project.activeTrackID = first.id }
        DeletionMarks.remove(targetingIDs: [second.id], in: context)
        context.delete(junction)
        context.delete(second)
        first.updatedAt = .now
        project.touch()
        try? context.persist()
        return first
    }

    private static func check(
        _ kind: JunctionKind,
        first: ProjectThread,
        second: ProjectThread,
        heldStop: TrackStop?,
        ignoring: TrackJunction?
    ) throws {
        guard first.id != second.id else { throw JunctionStoreError.sameTrack }
        guard let project = first.project, project.id == second.project?.id else { throw JunctionStoreError.differentProjects }
        if let heldStop, kind == .wait, heldStop.thread?.id != second.id { throw JunctionStoreError.heldStopElsewhere }
        guard kind == .wait else { return }
        // A waits on B while B waits on A would hold both forever.
        var stack = [first]
        var seen: Set<UUID> = []
        while let current = stack.popLast() {
            if current.id == second.id { throw JunctionStoreError.cycle }
            guard seen.insert(current.id).inserted else { continue }
            stack.append(contentsOf: current.junctionsAsSecond
                .filter { $0.kind == .wait && $0.id != ignoring?.id }
                .compactMap(\.first))
        }
    }

    private static func check(
        stop: TrackStop?,
        task: AgendaItem?,
        text: String,
        on junction: TrackJunction,
        existing: JunctionRequirement? = nil
    ) throws {
        if stop != nil, task != nil { throw JunctionStoreError.stopAndTask }
        if stop == nil, task == nil, existing == nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JunctionStoreError.emptyRequirement
        }
        guard let stop else { return }
        let allowed = junction.kind == .wait ? [junction.first?.id] : [junction.first?.id, junction.second?.id]
        guard allowed.contains(stop.thread?.id) else {
            throw junction.kind == .wait ? JunctionStoreError.stopNotOnFirst : JunctionStoreError.stopNotOnEither
        }
    }

    private static func touch(_ junction: TrackJunction) {
        junction.updatedAt = .now
        junction.first?.updatedAt = .now
        junction.second?.updatedAt = .now
        junction.first?.project?.touch()
    }
}

enum JunctionStoreError: LocalizedError {
    case sameTrack
    case differentProjects
    case heldStopElsewhere
    case cycle
    case stopAndTask
    case emptyRequirement
    case stopNotOnFirst
    case stopNotOnEither
    case unknownStop(UUID)
    case unknownTask(UUID)
    case notOnJunction(UUID)
    case listedTwice(UUID)
    case notAMerge
    case missingTrack
    case nothingToReconcile
    case unmet([String])

    var errorDescription: String? {
        switch self {
        case .sameTrack: "A junction sits between two different tracks."
        case .differentProjects: "Both tracks have to be in the same project."
        case .heldStopElsewhere: "The stop that waits has to be on the track that waits."
        case .cycle: "These tracks would each be waiting on the other."
        case .stopAndTask: "A requirement can point at a stop or a task, not both."
        case .emptyRequirement: "A requirement needs some text, a stop, or a task."
        case .stopNotOnFirst: "On a wait, a requirement's stop has to be on the track being waited on."
        case .stopNotOnEither: "A requirement's stop has to be on one of the junction's two tracks."
        case .unknownStop(let id): "No stop with id \(id.uuidString)."
        case .unknownTask(let id): "No task with id \(id.uuidString)."
        case .notOnJunction(let id): "Requirement \(id.uuidString) is not on this junction. Leave id out to add a new one."
        case .listedTwice(let id): "Requirement \(id.uuidString) is listed twice."
        case .notAMerge: "This junction is a wait. Only a merge junction joins two tracks into one."
        case .missingTrack: "One of this junction's tracks is gone."
        case .nothingToReconcile: "List what has to be reconciled between the two tracks before merging them."
        case .unmet(let texts): "Not reconciled yet: \(texts.joined(separator: "; "))."
        }
    }
}

enum TasksFilter: String, CaseIterable, Identifiable, Sendable {
    case today
    case upcoming
    case inbox
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .inbox: "Inbox"
        case .all: "All"
        }
    }
}

struct TasksSection: Identifiable, Equatable {
    var id: String
    var title: String
    var items: [AgendaItem]

    static func == (lhs: TasksSection, rhs: TasksSection) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.items.map(\.id) == rhs.items.map(\.id)
    }
}

enum TasksLayout {
    static func sections(
        from tasks: [AgendaItem],
        filter: TasksFilter,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [TasksSection] {
        let open = tasks.filter { !$0.isCompleted }
        switch filter {
        case .today:
            let overdue = open.filter { task in
                guard let due = task.due else { return false }
                return TaskDue.isOverdue(due, now: now, calendar: calendar)
            }.sorted(by: TaskStore.boardSort)
            let today = open.filter { task in
                guard let due = task.due else { return false }
                return TaskDue.isDueToday(due, now: now, calendar: calendar)
            }.sorted(by: TaskStore.boardSort)
            var result: [TasksSection] = []
            if !overdue.isEmpty {
                result.append(TasksSection(id: "overdue", title: "Overdue", items: overdue))
            }
            if !today.isEmpty {
                result.append(TasksSection(id: "today", title: "Today", items: today))
            }
            return result

        case .upcoming:
            let upcoming = open.filter { task in
                guard let due = task.due else { return false }
                return TaskDue.isUpcoming(due, now: now, calendar: calendar)
            }
            let grouped = Dictionary(grouping: upcoming) { task -> Date in
                calendar.startOfDay(for: task.due ?? now)
            }
            return grouped.keys.sorted().map { day in
                TasksSection(
                    id: "day-\(day.timeIntervalSinceReferenceDate)",
                    title: TaskDue.dayHeading(day, now: now, calendar: calendar),
                    items: (grouped[day] ?? []).sorted(by: TaskStore.boardSort)
                )
            }

        case .inbox:
            let inbox = open.filter { $0.project == nil }.sorted(by: TaskStore.boardSort)
            return inbox.isEmpty ? [] : [TasksSection(id: "inbox", title: "Inbox", items: inbox)]

        case .all:
            let inbox = open.filter { $0.project == nil }.sorted(by: TaskStore.boardSort)
            var result: [TasksSection] = []
            if !inbox.isEmpty {
                result.append(TasksSection(id: "inbox", title: "Inbox", items: inbox))
            }
            let assigned = Dictionary(grouping: open.filter { $0.project != nil }) { $0.project!.id }
            let projects = assigned.values.compactMap { items -> TasksSection? in
                guard let project = items.first?.project else { return nil }
                let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return TasksSection(
                    id: "project-\(project.id.uuidString)",
                    title: name.isEmpty ? "Untitled" : name,
                    items: items.sorted(by: TaskStore.boardSort)
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return result + projects
        }
    }
}
