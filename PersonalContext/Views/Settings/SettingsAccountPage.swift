import SwiftUI

struct SettingsAccountPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var confirmCloudOff = false
    @State private var openActivity: Set<String> = []

    var body: some View {
        let account = app.account
        SettingsPage {
            SettingsGroup("Account") {
                SettingsRow {
                    Text(account.isSignedIn
                         ? "Your account owns what syncs. Each device holds a key from it."
                         : "An account is needed to sync and for a second device. It signs in with a passkey; there is no password.")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Text("Status")
                    Spacer(minLength: 16)
                    Text(statusText)
                        .foregroundStyle(isFailure ? Color.red : Color.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Hairline().padding(.horizontal, 16)
                if account.isSignedIn {
                    SettingsRow {
                        Text("Account")
                        Spacer(minLength: 16)
                        Text(String(account.accountID.prefix(8)))
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        HStack(spacing: 8) {
                            Button("Sign out of this device") { Task { await account.signOut() } }
                            Button("Turn off Cloud", role: .destructive) { confirmCloudOff = true }
                        }
                        .disabled(account.isWorking)
                    }
                    .confirmationDialog(
                        "Turn off Cloud?",
                        isPresented: $confirmCloudOff,
                        titleVisibility: .visible
                    ) {
                        Button("Remove everything from Cloudflare", role: .destructive) {
                            Task { await app.sync.turnOffCloud(in: context) }
                        }
                    } message: {
                        Text("Every Space goes back to this Mac and your copy in Cloudflare is deleted. Chats you allowed will find nothing. You stay signed in.")
                    }
                } else {
                    SettingsRow {
                        HStack(spacing: 8) {
                            Button("Create account") { Task { await account.createAccount() } }
                            Button("Sign in") { Task { await account.signIn() } }
                        }
                        .disabled(account.isWorking)
                    }
                }
            }
            if account.isSignedIn {
                SettingsGroup("Connected chats") {
                    if account.connections.isEmpty {
                        SettingsRow {
                            Text("No chat has been allowed yet. Connect ChatGPT or Claude from Import.")
                                .font(CraftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(account.connections) { connection in
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.client)
                                    Text("Allowed \(seen(connection.approvedAt))\(connection.lastUsedAt.isEmpty ? "" : " · last used \(seen(connection.lastUsedAt))")")
                                        .font(CraftFont.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 16)
                                Button(openActivity.contains(connection.id) ? "Hide activity" : "Activity") {
                                    if openActivity.contains(connection.id) {
                                        openActivity.remove(connection.id)
                                    } else {
                                        openActivity.insert(connection.id)
                                        Task { await account.loadActivity(for: connection.id) }
                                    }
                                }
                                Button("Revoke", role: .destructive) { Task { await account.revoke(connection.id) } }
                            }
                            if openActivity.contains(connection.id) {
                                activityList(account.activity[connection.id] ?? [])
                            }
                        }
                        if connection.id != account.connections.last?.id {
                            Hairline().padding(.horizontal, 16)
                        }
                    }
                }
            }
            if account.isSignedIn, let summary = account.summary {
                SettingsGroup("Devices") {
                    ForEach(summary.devices) { device in
                        SettingsRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.id == summary.thisDevice ? "This Mac" : "Last seen \(seen(device.lastSeenAt))")
                                    .font(CraftFont.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 16)
                            if device.id != summary.thisDevice {
                                Button("Remove") { Task { await account.removeDevice(device.id) } }
                            }
                        }
                        if device.id != summary.devices.last?.id {
                            Hairline().padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
    }

    private func activityList(_ lines: [AccountActivity]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if lines.isEmpty {
                Text("Nothing yet.")
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                HStack(spacing: 8) {
                    Text(seen(line.at))
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(line.isWrite ? "wrote" : "read")
                        .font(CraftFont.caption)
                        .foregroundStyle(line.isWrite ? Color.primary : Color.secondary)
                        .frame(width: 40, alignment: .leading)
                    Text(line.tool.replacingOccurrences(of: "_", with: " "))
                        .font(CraftFont.caption)
                    if !line.spaceName.isEmpty {
                        Text("in \(line.spaceName)")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var statusText: String {
        switch app.account.status {
        case .signedOut: "Not signed in"
        case .working(let label): label
        case .signedIn: "Signed in"
        case .failed(let message): message
        }
    }

    private var isFailure: Bool {
        if case .failed = app.account.status { return true }
        return false
    }

    private func seen(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
