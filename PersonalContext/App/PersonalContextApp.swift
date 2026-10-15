import AppKit
import SwiftData
import SwiftUI

/// Quitting waits for a session's running turn, so the worker can commit and the session carries on after relaunch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the app model exists.
    static var turnIsRunning: () -> Bool = { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.turnIsRunning() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "The agent is in the middle of a turn"
        alert.informativeText = "Membrae will quit as soon as it finishes, so the session carries on when you come back."
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Quit Now")
        if alert.runModal() == .alertSecondButtonReturn { return .terminateNow }
        Task { @MainActor in
            let deadline = Date.now.addingTimeInterval(180)
            while Self.turnIsRunning(), Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(300))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MembraeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(app.appearance.colorScheme)
                .modelContainer(app.container)
                .textSelection(.enabled)
                .background(MembraneLabLauncher())
                .onAppear {
                    FocusDismissal.install()
                    CloseTabShortcut.install(app)
                    let model = app
                    AppDelegate.turnIsRunning = { model.runCoordinator.hasRunningSessionTurn }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        app.importRelay.handleForeground()
                        app.sync.handleForeground()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    app.flushWindowTabs()
                    app.browser.shutdown()
                    app.mcp.shutdown()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    app.importRelay.handleWake()
                    app.sync.handleWake()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Space") {
                    app.present(.newSpace)
                }
                .keyboardShortcut("n")
                Button("New Chat") {
                    app.openNewChatTab()
                }
                .keyboardShortcut("t")
            }
            CommandMenu("Tabs") {
                Button("Back") {
                    app.goBack()
                }
                .keyboardShortcut("[")
                .disabled(!app.canGoBack)
                Button("Forward") {
                    app.goForward()
                }
                .keyboardShortcut("]")
                .disabled(!app.canGoForward)
                Divider()
                Button("Close Tab") {
                    app.closeSelectedTab()
                }
                .keyboardShortcut("w")
                Button("Show Next Tab") {
                    app.selectAdjacentTab(1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Show Next Tab") {
                    app.selectAdjacentTab(1)
                }
                .keyboardShortcut(.tab, modifiers: .control)
                Button("Show Previous Tab") {
                    app.selectAdjacentTab(-1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Show Previous Tab") {
                    app.selectAdjacentTab(-1)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Divider()
                ForEach(0..<8, id: \.self) { index in
                    Button("Tab \(index + 1)") {
                        app.selectTab(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Button("Last Tab") {
                    app.selectLastTab()
                }
                .keyboardShortcut("9")
            }
            CommandGroup(after: .textEditing) {
                Button("Composer") {
                    app.composer.toggle()
                }
                .keyboardShortcut("k")
                Button(app.objectFind.isOpen ? "Hide Find" : "Find…") {
                    app.objectFind.toggle()
                }
                .keyboardShortcut("f")
                .disabled(!app.isObjectPage && !app.objectFind.isOpen)
                Button("Find Next") {
                    app.objectFind.next()
                }
                .keyboardShortcut("g")
                .disabled(!app.isObjectPage && !app.objectFind.isOpen)
                Button("Find Previous") {
                    app.objectFind.previous()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!app.isObjectPage && !app.objectFind.isOpen)
            }
            CommandGroup(after: .sidebar) {
                Button(app.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    app.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                MembraneLabButton()
            }
        }

        Window("Membrane", id: MembraneLabButton.windowID) {
            MembraneLab()
        }
        .defaultSize(width: 560, height: 640)

        Settings {
            SettingsView()
                .navigationTitle("Settings")
                .environment(app)
                .preferredColorScheme(app.appearance.colorScheme)
                .modelContainer(app.container)
                .textSelection(.enabled)
                .frame(minWidth: 820, minHeight: 680)
                .environment(\.modalHost, .settings)
                .overlay {
                    MembraeModalPresenter(modal: app.modal(in: .settings), onDismiss: app.dismissModal) { modal in
                        switch modal {
                        case .connectCursor: ConnectCursorSheet()
                        case .connectChatGPT: ConnectChatGPTSheet()
                        case .connectAI: ConnectAISheet()
                        case .connectLocalAgent(let agent): ConnectLocalAgentSheet(agent: agent)
                        case .connectGitHub: ConnectGitHubSheet()
                        case .connectGitLab: ConnectGitLabSheet()
                        case .replaceImportKey: ReplaceImportKeySheet()
                        default: EmptyView()
                        }
                    }
                    .environment(app)
                }
        }
        .defaultSize(width: 860, height: 720)
    }
}

private struct MembraneLabButton: View {
    static let windowID = "membrane-lab"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Membrane Prototype") {
            openWindow(id: Self.windowID)
        }
        .keyboardShortcut("m", modifiers: [.option, .command])
    }
}

/// Opens the prototype at launch when the app is started with `-openMembraneLab YES`.
private struct MembraneLabLauncher: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            if UserDefaults.standard.bool(forKey: "openMembraneLab") {
                openWindow(id: MembraneLabButton.windowID)
            }
        }
    }
}
