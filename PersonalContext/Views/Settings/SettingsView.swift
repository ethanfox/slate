import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            SettingsColumn()
                .frame(width: 250)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(CraftColor.hairline)
                        .frame(width: 1)
                }
                .zIndex(1)
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.settingsSection {
        case .chatgpt:
            SettingsChatGPTPage()
        case .cursor:
            SettingsCursorPage()
        case .compatible:
            SettingsCompatiblePage()
        case .sources:
            SettingsSourcesPage()
        case .calendar:
            SettingsCalendarPage()
        case .tags:
            SettingsTagsPage()
        case .appearance:
            SettingsAppearancePage()
        case .model:
            SettingsModelPage()
        case .orb:
            SettingsOrbPage()
        case .developer:
            SettingsDeveloperPage()
        }
    }
}
