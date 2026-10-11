import AppKit
import Foundation
import Observation
import SwiftData

enum ComposerMentionTab: String, Hashable {
    case membrae
    case repos
}

enum ComposerPopup: Hashable {
    case none
    case actions
    case help
    case save(ComposerSaveKind)
}

enum ComposerSaveKind: String, Hashable, CaseIterable {
    case chat
    case note
    case track
    case task

    var title: String {
        switch self {
        case .chat: "Save as chat"
        case .note: "Save as note"
        case .track: "Save as track"
        case .task: "Save as task"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left"
        case .note: "note.text"
        case .track: TrackStyle.symbol
        case .task: "checklist"
        }
    }
}

struct ComposerAction: Identifiable, Hashable {
    var id: String
    var title: String
    var symbol: String
    var shortcut: String?

    static let open = ComposerAction(id: "open", title: "Open", symbol: "arrow.up.forward.square", shortcut: "↩")
    static let insert = ComposerAction(id: "insert", title: "Add", symbol: "plus", shortcut: "↩")
    static let attach = ComposerAction(id: "attach", title: "Add as context", symbol: "plus.circle")
    static let ask = ComposerAction(id: "ask", title: "Ask about this", symbol: "text.bubble")
    static let makeChat = ComposerAction(id: "chat", title: "Make chat", symbol: "bubble.left")
    static let saveNote = ComposerAction(id: "note", title: "Save as note", symbol: "note.text", shortcut: "↩")
    static let saveTrack = ComposerAction(id: "track", title: "Save as track", symbol: TrackStyle.symbol)
    static let saveTask = ComposerAction(id: "task", title: "Save as task", symbol: "checklist")
}

struct ComposerTagFilter: Identifiable, Hashable {
    var id: UUID
    var name: String
}

@MainActor
@Observable
final class ComposerSession {
    var isOpen = false
    var query = ""
    var draft = ""
    var tagFilters: [ComposerTagFilter] = []
    var mentions: [ComposerHit] = []
    var mentionTab = ComposerMentionTab.membrae
    var highlightIndex = 0
    var actionIndex = 0
    var actionQuery = ""
    var popup = ComposerPopup.none
    var scope = ComposerScope.workspace
    var focusNonce = 0
    var results: [ComposerHit] = []
    var savedChatID: UUID?
    private(set) var draftConversationID: UUID?
    private(set) var runtime: ChatRuntime?
    var visibleUserText: [UUID: String] = [:]
    var turnMentions: [UUID: [ComposerHit]] = [:]
    private(set) var focusNonceChat = 0

    @ObservationIgnored private var shortcutMonitor: Any?
    @ObservationIgnored private var app: AppModel?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var cachedAttachmentScope: ComposerScope?
    @ObservationIgnored private var lastToggleAt: TimeInterval = 0

    var parsed: ComposerQuery { ComposerQuery.parse(fieldText) }

    var fieldText: String { hasExchange ? draft : query }

    var hasExchange: Bool {
        guard let runtime else { return false }
        return !runtime.session.entries.isEmpty
    }

    var isGenerating: Bool { runtime?.session.isGenerating == true }

    var hasRepos: Bool { !cachedAttachments.isEmpty }

    var defaultAction: ComposerAction {
        switch parsed.token {
        case .mention, .tag:
            return ComposerAction.insert
        case .search:
            if hasExchange { return ComposerAction(id: "send", title: "Send", symbol: "arrow.up", shortcut: "↩") }
            if shouldAsk { return ComposerAction.ask }
            return ComposerAction.open
        }
    }

    var shouldAsk: Bool {
        let text = parsed.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mentions.isEmpty && !text.isEmpty { return true }
        if text.hasSuffix("?") { return true }
        if results.isEmpty && !text.isEmpty { return true }
        return false
    }

    var highlighted: ComposerHit? {
        results.indices.contains(highlightIndex) ? results[highlightIndex] : nil
    }

