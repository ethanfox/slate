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
            }
        }
    }
}
