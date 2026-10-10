import AppKit
import SwiftData
import SwiftUI

struct SettingsImportPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalHost) private var modalHost
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var lifetimeDays = 7
    @State private var customDays = "7"
    @State private var copiedURL = false
    @State private var copiedKey = false
    @State private var useCustomLifetime = false

    var body: some View {
        @Bindable var relay = app.importRelay
        SettingsPage {
            SettingsGroup("Import") {
                if hasLiveKey {
                    statusRow
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("Allow import while Membrae is open")
                        Spacer(minLength: 16)
                        Toggle("Allow import while Membrae is open", isOn: $relay.enabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Hairline().padding(.horizontal, 16)
                    expiresRow
                    Hairline().padding(.horizontal, 16)
                    copyRow(title: "URL", value: relay.mcpURL, copied: $copiedURL)
                    Hairline().padding(.horizontal, 16)
                    keyRow
                    if let last = relay.metadata?.lastImport {
                        Hairline().padding(.horizontal, 16)
                        SettingsRow {
                            Text("Last import")
                            Spacer(minLength: 16)
                            Text("\(last.kind) “\(last.title)” in \(last.projectName) · \(last.at.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if let error = relay.metadata?.lastOfflineError, !error.isEmpty {
                        Hairline().padding(.horizontal, 16)
                        SettingsRow {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                            Spacer(minLength: 16)
                            Button("Clear error") { relay.clearOfflineErrors() }
                        }
                    }
                } else {
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import from a browser")
                            Text("Claude and Gemini can add a new track, notes, and decisions to a project. They cannot read what is already in Membrae. This Mac must stay open.")
                                .font(CraftFont.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let expired = relay.metadata?.lastExpiredAt {
                                Text("The last key expired \(expired.formatted(date: .abbreviated, time: .shortened)). Create a key to continue.")
                                    .font(CraftFont.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if projects.isEmpty {
                                Text("Create a project in Membrae first. The chat can only add to a project that already exists.")
                                    .font(CraftFont.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Hairline().padding(.horizontal, 16)
                    lifetimeRow
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Button("Create key") { createKey() }
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

            if hasLiveKey {
                SettingsGroup("Set up Claude") {
                    numbered([
                        "In Claude, open Settings → Connectors.",
                        "Add a custom connector named Membrae.",
                        "Server URL: the URL shown above.",
                        "Authentication: No sign-in, then a request header. Authorization is Bearer plus a space plus the key. You can also use x-api-key with just the key.",
                        "In a new chat, enable the Membrae connector."
                    ])
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Button("Open Claude") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings")!) }
                        Spacer()
                    }
                }

                SettingsGroup("Set up Gemini CLI") {
                    numbered([
                        "Install Gemini CLI.",
                        "Add the server URL and Authorization header to ~/.gemini/settings.json.",
                        "Use the key shown above. Gemini in the browser is a different surface and is not set up here."
                    ])
                }

                SettingsGroup("ChatGPT") {
                    SettingsRow {
                        Text("ChatGPT on the web needs OAuth, which is not set up. Do not add this URL there.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SettingsGroup("Key") {
                    SettingsRow {
                        Button("New key…") { app.present(.replaceImportKey, in: modalHost) }
                        Spacer(minLength: 16)
                        Button("Expire") { relay.revokeKey() }
                    }
                }
            }
        }
        .onAppear { app.importRelay.retryNow() }
        .onDisappear { app.importRelay.hideKey() }
    }

    private var hasLiveKey: Bool {
        ImportKeyStore.readKey() != nil && app.importRelay.metadata?.expiresAt ?? .distantPast > .now
    }

    @ViewBuilder
    private var statusRow: some View {
        SettingsRow {
            Text("Status")
            Spacer(minLength: 16)
            Text(statusText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var statusText: String {
        switch app.importRelay.status {
        case .noKey: ""
        case .expired: "Expired"
        case .connecting: "Connecting"
        case .ready: "Ready. Membrae must stay open."
        case .reconnecting: "Reconnecting"
        case .unreachable: "Can’t reach the import relay"
        }
    }

    @ViewBuilder
    private var expiresRow: some View {
        SettingsRow {
            Text("Expires")
            Spacer(minLength: 16)
            Text(expiryText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var expiryText: String {
        guard let date = app.importRelay.metadata?.expiresAt else { return "" }
        let absolute = date.formatted(date: .abbreviated, time: .shortened)
        let remaining = date.timeIntervalSinceNow
        if remaining > 0, remaining < 24 * 60 * 60 {
            let hours = max(1, Int(remaining / 3600))
            return "\(absolute) · Expires in \(hours) hours"
        }
        return absolute
    }

    @ViewBuilder
    private var keyRow: some View {
        if let key = app.importRelay.revealedKey {
            VStack(alignment: .leading, spacing: 6) {
                copyRow(title: "Key", value: key, copied: $copiedKey, monospaced: true)
                Text("Copy this now. Leaving this page hides it. If you lose it, create a new key.")
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        } else {
            SettingsRow {
                Text("Key")
                Spacer(minLength: 16)
                Text("Hidden · last four \(app.importRelay.metadata?.lastFour ?? "————")")
                    .foregroundStyle(.secondary)
            }
            Text("The key is not shown again. Create a new key if you did not copy it.")
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    private func copyRow(title: String, value: String, copied: Binding<Bool>, monospaced: Bool = false) -> some View {
        SettingsRow {
            Text(title)
            Spacer(minLength: 16)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : CraftFont.body)
                .textSelection(.enabled)
                .lineLimit(2)
            Button(copied.wrappedValue ? "Copied" : "Copy") {
                CraftClipboard.copy(value)
                copied.wrappedValue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied.wrappedValue = false
                }
            }
        }
    }

    @ViewBuilder
    private var lifetimeRow: some View {
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
            .onChange(of: lifetimeDays) { _, value in
                useCustomLifetime = value == -1
            }
            if lifetimeDays == -1 {
                TextField("Days", text: $customDays)
                    .frame(width: 48)
            }
        }
    }

    private func numbered(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)")
                    .font(CraftFont.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private func createKey() {
        let days = lifetimeDays == -1 ? ImportLifetime.clamped(Int(customDays) ?? 7) : lifetimeDays
        app.importRelay.createKey(days: days)
    }
}

struct ReplaceImportKeySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalDismiss) private var modalDismiss
    @State private var lifetimeDays = 7
    @State private var customDays = "7"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Replace import key")
                .font(CraftFont.title)
            Text("Claude and Gemini will stop until you paste the new key.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ModalControlRow("Lifetime") {
                Picker("Lifetime", selection: $lifetimeDays) {
                    ForEach(ImportLifetime.presets, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                    Text("Custom").tag(-1)
                }
                .labelsHidden()
                .fixedSize()
            }
            if lifetimeDays == -1 {
                ModalField("Days") {
                    TextField("Days", text: $customDays)
                        .textFieldStyle(.plain)
                }
            }
            ModalFooter(actionTitle: "Replace key", action: replace)
        }
    }

    private func replace() {
        let days = lifetimeDays == -1 ? ImportLifetime.clamped(Int(customDays) ?? 7) : lifetimeDays
        app.importRelay.replaceKey(days: days)
        modalDismiss()
    }
}
