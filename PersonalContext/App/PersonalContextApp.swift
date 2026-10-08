import SwiftData
import SwiftUI

@main
struct SlateApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(app.appearance.colorScheme)
                .modelContainer(app.container)
                .textSelection(.enabled)
                .onAppear { FocusDismissal.install() }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    app.present(.newProject)
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
            }
        }

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
                    SlateModalPresenter(modal: app.modal(in: .settings), onDismiss: app.dismissModal) { modal in
                        switch modal {
                        case .connectCursor: ConnectCursorSheet()
                        case .connectChatGPT: ConnectChatGPTSheet()
                        case .connectGitHub: ConnectGitHubSheet()
                        case .connectGitLab: ConnectGitLabSheet()
                        default: EmptyView()
                        }
                    }
                    .environment(app)
                }
        }
        .defaultSize(width: 860, height: 720)
    }
}
