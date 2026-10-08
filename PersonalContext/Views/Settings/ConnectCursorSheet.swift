import AppKit
import SwiftUI

struct ConnectCursorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusKey: Bool

    @State private var key = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                BrandMarkImage(mark: .cursor, size: 16)
                Text("Connect to Cursor")
                    .font(CraftFont.title)
            }
            Text("Create an API key in the Cursor dashboard, then paste it here. It spends your Cursor plan. It is not GitHub. ChatGPT never sees this key. Stored in the keychain on this Mac.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Cursor Dashboard") {
                NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard/integrations")!)
            }
            ModalField("API key") {
                SecureField("API key", text: $key)
                    .textFieldStyle(.plain)
                    .focused($focusKey)
                    .onSubmit(addKey)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            ModalFooter(actionTitle: "Add Key", actionEnabled: canAdd, action: addKey)
        }
        .textSelection(.enabled)
        .onAppear { focusKey = true }
    }

    private var canAdd: Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try app.saveAPIKey(trimmed)
            modalDismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
