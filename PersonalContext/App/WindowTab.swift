import AppKit
import Foundation
import SwiftData
import SwiftUI

enum TabActivation {
    static var commandClick: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.command) == true
    }
}

enum TabRecency {
    static func remember(_ id: UUID, in order: [UUID]) -> [UUID] {
        var next = order.filter { $0 != id }
        next.append(id)
        return next
    }

    static func selection(afterClosing id: UUID, remaining: [UUID], recency: [UUID]) -> UUID? {
        recency.last { $0 != id && remaining.contains($0) } ?? remaining.last
    }
}

struct WindowTab: Identifiable, Hashable, Codable {
    var id: UUID
    var destination: Destination
    var projectTab: ProjectTab
    var selectedThread: UUID?
    var selectedNote: UUID?
    var selectedDecision: UUID?
    var selectedConversation: UUID?
    var selectedRun: UUID?

    static func home(id: UUID = UUID()) -> WindowTab {
        WindowTab(
            id: id,
            destination: .home,
            projectTab: .chat,
            selectedThread: nil,
            selectedNote: nil,
            selectedDecision: nil,
            selectedConversation: nil,
            selectedRun: nil
        )
    }

    var viewKey: TabViewKey {
        switch destination {
        case .home: .home
        case .projects: .projects
        case .tasks: .tasks
        case .calendar: .calendar
        case .chats: .chats
        case .runs: .runs
        case .settings: .settings
        case .quickAsk(let id): .conversation(id)
        case .run(let id): .run(id)
        case .aboutYou: .aboutYou
        case .space(let id): .space(id)
        case .spaceRecord(_, let record): .spaceRecord(record)
        case .project(let id):
            switch projectTab {
            case .overview: .projectOverview(id)
            case .tasks: .projectTasks(id)
            case .threads:
                selectedThread.map { .thread($0) } ?? .projectThreads(id)
            case .notes:
                selectedNote.map { .note($0) } ?? .projectNotes(id)
            case .decisions:
                selectedDecision.map { .decision($0) } ?? .projectDecisions(id)
            case .chat:
                selectedConversation.map { .conversation($0) } ?? .projectChat(id)
            case .runs:
                selectedRun.map { .run($0) } ?? .projectRuns(id)
            }
        }
    }

    var generatingID: UUID? {
        switch destination {
        case .quickAsk(let id): id
        case .run(let id): id
        default: selectedConversation ?? selectedRun
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, destination, projectTab, selectedThread, selectedNote, selectedDecision, selectedConversation, selectedRun
    }

    init(
        id: UUID,
        destination: Destination,
        projectTab: ProjectTab,
        selectedThread: UUID?,
        selectedNote: UUID?,
        selectedDecision: UUID?,
        selectedConversation: UUID?,
        selectedRun: UUID? = nil
    ) {
        self.id = id
        self.destination = destination
        self.projectTab = projectTab
        self.selectedThread = selectedThread
        self.selectedNote = selectedNote
        self.selectedDecision = selectedDecision
        self.selectedConversation = selectedConversation
        self.selectedRun = selectedRun
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        destination = try container.decode(Destination.self, forKey: .destination)
        projectTab = try container.decode(ProjectTab.self, forKey: .projectTab)
        selectedThread = try container.decodeIfPresent(UUID.self, forKey: .selectedThread)
        selectedNote = try container.decodeIfPresent(UUID.self, forKey: .selectedNote)
        selectedDecision = try container.decodeIfPresent(UUID.self, forKey: .selectedDecision)
        selectedConversation = try container.decodeIfPresent(UUID.self, forKey: .selectedConversation)
        selectedRun = try container.decodeIfPresent(UUID.self, forKey: .selectedRun)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(destination, forKey: .destination)
        try container.encode(projectTab, forKey: .projectTab)
        try container.encodeIfPresent(selectedThread, forKey: .selectedThread)
        try container.encodeIfPresent(selectedNote, forKey: .selectedNote)
        try container.encodeIfPresent(selectedDecision, forKey: .selectedDecision)
        try container.encodeIfPresent(selectedConversation, forKey: .selectedConversation)
        try container.encodeIfPresent(selectedRun, forKey: .selectedRun)
    }
}

enum TabViewKey: Hashable {
    case home, projects, tasks, calendar, chats, runs, settings, aboutYou
    case space(UUID)
    case spaceRecord(UUID)
    case projectOverview(UUID)
    case projectTasks(UUID)
    case projectChat(UUID)
    case projectRuns(UUID)
    case projectThreads(UUID)
    case projectNotes(UUID)
    case projectDecisions(UUID)
    case thread(UUID)
    case note(UUID)
    case decision(UUID)
    case conversation(UUID)
    case run(UUID)
}

struct ProjectViewMemory: Codable, Equatable {
    var tab: ProjectTab
    var thread: UUID?
    var note: UUID?
    var decision: UUID?
    var conversation: UUID?
    var run: UUID?