    var actions: [ComposerAction] {
        let available: [ComposerAction]
        if hasExchange, parsed.token == .search, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            available = [.saveNote, .saveTrack, .saveTask, .makeChat]
        } else if parsed.token == .mention || parsed.token == .tag {
            available = highlighted == nil ? [] : [ComposerAction.insert, ComposerAction.open, ComposerAction.attach, ComposerAction.ask]
        } else if highlighted != nil {
            available = [ComposerAction.open, ComposerAction.attach, ComposerAction.ask]
        } else {
            return []
        }
        let needle = actionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return available }
        return available.filter { $0.title.localizedStandardContains(needle) }
    }

    var highlightedAction: ComposerAction? {
        actions.indices.contains(actionIndex) ? actions[actionIndex] : nil
    }

    private var cachedAttachments: [CodeAttachment] = []

    func attach(_ app: AppModel) {
        self.app = app
        installShortcuts()
    }

    func toggle() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastToggleAt < 0.05 { return }
        lastToggleAt = now
        if isOpen {
            if popup == .actions {
                closePopup()
            } else {
                openActions()
            }
        } else {
            open()
        }
    }

    func open() {
        isOpen = true
        popup = .none
        focusNonce += 1
        Task { @MainActor in
            await Task.yield()
            refresh(in: app?.container.mainContext)
        }
    }

    func close() {
        refreshTask?.cancel()
        refreshTask = nil
        cachedAttachmentScope = nil
        discardDraftIfNeeded()
        isOpen = false
        query = ""
        draft = ""
        tagFilters = []
        mentions = []
        mentionTab = .membrae
        highlightIndex = 0
        actionIndex = 0
        actionQuery = ""
        popup = .none
        scope = .workspace
        results = []
        savedChatID = nil
        draftConversationID = nil
        runtime = nil
        visibleUserText = [:]
        turnMentions = [:]
    }

    func setField(_ text: String, context: ModelContext?) {
        let current = hasExchange ? draft : query
        if hasExchange {
            draft = text
        } else {
            query = text
        }
        guard text != current else { return }
        if parsed.token != .mention { mentionTab = .membrae }
        if popup != .none { closePopup() }
        scheduleRefresh(in: context)
    }

    func refresh(in context: ModelContext?) {
        refreshTask?.cancel()
        refreshTask = nil
        applyResults(in: context)
    }

    private func scheduleRefresh(in context: ModelContext?) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            applyResults(in: context)
        }
    }

    private func applyResults(in context: ModelContext?) {
        guard let context else {
            results = []
            return
        }
        let parsed = parsed
        let next: [ComposerHit]
        switch parsed.token {
        case .tag:
            next = ComposerSearch.tags(query: parsed.tokenQuery, in: context)
        case .mention:
            if cachedAttachmentScope != scope {
                cachedAttachments = ComposerSearch.attachments(for: scope, in: context)
                cachedAttachmentScope = scope
            }
            if mentionTab == .repos {
                next = ComposerSearch.files(query: parsed.tokenQuery, scope: scope, in: context)
            } else {
                next = ComposerSearch.records(query: parsed.tokenQuery, scope: scope, tags: tagFilters.map(\.id), in: context)
            }
        case .search:
            next = ComposerSearch.records(
                query: hasExchange ? "" : parsed.prefix,
                scope: scope,
                tags: tagFilters.map(\.id),
                in: context
            )
        }
        let selected = highlighted?.id
        if next != results {
            results = next
        }
        if let selected, let index = results.firstIndex(where: { $0.id == selected }) {
            highlightIndex = index
        } else if highlightIndex >= results.count {
            highlightIndex = max(0, results.count - 1)
        }
    }

    func moveHighlight(_ step: Int) {
        guard !results.isEmpty else { return }
        highlightIndex = (highlightIndex + step + results.count) % results.count
    }

    func moveAction(_ step: Int) {
        guard !actions.isEmpty else { return }
        actionIndex = (actionIndex + step + actions.count) % actions.count
    }

    func confirm(app: AppModel, context: ModelContext) {
        refresh(in: context)
        switch popup {
        case .actions:
            performHighlightedAction(app: app, context: context)
        case .help:
            closePopup()
        case .save:
            break
        case .none:
            performDefault(app: app, context: context)
        }
    }

    func performDefault(app: AppModel, context: ModelContext) {
        if hasExchange, parsed.token == .search {
            send(app: app, context: context)
            return
        }
        switch parsed.token {
        case .mention:
            insertMention(context: context)
        case .tag:
            insertTag(context: context)
        case .search:
            if shouldAsk {
                ask(app: app, context: context, hit: highlighted)
            } else {
                openHighlighted(app: app, context: context)
            }
        }
    }

    func performHighlightedAction(app: AppModel, context: ModelContext) {
        guard let action = highlightedAction else { return }
        switch action.id {
        case ComposerAction.open.id:
            openHighlighted(app: app, context: context)
        case ComposerAction.insert.id:
            if parsed.token == .tag {
                insertTag(context: context)
            } else {
                insertMention(context: context)
            }
        case ComposerAction.attach.id:
            attachHighlighted(context: context)
        case ComposerAction.ask.id:
            ask(app: app, context: context, hit: highlighted)
        case ComposerAction.makeChat.id:
            presentSave(.chat)
        case ComposerAction.saveNote.id:
            presentSave(.note)
        case ComposerAction.saveTrack.id:
            presentSave(.track)
        case ComposerAction.saveTask.id:
            presentSave(.task)
        case "send":
            send(app: app, context: context)
        default:
            break
        }
    }

    func openHighlighted(app: AppModel, context: ModelContext) {
        guard let hit = highlighted else { return }
        open(hit, app: app, context: context)
        close()
    }

    func open(_ hit: ComposerHit, app: AppModel, context: ModelContext) {
        switch hit.kind {
        case .project:
            if let id = hit.recordID,
               let project = fetch(Project.self, id: id, in: context) {
                app.open(project)
            }
        case .track:
            if let id = hit.recordID,
               let thread = fetch(ProjectThread.self, id: id, in: context) {
                app.open(thread)
            }
        case .note:
            if let id = hit.recordID,
               let note = fetch(Note.self, id: id, in: context) {
                app.open(note)
            }
        case .decision:
            if let id = hit.recordID,
               let decision = fetch(Decision.self, id: id, in: context) {
                app.open(decision)
            }
        case .conversation:
            if let id = hit.recordID,
               let conversation = fetch(Conversation.self, id: id, in: context) {
                app.open(conversation)
            }
        case .task:
            if let id = hit.recordID,
               let task = fetch(AgendaItem.self, id: id, in: context) {
                app.open(task)
            }
        case .tag:
            if let id = hit.tagID,
               let tag = fetch(Tag.self, id: id, in: context) {
                addTagFilter(tag)
            }
        case .file:
            break
        }
    }

    func insertMention(context: ModelContext?) {
        guard let hit = highlighted, hit.kind != .tag else { return }
        mentions.append(hit)
        followScope(for: mentions)
        replaceToken(with: "")
        refresh(in: context)
        focusNonce += 1
    }

    func insertTag(context: ModelContext?) {
        guard let hit = highlighted, let id = hit.tagID else { return }
        if !tagFilters.contains(where: { $0.id == id }) {
            tagFilters.append(ComposerTagFilter(id: id, name: hit.title))
        }
        replaceToken(with: "")
        refresh(in: context)
        focusNonce += 1
    }

    func attachHighlighted(context: ModelContext?) {
        guard let hit = highlighted else { return }
        if hit.kind == .tag, let id = hit.tagID {
            if !tagFilters.contains(where: { $0.id == id }) {
                tagFilters.append(ComposerTagFilter(id: id, name: hit.title))
            }
        } else if !mentions.contains(where: { $0.id == hit.id }) {
            mentions.append(hit)
            followScope(for: mentions)
        }
        closePopup()
    }

    func removeMention(_ hit: ComposerHit) {
        mentions.removeAll { $0.id == hit.id }
        followScope(for: mentions)
    }

    func removeTag(_ id: UUID) {
        tagFilters.removeAll { $0.id == id }
    }

    @discardableResult
    func popTrailingChip(context: ModelContext?) -> Bool {
        guard fieldText.isEmpty else { return false }
        if let mention = mentions.last {
            removeMention(mention)
            refresh(in: context)
            return true
        }
        if let tag = tagFilters.last {
            removeTag(tag.id)
            refresh(in: context)
            return true
        }
        return false
    }

    func addTagFilter(_ tag: Tag) {
        if !tagFilters.contains(where: { $0.id == tag.id }) {
            tagFilters.append(ComposerTagFilter(id: tag.id, name: tag.displayName))
        }
        replaceToken(with: "")
    }

    func setScope(_ scope: ComposerScope, context: ModelContext?) {
        self.scope = scope
        refresh(in: context)
    }

    func setMentionTab(_ tab: ComposerMentionTab, context: ModelContext?) {
        mentionTab = tab
        refresh(in: context)
    }

    func openActions() {
        popup = .actions
        actionIndex = 0
        actionQuery = ""
    }

    func toggleHelp() {
        popup = popup == .help ? .none : .help
    }

    func closePopup() {
        if case .save = popup { return }
        let restoreField = popup == .actions
        popup = .none
        actionQuery = ""
        actionIndex = 0
        if restoreField {
            restoreFieldFocus()
        }
    }

    func restoreFieldFocus() {
        if hasExchange {
            focusNonceChat += 1
        } else {
            focusNonce += 1
        }
    }

    func presentSave(_ kind: ComposerSaveKind) {
        popup = .save(kind)
    }

    func cancelSave() {
        popup = .none
    }

    func ask(app: AppModel, context: ModelContext, hit: ComposerHit?) {
        if let hit, hit.kind != .tag, !mentions.contains(where: { $0.id == hit.id }) {
            mentions.append(hit)
            followScope(for: mentions)
        }
        let question = askText(for: hit)
        closePopup()
        send(question, app: app, context: context)
    }

    func send(app: AppModel, context: ModelContext) {
        let text = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !mentions.isEmpty else { return }
        send(text, app: app, context: context)
    }

    func send(_ text: String, app: AppModel, context: ModelContext) {
        closePopup()
        if runtime?.session.isGenerating == true {
            runtime?.session.cancel()
        }
        let runtime = ensureRuntime(app: app, context: context)
        let refs = mentions
        let resolved = refs.map { hit in
            let body = ComposerSearch.resolve(hit, in: context)
            return (hit, body)
        }
        var payload = text
        if !resolved.isEmpty {
            var block = ["Referenced context:"]
            for (hit, body) in resolved {
                let identity = hit.recordID?.uuidString ?? hit.filePath ?? hit.title
                let clip = body.count > 4000 ? String(body.prefix(4000)) + "…" : body
                block.append("- \(hit.kind.label) \(hit.title) (\(identity)): \(clip)")
            }
            if !text.isEmpty {
                block.append("")
                block.append(text)
            }
            payload = block.joined(separator: "\n")
        }
        let asked = text.isEmpty ? refs.map(\.title).joined(separator: ", ") : text
        if hasExchange {
            draft = ""
        } else {
            query = ""
        }
        let sent = runtime.send(payload)
        if sent, let user = runtime.session.entries.reversed().compactMap({ entry -> ChatEntry.User? in
            if case .userMessage(let user) = entry { return user }
            return nil
        }).first {
            visibleUserText[user.id] = asked
            turnMentions[user.id] = refs
        }
        focusNonceChat += 1
    }

    func stop() {
        runtime?.session.cancel()
    }

    func conversationTranscript() -> String {
        guard let runtime else { return "" }
        var lines: [String] = []
        for entry in runtime.session.entries {
            switch entry {
            case .userMessage(let user):
                let text = visibleUserText[user.id] ?? user.text
                if !text.isEmpty { lines.append("**User:** \(text)") }
            case .aiMessage(let reply):
                let text = ChatTranscript.unpack(reply.text).text
                if !text.isEmpty { lines.append("**Assistant:** \(text)") }
            case .activity:
                break
            }
        }
        return lines.joined(separator: "\n\n")
    }

    func firstQuestion() -> String {
        for entry in runtime?.session.entries ?? [] {
            if case .userMessage(let user) = entry {
                let text = visibleUserText[user.id] ?? user.text
                if !text.isEmpty { return text }
            }
        }
        return "Composer chat"
    }

    func saveAsChat(project: Project?, app: AppModel, context: ModelContext) {
        if let savedChatID,
           let existing = fetch(Conversation.self, id: savedChatID, in: context) {
            existing.isArchived = false
            existing.project = project
            existing.updatedAt = .now
            try? context.persist()
            app.open(existing)
            close()
            return
        }
        let conversation = ensureConversation(app: app, context: context, project: project)
        conversation.isArchived = false
        conversation.project = project
        conversation.title = String(firstQuestion().prefix(80))
        persistRuntime()
        savedChatID = conversation.id
        try? context.persist()
        app.open(conversation)
        draftConversationID = nil
        close()
    }

    func saveAsNote(project: Project, app: AppModel, context: ModelContext) {
        let note = Note(content: conversationTranscript(), project: project, title: String(firstQuestion().prefix(80)))
        context.insert(note)
        project.touch()
        try? context.persist()
        app.open(note)
        close()
    }

    func saveAsTrack(project: Project, app: AppModel, context: ModelContext) {
        let thread = ProjectThread(title: String(firstQuestion().prefix(80)), kind: .topic, project: project)
        thread.body = conversationTranscript()
        thread.summary = "Saved from composer."
        context.insert(thread)
        project.touch()
        try? context.persist()
        app.open(thread)
        close()
    }

    func saveAsTask(project: Project?, app: AppModel, context: ModelContext) {
        let item = AgendaItem(kind: .task, eventKitID: "", title: String(firstQuestion().prefix(80)))
        item.notes = conversationTranscript()
        item.project = project
        context.insert(item)
        project?.touch()
        try? context.persist()
        app.open(item)
        close()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        if event.window?.title == "Settings" { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, modifiers) {
        case (40, .command):
            toggle()
            return true
        case (48, []):
            toggleHelp()
            return true
        case (53, []):
            if popup != .none {
                if case .save = popup {
                    cancelSave()
                } else {
                    closePopup()
                }
            } else {
                close()
            }
            return true
        case (125, []):
            if popup == .actions { moveAction(1) } else { moveHighlight(1) }
            return true
        case (126, []):
            if popup == .actions { moveAction(-1) } else { moveHighlight(-1) }
            return true
        case (36, []), (76, []):
            guard let app else { return false }
            confirm(app: app, context: app.container.mainContext)
            return true
        case (51, []):
            return popTrailingChip(context: app?.container.mainContext)
        default:
            return false
        }
    }

    private func askText(for hit: ComposerHit?) -> String {
        let typed = parsed.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        if let hit { return "What should I know about \(hit.title)?" }
        return ""
    }

    private func replaceToken(with replacement: String) {
        let next = parsed.prefix + replacement
        if hasExchange {
            draft = next
        } else {
            query = next
        }
    }

    private func followScope(for mentions: [ComposerHit]) {
        let projects = Set(mentions.compactMap(\.projectID))
        if projects.count == 1, let id = projects.first {
            scope = .project(id)
        } else if projects.count > 1 {
            scope = .workspace
        }
    }

    private func ensureRuntime(app: AppModel, context: ModelContext) -> ChatRuntime {
        if let runtime { return runtime }
        let conversation = ensureConversation(app: app, context: context, project: scopedProject(in: context))
        let runtime = app.chatRuntime(for: conversation, project: conversation.project)
        self.runtime = runtime
        return runtime
    }

    private func ensureConversation(app: AppModel, context: ModelContext, project: Project?) -> Conversation {
        if let draftConversationID,
           let existing = fetch(Conversation.self, id: draftConversationID, in: context) {
            existing.project = project
            return existing
        }
        let conversation = Conversation(
            providerID: app.talkProvider.rawValue,
            modelID: app.talkModelID,
            project: project
        )
        conversation.isArchived = true
        conversation.title = "Composer"
        context.insert(conversation)
        try? context.persist()
        draftConversationID = conversation.id
        return conversation
    }

    private func persistRuntime() {
        runtime?.persist()
    }

    private func discardDraftIfNeeded() {
        guard savedChatID == nil, let id = draftConversationID, let app else { return }
        let context = app.container.mainContext
        if let conversation = fetch(Conversation.self, id: id, in: context) {
            context.delete(conversation)
            try? context.persist()
        }
    }

    private func scopedProject(in context: ModelContext) -> Project? {
        guard let id = scope.projectID else { return nil }
        return fetch(Project.self, id: id, in: context)
    }

    private func fetch<T: PersistentModel>(_ type: T.Type, id: UUID, in context: ModelContext) -> T? {
        func match(_ model: T) -> Bool {
            if let project = model as? Project { return project.id == id }
            if let thread = model as? ProjectThread { return thread.id == id }
            if let note = model as? Note { return note.id == id }
            if let decision = model as? Decision { return decision.id == id }
            if let conversation = model as? Conversation { return conversation.id == id }
            if let task = model as? AgendaItem { return task.id == id }
            if let tag = model as? Tag { return tag.id == id }
            return false
        }
        return ((try? context.fetch(FetchDescriptor<T>())) ?? []).first(where: match)
    }

    private func installShortcuts() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            var consumed = false
            let apply = { consumed = self.consumeShortcut(event) }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.sync(execute: apply)
            }
            return consumed ? nil : event
        }
    }

    private func consumeShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if !isOpen {
            if event.keyCode == 40, modifiers == .command {
                if event.window?.title == "Settings" { return false }
                open()
                return true
            }
            return false
        }
        return handleKey(event)
    }
}
