import AppKit
import SwiftUI

struct SettingsImportPage: View {
    @Environment(AppModel.self) private var app
    @State private var copiedURL = false
    @State private var showChatGPTSetup = false
    @State private var showClaudeSetup = false

    var body: some View {
        @Bindable var relay = app.importRelay
        SettingsPage {
            SettingsGroup("Import") {
                SettingsRow {
                    Text(app.account.isSignedIn
                         ? "Chats file into your hosted context. Membrae need not be open."
                         : "Keep Membrae open to receive imports")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Text("Allow import")
                    Spacer(minLength: 16)
                    Toggle("Allow import", isOn: $relay.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Text("Status")
                    Spacer(minLength: 16)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server URL")
                        HStack(spacing: 8) {
                            Text(relay.mcpURL)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .padding(10)
                                .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(CraftColor.hairline)
                                )
                            rowButton(copiedURL ? "Copied" : "Copy", action: copyURL)
                        }
                    }
                }
                if hasExpiry || hasLastImport {
                    Hairline().padding(.horizontal, 16)
                    VStack(alignment: .leading, spacing: 4) {
                        if hasExpiry {
                            Text("Expires \(expiryText)")
                        }
                        if let last = relay.metadata?.lastImport {
                            Text("Last import \(last.kind) “\(last.title)” in \(last.projectName) · \(last.at.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                if let error = relay.metadata?.lastOfflineError, !error.isEmpty {
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text(error)
                            .font(CraftFont.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 16)
                        rowButton("Clear error") { relay.clearOfflineErrors() }
                    }
                }
            }

            SettingsGroup("Connectors") {
                providerRow("ChatGPT", isExpanded: $showChatGPTSetup, open: openChatGPT, steps: [
                    "chatgpt.com/plugins, turn on Developer Mode",
                    "Add a custom MCP server named Membrae",
                    "Paste the server URL, then Create as a plugin",
                    "If tools are missing, Refresh the plugin, then start a new chat"
                ])
                Hairline().padding(.horizontal, 16)
                providerRow("Claude", isExpanded: $showClaudeSetup, open: openClaude, steps: [
                    "Settings → Connectors",
                    "Add a custom connector named Membrae",
                    "Paste the server URL",
                    "Allow access, then enable it in a chat"
                ])
            }
        }
        .onAppear { app.importRelay.retryNow() }
    }

    private var hasExpiry: Bool {
        app.importRelay.metadata?.expiresAt != nil && ImportKeyStore.readKey() != nil
    }

    private var hasLastImport: Bool {
        app.importRelay.metadata?.lastImport != nil
    }

    private var statusText: String {
        if !app.importRelay.enabled { return "Off" }
        switch app.importRelay.status {
        case .noKey: return "Waiting for ChatGPT or Claude"
        case .expired: return "Expired"
        case .connecting: return "Connecting"
        case .ready: return "Ready"
        case .reconnecting: return "Reconnecting"
        case .unreachable: return "Can’t reach the import relay"
        }
    }

    private var expiryText: String {
        guard let date = app.importRelay.metadata?.expiresAt else { return "" }
        let absolute = date.formatted(date: .abbreviated, time: .shortened)
        let remaining = date.timeIntervalSinceNow
        if remaining > 0, remaining < 24 * 60 * 60 {
            let hours = max(1, Int(remaining / 3600))
            return "\(absolute) · in \(hours) hours"
        }
        return absolute
    }

    private func providerRow(_ name: String, isExpanded: Binding<Bool>, open: @escaping () -> Void, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow {
                Text(name)
                Spacer(minLength: 16)
                rowButton("Open", action: open)
            }
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text("Setup instructions")
                    Spacer(minLength: 0)
                }
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
    }

    private func copyURL() {
        let relay = app.importRelay
        relay.prepareForImport()
        CraftClipboard.copy(relay.mcpURL)
        copiedURL = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedURL = false
        }
    }

    private func openChatGPT() {
        app.importRelay.prepareForImport()
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/plugins")!)
    }

    private func openClaude() {
        app.importRelay.prepareForImport()
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/connectors")!)
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
            Text("ChatGPT and Claude will need to connect again. Gemini CLI will need the new key.")
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