    static func windowTab(projectID: UUID, tab: ProjectTab?, memory: ProjectViewMemory?) -> WindowTab {
        let section = tab ?? memory?.tab ?? .overview
        return WindowTab(
            id: UUID(),
            destination: .project(projectID),
            projectTab: section,
            selectedThread: section == .threads ? memory?.thread : nil,
            selectedNote: section == .notes ? memory?.note : nil,
            selectedDecision: section == .decisions ? memory?.decision : nil,
            selectedConversation: section == .chat ? memory?.conversation : nil,
            selectedRun: section == .runs ? memory?.run : nil
        )
    }

    static func snapshot(from tab: WindowTab) -> (UUID, ProjectViewMemory)? {
        guard case .project(let id) = tab.destination else { return nil }
        return (
            id,
            ProjectViewMemory(
                tab: tab.projectTab,
                thread: tab.selectedThread,
                note: tab.selectedNote,
                decision: tab.selectedDecision,
                conversation: tab.selectedConversation,
                run: tab.selectedRun
            )
        )
    }
}

struct TabHistory: Codable, Equatable {
    var back: [WindowTab] = []
    var forward: [WindowTab] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
}

private struct StoredTabHistory: Codable {
    var tabID: UUID
    var back: [WindowTab]
    var forward: [WindowTab]
}

private struct StoredWindowTabs: Codable {
    var tabs: [WindowTab]
    var selectedID: UUID
    var histories: [StoredTabHistory]?
    var recency: [UUID]?
    var projectViews: [UUID: ProjectViewMemory]?
}

extension AppModel {
    var destination: Destination {
        get { chromeDestination }
        set { navigate(to: newValue) }
    }

    func navigate(to destination: Destination, newTab: Bool = TabActivation.commandClick) {
        reveal(windowTab(for: destination), newTab: newTab)
    }

    func open(_ project: Project, tab: ProjectTab? = nil, newTab: Bool = TabActivation.commandClick) {
        reveal(windowTab(for: project, tab: tab), newTab: newTab)
    }

    func open(_ row: TitleIndex, newTab: Bool = TabActivation.commandClick) {
        NavTrace.begin("open.\(row.kind.rawValue) id=\(row.id)")
        NavTrace.keep()
        let context = container.mainContext
        switch row.kind {
        case .project:
            if let project = NavTrace.measure("fetch.project") { TitleIndexStore.project(row.id, in: context) } {
                open(project, newTab: newTab)
            }
        case .track:
            if let thread = NavTrace.measure("fetch.track") { TitleIndexStore.thread(row.id, in: context) } {
                open(thread, newTab: newTab)
            }
        case .note:
            if let note = NavTrace.measure("fetch.note") { TitleIndexStore.note(row.id, in: context) } {
                open(note, newTab: newTab)
            }
        case .decision:
            if let decision = NavTrace.measure("fetch.decision") { TitleIndexStore.decision(row.id, in: context) } {
                open(decision, newTab: newTab)
            }
        case .chat:
            if let conversation = NavTrace.measure("fetch.chat") { TitleIndexStore.conversation(row.id, in: context) } {
                open(conversation, newTab: newTab)
            }
        case .task:
            if let task = NavTrace.measure("fetch.task") { TitleIndexStore.task(row.id, in: context) } {
                open(task, newTab: newTab)
            }
        case .run:
            if let run = NavTrace.measure("fetch.run") { TitleIndexStore.run(row.id, in: context) } {
                open(run, newTab: newTab)
            }
        }
    }

