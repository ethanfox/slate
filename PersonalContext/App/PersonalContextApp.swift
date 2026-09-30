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
                        if case .connectCursor = modal {
                            ConnectCursorSheet()
                        }
                    }
                    .environment(app)
                }
        }
        .defaultSize(width: 860, height: 720)
    }
}
