import SwiftUI

struct SettingsModelPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        SettingsPage {
            SettingsGroup("Talk") {
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

            SettingsGroup("Read") {
                SettingsRow {
                    Text("A lower-cost model that searches project code and returns the relevant context before an answer.")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if app.availableReadProviders.isEmpty {
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("Connect ChatGPT or Cursor first.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("Provider")
                        Spacer(minLength: 16)
                        Picker("Provider", selection: $app.readProvider) {
                            ForEach(app.availableReadProviders) { provider in
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
                        Picker("Model", selection: $app.readModelID) {
                            if app.readProvider == .cursor {
                                Text("Account default").tag("")
                            }
                            if app.readModels.isEmpty, app.readProvider == .chatgpt {
                                Text("None yet").tag("")
                            }
                            ForEach(app.readModels, id: \.id) { model in
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
            app.normalizeReadProvider()
            app.refreshChatGPTModels()
            if app.hasAPIKey, app.models.isEmpty, app.connection != .checking {
                app.refreshConnection()
            }
        }
        .onChange(of: app.talkProvider) {
            app.refreshChatGPTModels()
        }
        .onChange(of: app.readProvider) {
            app.refreshChatGPTModels()
            if app.readProvider == .cursor, app.hasAPIKey, app.models.isEmpty {
                app.refreshConnection()
            }
        }
    }
}
