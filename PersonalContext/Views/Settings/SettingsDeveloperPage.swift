import SwiftData
import SwiftUI

struct SettingsDeveloperPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalHost) private var modalHost
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(ChangeLog.latestDescriptor) private var latestChanges: [RecordChange]
    @State private var changeCount = 0
    @State private var previewProjectID: UUID?
    @State private var lifetimeDays = 7
    @State private var customDays = "7"
    @State private var copiedKey = false

    var body: some View {
        @Bindable var app = app
        @Bindable var relay = app.importRelay
        SettingsPage {
            SettingsGroup("Import key") {
                SettingsRow {
                    Text("Manual key for Gemini CLI and other clients that send a header. ChatGPT and Claude use Settings → Import.")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if hasLiveKey {
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("Key")
                        Spacer(minLength: 16)
                        if let key = relay.revealedKey {
                            Text(key)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Button(copiedKey ? "Copied" : "Copy") {
                                CraftClipboard.copy(key)
                                copiedKey = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    copiedKey = false
                                }
                            }
                        } else {
                            Text("Hidden · last four \(relay.metadata?.lastFour ?? "————")")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Button("New key…") { app.present(.replaceImportKey, in: modalHost) }
                        Spacer(minLength: 16)
                        Button("Expire") { relay.revokeKey() }
                    }
                } else {
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("Lifetime")
                        Spacer(minLength: 16)
                        Picker("Lifetime", selection: $lifetimeDays) {
                            ForEach(ImportLifetime.presets, id: \.self) { days in
                                Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                            }
                            Text("Custom").tag(-1)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if lifetimeDays == -1 {
                            TextField("Days", text: $customDays)
                                .frame(width: 48)
                        }
                    }
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Button("Create key") {
                            let days = lifetimeDays == -1 ? ImportLifetime.clamped(Int(customDays) ?? 7) : lifetimeDays
                            relay.createKey(days: days)
                        }
                        Spacer()
                    }
                    if let error = relay.keyError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            }

            SettingsGroup("Gemini CLI") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Install Gemini CLI.")
                    Text("2. Add \(relay.mcpURL) and an Authorization header to ~/.gemini/settings.json.")
                    Text("3. Use the key on this page. Gemini in the browser is not set up here.")
                }
                .font(CraftFont.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
            }

            SettingsGroup("Developer") {
                SettingsRow {
                    Text("Show Cursor agent IDs")
                    Spacer(minLength: 16)
                    Toggle("Show Cursor agent IDs", isOn: $app.showAgentIDs)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import relay URL")
                        Text("Empty uses https://mcp.membrae.com. For local testing only.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    TextField("https://127.0.0.1:8787", text: $relay.relayOverride)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                if !projects.isEmpty {
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("Space context")
                        Spacer(minLength: 16)
                        Picker("Space context", selection: $previewProjectID) {
                            Text("None").tag(UUID?.none)
                            ForEach(projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if let project = projects.first(where: { $0.id == previewProjectID }) {
                        Text(ContextBuilder.package(for: project))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            }

            SettingsGroup("Sync") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.sync.status.label)
                        Text("Pushed through \(app.sync.pushedSequence) · pulled to \(app.sync.pulledCursor) · last run sent \(app.sync.lastPushed), received \(app.sync.lastPulled)")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Button("Sync now") { app.sync.syncSoon() }
                }
                ForEach(projects) { project in
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text(project.displayName)
                        Spacer(minLength: 16)
                        Toggle("Synced", isOn: Binding(
                            get: { project.isSynced },
                            set: { try? SpaceStore.setSynced($0, on: project, in: context) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            SettingsGroup("Change record") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Records changed on this Mac")
                        Text("One row per record, kept for sync. A deleted record keeps its row.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Text("\(changeCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let latest = latestChanges.first {
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Latest: \(latest.sentence)")
                            Text("\(latest.origin) · \(latest.changedAt.formatted(date: .abbreviated, time: .shortened)) · sequence \(latest.sequence)")
                                .font(CraftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                    }
                }
            }
        }
        .onAppear {
            if previewProjectID == nil {
                previewProjectID = projects.first?.id
            }
        }
        .onChange(of: latestChanges.first?.sequence, initial: true) { _, _ in
            changeCount = ChangeLog.count(in: context)
        }
        .onDisappear { app.importRelay.hideKey() }
    }

    private var hasLiveKey: Bool {
        ImportKeyStore.readKey() != nil && app.importRelay.metadata?.expiresAt ?? .distantPast > .now
    }
}
