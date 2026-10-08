import SwiftUI

struct SettingsSourcesPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalHost) private var modalHost
    @State private var renameID: UUID?
    @State private var renameText = ""

    var body: some View {
        SettingsPage {
            SettingsGroup("Sources") {
                SettingsRow {
                    Text("Slate uses these tokens to list repos and read files directly. Cursor Cloud does not use them — connect GitHub on cursor.com for cloud clones.")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            forgeGroup(
                "GitHub",
                mark: .github,
                detail: "Fine-grained tokens only see the repos you grant. Add one per set of repos.",
                tokens: app.sources.githubTokens,
                connect: { app.present(.connectGitHub, in: modalHost) }
            )
            forgeGroup(
                "GitLab",
                mark: .gitlab,
                detail: "Read-only tokens. Name each one.",
                tokens: app.sources.gitlabTokens,
                connect: { app.present(.connectGitLab, in: modalHost) }
            )
        }
        .onAppear { app.sources.refresh() }
        .alert("Rename Token", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { saveRename() }
            Button("Cancel", role: .cancel) { renameID = nil }
        }
    }

    private func forgeGroup(
        _ title: String,
        mark: BrandMark,
        detail: String,
        tokens: [ForgeToken],
        connect: @escaping () -> Void
    ) -> some View {
        SettingsGroup(title, mark: mark) {
            SettingsRow {
                Text(detail)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(tokens) { token in
                Hairline().padding(.horizontal, 16)
                tokenRow(token)
            }
            Hairline().padding(.horizontal, 16)
            SettingsRow {
                Spacer(minLength: 0)
                Button("Add token…", action: connect)
            }
        }
    }

    private func tokenRow(_ token: ForgeToken) -> some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(token.name)
                Text(subtitle(for: token))
                    .font(CraftFont.caption)
                    .foregroundStyle(statusColor(for: token))
                    .lineLimit(2)
            }
            Spacer(minLength: 16)
            Button("Rename") {
                renameID = token.id
                renameText = token.name
            }
            Button("Remove") { app.sources.remove(token.id) }
        }
    }

    private func subtitle(for token: ForgeToken) -> String {
        switch app.sources.tokenStatus[token.id] {
        case .checking: "Checking"
        case .failed(let message): message
        case .ready, .none:
            token.login.isEmpty || token.login == token.name ? "Connected" : token.login
        }
    }

    private func statusColor(for token: ForgeToken) -> Color {
        if case .failed = app.sources.tokenStatus[token.id] { return .red }
        return .secondary
    }

    private func saveRename() {
        if let renameID {
            app.sources.rename(renameID, to: renameText)
        }
        renameID = nil
    }
}
