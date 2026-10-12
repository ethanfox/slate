import SwiftUI

struct SettingsColumn: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalHost) private var modalHost

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 1) {
                    section("AI Providers", first: true)
                    ForEach(providers) { row($0) }
                    connectRow
                    section("Sources")
                    row(.sources)
                    row(.mcp)
                    row(.importRelay)
                    row(.browser)
                    section("Workspace")
                    row(.calendar)
                    row(.tags)
                    row(.appearance)
                    section("Chat")
                    row(.model)
                    row(.orb)
                    section("Advanced")
                    row(.developer)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// Only what the user connected, plus the one they are setting up now.
    private var providers: [SettingsSection] {
        SettingsSection.providers.filter { app.isConnected($0) || app.settingsSection == $0 }
    }

    private var connectRow: some View {
        Button {
            app.present(.connectAI, in: modalHost)
        } label: {
            SidebarRow(title: "Connect AI", systemImage: "plus", mark: nil, isSelected: false)
        }
        .buttonStyle(.plain)
    }

    private func section(_ title: String, first: Bool = false) -> some View {
        Text(title)
            .font(CraftFont.section)
            .foregroundStyle(.secondary)
            .padding(.top, first ? 4 : 20)
            .padding(.bottom, 4)
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
    }

    private func row(_ section: SettingsSection) -> some View {
        Button {
            app.settingsSection = section
        } label: {
            SidebarRow(
                title: section.title,
                systemImage: section.symbol,
                mark: section.mark,
                isSelected: app.settingsSection == section
            )
        }
        .buttonStyle(.plain)
    }
}

extension AppModel {
    func isConnected(_ section: SettingsSection) -> Bool {
        switch section {
        case .chatgpt: sources.hasChatGPT
        case .cursor: hasAPIKey
        case .compatible: !compatibleEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .claudeCode, .codex: section.localAgent.map(isConnected) ?? false
        default: true
        }
    }
}