    private func windowTab(for destination: Destination) -> WindowTab {
        if case .project(let id) = destination {
            return windowTab(projectID: id, tab: nil)
        }
        return WindowTab(
            id: UUID(),
            destination: destination,
            projectTab: .chat,
            selectedThread: nil,
            selectedNote: nil,
            selectedDecision: nil,
            selectedConversation: nil,
            selectedRun: nil
        )
    }

    private func windowTab(for project: Project, tab: ProjectTab?) -> WindowTab {
        windowTab(projectID: project.id, tab: tab)
    }

    private func windowTab(projectID: UUID, tab: ProjectTab?) -> WindowTab {
        ProjectViewMemory.windowTab(projectID: projectID, tab: tab, memory: projectViews[projectID])
    }

    func open(_ thread: ProjectThread, newTab: Bool = TabActivation.commandClick) {
        guard let project = thread.project else { return }
        openProjectSection(.tracks)
        reveal(
            WindowTab(
                id: UUID(),
                destination: .project(project.id),
                projectTab: .threads,
                selectedThread: thread.id,
                selectedNote: nil,
                selectedDecision: nil,
                selectedConversation: nil
            ),
            newTab: newTab
        )
    }

    func open(_ note: Note, newTab: Bool = TabActivation.commandClick) {
        guard let project = note.project else { return }
        openProjectSection(.notes)
        reveal(
            WindowTab(
                id: UUID(),
                destination: .project(project.id),
                projectTab: .notes,
                selectedThread: nil,
                selectedNote: note.id,
                selectedDecision: nil,
                selectedConversation: nil
            ),
            newTab: newTab
        )
    }

    func open(_ decision: Decision, newTab: Bool = TabActivation.commandClick) {
        guard let project = decision.project else { return }
        openProjectSection(.decisions)
        reveal(
            WindowTab(
                id: UUID(),
                destination: .project(project.id),
                projectTab: .decisions,
                selectedThread: nil,
                selectedNote: nil,
                selectedDecision: decision.id,
                selectedConversation: nil
            ),
            newTab: newTab
        )
    }

    func open(_ run: AgentRun, newTab: Bool = TabActivation.commandClick) {
        if let project = run.project {
            openProjectSection(.runs)
            reveal(
                WindowTab(
                    id: UUID(),
                    destination: .project(project.id),
                    projectTab: .runs,
                    selectedThread: nil,
                    selectedNote: nil,
                    selectedDecision: nil,
                    selectedConversation: nil,
                    selectedRun: run.id
                ),
                newTab: newTab
            )
        } else {
            reveal(
                WindowTab(
                    id: UUID(),
                    destination: .run(run.id),
                    projectTab: .runs,
                    selectedThread: nil,
                    selectedNote: nil,
                    selectedDecision: nil,
                    selectedConversation: nil,
                    selectedRun: run.id
                ),
                newTab: newTab
            )
        }
    }

    func showProjectRuns(in project: Project, newTab: Bool = TabActivation.commandClick) {
        openProjectSection(.runs)
        reveal(
            WindowTab(
                id: UUID(),
                destination: .project(project.id),
                projectTab: .runs,
                selectedThread: nil,
                selectedNote: nil,
                selectedDecision: nil,
                selectedConversation: nil,
                selectedRun: nil
            ),
            newTab: newTab
        )
    }

    func open(_ conversation: Conversation, newTab: Bool = TabActivation.commandClick) {
        if let project = conversation.project {
            openProjectSection(.chats)
            reveal(
                WindowTab(
                    id: UUID(),
                    destination: .project(project.id),
                    projectTab: .chat,
                    selectedThread: nil,
                    selectedNote: nil,
                    selectedDecision: nil,
                    selectedConversation: conversation.id
                ),
                newTab: newTab
            )
        } else {
            reveal(
                WindowTab(
                    id: UUID(),
                    destination: .quickAsk(conversation.id),
                    projectTab: .chat,
                    selectedThread: nil,
                    selectedNote: nil,
                    selectedDecision: nil,
                    selectedConversation: conversation.id
                ),
                newTab: newTab
            )
        }
    }

