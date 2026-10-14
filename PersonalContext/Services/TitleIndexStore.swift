import Foundation
import SwiftData

enum TitleIndexStore {
    static func applyPending(in context: ModelContext) {
        let start = ContinuousClock.now
        let insertedCount = context.insertedModelsArray.count
        let changedCount = context.changedModelsArray.count
        let deletedCount = context.deletedModelsArray.count
        var deleted: [UUID] = []
        var removedProjects: [UUID] = []
        var marked: [UUID: Bool] = [:]
        var sources: [any PersistentModel] = []

        for model in context.deletedModelsArray {
            switch model {
            case is TitleIndex:
                continue
            case let mark as DeletionMark:
                marked[mark.targetID] = false
            case let project as Project:
                removedProjects.append(project.id)
            default:
                if let id = recordID(model) {
                    deleted.append(id)
                }
            }
        }

        for model in context.insertedModelsArray + context.changedModelsArray {
            switch model {
            case is TitleIndex:
                continue
            case let mark as DeletionMark:
                marked[mark.targetID] = true
            default:
                sources.append(model)
            }
        }

        for id in removedProjects {
            removeProject(id, in: context)
        }
        for id in deleted {
            remove(id, in: context)
        }
        // A record emptied and deleted in one save is in both lists. Deleted wins, or its row would come back.
        let gone = Set(deleted)
        for source in sources where recordID(source).map({ !gone.contains($0) }) ?? true {
            upsert(source, in: context)
        }
        for (id, isMarked) in marked {
            row(id, in: context)?.isMarked = isMarked
        }
        NavTrace.event(
            "index.apply inserted=\(insertedCount) changed=\(changedCount) deleted=\(deletedCount) sources=\(sources.count) \(NavTrace.elapsed(start))"
        )
    }

    static func backfillIfNeeded(in context: ModelContext) {
        let start = ContinuousClock.now
        let count = (try? context.fetchCount(FetchDescriptor<TitleIndex>())) ?? 0
        if count > 0 {
            pruneMissingTracks(in: context)
            NavTrace.event("index.backfill skip rows=\(count) \(NavTrace.elapsed(start))")
            return
        }
        rebuild(in: context)
        NavTrace.event("index.backfill rebuilt \(NavTrace.elapsed(start))")
    }

