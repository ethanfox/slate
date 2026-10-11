import AppKit
import SwiftUI

struct SettingsBrowserPage: View {
    @Environment(AppModel.self) private var app
    @State private var confirmClear = false

    private var browser: BrowserRuntime { app.browser }

    var body: some View {
        SettingsPage {
            SettingsGroup("Limits") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Concurrent pages")
                        Text("Caps how many Chromium pages stay open at once.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Stepper(value: concurrentBinding, in: 1...8) {
                        Text("\(browser.store.maxConcurrentPages)")
                            .monospacedDigit()
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow private-network sites")
                        Text("Localhost and other private addresses stay blocked unless this is on.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Toggle("Allow private-network sites", isOn: privateNetworkBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            if !browser.profiles.isEmpty || !browser.rememberedHosts.isEmpty {
                SettingsGroup("Stored sessions") {
                    ForEach(Array(browser.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { Hairline().padding(.horizontal, 16) }
                        SettingsRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text(profile.host.isEmpty ? "No remembered site" : profile.host)
                                    .font(CraftFont.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 16)
                            Button("Reset") { try? browser.store.reset(profile.id) }
                            Button("Delete", role: .destructive) { try? browser.store.remove(profile.id) }
                        }
                    }
                    if !browser.rememberedHosts.isEmpty {
                        Hairline().padding(.horizontal, 16)
                        SettingsRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Remembered sites")
                                Text(browser.rememberedHosts.joined(separator: ", "))
                                    .font(CraftFont.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            SettingsGroup("Data") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Browser log")
                        Text("Timed launch, helper, and Chromium output.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Button("Open") {
                        try? BrowserSupport.ensureDirectories()
                        if !FileManager.default.fileExists(atPath: BrowserSupport.logFile.path) {
                            FileManager.default.createFile(atPath: BrowserSupport.logFile.path, contents: nil)
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([BrowserSupport.logFile])
                    }
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear browsing data")
                        Text("Removes stored sessions, remembered sites, and downloads.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Button("Clear…") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear browsing data?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                try? browser.store.clearBrowsingData()
            }
        } message: {
            Text("Stored website sessions and downloads are removed from this Mac.")
        }
    }

    private var concurrentBinding: Binding<Int> {
        Binding(
            get: { browser.store.maxConcurrentPages },
            set: { try? browser.store.setMaxConcurrentPages($0) }
        )
    }

    private var privateNetworkBinding: Binding<Bool> {
        Binding(
            get: { browser.store.allowPrivateNetwork },
            set: { try? browser.store.setAllowPrivateNetwork($0) }
        )
    }
}