    func open(_ task: AgendaItem, newTab: Bool = TabActivation.commandClick) {
        if let project = task.project {
            reveal(
                WindowTab(
                    id: UUID(),
                    destination: .project(project.id),
                    projectTab: .tasks,
                    selectedThread: nil,
                    selectedNote: nil,
                    selectedDecision: nil,
                    selectedConversation: nil
                ),
                newTab: newTab
            )
            selectTask(task.id)
        } else {
            navigate(to: .tasks, newTab: newTab)
        }
    }

    func showNewChat(in project: Project, newTab: Bool = TabActivation.commandClick) {
        reveal(
            WindowTab(
                id: UUID(),
                destination: .project(project.id),
                projectTab: .chat,
                selectedThread: nil,
                selectedNote: nil,
                selectedDecision: nil,
                selectedConversation: nil
            ),
            newTab: newTab
        )
    }

    func openNewChatTab() {
        _ = makeConversation(in: nil, context: container.mainContext, newTab: true)
    }

    func goBack() {
        guard var history = tabHistories[selectedTabID], let previous = history.back.popLast() else { return }
        persistCurrentIntoSelectedTab()
        history.forward.append(currentWindowTab())
        tabHistories[selectedTabID] = history
        restoreHistory(previous)
    }

    func goForward() {
        guard var history = tabHistories[selectedTabID], let next = history.forward.popLast() else { return }
        persistCurrentIntoSelectedTab()
        history.back.append(currentWindowTab())
        tabHistories[selectedTabID] = history
        restoreHistory(next)
    }

    func selectTab(_ id: UUID) {
        guard id != selectedTabID, windowTabs.contains(where: { $0.id == id }) else { return }
        persistCurrentIntoSelectedTab()
        selectedTabID = id
        rememberSelectedTab()
        if let tab = windowTabs.first(where: { $0.id == id }) {
            withoutHistory {
                apply(tab, persist: true)
            }
        }
    }

    func selectAdjacentTab(_ step: Int) {
        guard let index = windowTabs.firstIndex(where: { $0.id == selectedTabID }), !windowTabs.isEmpty else { return }
        let next = (index + step + windowTabs.count) % windowTabs.count
        selectTab(windowTabs[next].id)
    }

    func selectTab(at index: Int) {
        guard windowTabs.indices.contains(index) else { return }
        selectTab(windowTabs[index].id)
    }

    func selectLastTab() {
        guard let last = windowTabs.last else { return }
        selectTab(last.id)
    }

