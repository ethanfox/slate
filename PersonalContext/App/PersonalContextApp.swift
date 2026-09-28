import SwiftData
import SwiftUI

@main
struct PersonalContextApp: App {
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
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    app.isPresentingNewProject = true
                }
                .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .navigationTitle("Settings")
                .environment(app)
                .preferredColorScheme(app.appearance.colorScheme)
                .modelContainer(app.container)
                .frame(width: 560, height: 640)
        }
    }
}
