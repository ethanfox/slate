import Foundation
import SwiftData

enum ComposerToken {
    case search
    case mention
    case tag
}

struct ComposerQuery: Equatable {
    var text: String
    var token: ComposerToken
    var tokenQuery: String
    var prefix: String

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func parse(_ raw: String) -> ComposerQuery {
        let mention = lastTrigger(in: raw, mark: "@")
        let tag = lastTrigger(in: raw, mark: "#")
        switch (mention, tag) {
        case (let mention?, let tag?) where mention.index > tag.index:
            return ComposerQuery(text: raw, token: .mention, tokenQuery: mention.query, prefix: mention.prefix)
        case (_, let tag?):
            return ComposerQuery(text: raw, token: .tag, tokenQuery: tag.query, prefix: tag.prefix)
        case (let mention?, nil):
            return ComposerQuery(text: raw, token: .mention, tokenQuery: mention.query, prefix: mention.prefix)
        default:
            return ComposerQuery(text: raw, token: .search, tokenQuery: "", prefix: raw)
        }
    }

    private static func lastTrigger(in raw: String, mark: Character) -> (index: String.Index, query: String, prefix: String)? {
        guard let index = raw.lastIndex(of: mark) else { return nil }
        if mark == "@", index > raw.startIndex {
            let before = raw[raw.index(before: index)]
            if before.isLetter || before.isNumber { return nil }
        }
        let queryStart = raw.index(after: index)
        let query = String(raw[queryStart...])
        if query.contains(where: { $0.isWhitespace }) { return nil }
        return (index, query, String(raw[..<index]))
    }
}

enum ComposerHitKind: String, Hashable, Sendable {
    case project
    case track
    case note
    case decision
    case conversation
    case task
    case tag
    case file

    var label: String {
        switch self {
        case .project: "Space"
        case .track: "Track"
        case .note: "Note"
        case .decision: "Decision"
        case .conversation: "Chat"
        case .task: "Task"
        case .tag: "Tag"
        case .file: "File"
        }
    }

    var symbol: String {
        switch self {
        case .project: "square.stack"
        case .track: TrackStyle.symbol
        case .note: "note.text"
        case .decision: "checkmark.seal"
        case .conversation: "bubble.left"
        case .task: "checklist"
        case .tag: "number"
        case .file: "doc"
        }
    }

    var sourceKind: ChatSource.Kind? {
        switch self {
        case .project: .project
        case .track: .thread
        case .note: .note
        case .decision: .decision
        case .conversation: .conversation
        case .task: .task
        case .tag, .file: nil
        }
    }
}

struct ComposerHit: Identifiable, Hashable, Sendable {
    var id: String
    var kind: ComposerHitKind
    var title: String
    var owner: String
    var excerpt: String
    var symbol: String
    var recordID: UUID?
    var projectID: UUID?
    var tagID: UUID?
    var attachmentID: UUID?
    var filePath: String?
    var revision: String?

    var ownerLabel: String {
        owner.isEmpty ? kind.label : owner
    }

    func asSource() -> ChatSource? {
        guard let kind = kind.sourceKind, let recordID else { return nil }
        return ChatSource(id: recordID.uuidString, title: title, url: nil, kind: kind, pin: true)
    }
}

enum ComposerSearch {
    static let resultLimit = 24
    static let fileLimit = 40

