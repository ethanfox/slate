import AppKit
import SwiftUI

struct SettingsLocalAgentPage: View {
    var agent: LocalAgent

    @Environment(AppModel.self) private var app
    @Environment(\.modalHost) private var modalHost
    @State private var status: LocalAgentStatus?
    @State private var test = LocalAgentTest.idle

    var body: some View {
        SettingsPage {
            SettingsGroup(agent.title) {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.title)
                        Text("Membrae starts \(agent.title) on this Mac and hands it work from a Run. It uses your own install and sign-in.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    if app.isConnected(agent) {
                        Button("Disconnect") { disconnect() }
                    } else {
                        Button("Connect…") { app.present(.connectLocalAgent(agent), in: modalHost) }
                    }
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Text("Installed")
                    Spacer(minLength: 16)
                    installedLabel
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Text("Signed in")
                    Spacer(minLength: 16)
                    signedInLabel
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Text("Test")
                    Spacer(minLength: 16)
                    LocalAgentTestLabel(test: test)
                    Button("Send a Test") { runTest() }
                        .disabled(test == .running || status?.isReady != true)
                }
                Hairline().padding(.horizontal, 16)
                SettingsRow {
                    Button("Check Again") { refresh() }
                    Spacer(minLength: 16)
                }
            }

            SettingsGroup("What it may do") {
                SettingsRow {
                    Text(permissionNote)
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: agent) { await load() }
    }

