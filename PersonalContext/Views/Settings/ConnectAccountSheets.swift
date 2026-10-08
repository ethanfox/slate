import AppKit
import SwiftUI

struct ConnectChatGPTSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalDismiss) private var modalDismiss

    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                BrandMarkImage(mark: .chatgpt, size: 16)
                Text("Continue with ChatGPT")
                    .font(CraftFont.title)
            }
            Text("Opens ChatGPT in your browser so Slate can use your Plus or Pro plan. It does not bring memory, chats, custom instructions, or files. Slate stays the personal context.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            ModalFooter(
                actionTitle: working ? "Waiting for ChatGPT…" : "Continue with ChatGPT",
                actionEnabled: !working,
                action: start
            )
        }
        .textSelection(.enabled)
    }

    private func start() {
        working = true
        error = nil
        Task {
            do {
                try await app.sources.signInChatGPT()
                app.normalizeTalkProvider()
                app.refreshChatGPTModels()
                modalDismiss()
            } catch is CancellationError {
                working = false
            } catch {
                working = false
                self.error = error.localizedDescription
            }
        }
    }
}

struct ConnectGitHubSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusName: Bool

    @State private var name = ""
    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                BrandMarkImage(mark: .github, size: 16)
                Text("Add GitHub token")
                    .font(CraftFont.title)
            }
            Text("Create a fine-grained token for the repos you will attach. Contents: Read-only. Expire it in 90 days. Do not use a classic token that can see every private repo. Name it so you can keep more than one.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open GitHub token settings") {
                NSWorkspace.shared.open(URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            }
            ModalField("Name") {
                TextField("Work, Personal, Acme…", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focusName)
            }
            ModalField("Token") {
                SecureField("github_pat_…", text: $token)
                    .textFieldStyle(.plain)
                    .onSubmit(add)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            ModalFooter(actionTitle: working ? "Checking…" : "Add Token", actionEnabled: canAdd && !working, action: add)
        }
        .textSelection(.enabled)
        .onAppear { focusName = true }
    }

    private var canAdd: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                try await app.sources.saveGitHub(trimmed, name: name)
                modalDismiss()
            } catch {
                working = false
                self.error = error.localizedDescription
            }
        }
    }
}

struct ConnectGitLabSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusName: Bool

    @State private var name = ""
    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                BrandMarkImage(mark: .gitlab, size: 16)
                Text("Add GitLab token")
                    .font(CraftFont.title)
            }
            Text("Create a personal access token with read_api only. Expire it. Do not grant write_repository or api. Name it so you can keep more than one.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open GitLab token settings") {
                NSWorkspace.shared.open(URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens")!)
            }
            ModalField("Name") {
                TextField("Work, Personal, Acme…", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focusName)
            }
            ModalField("Token") {
                SecureField("glpat-…", text: $token)
                    .textFieldStyle(.plain)
                    .onSubmit(add)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            ModalFooter(actionTitle: working ? "Checking…" : "Add Token", actionEnabled: canAdd && !working, action: add)
        }
        .textSelection(.enabled)
        .onAppear { focusName = true }
    }

    private var canAdd: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                try await app.sources.saveGitLab(trimmed, name: name)
                modalDismiss()
            } catch {
                working = false
                self.error = error.localizedDescription
            }
        }
    }
}