    func closeTab(_ id: UUID) {
        persistCurrentIntoSelectedTab()
        guard windowTabs.contains(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        windowTabs.removeAll { $0.id == id }
        discardHistory(id)
        tabRecency.removeAll { $0 == id }
        if windowTabs.isEmpty {
            showLoneHome()
            return
        }
        if wasSelected {
            activateRemainingTab()
        } else {
            persistWindowTabs()
            syncHistoryButtons()
        }
    }

    func closeSelectedTab() {
        closeTab(selectedTabID)
    }

    func closeTabs(forProject id: UUID) {
        persistCurrentIntoSelectedTab()
        let remaining = windowTabs.filter { tab in
            if case .project(let projectID) = tab.destination { return projectID != id }
            return true
        }
        if remaining.count == windowTabs.count { return }
        let removed = windowTabs.filter { tab in !remaining.contains(where: { $0.id == tab.id }) }
        for tab in removed {
            discardHistory(tab.id)
        }
        windowTabs = remaining
        tabRecency.removeAll { id in removed.contains(where: { $0.id == id }) }
        if windowTabs.isEmpty {
            showLoneHome()
            return
        }
        if !windowTabs.contains(where: { $0.id == selectedTabID }) {
            activateRemainingTab()
        } else {
            persistWindowTabs()
            syncHistoryButtons()
        }
    }

    func reorderTabs(_ ids: [UUID]) {
        persistCurrentIntoSelectedTab()
        let current = windowTabs.map(\.id)
        guard current != ids, current.count == ids.count, Set(current) == Set(ids) else { return }
        windowTabs = ids.compactMap { id in windowTabs.first { $0.id == id } }
        persistWindowTabs()
    }

    func reveal(_ incoming: WindowTab, newTab: Bool) {
        NavTrace.begin("reveal \(incoming.viewKey) newTab=\(newTab)")
        persistCurrentIntoSelectedTab()
        if let existing = windowTabs.first(where: { $0.viewKey == incoming.viewKey }) {
            if newTab || existing.id == selectedTabID {
                selectedTabID = existing.id
                rememberSelectedTab()
                withoutHistory {
                    apply(existing, persist: true)
                }
                return
            }
            discardHistory(existing.id)
            windowTabs.removeAll { $0.id == existing.id }
            tabRecency.removeAll { $0 == existing.id }
        }
        if newTab, !windowTabs.isEmpty {
            var tab = incoming
            if windowTabs.contains(where: { $0.id == tab.id }) {
                tab.id = UUID()
            }
            windowTabs.append(tab)
            selectedTabID = tab.id
            rememberSelectedTab()
            apply(tab, persist: true)
            return
        }
        if let index = windowTabs.firstIndex(where: { $0.id == selectedTabID }) {
            var tab = incoming
            tab.id = selectedTabID
            windowTabs[index] = tab
            apply(tab, persist: true)
            return
        }
        windowTabs = [incoming]
        selectedTabID = incoming.id
        rememberSelectedTab()
        apply(incoming, persist: true)
    }

    func restoreWindowTabs() {
        if let data = defaults.data(forKey: Keys.windowTabs),
           let stored = try? JSONDecoder().decode(StoredWindowTabs.self, from: data),
           !stored.tabs.isEmpty {
            windowTabs = stored.tabs
            selectedTabID = stored.tabs.contains(where: { $0.id == stored.selectedID })
                ? stored.selectedID
                : stored.tabs[0].id
            tabHistories = Dictionary(
                uniqueKeysWithValues: (stored.histories ?? []).compactMap { record in
                    guard stored.tabs.contains(where: { $0.id == record.tabID }) else { return nil }
                    return (record.tabID, TabHistory(back: record.back, forward: record.forward))
                }
            )
            let live = stored.tabs.map(\.id)
            tabRecency = TabRecency.remember(
                selectedTabID,
                in: (stored.recency ?? []).filter { live.contains($0) }
            )
            if let storedViews = stored.projectViews {
                projectViews = storedViews
            } else {
                for tab in stored.tabs {
                    rememberProjectView(tab)
                }
            }
        } else {
            let home = WindowTab.home()
            windowTabs = [home]
            selectedTabID = home.id
            tabHistories = [:]
            tabRecency = [home.id]
        }
        if let tab = windowTabs.first(where: { $0.id == selectedTabID }) {
            withoutHistory {
                apply(tab, persist: false)
            }
        }
    }

    private func persistCurrentIntoSelectedTab() {
        guard let index = windowTabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let current = currentWindowTab()
        guard windowTabs[index] != current else { return }
        windowTabs[index] = current
    }

    private func currentWindowTab() -> WindowTab {
        let projectTab: ProjectTab = {
            if case .project(let id) = chromeDestination { return tabs[id] ?? .chat }
            return .chat
        }()
        return WindowTab(
            id: selectedTabID,
            destination: chromeDestination,
            projectTab: projectTab,
            selectedThread: selectedThread,
            selectedNote: selectedNote,
            selectedDecision: selectedDecision,
            selectedConversation: selectedConversation,
            selectedRun: selectedRun
        )
    }

    private func apply(_ tab: WindowTab, persist: Bool) {
        let start = ContinuousClock.now
        let previous = currentWindowTab()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            nav = NavSelection(
                destination: tab.destination,
                thread: tab.selectedThread,
                note: tab.selectedNote,
                decision: tab.selectedDecision,
                conversation: tab.selectedConversation,
                run: tab.selectedRun
            )
            if case .project(let id) = tab.destination {
                tabs[id] = tab.projectTab
            }
        }
        rememberProjectView(tab)
        if !historyLocked, previous.viewKey != tab.viewKey {
            recordNavigation(from: previous, to: tab)
        }
        if persist { schedulePersistWindowTabs() }
        syncHistoryButtons()
        NavTrace.event("apply \(tab.viewKey) persist=\(persist) \(NavTrace.elapsed(start))")
        NavTrace.afterTurn("apply.runloop \(tab.viewKey)")
    }

