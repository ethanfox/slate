import SwiftUI

struct SettingsAppearancePage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        SettingsPage {
            SettingsGroup("Appearance") {
                SettingsRow {
                    Text("Appearance")
                    Spacer(minLength: 16)
                    Picker("Appearance", selection: $app.appearance) {
                        ForEach(AppearancePreference.allCases) { preference in
                            Text(preference.label).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Text("Accent")
                    Spacer(minLength: 16)
                    HStack(spacing: 8) {
                        ForEach(AccentPreference.allCases) { preference in
                            AccentSwatch(preference: preference, isSelected: app.accent == preference) {
                                app.accent = preference
                            }
                        }
                    }
                }
            }

            SettingsGroup("Tabs") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open chat links in a new tab")
                        Text("Notes and other objects from chat open beside the conversation.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Toggle("Open chat links in a new tab", isOn: $app.openChatLinksInNewTab)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsGroup("Use accent") {
                ForEach(Array(AccentedView.allCases.enumerated()), id: \.element.id) { index, view in
                    if index > 0 { Hairline().padding(.horizontal, 16) }
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(view.label)
                            Text(view.defaultLabel)
                                .font(CraftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Toggle(view.label, isOn: accentBinding(for: view))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }
        }
    }

    private func accentBinding(for view: AccentedView) -> Binding<Bool> {
        Binding(
            get: { app.usesAccent(view) },
            set: { app.setUsesAccent(view, enabled: $0) }
        )
    }
}

private struct AccentSwatch: View {
    var preference: AccentPreference
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(swatch)
                    .frame(width: 18, height: 18)
                if preference == .system {
                    Circle()
                        .trim(from: 0.5, to: 1)
                        .fill(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                }
                Circle()
                    .strokeBorder(isSelected ? Color.primary : Color.clear, lineWidth: 2)
                    .frame(width: 24, height: 24)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(preference.label)
        .accessibilityLabel(preference.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var swatch: Color {
        preference.color
    }
}
