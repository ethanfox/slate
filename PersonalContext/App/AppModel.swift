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
    var tabs: [UUID: ProjectTab] = [:]
    var selectedThread: UUID?
    var selectedNote: UUID?
    var selectedDecision: UUID?
    var selectedConversation: UUID?
    var modal: AppModal?
    var modalHost = ModalHost.main
    var toast: String?
    var pendingSend: PendingSend?
    var chatConversationID: UUID?
    var activeReply = ""
    private(set) var runningChats: [RunningChat] = []
    @ObservationIgnored private var chatRuntimes: [UUID: ChatRuntime] = [:]
    @ObservationIgnored private var retiredContainers: [ModelContainer] = []
    @ObservationIgnored private var storeReloadTask: Task<Void, Never>?
    private(set) var storeGeneration = UUID()
    var chatGenerating = false {
        didSet {
            if oldValue, !chatGenerating { refreshUsage(force: true) }
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
    var chatGPTModelID: String {
        didSet { defaults.set(chatGPTModelID, forKey: Keys.chatGPTModel) }
    }
    var readProvider: TalkProvider {
        didSet { defaults.set(readProvider.rawValue, forKey: Keys.readProvider) }
    }
    var chatGPTReadModelID: String {
        didSet { defaults.set(chatGPTReadModelID, forKey: Keys.chatGPTReadModel) }
    }
    var cursorReadModelID: String {
        didSet { defaults.set(cursorReadModelID, forKey: Keys.cursorReadModel) }
    }
    private(set) var cursorCloudRepositories: CursorCloudRepositoriesState = .idle
    @ObservationIgnored private var cursorCloudFetchStartedAt: Date?
    private(set) var chatGPTModels: [ChatGPTModel] = ChatGPTModel.fallback
    var showAgentIDs: Bool {
        didSet { defaults.set(showAgentIDs, forKey: Keys.showAgentIDs) }
    }
    var projectsLayout: ProjectsLayout {
        didSet { defaults.set(projectsLayout.rawValue, forKey: Keys.projectsLayout) }
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

    func selectOverviewPlate(_ id: UUID?) {
        selectedOverviewPlate = id
        guard id != nil, !inspectorOpen else { return }
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

    func isProjectSectionOpen(_ section: ProjectColumnSection) -> Bool {
        !collapsedProjectSections.contains(section.rawValue)
    }

    func toggleProjectSection(_ section: ProjectColumnSection) {
        if collapsedProjectSections.contains(section.rawValue) {
            collapsedProjectSections.remove(section.rawValue)
        } else {
            collapsedProjectSections.insert(section.rawValue)
        }
    }

    func openProjectSection(_ section: ProjectColumnSection) {
        collapsedProjectSections.remove(section.rawValue)
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
        talkProvider = TalkProvider(rawValue: UserDefaults.standard.string(forKey: Keys.talkProvider) ?? "") ?? .cursor
        chatGPTModelID = UserDefaults.standard.string(forKey: Keys.chatGPTModel) ?? ""
        readProvider = TalkProvider(rawValue: UserDefaults.standard.string(forKey: Keys.readProvider) ?? "") ?? .cursor
        chatGPTReadModelID = UserDefaults.standard.string(forKey: Keys.chatGPTReadModel) ?? ""
        cursorReadModelID = UserDefaults.standard.string(forKey: Keys.cursorReadModel) ?? ""
        if let checkedAt = defaults.object(forKey: Keys.cursorCloudCheckedAt) as? TimeInterval,
           let urls = defaults.stringArray(forKey: Keys.cursorCloudRepoURLs) {
            cursorCloudRepositories = .ready(urls: urls, checkedAt: Date(timeIntervalSince1970: checkedAt))
        }
        showAgentIDs = UserDefaults.standard.bool(forKey: Keys.showAgentIDs)
        let storedLayout = UserDefaults.standard.string(forKey: Keys.projectsLayout) ?? ""
        projectsLayout = storedLayout == "list" ? .card : (ProjectsLayout(rawValue: storedLayout) ?? .table)
        sidebarCollapsed = UserDefaults.standard.bool(forKey: Keys.sidebarCollapsed)
        projectColumnCollapsed = UserDefaults.standard.bool(forKey: Keys.projectColumnCollapsed)
        collapsedProjectSections = Set(UserDefaults.standard.stringArray(forKey: Keys.collapsedProjectSections) ?? [])
        settingsSection = SettingsSection(rawValue: UserDefaults.standard.string(forKey: Keys.settingsSection) ?? "") ?? .cursor
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
        try? container.mainContext.save()
        do {
            let previous = container
            let reopened = try Store.open()
            retiredContainers.append(previous)
            container = reopened
            storeGeneration = UUID()
            storeError = nil
            for runtime in chatRuntimes.values {
                runtime.reattach(in: reopened.mainContext)
                runtime.persist()
            }
            ChatTrace.event("store reopened after outside change")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
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
            runtime.persist()
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
        let conversation = Conversation(model: talkModelID, project: project)
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
        let conversation = Conversation(model: talkModelID, project: project)
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
        normalizeReadProvider()
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
        return list
    }

    var talkModelID: String {
        get {
            if talkProvider == .chatgpt {
                if !chatGPTModelID.isEmpty { return chatGPTModelID }
                return talkModels.first?.id ?? ""
            }
            return defaultModelID
        }
        set {
            if talkProvider == .chatgpt {
                chatGPTModelID = newValue
            } else {
                defaultModelID = newValue
            }
        }
    }

    var talkModels: [(id: String, name: String)] {
        switch talkProvider {
        case .chatgpt:
            let list = chatGPTModels.isEmpty ? ChatGPTModel.fallback : chatGPTModels
            return list.map { (id: $0.id, name: $0.displayName) }
        case .cursor:
            return models.map { (id: $0.id, name: $0.displayName) }
        }
    }

    func modelName(for id: String) -> String {
        if id.isEmpty { return "Account default" }
        if let name = chatGPTModels.first(where: { $0.id == id })?.displayName { return name }
        return models.first { $0.id == id }?.displayName ?? id
    }

    func refreshChatGPTModels() {
        guard let session = ChatGPTSignIn.load() else {
            chatGPTModels = ChatGPTModel.fallback
            return
        }
        Task {
            do {
                let fetched = try await ChatGPTSignIn.models(session: session)
                chatGPTModels = fetched.isEmpty ? ChatGPTModel.fallback : fetched
                if chatGPTModelID.isEmpty, let first = chatGPTModels.first {
                    chatGPTModelID = first.id
                }
                if chatGPTReadModelID.isEmpty, let first = chatGPTModels.first {
                    chatGPTReadModelID = first.id
                }
            } catch {
                if chatGPTModels.isEmpty { chatGPTModels = ChatGPTModel.fallback }
                ChatTrace.event("chatgpt models failed: \(error.localizedDescription)")
            }
        }
    }

    func normalizeTalkProvider() {
        let available = availableTalkProviders
        if !available.contains(talkProvider) {
            talkProvider = available.first ?? .cursor
        }
    }

    var availableReadProviders: [TalkProvider] { availableTalkProviders }

    var readModelID: String {
        get {
            if readProvider == .chatgpt {
                if !chatGPTReadModelID.isEmpty { return chatGPTReadModelID }
                return readModels.first?.id ?? ""
            }
            return cursorReadModelID
        }
        set {
            if readProvider == .chatgpt {
                chatGPTReadModelID = newValue
            } else {
                cursorReadModelID = newValue
            }
        }
    }

    var readModels: [(id: String, name: String)] {
        switch readProvider {
        case .chatgpt:
            let list = chatGPTModels.isEmpty ? ChatGPTModel.fallback : chatGPTModels
            return list.map { (id: $0.id, name: $0.displayName) }
        case .cursor:
            return models.map { (id: $0.id, name: $0.displayName) }
        }
    }

    func normalizeReadProvider() {
        let available = availableReadProviders
        if !available.contains(readProvider) {
            readProvider = available.first ?? .cursor
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

    func cursorCloudIncludesGitHubAttachment(_ attachment: CodeAttachment) -> Bool? {
        guard attachment.kind == .github else { return nil }
        let target = GitHubRemote.url(forLocator: attachment.locator)
        switch cursorCloudRepositories {
        case .ready(let urls, _):
            return urls.contains { GitHubRemote.sameRepository($0, target) }
        case .loading, .idle:
            return nil
        case .unavailable, .failed:
            return false
        }
    }

    static let cursorIntegrationsURL = URL(string: "https://cursor.com/dashboard?tab=integrations")!
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
    static let readProvider = "readProvider"
    static let chatGPTReadModel = "chatGPTReadModelID"
    static let cursorReadModel = "cursorReadModelID"
    static let cursorCloudRepoURLs = "cursorCloudRepoURLs"
    static let cursorCloudCheckedAt = "cursorCloudCheckedAt"
    static let showAgentIDs = "showAgentIDs"
    static let projectsLayout = "projectsLayout"
    static let sidebarCollapsed = "sidebarCollapsed"
    static let projectColumnCollapsed = "projectColumnCollapsed"
    static let collapsedProjectSections = "collapsedProjectSections"
    static let settingsSection = "settingsSection"
    static let orbPalette = "orbPalette"
    static let windowTabs = "windowTabs"
    static let openChatLinksInNewTab = "openChatLinksInNewTab"
}