    @ViewBuilder
    private var installedLabel: some View {
        if let status {
            if let path = status.path {
                Text(path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text("Not found on this Mac")
                    .foregroundStyle(.secondary)
                Button("Get \(agent.title)") { NSWorkspace.shared.open(agent.installURL) }
            }
        } else {
            Text("Checking")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var signedInLabel: some View {
        if let status {
            if status.signedIn {
                Text(status.account.isEmpty ? "Yes" : status.account)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if status.path == nil {
                Text("Install it first")
                    .foregroundStyle(.secondary)
            } else {
                Text(agent.signInHint)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        } else {
            Text("Checking")
                .foregroundStyle(.secondary)
        }
    }

    private var permissionNote: String {
        switch agent {
        case .claudeCode:
            "Each Run asks whether Claude Code may edit files and run commands. Membrae passes your choice on and Claude Code enforces it, along with its own settings on this Mac."
        case .codex:
            "Codex puts its own sandbox around every command, and that cannot start inside Membrae. So a Codex Run needs “Let it edit files and run commands” turned on, which turns Codex’s sandbox off. Membrae’s own sandbox still limits what it can reach."
        }
    }

    private func load() async {
        status = nil
        test = .idle
        status = await agent.status()
    }

    private func refresh() {
        Task { await load() }
    }

    private func runTest() {
        test = .running
        Task {
            do {
                test = .passed(try await agent.test())
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }

    private func disconnect() {
        app.connectedLocalAgents.remove(agent.rawValue)
        app.settingsSection = SettingsSection.providers.first { app.isConnected($0) } ?? .model
    }
}

enum LocalAgentTest: Equatable {
    case idle
    case running
    case passed(String)
    case failed(String)
}

struct LocalAgentTestLabel: View {
    var test: LocalAgentTest

    var body: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            Text("Waiting for a reply")
                .foregroundStyle(.secondary)
        case .passed(let reply):
            Text("Replied: \(reply)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
    }
}

extension LocalAgent {
    var signInHint: String {
        switch self {
        case .claudeCode: "Run “\(signInCommand)” in Terminal, then check again."
        case .codex: "Sign in from the Codex app, or run “\(signInCommand)” in Terminal, then check again."
        }
    }

    var purpose: String {
        switch self {
        case .claudeCode: "Sends code work to Claude Code on this Mac."
        case .codex: "Sends code work to Codex on this Mac."
        }
    }
}

struct ConnectAISheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalDismiss) private var modalDismiss
    @Environment(\.modalHost) private var modalHost

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect AI")
                .font(CraftFont.title)
            if choices.isEmpty {
                Text("Everything Membrae can use is already connected.")
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose what Membrae should use. You can connect more than one.")
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(choices.enumerated()), id: \.element) { index, section in
                        if index > 0 { Hairline().padding(.horizontal, 14) }
                        ConnectAIRow(section: section) { choose(section) }
                    }
                }
                .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            ModalFooterButton(title: "Cancel", action: { modalDismiss() })
                .keyboardShortcut(.cancelAction)
        }
    }

    private var choices: [SettingsSection] {
        SettingsSection.providers.filter { !app.isConnected($0) }
    }

    private func choose(_ section: SettingsSection) {
        if let agent = section.localAgent {
            app.present(.connectLocalAgent(agent), in: modalHost)
            return
        }
        app.settingsSection = section
        switch section {
        case .chatgpt: app.present(.connectChatGPT, in: modalHost)
        case .cursor: app.present(.connectCursor, in: modalHost)
        default: modalDismiss()
        }
    }
}

private struct ConnectAIRow: View {
    var section: SettingsSection
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let mark = section.mark {
                        BrandMarkImage(mark: mark, size: 16)
                    } else {
                        Image(systemName: section.symbol)
                            .font(CraftFont.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(CraftFont.body)
                        .foregroundStyle(.primary)
                    Text(section.connectSummary)
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension SettingsSection {
    var connectSummary: String {
        switch self {
        case .chatgpt: "Chat using your Plus or Pro plan."
        case .cursor: "Chat and send work, with a Cursor API key."
        case .compatible: "Chat through any OpenAI-compatible URL, such as OpenRouter or a local server."
        case .claudeCode: LocalAgent.claudeCode.purpose
        case .codex: LocalAgent.codex.purpose
        default: ""
        }
    }
}

struct ConnectLocalAgentSheet: View {
    var agent: LocalAgent

    @Environment(AppModel.self) private var app
    @Environment(\.modalDismiss) private var modalDismiss
    @State private var status: LocalAgentStatus?
    @State private var test = LocalAgentTest.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect \(agent.title)")
                .font(CraftFont.title)
            Text("Membrae starts \(agent.title) on this Mac and hands it work. It uses your own install and sign-in, so there is no key to paste.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                step(
                    "Installed",
                    done: status?.path != nil,
                    detail: installedDetail
                ) {
                    if status != nil, status?.path == nil {
                        Button("Get \(agent.title)") { NSWorkspace.shared.open(agent.installURL) }
                    }
                }
                step(
                    "Signed in",
                    done: status?.signedIn == true,
                    detail: signedInDetail
                ) { EmptyView() }
                step(
                    "Test",
                    done: { if case .passed = test { return true } else { return false } }(),
                    detail: testDetail
                ) {
                    Button("Send a Test") { runTest() }
                        .disabled(test == .running || status?.isReady != true)
                }
            }

            ModalFooter(
                actionTitle: "Connect \(agent.title)",
                actionEnabled: status?.isReady == true,
                action: connect
            ) {
                ModalFooterButton(title: "Check Again", action: refresh)
            }
        }
        .task { await load() }
    }

    private var installedDetail: String {
        guard let status else { return "Checking" }
        return status.path ?? "Not found on this Mac. Install it, then check again."
    }

    private var signedInDetail: String {
        guard let status else { return "Checking" }
        if status.signedIn { return status.account.isEmpty ? "Yes" : status.account }
        return status.path == nil ? "Install it first." : agent.signInHint
    }

    private var testDetail: String {
        switch test {
        case .idle: "Optional. Sends one short request to check it answers."
        case .running: "Waiting for a reply"
        case .passed(let reply): "Replied: \(reply)"
        case .failed(let message): message
        }
    }

    private func step<Trailing: View>(
        _ title: String,
        done: Bool,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(CraftFont.body)
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CraftFont.body)
                Text(detail)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func load() async {
        status = nil
        status = await agent.status()
    }

    private func refresh() {
        Task { await load() }
    }

    private func runTest() {
        test = .running
        Task {
            do {
                test = .passed(try await agent.test())
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }

    private func connect() {
        app.connectedLocalAgents.insert(agent.rawValue)
        app.settingsSection = agent == .claudeCode ? .claudeCode : .codex
        modalDismiss()
    }
}
