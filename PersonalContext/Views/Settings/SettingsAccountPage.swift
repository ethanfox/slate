import SwiftUI

struct SettingsAccountPage: View {
    @Environment(AppModel.self) private var app

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
                        Button("Sign out of this device") { Task { await account.signOut() } }
                            .disabled(account.isWorking)
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
