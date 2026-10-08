import AppKit
import SwiftUI

struct SettingsChatGPTPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalHost) private var modalHost

    var body: some View {
        SettingsPage {
            SettingsGroup("ChatGPT", mark: .chatgpt) {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ChatGPT")
                        Text("Uses your Plus or Pro plan to talk. It does not bring memory, chats, or files.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    switch app.sources.chatGPT {
                    case .missing:
                        Button("Connect…") { app.present(.connectChatGPT, in: modalHost) }
                    case .checking:
                        Text("Checking")
                            .foregroundStyle(.secondary)
                    case .connected(let label):
                        Text(label)
                            .lineLimit(1)
                        Button("Remove") { removeChatGPT() }
                    case .failed(let message):
                        Text(message)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        Button("Remove") { removeChatGPT() }
                    }
                }
                if case .connected = app.sources.chatGPT {
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("Plan")
                        Spacer(minLength: 16)
                        Text("Using ChatGPT plan")
                            .foregroundStyle(.secondary)
                    }
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("Usage")
                        Spacer(minLength: 16)
                        Button("Manage usage") {
                            NSWorkspace.shared.open(ChatGPTSignIn.usageURL)
                        }
                    }
                }
            }
        }
        .onAppear { app.sources.refresh() }
    }

    private func removeChatGPT() {
        app.sources.removeChatGPT()
        app.normalizeTalkProvider()
    }
}
