import Foundation
import SwiftData
import SwiftUI

enum ConnectionState: Equatable {
    case missing
    case checking
    case connected(String)
    case failed(String)

    var isPresent: Bool {
        if case .missing = self { return false }
        return true
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var container: ModelContainer
    var chromeDestination: Destination = .home
    var windowTabs: [WindowTab] = [AppModel.launchTab]
    var selectedTabID = AppModel.launchTab.id
    var tabHistories: [UUID: TabHistory] = [:]
    var canGoBack = false
    var canGoForward = false
    @ObservationIgnored var historyLocked = false
    var tabs: [UUID: ProjectTab] = [:]
    var selectedThread: UUID?
    var selectedNote: UUID?
    var selectedDecision: UUID?
    var selectedConversation: UUID?
    var selectedRun: UUID?
    var modal: AppModal?
    var modalHost = ModalHost.main
    var toast: String?
    var pendingSend: PendingSend?
    var chatConversationID: UUID?
    var activeReply = ""
    private(set) var runningChats: [RunningChat] = []
    let runCoordinator = RunCoordinator()
    @ObservationIgnored private var chatRuntimes: [UUID: ChatRuntime] = [:]
    @ObservationIgnored private var retiredContainers: [ModelContainer] = []
    @ObservationIgnored private var storeReloadTask: Task<Void, Never>?
    private(set) var storeGeneration = UUID()
    var chatGenerating = false {
        didSet {
            if oldValue, !chatGenerating,
               let chatConversationID,
               chatRuntimes[chatConversationID]?.providerID == TalkProvider.cursor.rawValue {
                refreshUsage(force: true)
            }
        }
    }
    var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    var accent: AccentPreference {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }
    var accentedViews: Set<String> {
        didSet { defaults.set(Array(accentedViews), forKey: Keys.accentedViews) }
    }
    var defaultModelID: String {
        didSet { defaults.set(defaultModelID, forKey: Keys.defaultModel) }
    }
    var talkProvider: TalkProvider {
        didSet { defaults.set(talkProvider.rawValue, forKey: Keys.talkProvider) }
    }
    var talkProviderID: String {
        get { talkProvider.rawValue }
        set { talkProvider = TalkProvider(rawValue: newValue) ?? talkProvider }
    }
    var chatGPTModelID: String {
        didSet { defaults.set(chatGPTModelID, forKey: Keys.chatGPTModel) }
    }
    var compatibleEndpoint: String {
        didSet { defaults.set(compatibleEndpoint, forKey: Keys.compatibleEndpoint) }
    }
    var compatibleModelID: String {
        didSet { defaults.set(compatibleModelID, forKey: Keys.compatibleModel) }
    }
    var compatibleModels: [(id: String, name: String)] = []
    var compatibleKeyPresent = false
    private(set) var cursorCloudRepositories: CursorCloudRepositoriesState = .idle
    @ObservationIgnored private var cursorCloudFetchStartedAt: Date?
    private(set) var chatGPTModels: [ChatGPTModel] = []
    var showAgentIDs: Bool {
        didSet { defaults.set(showAgentIDs, forKey: Keys.showAgentIDs) }
    }
    var projectsLayout: ProjectsLayout {
        didSet { defaults.set(projectsLayout.rawValue, forKey: Keys.projectsLayout) }
    }
    var projectTasksLayout: ProjectTasksLayout {
        didSet { defaults.set(projectTasksLayout.rawValue, forKey: Keys.projectTasksLayout) }
    }
    var sidebarCollapsed: Bool {
        didSet { defaults.set(sidebarCollapsed, forKey: Keys.sidebarCollapsed) }
    }
    var projectColumnCollapsed: Bool {
        didSet { defaults.set(projectColumnCollapsed, forKey: Keys.projectColumnCollapsed) }
    }
    var collapsedProjectSections: Set<String> {
        didSet { defaults.set(Array(collapsedProjectSections), forKey: Keys.collapsedProjectSections) }
    }
    var expandedProjectSections: Set<String> {
        didSet { defaults.set(Array(expandedProjectSections), forKey: Keys.expandedProjectSections) }
    }
    var settingsSection: SettingsSection {
        didSet { defaults.set(settingsSection.rawValue, forKey: Keys.settingsSection) }
    }
    var openChatLinksInNewTab: Bool {
        didSet { defaults.set(openChatLinksInNewTab, forKey: Keys.openChatLinksInNewTab) }
    }
    var orbPalette: OrbPalette {
        didSet {
            if let data = try? JSONEncoder().encode(orbPalette) {
                defaults.set(data, forKey: Keys.orbPalette)
            }
        }
    }
    var trackChatOpen = false
    var inspectorOpen = false
    var selectedOverviewPlate: UUID?
    var selectedTaskID: UUID?
    let objectFind = ObjectFindSession()

    var isObjectPage: Bool {
        if selectedNote != nil || selectedDecision != nil || selectedThread != nil || selectedRun != nil {
            return true
        }
        if case .run = chromeDestination { return true }
        return false
    }

    func selectOverviewPlate(_ id: UUID?) {
        selectedOverviewPlate = id
        guard id != nil, !inspectorOpen else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            inspectorOpen = true
        }
    }

