import Foundation
import SwiftData

enum RunStoreError: LocalizedError, Equatable {
    case emptyBrief
    case taskNeedsProject
    case taskWrongProject
    case taskHasActiveRun
    case notTerminal
    case stillActive
    case invalidTransition
    case indexingIdentityLost

    var errorDescription: String? {
        switch self {
        case .emptyBrief: "Write a brief before starting."
        case .taskNeedsProject: "A task run needs a project."
        case .taskWrongProject: "That task is not in this project."
        case .taskHasActiveRun: "This task already has a run in progress."
        case .notTerminal: "Only a finished run can be deleted."
        case .stillActive: "Cancel the run on this task first."
        case .invalidTransition: "That run cannot move to that state."
        case .indexingIdentityLost:
            "The indexing run did not persist its purpose and attachment. It was not started."
        }
    }
}

enum RunStore {
    static let quitDetail = "Membrae stopped before this run finished."

    static func runs(in context: ModelContext, project: Project? = nil, status: RunStatus? = nil) -> [AgentRun] {
        let descriptor = FetchDescriptor<AgentRun>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return ((try? context.fetch(descriptor)) ?? []).filter { run in
            if let project, run.project?.id != project.id { return false }
            if let status, run.status != status { return false }
            return true
        }
    }

    static func workspaceRecent(in context: ModelContext, limit: Int = 10) -> [AgentRun] {
        Array(
            runs(in: context)
                .filter { $0.status.isTerminal }
                .prefix(limit)
        )
    }

    static func activeRuns(in context: ModelContext) -> [AgentRun] {
        runs(in: context).filter { $0.status.isActive }
    }

    static func activeRun(forTask id: UUID, in context: ModelContext) -> AgentRun? {
        activeRuns(in: context).first { $0.task?.id == id }
    }

    static func runs(originatedFromChat id: UUID, in context: ModelContext) -> [AgentRun] {
        runs(in: context).filter { $0.originChat?.id == id }
    }

