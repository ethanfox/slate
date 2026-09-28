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
                    app.isPresentingNewProject = true
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
                .frame(width: 560, height: 640)
        }
    }
}