    func selectTask(_ id: UUID?) {
        selectedTaskID = id
        if id == nil {
            guard inspectorOpen else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                inspectorOpen = false
            }
            return
        }
        guard !inspectorOpen else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            inspectorOpen = true
        }
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            sidebarCollapsed.toggle()
        }
    }

    func toggleProjectColumn() {
        withAnimation(.easeInOut(duration: 0.22)) {
            projectColumnCollapsed.toggle()
        }
    }

    func isProjectSectionOpen(_ section: ProjectColumnSection, tab: ProjectTab) -> Bool {
        if collapsedProjectSections.contains(section.rawValue) { return false }
        if expandedProjectSections.contains(section.rawValue) { return true }
        return section.tab == tab
    }

    func toggleProjectSection(_ section: ProjectColumnSection, tab: ProjectTab) {
        if isProjectSectionOpen(section, tab: tab) {
            expandedProjectSections.remove(section.rawValue)
            collapsedProjectSections.insert(section.rawValue)
        } else {
            collapsedProjectSections.remove(section.rawValue)
            expandedProjectSections.insert(section.rawValue)
        }
    }

    func openProjectSection(_ section: ProjectColumnSection) {
        collapsedProjectSections.remove(section.rawValue)
        expandedProjectSections.insert(section.rawValue)
    }

    func toggleInspector() {
        withAnimation(.easeInOut(duration: 0.22)) {
            inspectorOpen.toggle()
        }
    }

    func present(_ modal: AppModal, in host: ModalHost = .main) {
        withAnimation(Motion.snappy) {
            modalHost = host
            self.modal = modal
        }
    }

    func modal(in host: ModalHost) -> AppModal? {
        modalHost == host ? modal : nil
    }

    func dismissModal() {
        withAnimation(Motion.quick) {
            modal = nil
        }
    }

    func usesAccent(_ view: AccentedView) -> Bool {
        accentedViews.contains(view.rawValue)
    }

    func setUsesAccent(_ view: AccentedView, enabled: Bool) {
        if enabled {
            accentedViews.insert(view.rawValue)
        } else {
            accentedViews.remove(view.rawValue)
        }
    }

    func accent(for view: AccentedView) -> Color {
        usesAccent(view) ? accent.color : view.defaultColor
    }

    private(set) var apiKey: String?
    private(set) var connection: ConnectionState = .missing
    private(set) var models: [CursorModel] = []
    private(set) var modelsError: String?
    private(set) var usage: CursorUsage?
    private(set) var usageNote: String?
    @ObservationIgnored private var usageCheckedAt: Date?
    var storeError: String?
    let eventKit = EventKitService()
    let sources = SourceConnections()

    var hasAPIKey: Bool { apiKey?.isEmpty == false }

    private static let launchTab = WindowTab.home()
    let defaults = UserDefaults.standard

    init() {
        appearance = AppearancePreference(rawValue: UserDefaults.standard.string(forKey: Keys.appearance) ?? "") ?? .system
        accent = AccentPreference(rawValue: UserDefaults.standard.string(forKey: Keys.accent) ?? "") ?? .system
        accentedViews = Set(UserDefaults.standard.stringArray(forKey: Keys.accentedViews) ?? [])
        defaultModelID = UserDefaults.standard.string(forKey: Keys.defaultModel) ?? ""
        talkProvider = TalkProvider(rawValue: UserDefaults.standard.string(forKey: Keys.talkProvider) ?? "") ?? .unconfigured
        chatGPTModelID = UserDefaults.standard.string(forKey: Keys.chatGPTModel) ?? ""
        compatibleEndpoint = UserDefaults.standard.string(forKey: Keys.compatibleEndpoint) ?? ""
        compatibleModelID = UserDefaults.standard.string(forKey: Keys.compatibleModel) ?? ""
        compatibleKeyPresent = KeychainStore.read(.compatibleAPIKey) != nil
        if let checkedAt = defaults.object(forKey: Keys.cursorCloudCheckedAt) as? TimeInterval,
           let urls = defaults.stringArray(forKey: Keys.cursorCloudRepoURLs) {
            cursorCloudRepositories = .ready(urls: urls, checkedAt: Date(timeIntervalSince1970: checkedAt))
        }
        showAgentIDs = UserDefaults.standard.bool(forKey: Keys.showAgentIDs)
        let storedLayout = UserDefaults.standard.string(forKey: Keys.projectsLayout) ?? ""
        projectsLayout = storedLayout == "list" ? .card : (ProjectsLayout(rawValue: storedLayout) ?? .table)
        projectTasksLayout = ProjectTasksLayout(rawValue: UserDefaults.standard.string(forKey: Keys.projectTasksLayout) ?? "") ?? .kanban
        sidebarCollapsed = UserDefaults.standard.bool(forKey: Keys.sidebarCollapsed)
        projectColumnCollapsed = UserDefaults.standard.bool(forKey: Keys.projectColumnCollapsed)
        if UserDefaults.standard.object(forKey: Keys.expandedProjectSections) == nil {
            collapsedProjectSections = []
            expandedProjectSections = []
        } else {
            collapsedProjectSections = Set(UserDefaults.standard.stringArray(forKey: Keys.collapsedProjectSections) ?? [])
            expandedProjectSections = Set(UserDefaults.standard.stringArray(forKey: Keys.expandedProjectSections) ?? [])
        }
        settingsSection = SettingsSection(rawValue: UserDefaults.standard.string(forKey: Keys.settingsSection) ?? "") ?? .model
        if UserDefaults.standard.object(forKey: Keys.openChatLinksInNewTab) == nil {
            openChatLinksInNewTab = true
        } else {
            openChatLinksInNewTab = UserDefaults.standard.bool(forKey: Keys.openChatLinksInNewTab)
        }
        if let data = UserDefaults.standard.data(forKey: Keys.orbPalette),
           let stored = try? JSONDecoder().decode(OrbPalette.self, from: data),
           stored != .legacySlate {
            orbPalette = stored
        } else {
            orbPalette = .slate
        }
        apiKey = KeychainStore.read(.cursorAPIKey)
        sources.load()

        var opened: ModelContainer?
        var failure: String?
        for _ in 0..<3 {
            do {
                opened = try Store.open()
                failure = nil
                break
            } catch {
                failure = error.localizedDescription
            }
        }
        storeError = failure
        if let opened {
            container = opened
        } else {
            container = try! Store.open()
            storeError = nil
        }
        Store.disableAutosave(container)
        ChatTrace.event("app launch hasKey=\(hasAPIKey) storeError=\(storeError ?? "none")")
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let app = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in app.storeDidChangeElsewhere() }
            },
            Store.changedNotification as CFString,
            nil,
            .deliverImmediately
        )
        if hasAPIKey {
            refreshConnection()
        } else {
            connection = .missing
        }
        normalizeTalkProvider()
        refreshChatGPTModels()
        refreshUsage()
        restoreWindowTabs()
        runCoordinator.attach(self)
        runCoordinator.recover(in: container.mainContext)
        objectFind.installShortcuts { [weak self] in
            guard let self else { return false }
            return self.isObjectPage || self.objectFind.isOpen
        }
    }

    func refreshUsage(force: Bool = false) {
        if !force, let usageCheckedAt, Date.now.timeIntervalSince(usageCheckedAt) < 60 { return }
        usageCheckedAt = .now
        Task {
            do {
                if let fetched = try await CursorUsageClient.fetch() {
                    usage = fetched
                    usageNote = nil
                } else {
                    usage = nil
                    usageNote = "Sign in to the Cursor app on this Mac to see usage."
                }
            } catch {
                usageNote = error.localizedDescription
                ChatTrace.event("usage failed: \(error.localizedDescription)")
            }
        }
    }

    private func storeDidChangeElsewhere() {
        storeReloadTask?.cancel()
        storeReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.reloadStore()
            self.storeReloadTask = nil
        }
    }

    private func reloadStore() {
        for runtime in chatRuntimes.values {
            runtime.persist()
        }
        Store.disableAutosave(container)
        try? container.mainContext.save()
        do {
            let previous = container
            Store.disableAutosave(previous)
            let reopened = try Store.open()
            Store.disableAutosave(reopened)
            retiredContainers.append(previous)
            container = reopened
            storeGeneration = UUID()
            storeError = nil
            for runtime in chatRuntimes.values {
                runtime.reattach(in: reopened.mainContext)
                runtime.persist()
            }
            DraftTrace.storeReopen(
                generation: storeGeneration,
                runtimes: chatRuntimes.values.map {
                    (
                        object: $0.conversationID.uuidString,
                        runtime: DraftTrace.runtimeID($0),
                        draftChars: $0.draft.count
                    )
                }
            )
            ChatTrace.event("store reopened after outside change")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                Store.disableAutosave(previous)
                self?.retiredContainers.removeAll { $0 === previous }
            }
        } catch {
            storeError = error.localizedDescription
        }
    }

    func chatRuntime(for conversation: Conversation, project: Project?) -> ChatRuntime {
        if let runtime = chatRuntimes[conversation.id] {
            runtime.attach(conversation: conversation, project: project)
            return runtime
        }
        let runtime = ChatRuntime(conversation: conversation, project: project)
        runtime.onTick = { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            runtime.schedulePersist()
            self.syncChrome(from: runtime)
            self.syncRunning()
        }
        chatRuntimes[conversation.id] = runtime
        return runtime
    }

    func revealChat(_ runtime: ChatRuntime) {
        chatConversationID = runtime.conversationID
        syncChrome(from: runtime)
        runtime.persist()
    }

    private func syncChrome(from runtime: ChatRuntime) {
        guard chatConversationID == runtime.conversationID else { return }
        chatGenerating = runtime.session.isGenerating
        activeReply = runtime.lastReply
    }

    private func syncRunning() {
        let next = chatRuntimes.values
            .filter { $0.session.isGenerating }
            .map { RunningChat(id: $0.conversationID, label: $0.liveWaitLabel) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        if next != runningChats {
            runningChats = next
        }
    }

    func tab(for project: UUID) -> ProjectTab {
        tabs[project] ?? .chat
    }

    func makeConversation(in project: Project?, context: ModelContext, newTab: Bool = false) -> Conversation {
        let conversation = Conversation(providerID: talkProvider.rawValue, modelID: talkModelID, project: project)
        context.insert(conversation)
        project?.touch()
        try? context.save()
        open(conversation, newTab: newTab)
        return conversation
    }

    func makeTrackConversation(for thread: ProjectThread, in project: Project, context: ModelContext) -> Conversation {
        if let existing = thread.conversations
            .filter({ !$0.isArchived })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first {
            return existing
        }
        let conversation = Conversation(providerID: talkProvider.rawValue, modelID: talkModelID, project: project)
        conversation.thread = thread
        conversation.title = thread.title.isEmpty ? "Track chat" : thread.title
        context.insert(conversation)
        project.touch()
        try? context.save()
        return conversation
    }

    func saveAPIKey(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try KeychainStore.save(key, account: .cursorAPIKey)
        apiKey = key
        refreshConnection()
        refreshCursorCloudRepositories(force: true)
    }

    func removeAPIKey() throws {
        try KeychainStore.delete(.cursorAPIKey)
        apiKey = nil
        models = []
        modelsError = nil
        connection = .missing
        cursorCloudRepositories = .unavailable
        defaults.removeObject(forKey: Keys.cursorCloudRepoURLs)
        defaults.removeObject(forKey: Keys.cursorCloudCheckedAt)
        normalizeTalkProvider()
    }

    func refreshConnection() {
        guard let apiKey, !apiKey.isEmpty else {
            connection = .missing
            models = []
            modelsError = nil
            return
        }
        connection = .checking
        modelsError = nil
        ChatTrace.event("refreshConnection start")
        let client = CursorClient(apiKey: apiKey)
        Task {
            do {
                let account = try await client.account()
                connection = .connected(account.userEmail ?? account.apiKeyName)
                ChatTrace.event("refreshConnection account=\(account.userEmail ?? account.apiKeyName)")
            } catch {
                connection = .failed(error.localizedDescription)
                models = []
                ChatTrace.event("refreshConnection account failed: \(error.localizedDescription)")
                return
            }
            do {
                models = try await client.models()
                modelsError = models.isEmpty ? "Cursor didn’t return any models for this key." : nil
                ChatTrace.event("refreshConnection models=\(models.count) error=\(modelsError ?? "none")")
            } catch {
                models = []
                modelsError = error.localizedDescription
                ChatTrace.event("refreshConnection models failed: \(error.localizedDescription)")
            }
        }
    }

    func flash(_ message: String) {
        withAnimation(Motion.snappy) {
            toast = message
        }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if toast == message {
                withAnimation(Motion.quick) {
                    toast = nil
                }
            }
        }
    }

    var availableTalkProviders: [TalkProvider] {
        var list: [TalkProvider] = []
        if sources.hasChatGPT { list.append(.chatgpt) }
        if hasAPIKey { list.append(.cursor) }
        if !compatibleEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            list.append(.compatible)
        }
        return list
    }

    var talkModelID: String {
        get {
            switch talkProvider {
            case .chatgpt:
                if !chatGPTModelID.isEmpty { return chatGPTModelID }
                return talkModels.first?.id ?? ""
            case .cursor:
                return defaultModelID
            case .compatible:
                return compatibleModelID
            case .unconfigured:
                return ""
            }
        }
        set {
            switch talkProvider {
            case .chatgpt:
                chatGPTModelID = newValue
            case .cursor:
                defaultModelID = newValue
            case .compatible:
                compatibleModelID = newValue
            case .unconfigured:
                break
            }
        }
    }

    var talkModels: [(id: String, name: String)] {
        models(for: talkProvider.rawValue)
    }

    func models(for providerID: String) -> [(id: String, name: String)] {
        switch TalkProvider(rawValue: providerID) {
        case .unconfigured:
            return []
        case .chatgpt:
            return chatGPTModels.map { (id: $0.id, name: $0.displayName) }
        case .cursor:
            return models.map { (id: $0.id, name: $0.displayName) }
        case .compatible:
            var list = compatibleModels
            if !compatibleModelID.isEmpty, !list.contains(where: { $0.id == compatibleModelID }) {
                list.insert((id: compatibleModelID, name: compatibleModelID), at: 0)
            }
            return list
        case .none:
            return []
        }
    }

    func modelName(for id: String, providerID: String? = nil) -> String {
        if id.isEmpty { return "Account default" }
        switch providerID.flatMap(TalkProvider.init(rawValue:)) {
        case .chatgpt:
            return chatGPTModels.first(where: { $0.id == id })?.displayName ?? id
        case .cursor:
            return models.first(where: { $0.id == id })?.displayName ?? id
        case .compatible:
            return compatibleModels.first(where: { $0.id == id })?.name ?? id
        default:
            if let name = chatGPTModels.first(where: { $0.id == id })?.displayName { return name }
            return models.first { $0.id == id }?.displayName ?? id
        }
    }

    func refreshChatGPTModels() {
        guard let session = ChatGPTSignIn.load() else {
            chatGPTModels = []
            return
        }
        Task {
            do {
                let fetched = try await ChatGPTSignIn.models(session: session)
                chatGPTModels = fetched
                if chatGPTModelID.isEmpty, let first = chatGPTModels.first {
                    chatGPTModelID = first.id
                }
            } catch {
                chatGPTModels = []
                ChatTrace.event("chatgpt models failed: \(error.localizedDescription)")
            }
        }
    }

    func refreshCompatibleModels() {
        let endpoint = compatibleEndpoint
        let key = KeychainStore.read(.compatibleAPIKey)
        compatibleKeyPresent = key != nil
        guard AttachmentCapabilityStore.isOpenRouter(endpoint) else { return }
        Task {
            do {
                let fetched = try await GenericChatProvider.fetchOpenRouterModels(endpoint: endpoint, apiKey: key)
                compatibleModels = fetched.map { (id: $0.id, name: $0.name) }
                for model in fetched {
                    AttachmentCapabilityStore.applyEndpoint(
                        provider: .compatible,
                        model: model.id,
                        endpoint: endpoint,
                        image: model.image ? .supported : .unsupported,
                        document: model.file ? .supported : .unsupported,
                        pdfParser: model.file
                    )
                }
                if compatibleModelID.isEmpty, let first = compatibleModels.first {
                    compatibleModelID = first.id
                }
            } catch {
                ChatTrace.event("compatible models failed: \(error.localizedDescription)")
            }
        }
    }

    func normalizeTalkProvider() {
        let available = availableTalkProviders
        if !available.contains(talkProvider) {
            talkProvider = available.first ?? .unconfigured
        }
    }

    func refreshCursorCloudRepositories(force: Bool = false) {
        guard hasAPIKey, let apiKey else {
            cursorCloudRepositories = .unavailable
            return
        }
        if case .loading = cursorCloudRepositories { return }
        if !force, case .ready(_, let checkedAt) = cursorCloudRepositories,
           Date().timeIntervalSince(checkedAt) < 60 {
            return
        }
        cursorCloudRepositories = .loading
        cursorCloudFetchStartedAt = .now
        Task {
            do {
                let urls = try await CursorClient(apiKey: apiKey).repositories()
                let checkedAt = Date()
                defaults.set(urls, forKey: Keys.cursorCloudRepoURLs)
                defaults.set(checkedAt.timeIntervalSince1970, forKey: Keys.cursorCloudCheckedAt)
                cursorCloudRepositories = .ready(urls: urls, checkedAt: checkedAt)
            } catch {
                cursorCloudRepositories = .failed(error.localizedDescription)
            }
        }
    }

    static let cursorIntegrationsURL = URL(string: "https://cursor.com/dashboard?tab=integrations")!

    func presentNewRun(
        origin: RunOrigin,
        project: Project? = nil,
        task: AgendaItem? = nil,
        chat: Conversation? = nil,
        brief: String = "",
        retryOf: AgentRun? = nil
    ) {
        if origin == .task, let task, let active = RunStore.activeRun(forTask: task.id, in: container.mainContext) {
            open(active)
            return
        }
        let defaults = runDefaults(for: project)
        present(.newRun(
            retryOf.map(RunStore.retryDraft) ?? NewRunDraft.blank(
                origin: origin,
                projectID: project?.id,
                taskID: task?.id,
                originChatID: chat?.id,
                brief: brief,
                providerID: defaults.provider,
                modelID: defaults.model,
                pathRaw: defaults.path
            )
        ))
    }

    func startRun(_ draft: NewRunDraft) {
        do {
            let run = try RunStore.enqueue(draft, in: container.mainContext)
            dismissModal()
            open(run)
            runCoordinator.start(run, in: container.mainContext)
        } catch {
            flash(error.localizedDescription)
        }
    }

    func startIndexing(attachment: CodeAttachment) {
        guard let project = attachment.project else {
            flash("That repository is not attached to a project.")
            return
        }
        if let active = CodeReferenceStore.activeIndexingRun(for: attachment, in: container.mainContext) {
            open(active)
            return
        }
        let defaults = runDefaults(for: project)
        guard providerConnected(defaults.provider) else {
            flash("Connect the project worker in Settings before indexing.")
            return
        }
        do {
            let run = try RunStore.enqueue(
                RepositoryIndex.draft(
                    for: attachment,
                    project: project,
                    providerID: defaults.provider,
                    modelID: defaults.model
                ),
                in: container.mainContext
            )
            let tools = RunToolPolicy.catalogNames(for: run)
            guard run.purpose == .indexRepository,
                  run.indexedAttachmentID == attachment.id,
                  tools.contains("upsert_code_reference_entry"),
                  tools.contains("set_code_reference_meta")
            else {
                try RunStore.failUnpublishedIndex(
                    run,
                    workerSummary: "",
                    detail: "Indexing tools were not granted. The run was not started.",
                    in: container.mainContext
                )
                flash("Indexing was not started. The run is missing its attachment identity or write tools.")
                open(run)
                return
            }
            open(run)
            runCoordinator.start(run, in: container.mainContext)
        } catch {
            flash(error.localizedDescription)
        }
    }

    func retryRun(_ run: AgentRun) {
        presentNewRun(
            origin: run.origin,
            project: run.project,
            task: run.task,
            chat: run.originChat,
            brief: run.brief,
            retryOf: run
        )
    }

    func cancelRun(_ run: AgentRun) {
        runCoordinator.cancel(run, in: container.mainContext)
    }

    func runDefaults(for project: Project?) -> (provider: String, model: String, path: String) {
        if let project, !project.workerProviderID.isEmpty {
            return (
                project.workerProviderID,
                project.workerModelID.isEmpty ? talkModelID : project.workerModelID,
                project.workerPath.isEmpty ? WorkerPath.local.rawValue : project.workerPath
            )
        }
        return (talkProvider.rawValue, talkModelID, WorkerPath.local.rawValue)
    }

    func providerConnected(_ id: String) -> Bool {
        switch TalkProvider(rawValue: id) {
        case .chatgpt: sources.hasChatGPT
        case .cursor: hasAPIKey
        case .compatible: !compatibleEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }
}

