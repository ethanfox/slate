import Foundation
import SwiftData
import SwiftUI

enum ConnectionState: Equatable {
    case missing
    case checking
    case connected(String)
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    private(set) var container: ModelContainer
    var destination: Destination = .home
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
    var showAgentIDs: Bool {
        didSet { defaults.set(showAgentIDs, forKey: Keys.showAgentIDs) }
    }
    var projectsLayout: ProjectsLayout {
        didSet { defaults.set(projectsLayout.rawValue, forKey: Keys.projectsLayout) }
    }
    var sidebarCollapsed: Bool {
        didSet { defaults.set(sidebarCollapsed, forKey: Keys.sidebarCollapsed) }
    }
    var settingsSection: SettingsSection {
        didSet { defaults.set(settingsSection.rawValue, forKey: Keys.settingsSection) }
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

    var hasAPIKey: Bool { apiKey?.isEmpty == false }

    private let defaults = UserDefaults.standard

    init() {
        appearance = AppearancePreference(rawValue: UserDefaults.standard.string(forKey: Keys.appearance) ?? "") ?? .system
        accent = AccentPreference(rawValue: UserDefaults.standard.string(forKey: Keys.accent) ?? "") ?? .system
        accentedViews = Set(UserDefaults.standard.stringArray(forKey: Keys.accentedViews) ?? [])
        defaultModelID = UserDefaults.standard.string(forKey: Keys.defaultModel) ?? ""
        showAgentIDs = UserDefaults.standard.bool(forKey: Keys.showAgentIDs)
        let storedLayout = UserDefaults.standard.string(forKey: Keys.projectsLayout) ?? ""
        projectsLayout = storedLayout == "list" ? .card : (ProjectsLayout(rawValue: storedLayout) ?? .table)
        sidebarCollapsed = UserDefaults.standard.bool(forKey: Keys.sidebarCollapsed)
        settingsSection = SettingsSection(rawValue: UserDefaults.standard.string(forKey: Keys.settingsSection) ?? "") ?? .cursor
        if let data = UserDefaults.standard.data(forKey: Keys.orbPalette),
           let stored = try? JSONDecoder().decode(OrbPalette.self, from: data),
           stored != .legacySlate {
            orbPalette = stored
        } else {
            orbPalette = .slate
        }
        apiKey = KeychainStore.read()

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
        refreshUsage()
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

    func tab(for project: UUID) -> ProjectTab {
        tabs[project] ?? .chat
    }

    func open(_ project: Project, tab: ProjectTab? = nil) {
        if let tab {
            tabs[project.id] = tab
        }
        destination = .project(project.id)
    }

    func open(_ thread: ProjectThread) {
        guard let project = thread.project else { return }
        selectedThread = thread.id
        tabs[project.id] = .threads
        destination = .project(project.id)
    }

    func open(_ note: Note) {
        guard let project = note.project else { return }
        selectedNote = note.id
        tabs[project.id] = .notes
        destination = .project(project.id)
    }

    func open(_ conversation: Conversation) {
        selectedConversation = conversation.id
        if let project = conversation.project {
            tabs[project.id] = .chat
            destination = .project(project.id)
        } else {
            destination = .quickAsk(conversation.id)
        }
    }

    func makeConversation(in project: Project?, context: ModelContext) -> Conversation {
        let conversation = Conversation(model: defaultModelID, project: project)
        context.insert(conversation)
        project?.touch()
        try? context.save()
        selectedConversation = conversation.id
        if let project {
            tabs[project.id] = .chat
            destination = .project(project.id)
        } else {
            destination = .quickAsk(conversation.id)
        }
        return conversation
    }

    func makeTrackConversation(for thread: ProjectThread, in project: Project, context: ModelContext) -> Conversation {
        if let existing = thread.conversations
            .filter({ !$0.isArchived })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first {
            return existing
        }
        let conversation = Conversation(model: defaultModelID, project: project)
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
        try KeychainStore.save(key)
        apiKey = key
        refreshConnection()
    }

    func removeAPIKey() throws {
        try KeychainStore.delete()
        apiKey = nil
        models = []
        modelsError = nil
        connection = .missing
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

    func modelName(for id: String) -> String {
        if id.isEmpty { return "Account default" }
        return models.first { $0.id == id }?.displayName ?? id
    }
}

struct PendingSend: Equatable {
    var conversationID: UUID
    var text: String
}

enum SaveKind: String, Identifiable {
    case note, thread, addToThread, decision
    var id: String { rawValue }
}

private enum Keys {
    static let appearance = "appearance"
    static let accent = "accent"
    static let accentedViews = "accentedViews"
    static let defaultModel = "defaultModelID"
    static let showAgentIDs = "showAgentIDs"
    static let projectsLayout = "projectsLayout"
    static let sidebarCollapsed = "sidebarCollapsed"
    static let settingsSection = "settingsSection"
    static let orbPalette = "orbPalette"
}
