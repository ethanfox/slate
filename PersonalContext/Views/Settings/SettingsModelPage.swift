import SwiftUI

struct SettingsModelPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        SettingsPage {
            SettingsGroup("Chat") {
                if app.availableTalkProviders.isEmpty {
                    SettingsRow {
                        Text("Connect ChatGPT or Cursor first.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SettingsRow {
                        Text("Provider")
                        Spacer(minLength: 16)
                        Picker("Provider", selection: $app.talkProvider) {
                            ForEach(app.availableTalkProviders) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("Model")
                        Spacer(minLength: 16)
                        Picker("Model", selection: $app.talkModelID) {
                            if app.talkProvider == .cursor {
                                Text("Account default").tag("")
                            }
                            if app.talkModels.isEmpty, app.talkProvider == .chatgpt {
                                Text("None yet").tag("")
                            }
                            ForEach(app.talkModels, id: \.id) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
        .onAppear {
            app.normalizeTalkProvider()
            app.refreshChatGPTModels()
            if app.hasAPIKey, app.models.isEmpty, app.connection != .checking {
                app.refreshConnection()
            }
        }
        .onChange(of: app.talkProvider) {
            if app.talkProvider == .chatgpt {
                app.refreshChatGPTModels()
            } else if app.talkProvider == .cursor,
                      app.hasAPIKey, app.models.isEmpty, app.connection != .checking {
                app.refreshConnection()
            }
        }
    }
}
