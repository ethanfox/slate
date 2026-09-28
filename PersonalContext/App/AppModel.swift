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
    private var storeChangedElsewhere = false
    var destination: Destination = .home
    var tabs: [UUID: ProjectTab] = [:]
    var selectedThread: UUID?
    var selectedNote: UUID?
    var selectedDecision: UUID?
    var selectedConversation: UUID?
    var isPresentingNewProject = false
    var toast: String?
    var pendingSend: PendingSend?
    var chatConversationID: UUID?
    var activeReply = ""
    var chatGenerating = false {
        didSet { if !chatGenerating { reloadIfIdle() } }
    }
    var saveKind: SaveKind?

    var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
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

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            sidebarCollapsed.toggle()
        }
    }

    private(set) var apiKey: String?
    private(set) var connection: ConnectionState = .missing
    private(set) var models: [CursorModel] = []
    private(set) var modelsError: String?
    var storeError: String?

    var hasAPIKey: Bool { apiKey?.isEmpty == false }

    private let defaults = UserDefaults.standard

    init() {
        appearance = AppearancePreference(rawValue: UserDefaults.standard.string(forKey: Keys.appearance) ?? "") ?? .system
        defaultModelID = UserDefaults.standard.string(forKey: Keys.defaultModel) ?? ""
        showAgentIDs = UserDefaults.standard.bool(forKey: Keys.showAgentIDs)
        let storedLayout = UserDefaults.standard.string(forKey: Keys.projectsLayout) ?? ""
        projectsLayout = storedLayout == "list" ? .card : (ProjectsLayout(rawValue: storedLayout) ?? .table)
        sidebarCollapsed = UserDefaults.standard.bool(forKey: Keys.sidebarCollapsed)
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
    }

    /// The MCP writes from its own process, so this context never sees those rows until the store is reopened.
    /// A streaming chat still holds records from the current context, so the reopen waits until it has saved its reply.
    private func storeDidChangeElsewhere() {
        storeChangedElsewhere = true
        reloadIfIdle()
    }

    private func reloadIfIdle() {
        guard storeChangedElsewhere, !chatGenerating else { return }
        storeChangedElsewhere = false
        try? container.mainContext.save()
        do {
            container = try Store.open()
            ChatTrace.event("store reopened after outside change")
        } catch {
            storeError = error.localizedDescription
        }
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
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if toast == message { toast = nil }
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
    static let defaultModel = "defaultModelID"
    static let showAgentIDs = "showAgentIDs"
    static let projectsLayout = "projectsLayout"
    static let sidebarCollapsed = "sidebarCollapsed"
}
