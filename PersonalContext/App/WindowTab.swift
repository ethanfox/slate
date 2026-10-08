import Foundation
import SwiftData
import SwiftUI

struct WindowTab: Identifiable, Hashable, Codable {
    var id: UUID
    var destination: Destination
    var projectTab: ProjectTab
    var selectedThread: UUID?
    var selectedNote: UUID?
    var selectedDecision: UUID?
    var selectedConversation: UUID?

    static func home(id: UUID = UUID()) -> WindowTab {
        WindowTab(
            id: id,
            destination: .home,
            projectTab: .chat,
            selectedThread: nil,
            selectedNote: nil,
            selectedDecision: nil,
            selectedConversation: nil
        )
    }

    var viewKey: TabViewKey {
        switch destination {
        case .home: .home
        case .projects: .projects
        case .tasks: .tasks
        case .calendar: .calendar
        case .chats: .chats
        case .settings: .settings
        case .quickAsk(let id): .conversation(id)
        case .project(let id):
            switch projectTab {
            case .overview: .projectOverview(id)
            case .threads:
                selectedThread.map { .thread($0) } ?? .projectChat(id)
            case .notes:
                selectedNote.map { .note($0) } ?? .projectChat(id)
            case .decisions:
                selectedDecision.map { .decision($0) } ?? .projectChat(id)
            case .chat:
                selectedConversation.map { .conversation($0) } ?? .projectChat(id)
            }
        }
    }

    var generatingID: UUID? {
        switch destination {
        case .quickAsk(let id): id
        default: selectedConversation
        }
    }
}

enum TabViewKey: Hashable {
    case home, projects, tasks, calendar, chats, settings
    case projectOverview(UUID)
    case projectChat(UUID)
    case thread(UUID)
    case note(UUID)
    case decision(UUID)
    case conversation(UUID)
}

private struct StoredWindowTabs: Codable {
    var tabs: [WindowTab]
    var selectedID: UUID
}

extension AppModel {
    var destination: Destination {
        get { chromeDestination }
        set { navigate(to: newValue) }
    }

    func navigate(to destination: Destination, newTab: Bool = false) {
        reveal(windowTab(for: destination), newTab: newTab)
    }

    func open(_ project: Project, tab: ProjectTab? = nil, newTab: Bool = false) {
        reveal(windowTab(for: project, tab: tab), newTab: newTab)
    }

    private func windowTab(for destination: Destination) -> WindowTab {
        if case .project(let id) = destination,
           let project = (try? container.mainContext.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })))?.first {
            return windowTab(for: project, tab: nil)
        }
        return WindowTab(
            id: UUID(),
            destination: destination,
            projectTab: .chat,
            selectedThread: nil,
            selectedNote: nil,
            selectedDecision: nil,
            selectedConversation: nil
        )
    }

    private func windowTab(for project: Project, tab: ProjectTab?) -> WindowTab {
        let section = tab ?? .overview
        let thread = project.threads.contains(where: { $0.id == selectedThread }) ? selectedThread : nil
        let note = project.notes.contains(where: { $0.id == selectedNote }) ? selectedNote : nil
        let decision = project.decisions.contains(where: { $0.id == selectedDecision }) ? selectedDecision : nil
        let conversation = project.conversations.contains(where: { $0.id == selectedConversation }) ? selectedConversation : nil
        return WindowTab(
            id: UUID(),
            destination: .project(project.id),
            projectTab: section,
            selectedThread: section == .threads ? thread : nil,
            selectedNote: section == .notes ? note : nil,
            selectedDecision: section == .decisions ? decision : nil,
            selectedConversation: section == .chat ? conversation : nil
        )
    }

    func open(_ thread: ProjectThread, newTab: Bool = false) {
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

    func open(_ note: Note, newTab: Bool = false) {
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

    func open(_ decision: Decision, newTab: Bool = false) {
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

    func open(_ conversation: Conversation, newTab: Bool = false) {
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

    func showNewChat(in project: Project, newTab: Bool = false) {
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

    func selectTab(_ id: UUID) {
        guard id != selectedTabID, windowTabs.contains(where: { $0.id == id }) else { return }
        persistCurrentIntoSelectedTab()
        selectedTabID = id
        if let tab = windowTabs.first(where: { $0.id == id }) {
            apply(tab, persist: true)
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
        guard let index = windowTabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        windowTabs.remove(at: index)
        if windowTabs.isEmpty {
            let home = WindowTab.home()
            windowTabs = [home]
            selectedTabID = home.id
            apply(home, persist: true)
            return
        }
        if wasSelected {
            let next = index < windowTabs.count ? windowTabs[index] : windowTabs[index - 1]
            selectedTabID = next.id
            apply(next, persist: true)
        } else {
            persistWindowTabs()
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
        windowTabs = remaining
        if windowTabs.isEmpty {
            let home = WindowTab.home()
            windowTabs = [home]
            selectedTabID = home.id
            apply(home, persist: true)
            return
        }
        if !windowTabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = windowTabs[min(windowTabs.count - 1, 0)].id
            if let tab = windowTabs.first(where: { $0.id == selectedTabID }) {
                apply(tab, persist: true)
            }
        } else {
            persistWindowTabs()
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
        persistCurrentIntoSelectedTab()
        if let existing = windowTabs.first(where: { $0.viewKey == incoming.viewKey }) {
            if newTab || existing.id == selectedTabID {
                selectedTabID = existing.id
                apply(existing, persist: true)
                return
            }
            windowTabs.removeAll { $0.id == existing.id }
        }
        if newTab, !windowTabs.isEmpty {
            var tab = incoming
            if windowTabs.contains(where: { $0.id == tab.id }) {
                tab.id = UUID()
            }
            windowTabs.append(tab)
            selectedTabID = tab.id
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
        } else {
            let home = WindowTab.home()
            windowTabs = [home]
            selectedTabID = home.id
        }
        if let tab = windowTabs.first(where: { $0.id == selectedTabID }) {
            apply(tab, persist: false)
        }
    }

    private func persistCurrentIntoSelectedTab() {
        guard let index = windowTabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        windowTabs[index] = currentWindowTab()
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
            selectedConversation: selectedConversation
        )
    }

    private func apply(_ tab: WindowTab, persist: Bool) {
        chromeDestination = tab.destination
        if case .project(let id) = tab.destination {
            tabs[id] = tab.projectTab
        }
        selectedThread = tab.selectedThread
        selectedNote = tab.selectedNote
        selectedDecision = tab.selectedDecision
        selectedConversation = tab.selectedConversation
        if persist { persistWindowTabs() }
    }

    private func persistWindowTabs() {
        let stored = StoredWindowTabs(tabs: windowTabs, selectedID: selectedTabID)
        defaults.set(try? JSONEncoder().encode(stored), forKey: Keys.windowTabs)
    }
}
