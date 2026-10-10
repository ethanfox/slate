import AppKit
import SwiftUI

struct SettingsCursorPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalHost) private var modalHost

    var body: some View {
        @Bindable var app = app
        SettingsPage {
            SettingsGroup("Cursor", mark: .cursor) {
                SettingsRow {
                    Text("Cursor API Key")
                    Spacer(minLength: 16)
                    if app.hasAPIKey {
                        connectionLabel
                            .lineLimit(1)
                        Button("Remove") { removeKey() }
                    } else {
                        Button("Connect…") { app.present(.connectCursor, in: modalHost) }
                    }
                }
                Hairline().padding(.horizontal, 16)
                usageRows
            }

            SettingsGroup("Cloud code access") {
                SettingsRow {
                    Text("Cursor Cloud clones GitHub repos using GitHub connected on cursor.com. This is separate from GitHub tokens in Sources.")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Text("GitHub for cloud")
                    Spacer(minLength: 16)
                    cloudStatusLabel
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Button("Open Cursor Integrations") {
                        NSWorkspace.shared.open(AppModel.cursorIntegrationsURL)
                    }
                    Spacer(minLength: 16)
                    Button("Refresh") {
                        app.refreshCursorCloudRepositories(force: true)
                    }
                    .disabled(!app.hasAPIKey || app.cursorCloudRepositories == .loading)
                }
            }

            SettingsGroup("Cursor app") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Knowledge base in Cursor")
                        Text("Lets agents in Cursor read and update this knowledge base.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Button("Connect to Cursor") { connectCursorApp() }
                }
            }
        }
        .onAppear {
            app.refreshUsage()
            app.refreshCursorCloudRepositories()
        }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch app.connection {
        case .missing:
            Text("Not connected")
                .foregroundStyle(.secondary)
        case .checking:
            Text("Checking")
                .foregroundStyle(.secondary)
        case .connected(let label):
            Text(label)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var cloudStatusLabel: some View {
        if !app.hasAPIKey {
            Text("Add a Cursor API key first.")
                .foregroundStyle(.secondary)
        } else {
            switch app.cursorCloudRepositories {
            case .unavailable:
                Text("Add a Cursor API key first.")
                    .foregroundStyle(.secondary)
            case .idle, .loading:
                Text("Checking…")
                    .foregroundStyle(.secondary)
            case .ready(let urls, let checkedAt):
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(urls.count) repos available")
                    Text(checkedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var usageRows: some View {
        if let usage = app.usage, !usage.isUnlimited {
            usageRow("Cursor models", percent: usage.cursorModels)
            Hairline().padding(.horizontal, 16)
            usageRow("Other models", percent: usage.otherModels)
            if let resetsAt = usage.resetsAt {
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Text("Usage resets")
                    Spacer(minLength: 16)
                    Text(resetsAt.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            SettingsRow {
                Text("Usage")
                Spacer(minLength: 16)
                Text(app.usage?.isUnlimited == true ? "Unlimited" : (app.usageNote ?? "Checking"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }
    }

    private func usageRow(_ title: String, percent: Double) -> some View {
        SettingsRow {
            Text(title)
            Spacer(minLength: 16)
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(percent >= 90 ? .orange : .accentColor)
                .frame(width: 180)
            Text("\(CursorUsage.percent(percent)) used")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func removeKey() {
        try? app.removeAPIKey()
    }

    private func connectCursorApp() {
        guard let mcp = Bundle.main.url(forAuxiliaryExecutable: "membrae-mcp"),
              let config = try? JSONSerialization.data(withJSONObject: ["command": mcp.path], options: .withoutEscapingSlashes),
              let encoded = config.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=membrae&config=\(encoded)")
        else { return }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            app.flash("Cursor isn’t installed on this Mac.")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