    static func excerpt(query: String, in text: String, radius: Int = 42) -> String {
        let haystack = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !haystack.isEmpty else { return "" }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return String(haystack.prefix(radius * 2)) }
        let range = (haystack as NSString).range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        )
        guard range.location != NSNotFound else { return String(haystack.prefix(radius * 2)) }
        let start = max(0, range.location - radius)
        let end = min((haystack as NSString).length, range.location + range.length + radius)
        var snippet = (haystack as NSString).substring(with: NSRange(location: start, length: end - start))
        if start > 0 { snippet = "…" + snippet }
        if end < (haystack as NSString).length { snippet += "…" }
        return snippet
    }

    static func matches(_ query: String, in fields: [String]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return fields.contains { $0.localizedStandardContains(needle) }
    }

    static func score(query: String, title: String, body: String) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 1 }
        if title.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return 100
        }
        if title.localizedStandardContains(needle) { return 60 }
        if body.localizedStandardContains(needle) { return 20 }
        return 0
    }

    @MainActor
    static func records(
        query: String,
        scope: ComposerScope,
        tags: [UUID],
        in context: ModelContext
    ) -> [ComposerHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            return recents(scope: scope, tags: tags, in: context)
        }
        let tagSet = Set(tags)
        let allowed = scope.projectID
        var hits: [(Int, Date, ComposerHit)] = []
        var pendingBodies: [() -> Void] = []
        var pendingTranscripts: [() -> Void] = []
        let indexed = TitleIndexStore.titles(projectID: allowed, in: context)

        func inScope(_ projectID: UUID?) -> Bool {
            if let allowed { return projectID == allowed }
            return true
        }

        func add(_ value: Int, _ date: Date, _ hit: ComposerHit) {
            hits.append((value, date, hit))
        }

        if tagSet.isEmpty, !indexed.isEmpty {
            for row in indexed where !row.isArchived && row.kind != .run {
                guard matches(query, in: [row.title, row.displayTitle]) else { continue }
                add(
                    score(query: query, title: row.displayTitle, body: ""),
                    row.updatedAt,
                    titleHit(row)
                )
            }
        } else {
        for project in fetchAll(Project.self, in: context) {
            guard inScope(project.id) else { continue }
            if tagSet.isEmpty, matches(query, in: [project.name, project.summary, project.currentDirection]) {
                add(
                    score(query: query, title: project.name, body: project.summary),
                    project.updatedAt,
                    hit(
                        kind: .project,
                        title: project.name,
                        owner: "Workspace",
                        excerpt: excerpt(query: query, in: project.summary.isEmpty ? project.currentDirection : project.summary),
                        symbol: project.symbol,
                        recordID: project.id,
                        projectID: project.id
                    )
                )
            }
        }

        for thread in fetchAll(ProjectThread.self, in: context) {
            guard inScope(thread.project?.id) else { continue }
            guard tagSet.isEmpty || carries(tagSet, on: thread.tags.map(\.id)) else { continue }
            if matches(query, in: [thread.title, thread.summary]) {
                add(
                    score(query: query, title: thread.title, body: thread.summary),
                    thread.updatedAt,
                    threadHit(thread, excerpt: excerpt(query: query, in: thread.summary))
                )
            } else {
                pendingBodies.append {
                    guard matches(query, in: [thread.body]) else { return }
                    add(
                        score(query: query, title: thread.title, body: thread.body),
                        thread.updatedAt,
                        threadHit(thread, excerpt: excerpt(query: query, in: thread.body))
                    )
                }
            }
        }

        for note in fetchAll(Note.self, in: context) {
            guard inScope(note.project?.id) else { continue }
            guard tagSet.isEmpty || carries(tagSet, on: note.tags.map(\.id)) else { continue }
            if matches(query, in: [note.title, note.source]) {
                add(
                    score(query: query, title: note.displayTitle, body: note.source),
                    note.updatedAt,
                    noteHit(note, excerpt: excerpt(query: query, in: note.source))
                )
            } else {
                pendingBodies.append {
                    guard matches(query, in: [note.content]) else { return }
                    add(
                        score(query: query, title: note.displayTitle, body: note.content),
                        note.updatedAt,
                        noteHit(note, excerpt: excerpt(query: query, in: note.content))
                    )
                }
            }
        }

        for decision in fetchAll(Decision.self, in: context) {
            guard inScope(decision.project?.id) else { continue }
            guard tagSet.isEmpty || carries(tagSet, on: decision.tags.map(\.id)) else { continue }
            if matches(query, in: [decision.title]) {
                add(
                    score(query: query, title: decision.title, body: ""),
                    decision.createdAt,
                    decisionHit(decision)
                )
            } else {
                pendingBodies.append {
                    let body = [decision.decision, decision.rationale].joined(separator: "\n")
                    guard matches(query, in: [body]) else { return }
                    add(
                        score(query: query, title: decision.title, body: body),
                        decision.createdAt,
                        decisionHit(decision, excerpt: excerpt(query: query, in: body))
                    )
                }
            }
        }

        for conversation in fetchAll(Conversation.self, in: context) where !conversation.isArchived {
            guard inScope(conversation.project?.id) else { continue }
            guard tagSet.isEmpty || carries(tagSet, on: conversation.tags.map(\.id)) else { continue }
            if matches(query, in: [conversation.title]) {
                add(
                    score(query: query, title: conversation.title, body: ""),
                    conversation.updatedAt,
                    conversationHit(conversation, excerpt: conversation.title)
                )
            } else {
                pendingTranscripts.append {
                    let body = conversation.orderedMessages.map(\.content).joined(separator: "\n")
                    guard matches(query, in: [body]) else { return }
                    add(
                        score(query: query, title: conversation.title, body: body),
                        conversation.updatedAt,
                        conversationHit(conversation, excerpt: excerpt(query: query, in: body))
                    )
                }
            }
        }

        for task in fetchAll(AgendaItem.self, in: context) where task.kind == .task {
            guard inScope(task.project?.id) else { continue }
            guard tagSet.isEmpty || carries(tagSet, on: task.tags.map(\.id)) else { continue }
            if matches(query, in: [task.title]) {
                add(
                    score(query: query, title: task.title, body: ""),
                    task.updatedAt,
                    taskHit(task)
                )
            } else {
                pendingBodies.append {
                    guard matches(query, in: [task.notes]) else { return }
                    add(
                        score(query: query, title: task.title, body: task.notes),
                        task.updatedAt,
                        taskHit(task, excerpt: excerpt(query: query, in: task.notes))
                    )
                }
            }
        }
        }

        if hits.count < resultLimit {
            for scan in pendingBodies { scan() }
        }
        if hits.count < resultLimit {
            for scan in pendingTranscripts { scan() }
        }

        return hits
            .sorted {
                if $0.0 != $1.0 { return $0.0 > $1.0 }
                return $0.1 > $1.1
            }
            .prefix(resultLimit)
            .map(\.2)
    }

    @MainActor
    static func recents(scope: ComposerScope, tags: [UUID], in context: ModelContext) -> [ComposerHit] {
        let tagSet = Set(tags)
        if tagSet.isEmpty {
            let rows = TitleIndexStore.titles(projectID: scope.projectID, in: context)
                .filter { !$0.isArchived && $0.kind != .run }
            if !rows.isEmpty {
                return rows.prefix(resultLimit).map(titleHit)
            }
        }
        var hits: [(Date, ComposerHit)] = []

        func take(_ hit: ComposerHit, date: Date) {
            hits.append((date, hit))
        }

        switch scope {
        case .workspace:
            for project in recent(Project.self, sort: SortDescriptor(\.updatedAt, order: .reverse), in: context) {
                take(
                    hit(
                        kind: .project,
                        title: project.name,
                        owner: "Workspace",
                        excerpt: project.summary,
                        symbol: project.symbol,
                        recordID: project.id,
                        projectID: project.id
                    ),
                    date: project.updatedAt
                )
            }
            for thread in recent(ProjectThread.self, sort: SortDescriptor(\.updatedAt, order: .reverse), in: context)
            where carries(tagSet, on: thread.tags.map(\.id)) {
                take(threadHit(thread, excerpt: thread.summary), date: thread.updatedAt)
            }
            for note in recent(Note.self, sort: SortDescriptor(\.updatedAt, order: .reverse), in: context)
            where carries(tagSet, on: note.tags.map(\.id)) {
                take(noteHit(note), date: note.updatedAt)
            }
            for decision in recent(Decision.self, sort: SortDescriptor(\.createdAt, order: .reverse), in: context)
            where carries(tagSet, on: decision.tags.map(\.id)) {
                take(decisionHit(decision), date: decision.createdAt)
            }
            for conversation in recent(Conversation.self, sort: SortDescriptor(\.updatedAt, order: .reverse), in: context)
            where !conversation.isArchived && carries(tagSet, on: conversation.tags.map(\.id)) {
                take(conversationHit(conversation), date: conversation.updatedAt)
            }
            for task in recent(AgendaItem.self, sort: SortDescriptor(\.updatedAt, order: .reverse), in: context)
            where task.kind == .task && carries(tagSet, on: task.tags.map(\.id)) {
                take(taskHit(task), date: task.updatedAt)
            }
        case .project(let id):
            guard let project = ((try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id }))) ?? []).first else {
                return []
            }
            for thread in project.threads.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(resultLimit)
            where carries(tagSet, on: thread.tags.map(\.id)) {
                take(threadHit(thread, excerpt: thread.summary), date: thread.updatedAt)
            }
            for note in project.notes.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(resultLimit)
            where carries(tagSet, on: note.tags.map(\.id)) {
                take(noteHit(note), date: note.updatedAt)
            }
            for decision in project.decisions.sorted(by: { $0.createdAt > $1.createdAt }).prefix(resultLimit)
            where carries(tagSet, on: decision.tags.map(\.id)) {
                take(decisionHit(decision), date: decision.createdAt)
            }
            for conversation in project.conversations.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(resultLimit)
            where !conversation.isArchived && carries(tagSet, on: conversation.tags.map(\.id)) {
                take(conversationHit(conversation), date: conversation.updatedAt)
            }
            for task in project.agendaItems.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(resultLimit)
            where task.kind == .task && carries(tagSet, on: task.tags.map(\.id)) {
                take(taskHit(task), date: task.updatedAt)
            }
        }

        return hits.sorted { $0.0 > $1.0 }.prefix(resultLimit).map(\.1)
    }

    @MainActor
    static func tags(query: String, in context: ModelContext) -> [ComposerHit] {
        let all = ((try? context.fetch(FetchDescriptor<Tag>())) ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return all.compactMap { tag in
            guard matches(query, in: [tag.displayName]) else { return nil }
            return hit(
                kind: .tag,
                title: tag.displayName,
                owner: "",
                excerpt: "",
                symbol: tag.symbol.isEmpty ? ComposerHitKind.tag.symbol : tag.symbol,
                tagID: tag.id
            )
        }
    }

    @MainActor
    static func files(
        query: String,
        scope: ComposerScope,
        in context: ModelContext
    ) -> [ComposerHit] {
        let projects = scopedProjects(scope, in: context)
        let storeURL = context.container.configurations.first?.url
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var hits: [ComposerHit] = []
        for project in projects {
            let attachments = project.codeAttachments.sorted { $0.createdAt < $1.createdAt }
            let roots = needle.isEmpty ? [] : ProjectCodeWorkspace.authorizedRoots(for: project, storeURL: storeURL)
            if needle.isEmpty || roots.isEmpty {
                for attachment in attachments {
                    let hay = [attachment.title, attachment.locator, attachment.subtitle]
                    guard matches(query, in: hay) else { continue }
                    hits.append(
                        hit(
                            kind: .file,
                            title: attachment.title,
                            owner: project.name,
                            excerpt: attachment.subtitle,
                            symbol: ComposerHitKind.file.symbol,
                            projectID: project.id,
                            attachmentID: attachment.id,
                            revision: attachment.defaultBranch
                        )
                    )
                }
                continue
            }
            for root in roots {
                let attachment = attachments.first {
                    $0.locator == root.locator || $0.title == root.title
                }
                hits.append(contentsOf: walk(root: root, query: query, project: project, attachment: attachment))
                if hits.count >= fileLimit { break }
            }
            if hits.count >= fileLimit { break }
        }
        return Array(hits.prefix(fileLimit))
    }

    @MainActor
    static func resolve(_ hit: ComposerHit, in context: ModelContext) -> String {
        guard let id = hit.recordID else {
            if hit.kind == .file, let path = hit.filePath { return readFile(at: path) }
            return hit.excerpt
        }
        switch hit.kind {
        case .project:
            let match = ((try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id }))) ?? []).first
            return [match?.summary, match?.currentDirection].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .track:
            let match = ((try? context.fetch(FetchDescriptor<ProjectThread>(predicate: #Predicate { $0.id == id }))) ?? []).first
            return [match?.summary, match?.body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .note:
            let match = ((try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id }))) ?? []).first
            return match?.content ?? hit.excerpt
        case .decision:
            let match = ((try? context.fetch(FetchDescriptor<Decision>(predicate: #Predicate { $0.id == id }))) ?? []).first
            return [match?.decision, match?.rationale].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .conversation:
            let match = ((try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id }))) ?? []).first
            return match?.orderedMessages
                .map { ChatTranscript.unpack($0.content).text }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n") ?? hit.excerpt
        case .task:
            let match = ((try? context.fetch(FetchDescriptor<AgendaItem>(predicate: #Predicate { $0.id == id }))) ?? []).first
            return [match?.title, match?.notes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .tag:
            return hit.title
        case .file:
            if let path = hit.filePath { return readFile(at: path) }
            return hit.excerpt
        }
    }

    @MainActor
    static func scopedProjects(_ scope: ComposerScope, in context: ModelContext) -> [Project] {
        let all = ((try? context.fetch(FetchDescriptor<Project>())) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        switch scope {
        case .workspace:
            return all
        case .project(let id):
            return all.filter { $0.id == id }
        }
    }

    @MainActor
    static func attachments(for scope: ComposerScope, in context: ModelContext) -> [CodeAttachment] {
        scopedProjects(scope, in: context).flatMap(\.codeAttachments)
    }

    private static func fetchAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private static func recent<T: PersistentModel>(
        _ type: T.Type,
        sort: SortDescriptor<T>,
        in context: ModelContext
    ) -> [T] {
        var descriptor = FetchDescriptor<T>(sortBy: [sort])
        descriptor.fetchLimit = resultLimit
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func titleHit(_ row: TitleIndex) -> ComposerHit {
        let kind: ComposerHitKind = switch row.kind {
        case .space: .project
        case .track: .track
        case .note: .note
        case .decision: .decision
        case .chat: .conversation
        case .task: .task
        case .run: .conversation
        }
        return hit(
            kind: kind,
            title: row.displayTitle,
            owner: row.owner,
            excerpt: "",
            symbol: row.symbol.isEmpty ? kind.symbol : row.symbol,
            recordID: row.id,
            projectID: row.kind == .space ? row.id : row.projectID
        )
    }

    private static func threadHit(_ thread: ProjectThread, excerpt: String) -> ComposerHit {
        hit(
            kind: .track,
            title: thread.title.isEmpty ? "Untitled" : thread.title,
            owner: thread.project?.name ?? "",
            excerpt: excerpt,
            symbol: TrackStyle.symbol,
            recordID: thread.id,
            projectID: thread.project?.id
        )
    }

    private static func noteHit(_ note: Note, excerpt: String = "") -> ComposerHit {
        hit(
            kind: .note,
            title: note.displayTitle,
            owner: note.project?.name ?? "",
            excerpt: excerpt,
            symbol: ComposerHitKind.note.symbol,
            recordID: note.id,
            projectID: note.project?.id
        )
    }

    private static func decisionHit(_ decision: Decision, excerpt: String = "") -> ComposerHit {
        hit(
            kind: .decision,
            title: decision.title.isEmpty ? "Untitled" : decision.title,
            owner: decision.project?.name ?? "",
            excerpt: excerpt,
            symbol: ComposerHitKind.decision.symbol,
            recordID: decision.id,
            projectID: decision.project?.id
        )
    }

    private static func conversationHit(_ conversation: Conversation, excerpt: String = "") -> ComposerHit {
        hit(
            kind: .conversation,
            title: conversation.title.isEmpty ? "New chat" : conversation.title,
            owner: conversation.project?.name ?? "Workspace",
            excerpt: excerpt,
            symbol: ComposerHitKind.conversation.symbol,
            recordID: conversation.id,
            projectID: conversation.project?.id
        )
    }

    private static func taskHit(_ task: AgendaItem, excerpt: String = "") -> ComposerHit {
        hit(
            kind: .task,
            title: task.title.isEmpty ? "Untitled" : task.title,
            owner: task.project?.name ?? "Workspace",
            excerpt: excerpt,
            symbol: ComposerHitKind.task.symbol,
            recordID: task.id,
            projectID: task.project?.id
        )
    }

    private static func carries(_ tags: Set<UUID>, on record: [UUID]) -> Bool {
        tags.isEmpty || !tags.isDisjoint(with: record)
    }

    private static func hit(
        kind: ComposerHitKind,
        title: String,
        owner: String,
        excerpt: String,
        symbol: String,
        recordID: UUID? = nil,
        projectID: UUID? = nil,
        tagID: UUID? = nil,
        attachmentID: UUID? = nil,
        filePath: String? = nil,
        revision: String? = nil
    ) -> ComposerHit {
        let identity = [recordID?.uuidString, tagID?.uuidString, attachmentID?.uuidString, filePath]
            .compactMap { $0 }
            .joined(separator: ":")
        return ComposerHit(
            id: "\(kind.rawValue):\(identity.isEmpty ? title : identity)",
            kind: kind,
            title: title,
            owner: owner,
            excerpt: excerpt,
            symbol: symbol,
            recordID: recordID,
            projectID: projectID,
            tagID: tagID,
            attachmentID: attachmentID,
            filePath: filePath,
            revision: revision
        )
    }

    private static func walk(
        root: ProjectCodeRoot,
        query: String,
        project: Project,
        attachment: CodeAttachment?
    ) -> [ComposerHit] {
        let url = URL(fileURLWithPath: root.path, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var hits: [ComposerHit] = []
        let skip = [".git", "node_modules", "build", "DerivedData", ".build"]
        for case let file as URL in enumerator {
            if skip.contains(file.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let isFile = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            let relative = file.path.replacingOccurrences(of: root.path.hasSuffix("/") ? root.path : root.path + "/", with: "")
            guard matches(query, in: [relative, file.lastPathComponent, root.title]) else { continue }
            hits.append(
                hit(
                    kind: .file,
                    title: file.lastPathComponent,
                    owner: "\(project.name) · \(root.title)",
                    excerpt: relative + (attachment?.defaultBranch.isEmpty == false ? " · \(attachment?.defaultBranch ?? "")" : ""),
                    symbol: ComposerHitKind.file.symbol,
                    projectID: project.id,
                    attachmentID: attachment?.id,
                    filePath: file.path,
                    revision: attachment?.defaultBranch
                )
            )
            if hits.count >= fileLimit { break }
        }
        return hits
    }

    private static func readFile(at path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path), data.count < 80_000 else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum ComposerScope: Hashable {
    case workspace
    case project(UUID)

    var projectID: UUID? {
        if case .project(let id) = self { return id }
        return nil
    }
}