enum CursorCloudRepositoriesState: Equatable {
    case unavailable
    case idle
    case loading
    case ready(urls: [String], checkedAt: Date)
    case failed(String)
}

struct PendingSend: Equatable {
    var conversationID: UUID
    var text: String
    var attachments: [ChatAttachmentRef] = []

    var submission: ChatSubmission {
        ChatSubmission(text: text, attachments: attachments)
    }
}

struct RunningChat: Equatable, Identifiable {
    var id: UUID
    var label: String
}

enum SaveKind: String, Identifiable {
    case note, thread, addToThread, decision
    var id: String { rawValue }
}

enum Keys {
    static let appearance = "appearance"
    static let accent = "accent"
    static let accentedViews = "accentedViews"
    static let defaultModel = "defaultModelID"
    static let talkProvider = "talkProvider"
    static let chatGPTModel = "chatGPTModelID"
    static let compatibleEndpoint = "compatibleEndpoint"
    static let compatibleModel = "compatibleModelID"
    static let cursorCloudRepoURLs = "cursorCloudRepoURLs"
    static let cursorCloudCheckedAt = "cursorCloudCheckedAt"
    static let showAgentIDs = "showAgentIDs"
    static let projectsLayout = "projectsLayout"
    static let projectTasksLayout = "projectTasksLayout"
    static let sidebarCollapsed = "sidebarCollapsed"
    static let projectColumnCollapsed = "projectColumnCollapsed"
    static let collapsedProjectSections = "collapsedProjectSections"
    static let expandedProjectSections = "expandedProjectSections"
    static let settingsSection = "settingsSection"
    static let orbPalette = "orbPalette"
    static let windowTabs = "windowTabs"
    static let openChatLinksInNewTab = "openChatLinksInNewTab"
}
