import SwiftUI

struct SettingsColumn: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 1) {
                    section("Account", first: true)
                    row(.chatgpt)
                    row(.cursor)
                    section("Sources")
                    row(.sources)
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