    static func run(_ id: UUID, in context: ModelContext) -> AgentRun? {
        let descriptor = FetchDescriptor<AgentRun>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    static func enqueue(_ draft: NewRunDraft, in context: ModelContext) throws -> AgentRun {
        let brief = draft.brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { throw RunStoreError.emptyBrief }

        let project = try draft.projectID.map { try lookupProject($0, in: context) }
        let task = try draft.taskID.map { try lookupTask($0, in: context) }
        if let task {
            guard let project else { throw RunStoreError.taskNeedsProject }
            guard task.project?.id == project.id else { throw RunStoreError.taskWrongProject }
            if activeRun(forTask: task.id, in: context) != nil {
                throw RunStoreError.taskHasActiveRun
            }
        }

        let run = AgentRun(
            brief: brief,
            origin: draft.origin,
            providerID: draft.providerID,
            modelID: draft.modelID,
            pathRaw: draft.pathRaw.isEmpty ? "local" : draft.pathRaw,
            project: project,
            task: task,
            originChat: try draft.originChatID.map { try lookupConversation($0, in: context) },
            retryOf: try draft.retryOfID.map { try lookupRun($0, in: context) },
            purpose: draft.purpose,
            indexedAttachmentID: draft.indexedAttachmentID
        )
        run.repositoryLocators = draft.repositoryLocators
        run.append(.queued)
        context.insert(run)
        project?.touch()
        try save(context)
        try confirmPersistedIndexingIdentity(run, draft: draft, in: context)
        return run
    }

    static func retryDraft(from run: AgentRun) -> NewRunDraft {
        NewRunDraft(
            brief: run.brief,
            projectID: run.project?.id,
            taskID: run.task?.id,
            originChatID: run.originChat?.id,
            origin: run.origin,
            providerID: run.providerID,
            modelID: run.modelID,
            pathRaw: run.pathRaw,
            repositoryLocators: run.repositoryLocators,
            purpose: run.purpose,
            indexedAttachmentID: run.indexedAttachmentID,
            retryOfID: run.id
        )
    }

    static func transition(_ run: AgentRun, to status: RunStatus, detail: String = "", in context: ModelContext) throws {
        guard allowed(from: run.status, to: status) else { throw RunStoreError.invalidTransition }
        apply(status, on: run, detail: detail, event: eventKind(for: status))
        try save(context)
    }

    static func succeed(_ run: AgentRun, summary: String, links: [RunResultLink], in context: ModelContext) throws {
        guard run.status == .running || run.status == .waiting || run.status == .queued else {
            throw RunStoreError.invalidTransition
        }
        run.resultSummary = summary
        run.resultLinks = links
        apply(.succeeded, on: run, detail: "", event: .succeeded)
        try save(context)
    }

    static func fail(_ run: AgentRun, detail: String, event: RunEventKind = .failed, in context: ModelContext) throws {
        guard !run.status.isTerminal else { throw RunStoreError.invalidTransition }
        apply(.failed, on: run, detail: detail, event: event)
        CodeReferenceStore.discardStaged(for: run, in: context)
        try save(context)
    }

    /// Worker may have finished; indexing did not publish. Keep the worker text, fail the run.
    static func failUnpublishedIndex(
        _ run: AgentRun,
        workerSummary: String,
        detail: String,
        in context: ModelContext
    ) throws {
        guard !run.status.isTerminal else { throw RunStoreError.invalidTransition }
        let worker = workerSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = reason.hasPrefix("Indexing did not publish")
            ? reason
            : "Indexing did not publish. \(reason.isEmpty ? "No validated reference was stored." : reason)"
        run.resultSummary = worker.isEmpty ? headline : "\(headline)\n\nWorker summary:\n\(worker)"
        apply(.failed, on: run, detail: headline, event: .failed)
        CodeReferenceStore.discardStaged(for: run, in: context)
        try save(context)
    }

    static func cancel(_ run: AgentRun, in context: ModelContext) throws {
        guard run.status.isActive else { throw RunStoreError.invalidTransition }
        apply(.cancelled, on: run, detail: "Cancelled.", event: .cancelled)
        CodeReferenceStore.discardStaged(for: run, in: context)
        try save(context)
    }

    static func deleteTerminal(_ run: AgentRun, in context: ModelContext) throws {
        guard run.status.isTerminal else { throw RunStoreError.notTerminal }
        let project = run.project
        context.delete(run)
        project?.touch()
        try save(context)
    }

    static func canDelete(_ task: AgendaItem, in context: ModelContext) -> Bool {
        activeRun(forTask: task.id, in: context) == nil
    }

    static func recoverAbandoned(in context: ModelContext) {
        let abandoned = activeRuns(in: context).filter { $0.status == .running || $0.status == .waiting }
        guard !abandoned.isEmpty else { return }
        for run in abandoned {
            apply(.failed, on: run, detail: quitDetail, event: .quit)
            CodeReferenceStore.discardStaged(for: run, in: context)
        }
        try? save(context)
    }

    static func cancelActive(in project: Project, context: ModelContext) {
        for run in activeRuns(in: context) where run.project?.id == project.id {
            apply(.cancelled, on: run, detail: "Cancelled because the project was deleted.", event: .cancelled)
            CodeReferenceStore.discardStaged(for: run, in: context)
        }
        try? save(context)
    }

    private static func apply(_ status: RunStatus, on run: AgentRun, detail: String, event: RunEventKind) {
        let now = Date.now
        if run.startedAt == nil, status == .running {
            run.startedAt = now
        }
        if status.isTerminal {
            run.finishedAt = now
        }
        run.status = status
        run.statusDetail = detail
        run.append(event, detail: detail, at: now)
    }

    private static func allowed(from: RunStatus, to: RunStatus) -> Bool {
        switch (from, to) {
        case (.queued, .running), (.queued, .failed), (.queued, .cancelled):
            return true
        case (.running, .waiting), (.running, .succeeded), (.running, .failed), (.running, .cancelled):
            return true
        case (.waiting, .running), (.waiting, .failed), (.waiting, .cancelled):
            return true
        default:
            return false
        }
    }

    private static func eventKind(for status: RunStatus) -> RunEventKind {
        switch status {
        case .queued: .queued
        case .running: .running
        case .waiting: .waiting
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    private static func lookupProject(_ id: UUID, in context: ModelContext) throws -> Project {
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })
        guard let project = try context.fetch(descriptor).first else {
            throw RunStoreError.taskWrongProject
        }
        return project
    }

    private static func lookupTask(_ id: UUID, in context: ModelContext) throws -> AgendaItem {
        let descriptor = FetchDescriptor<AgendaItem>(predicate: #Predicate { $0.id == id })
        guard let item = try context.fetch(descriptor).first, item.kind == .task else {
            throw RunStoreError.taskWrongProject
        }
        return item
    }

    private static func lookupConversation(_ id: UUID, in context: ModelContext) throws -> Conversation {
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        guard let conversation = try context.fetch(descriptor).first else {
            throw RunStoreError.taskWrongProject
        }
        return conversation
    }

    private static func lookupRun(_ id: UUID, in context: ModelContext) throws -> AgentRun {
        guard let run = run(id, in: context) else { throw RunStoreError.invalidTransition }
        return run
    }

    private static func confirmPersistedIndexingIdentity(
        _ run: AgentRun,
        draft: NewRunDraft,
        in context: ModelContext
    ) throws {
        guard draft.purpose == .indexRepository else { return }
        guard let expected = draft.indexedAttachmentID else {
            throw RunStoreError.indexingIdentityLost
        }
        guard run.purpose == .indexRepository, run.indexedAttachmentID == expected else {
            throw RunStoreError.indexingIdentityLost
        }
        guard let url = context.container.configurations.first?.url,
              context.container.configurations.contains(where: { !$0.isStoredInMemoryOnly }),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        guard let disk = Store.persistedAgentRunIdentity(runID: run.id, at: url),
              disk.purpose == RunPurpose.indexRepository.rawValue,
              disk.attachmentID.compare(expected.uuidString, options: .caseInsensitive) == .orderedSame
        else {
            throw RunStoreError.indexingIdentityLost
        }
    }

    private static func save(_ context: ModelContext) throws {
        try context.save()
    }
}
