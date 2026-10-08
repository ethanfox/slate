import SwiftUI

struct ModelPicker: View {
    @Binding var providerID: String
    @Binding var modelID: String
    var allowsProviderChange = true

    @Environment(AppModel.self) private var app
    @State private var isPresented = false

    var body: some View {
        Button(action: present) {
            HStack(spacing: 6) {
                if let mark = TalkProvider(rawValue: providerID)?.mark {
                    BrandMarkImage(mark: mark, size: 12)
                }
                Text(title)
                    .font(CraftFont.body)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelPickerPanel(
                providerID: $providerID,
                modelID: $modelID,
                allowsProviderChange: allowsProviderChange
            ) {
                isPresented = false
            }
        }
        .accessibilityLabel("Model")
        .accessibilityValue(accessibilityValue)
    }

    private var title: String {
        if modelID.isEmpty {
            return TalkProvider(rawValue: providerID) == .cursor ? "Account default" : "Choose model"
        }
        return app.modelName(for: modelID, providerID: providerID)
    }

    private var accessibilityValue: String {
        let provider = TalkProvider(rawValue: providerID)?.title
        if let provider, providerID != TalkProvider.unconfigured.rawValue {
            return "\(provider), \(title)"
        }
        return title
    }

    private func present() {
        app.normalizeTalkProvider()
        refreshModels()
        isPresented = true
    }

    private func refreshModels() {
        if shouldRefresh(.chatgpt) {
            app.refreshChatGPTModels()
        }
        if shouldRefresh(.cursor), app.hasAPIKey, app.models.isEmpty, app.connection != .checking {
            app.refreshConnection()
        }
    }

    private func shouldRefresh(_ provider: TalkProvider) -> Bool {
        providerID == provider.rawValue || (allowsProviderChange && app.availableTalkProviders.contains(provider))
    }
}

private struct ModelPickerPanel: View {
    @Binding var providerID: String
    @Binding var modelID: String
    var allowsProviderChange: Bool
    var onPick: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if providers.isEmpty {
                    Text("Connect ChatGPT or Cursor in Settings.")
                        .font(CraftFont.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    ForEach(providers) { provider in
                        ModelPickerSection(
                            provider: provider,
                            models: models(for: provider),
                            selectedID: selectedID(for: provider)
                        ) { modelID in
                            pick(provider: provider, modelID: modelID)
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 280)
        .frame(maxHeight: 360)
        .onAppear {
            if shouldRefresh(.chatgpt) {
                app.refreshChatGPTModels()
            }
            if shouldRefresh(.cursor), app.hasAPIKey, app.models.isEmpty, app.connection != .checking {
                app.refreshConnection()
            }
        }
    }

    private var providers: [TalkProvider] {
        if !allowsProviderChange, let current = TalkProvider(rawValue: providerID), current != .unconfigured {
            return [current]
        }
        var list = app.availableTalkProviders
        if let current = TalkProvider(rawValue: providerID),
           current != .unconfigured,
           !list.contains(current) {
            list.insert(current, at: 0)
        }
        return list
    }

    private func models(for provider: TalkProvider) -> [(id: String, name: String)] {
        var list = app.models(for: provider.rawValue)
        if provider == .cursor {
            list.insert((id: "", name: "Account default"), at: 0)
        }
        if provider.rawValue == providerID,
           !modelID.isEmpty,
           !list.contains(where: { $0.id == modelID }) {
            list.insert((id: modelID, name: app.modelName(for: modelID, providerID: providerID)), at: provider == .cursor ? 1 : 0)
        }
        return list
    }

    private func selectedID(for provider: TalkProvider) -> String? {
        provider.rawValue == providerID ? modelID : nil
    }

    private func pick(provider: TalkProvider, modelID: String) {
        if allowsProviderChange {
            providerID = provider.rawValue
            self.modelID = modelID
        } else if provider.rawValue == providerID {
            self.modelID = modelID
        }
        onPick()
    }

    private func shouldRefresh(_ provider: TalkProvider) -> Bool {
        providerID == provider.rawValue || (allowsProviderChange && app.availableTalkProviders.contains(provider))
    }
}

private struct ModelPickerSection: View {
    var provider: TalkProvider
    var models: [(id: String, name: String)]
    var selectedID: String?
    var onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let mark = provider.mark {
                    BrandMarkImage(mark: mark, size: 14)
                        .foregroundStyle(.secondary)
                }
                Text(provider.title)
                    .font(CraftFont.section)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)

            if models.isEmpty {
                Text("None yet")
                    .font(CraftFont.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
            } else {
                ForEach(models, id: \.id) { model in
                    ModelPickerRow(
                        title: model.name,
                        isSelected: model.id == selectedID
                    ) {
                        onPick(model.id)
                    }
                }
            }
        }
    }
}

private struct ModelPickerRow: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(isSelected ? .system(size: 13, weight: .medium) : CraftFont.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? CraftColor.selection : Color.clear)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(!isSelected && hovering ? CraftColor.hover : Color.clear)
                        .animation(Motion.hover, value: hovering)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