    private func rememberProjectView(_ tab: WindowTab) {
        guard let (id, memory) = ProjectViewMemory.snapshot(from: tab) else { return }
        projectViews[id] = memory
    }

    func flushWindowTabs() {
        persistTabsTask?.cancel()
        persistTabsTask = nil
        persistCurrentIntoSelectedTab()
        persistWindowTabs()
    }

    private func schedulePersistWindowTabs() {
        persistTabsTask?.cancel()
        persistTabsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.persistWindowTabs()
            self.persistTabsTask = nil
        }
    }

    private func persistWindowTabs() {
        tabHistories = tabHistories.filter { id, _ in windowTabs.contains { $0.id == id } }
        tabRecency = tabRecency.filter { id in windowTabs.contains { $0.id == id } }
        let stored = StoredWindowTabs(
            tabs: windowTabs,
            selectedID: selectedTabID,
            histories: tabHistories.map { id, history in
                StoredTabHistory(tabID: id, back: history.back, forward: history.forward)
            },
            recency: tabRecency,
            projectViews: projectViews
        )
        defaults.set(try? JSONEncoder().encode(stored), forKey: Keys.windowTabs)
    }

    private func rememberSelectedTab() {
        tabRecency = TabRecency.remember(selectedTabID, in: tabRecency)
    }

    private func showLoneHome() {
        let home = WindowTab.home()
        windowTabs = [home]
        selectedTabID = home.id
        tabRecency = [home.id]
        withoutHistory {
            apply(home, persist: true)
        }
    }

    private func activateRemainingTab() {
        guard let nextID = TabRecency.selection(
            afterClosing: selectedTabID,
            remaining: windowTabs.map(\.id),
            recency: tabRecency
        ), let next = windowTabs.first(where: { $0.id == nextID }) else { return }
        selectedTabID = next.id
        rememberSelectedTab()
        withoutHistory {
            apply(next, persist: true)
        }
    }

    private func recordNavigation(from previous: WindowTab, to next: WindowTab) {
        guard previous.viewKey != next.viewKey else { return }
        var history = tabHistories[selectedTabID] ?? TabHistory()
        history.back.append(previous)
        if history.back.count > 50 {
            history.back.removeFirst(history.back.count - 50)
        }
        history.forward = []
        tabHistories[selectedTabID] = history
    }

    private func restoreHistory(_ snapshot: WindowTab) {
        var tab = snapshot
        tab.id = selectedTabID
        if let other = windowTabs.first(where: { $0.id != selectedTabID && $0.viewKey == tab.viewKey }) {
            discardHistory(other.id)
            windowTabs.removeAll { $0.id == other.id }
        }
        if let index = windowTabs.firstIndex(where: { $0.id == selectedTabID }) {
            windowTabs[index] = tab
        }
        withoutHistory {
            apply(tab, persist: true)
        }
    }

    private func discardHistory(_ id: UUID) {
        tabHistories[id] = nil
        syncHistoryButtons()
    }

    private func syncHistoryButtons() {
        let history = tabHistories[selectedTabID]
        canGoBack = history?.canGoBack ?? false
        canGoForward = history?.canGoForward ?? false
    }

    private func withoutHistory(_ work: () -> Void) {
        historyLocked = true
        work()
        historyLocked = false
    }
}
