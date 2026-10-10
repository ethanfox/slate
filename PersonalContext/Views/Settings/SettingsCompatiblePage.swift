import SwiftUI

struct SettingsCompatiblePage: View {
    @Environment(AppModel.self) private var app
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var keySaved = false

    var body: some View {
        @Bindable var app = app
        SettingsPage {
            SettingsGroup("Compatible endpoint") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OpenAI-compatible Chat Completions URL. OpenRouter and local servers use this same path. ChatGPT OAuth is never sent here.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("https://openrouter.ai/api/v1", text: $endpoint)
                            .textFieldStyle(.plain)
                            .onSubmit { saveEndpoint() }
                        HStack {
                            SecureField("API key, if required", text: $apiKey)
                                .textFieldStyle(.plain)
                            Button(keySaved || app.compatibleKeyPresent ? "Replace key" : "Save key") {
                                saveKey()
                            }
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if app.compatibleKeyPresent {
                                Button("Remove key") { removeKey() }
                            }
                        }
                        TextField("Model ID", text: $app.compatibleModelID)
                            .textFieldStyle(.plain)
                        HStack {
                            Button("Save endpoint") { saveEndpoint() }
                            Button("List models") { app.refreshCompatibleModels() }
                                .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }

            SettingsGroup("This model") {
                CapabilitySettings(provider: .compatible, model: app.compatibleModelID, endpoint: app.compatibleEndpoint)
            }
        }
        .onAppear {
            endpoint = app.compatibleEndpoint
            app.compatibleKeyPresent = KeychainStore.read(.compatibleAPIKey) != nil
        }
    }

    private func saveEndpoint() {
        app.compatibleEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        app.normalizeTalkProvider()
        app.refreshCompatibleModels()
    }

    private func saveKey() {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        try? KeychainStore.save(value, account: .compatibleAPIKey)
        apiKey = ""
        keySaved = true
        app.compatibleKeyPresent = true
        app.refreshCompatibleModels()
    }

    private func removeKey() {
        try? KeychainStore.delete(.compatibleAPIKey)
        app.compatibleKeyPresent = false
        keySaved = false
    }
}

struct CapabilitySettings: View {
    var provider: TalkProvider
    var model: String
    var endpoint: String = ""

    var body: some View {
        let snapshot = AttachmentCapabilityStore.snapshot(provider: provider, model: model, endpoint: endpoint)
        let adapter = AttachmentCapabilityStore.adapter(for: provider, endpoint: endpoint)
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow {
                Text("Images")
                Spacer(minLength: 16)
                if adapter.images {
                    capabilityPicker(snapshot.image, source: snapshot.imageSource) { value in
                        AttachmentCapabilityStore.setUser(
                            provider: provider,
                            model: model,
                            endpoint: endpoint,
                            image: value
                        )
                    }
                } else {
                    Text("Adapter cannot send images")
                        .foregroundStyle(.secondary)
                }
            }
            Hairline().padding(.horizontal, 16)
            SettingsRow {
                Text("Native files")
                Spacer(minLength: 16)
                if adapter.nativeDocuments {
                    capabilityPicker(snapshot.document, source: snapshot.documentSource) { value in
                        AttachmentCapabilityStore.setUser(
                            provider: provider,
                            model: model,
                            endpoint: endpoint,
                            document: value
                        )
                    }
                } else {
                    Text(adapter.extraction ? "Extracted as text" : "Not available")
                        .foregroundStyle(.secondary)
                }
            }
            if snapshot.isOpenRouter, snapshot.openRouterPDFParser {
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Text("OpenRouter may parse PDFs for this connection. That is not the same as the model natively reading files.")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Hairline().padding(.horizontal, 16)
            SettingsRow {
                Text(sourceLine(snapshot))
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func capabilityPicker(
        _ value: CapabilityValue,
        source: CapabilitySource,
        onChange: @escaping (CapabilityValue) -> Void
    ) -> some View {
        Picker(source == .user ? "User-configured" : "Capability", selection: Binding(
            get: { value },
            set: onChange
        )) {
            Text("Unknown").tag(CapabilityValue.unknown)
            Text("Supported").tag(CapabilityValue.supported)
            Text("Unsupported").tag(CapabilityValue.unsupported)
        }
        .labelsHidden()
        .fixedSize()
    }

    private func sourceLine(_ snapshot: CapabilitySnapshot) -> String {
        let image = snapshot.imageSource.rawValue
        let document = snapshot.documentSource.rawValue
        return "Image source: \(image). File source: \(document). Missing metadata stays unknown."
    }
}