    /// Drops rows for tracks that no longer exist. Older builds left one behind when a track was merged or made a stop.
    static func pruneMissingTracks(in context: ModelContext) {
        let live = Set(fetch(ProjectThread.self, in: context).map(\.id))
        let kind = TitleIndexKind.track.rawValue
        let rows = fetch(TitleIndex.self, predicate: #Predicate { $0.kindRaw == kind }, in: context)
        let stale = rows.filter { !live.contains($0.id) }
        guard !stale.isEmpty else { return }
        stale.forEach(context.delete)
        try? context.save()
    }

    static func rebuild(in context: ModelContext) {
        NavTrace.measure("index.rebuild") {
            for row in (try? context.fetch(FetchDescriptor<TitleIndex>())) ?? [] {
                context.delete(row)
            }
            try? context.save()
            // Every row is new, so look rows up in memory instead of fetching per record.
            let fresh = FreshRows()
            for project in fetch(Project.self, in: context) { upsert(project, in: context, fresh: fresh) }
            for thread in fetch(ProjectThread.self, in: context) { upsert(thread, in: context, fresh: fresh) }
            for note in fetch(Note.self, in: context) { upsert(note, in: context, fresh: fresh) }
            for decision in fetch(Decision.self, in: context) { upsert(decision, in: context, fresh: fresh) }
            for conversation in fetch(Conversation.self, in: context) { upsert(conversation, in: context, fresh: fresh) }
            for task in fetch(AgendaItem.self, in: context) where task.kind == .task { upsert(task, in: context, fresh: fresh) }
            for run in fetch(AgentRun.self, in: context) { upsert(run, in: context, fresh: fresh) }
            for mark in fetch(DeletionMark.self, in: context) {
                fresh.rows[mark.targetID]?.isMarked = true
            }
            try? context.save()
        }
    }

    static func row(_ id: UUID, in context: ModelContext) -> TitleIndex? {
        let match = id
        return fetch(TitleIndex.self, predicate: #Predicate { $0.id == match }, limit: 1, in: context).first
    }

    static func project(_ id: UUID, in context: ModelContext) -> Project? {
        let match = id
        return fetch(Project.self, predicate: #Predicate { $0.id == match }, limit: 1, in: context).first
    }

    static func thread(_ id: UUID, in context: ModelContext) -> ProjectThread? {
        let match = id
        return fetch(ProjectThread.self, predicate: #Predicate { $0.id == match }, limit: 1, in: context).first
    }

    static func note(_ id: UUID, in context: ModelContext) -> Note? {
        let match = id
        return fetch(Note.self, predicate: #Predicate { $0.id == match }, limit: 1, in: context).first
    }

    static func decision(_ id: UUID, in context: ModelContext) -> Decision? {
        let match = id
        return fetch(Decision.self, predicate: #Predicate { $0.id == match }, limit: 1, in: context).first
    }

    static func conversation(_ id: UUID, in context: ModelContext) -> Conversation? {
        let match = id
        return fetch(Conversation.self, predicate: #Predicate { $0.id == match }, limit: 1, in: context).first
    }

    static func task(_ id: UUID, in context: ModelContext) -> AgendaItem? {
        let match = id
        return fetch(AgendaItem.self, predicate: #Predicate { $0.id == match }, limit: 1, in: context).first
    }

    static func run(_ id: UUID, in context: ModelContext) -> AgentRun? {
        let match = id
        return fetch(AgentRun.self, predicate: #Predicate { $0.id == match }, limit: 1, in: context).first
    }

    static func titles(
        kind: TitleIndexKind? = nil,
        projectID: UUID? = nil,
        in context: ModelContext
    ) -> [TitleIndex] {
        let kindRaw = kind?.rawValue ?? ""
        let projectKey = projectID?.uuidString.lowercased() ?? ""
        let rows: [TitleIndex]
        if let kind, projectID != nil {
            rows = fetch(
                TitleIndex.self,
                predicate: #Predicate { $0.kindRaw == kindRaw && $0.projectIDString == projectKey },
                in: context
            )
        } else if let kind {
            rows = fetch(TitleIndex.self, predicate: #Predicate { $0.kindRaw == kindRaw }, in: context)
        } else if projectID != nil {
            rows = fetch(TitleIndex.self, predicate: #Predicate { $0.projectIDString == projectKey }, in: context)
        } else {
            rows = fetch(TitleIndex.self, in: context)
        }
        return rows.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func trackTree(from rows: [TitleIndex]) -> [TrackNode] {
        let tracks = rows.filter { $0.kind == .track }
        var grouped: [String: [TitleIndex]] = [:]
        for row in tracks {
            grouped[row.parentIDString, default: []].append(row)
        }
        func nodes(parent: String) -> [TrackNode] {
            (grouped[parent] ?? [])
                .sorted { $0.createdAt < $1.createdAt }
                .map { row in
                    TrackNode(
                        id: row.id,
                        title: row.displayTitle,
                        kind: row.threadKind,
                        status: row.threadStatus,
                        createdAt: row.createdAt,
                        children: nodes(parent: row.id.uuidString.lowercased())
                    )
                }
        }
        return nodes(parent: "")
    }

    static func flattenedTracks(_ roots: [TrackNode]) -> [TrackNode] {
        roots.flatMap { [$0] + flattenedTracks($0.children) }
    }
}

extension ModelContext {
    func persist() throws {
        let start = ContinuousClock.now
        TitleIndexStore.applyPending(in: self)
        try save()
        NavTrace.event("store.persist \(NavTrace.elapsed(start))")
    }
}

private extension TitleIndexStore {
    /// Rows inserted by a rebuild, keyed by record id.
    final class FreshRows {
        var rows: [UUID: TitleIndex] = [:]
    }

    static func existing(_ id: UUID, in context: ModelContext, fresh: FreshRows?) -> TitleIndex? {
        if let fresh { return fresh.rows[id] }
        return row(id, in: context)
    }

    /// Each case names `fresh:` so the call picks the typed overload. Without it Swift prefers this
    /// function, which needs no default argument, and it calls itself until the stack runs out.
    static func upsert(_ model: any PersistentModel, in context: ModelContext) {
        switch model {
        case let project as Project: upsert(project, in: context, fresh: nil)
        case let thread as ProjectThread: upsert(thread, in: context, fresh: nil)
        case let note as Note: upsert(note, in: context, fresh: nil)
        case let decision as Decision: upsert(decision, in: context, fresh: nil)
        case let conversation as Conversation: upsert(conversation, in: context, fresh: nil)
        case let task as AgendaItem where task.kind == .task: upsert(task, in: context, fresh: nil)
        case let run as AgentRun: upsert(run, in: context, fresh: nil)
        default: break
        }
    }

    static func upsert(_ project: Project, in context: ModelContext, fresh: FreshRows? = nil) {
        // A Space that collects records is listed with the Areas, not the projects.
        guard !project.collects else {
            remove(project.id, in: context)
            return
        }
        let previous = existing(project.id, in: context, fresh: fresh)
        let name = project.displayName
        write(
            id: project.id,
            kind: .project,
            title: project.name,
            owner: "Workspace",
            projectID: project.id,
            parentID: nil,
            updatedAt: project.updatedAt,
            createdAt: project.createdAt,
            statusRaw: project.status.rawValue,
            symbol: project.symbol,
            isPinned: project.isPinned,
            in: context,
            fresh: fresh
        )
        if fresh == nil, previous?.title != project.name {
            renameOwner(projectID: project.id, name: name, in: context)
        }
    }

    static func upsert(_ thread: ProjectThread, in context: ModelContext, fresh: FreshRows? = nil) {
        write(
            id: thread.id,
            kind: .track,
            title: thread.title,
            owner: thread.project?.displayName ?? "",
            projectID: thread.project?.id,
            parentID: thread.parent?.id,
            updatedAt: thread.updatedAt,
            createdAt: thread.createdAt,
            statusRaw: thread.status.rawValue,
            detailRaw: thread.kind.rawValue,
            symbol: thread.status == .completed ? "checkmark.circle" : TitleIndexKind.track.symbol,
            in: context,
            fresh: fresh
        )
        bumpProject(thread.project?.id, at: thread.updatedAt, in: context, fresh: fresh)
    }

    static func upsert(_ note: Note, in context: ModelContext, fresh: FreshRows? = nil) {
        write(
            id: note.id,
            kind: .note,
            title: note.title,
            owner: note.project?.displayName ?? "",
            projectID: note.project?.id,
            parentID: note.thread?.id,
            updatedAt: note.updatedAt,
            createdAt: note.createdAt,
            symbol: TitleIndexKind.note.symbol,
            in: context,
            fresh: fresh
        )
        bumpProject(note.project?.id, at: note.updatedAt, in: context, fresh: fresh)
    }

    static func upsert(_ decision: Decision, in context: ModelContext, fresh: FreshRows? = nil) {
        write(
            id: decision.id,
            kind: .decision,
            title: decision.title,
            owner: decision.project?.displayName ?? "",
            projectID: decision.project?.id,
            parentID: decision.thread?.id,
            updatedAt: decision.createdAt,
            createdAt: decision.createdAt,
            statusRaw: decision.status.rawValue,
            symbol: decision.status == .active ? "checkmark.seal" : "xmark.seal",
            in: context,
            fresh: fresh
        )
        bumpProject(decision.project?.id, at: decision.createdAt, in: context, fresh: fresh)
    }

    static func upsert(_ conversation: Conversation, in context: ModelContext, fresh: FreshRows? = nil) {
        write(
            id: conversation.id,
            kind: .chat,
            title: conversation.title,
            owner: conversation.project?.displayName ?? "Quick Ask",
            projectID: conversation.project?.id,
            parentID: conversation.thread?.id,
            updatedAt: conversation.updatedAt,
            createdAt: conversation.createdAt,
            symbol: TitleIndexKind.chat.symbol,
            isArchived: conversation.isArchived,
            in: context,
            fresh: fresh
        )
        bumpProject(conversation.project?.id, at: conversation.updatedAt, in: context, fresh: fresh)
    }

    static func upsert(_ task: AgendaItem, in context: ModelContext, fresh: FreshRows? = nil) {
        write(
            id: task.id,
            kind: .task,
            title: task.title,
            owner: task.project?.displayName ?? "Workspace",
            projectID: task.project?.id,
            updatedAt: task.updatedAt,
            createdAt: task.createdAt,
            statusRaw: task.workflowStatus.rawValue,
            symbol: TitleIndexKind.task.symbol,
            isArchived: task.isCompleted,
            in: context,
            fresh: fresh
        )
        bumpProject(task.project?.id, at: task.updatedAt, in: context, fresh: fresh)
    }

    static func upsert(_ run: AgentRun, in context: ModelContext, fresh: FreshRows? = nil) {
        write(
            id: run.id,
            kind: .run,
            title: run.title,
            owner: run.project?.displayName ?? "No project",
            projectID: run.project?.id,
            updatedAt: run.updatedAt,
            createdAt: run.createdAt,
            statusRaw: run.status.rawValue,
            symbol: TitleIndexKind.run.symbol,
            isBusy: run.status.isActive,
            in: context,
            fresh: fresh
        )
        bumpProject(run.project?.id, at: run.updatedAt, in: context, fresh: fresh)
    }

    static func write(
        id: UUID,
        kind: TitleIndexKind,
        title: String,
        owner: String,
        projectID: UUID?,
        parentID: UUID? = nil,
        updatedAt: Date,
        createdAt: Date,
        statusRaw: String = "",
        detailRaw: String = "",
        symbol: String,
        isArchived: Bool = false,
        isPinned: Bool = false,
        isBusy: Bool = false,
        in context: ModelContext,
        fresh: FreshRows?
    ) {
        if let existing = existing(id, in: context, fresh: fresh) {
            existing.kind = kind
            existing.title = title
            existing.owner = owner
            existing.projectID = projectID
            existing.parentID = parentID
            existing.updatedAt = updatedAt
            existing.createdAt = createdAt
            existing.statusRaw = statusRaw
            existing.detailRaw = detailRaw
            existing.symbol = symbol
            existing.isArchived = isArchived
            existing.isPinned = isPinned
            existing.isBusy = isBusy
            return
        }
        let row = TitleIndex(
            id: id,
            kind: kind,
            title: title,
            owner: owner,
            projectID: projectID,
            parentID: parentID,
            updatedAt: updatedAt,
            createdAt: createdAt,
            statusRaw: statusRaw,
            detailRaw: detailRaw,
            symbol: symbol,
            isArchived: isArchived,
            isPinned: isPinned,
            isBusy: isBusy
        )
        context.insert(row)
        fresh?.rows[id] = row
    }

    static func bumpProject(_ id: UUID?, at date: Date, in context: ModelContext, fresh: FreshRows?) {
        guard let id, let project = existing(id, in: context, fresh: fresh), date > project.updatedAt else { return }
        project.updatedAt = date
    }

    static func renameOwner(projectID: UUID, name: String, in context: ModelContext) {
        for row in titles(projectID: projectID, in: context) where row.kind != .project {
            row.owner = name
        }
    }

    static func remove(_ id: UUID, in context: ModelContext) {
        if let row = row(id, in: context) {
            context.delete(row)
        }
    }

    static func removeProject(_ id: UUID, in context: ModelContext) {
        for row in titles(projectID: id, in: context) {
            context.delete(row)
        }
        remove(id, in: context)
    }

    static func recordID(_ model: any PersistentModel) -> UUID? {
        switch model {
        case let project as Project: project.id
        case let thread as ProjectThread: thread.id
        case let note as Note: note.id
        case let decision as Decision: decision.id
        case let conversation as Conversation: conversation.id
        case let task as AgendaItem where task.kind == .task: task.id
        case let run as AgentRun: run.id
        default: nil
        }
    }

    static func fetch<T: PersistentModel>(
        _ type: T.Type,
        predicate: Predicate<T>? = nil,
        limit: Int? = nil,
        in context: ModelContext
    ) -> [T] {
        var descriptor = FetchDescriptor<T>()
        descriptor.predicate = predicate
        if let limit { descriptor.fetchLimit = limit }
        return (try? context.fetch(descriptor)) ?? []
    }
}
