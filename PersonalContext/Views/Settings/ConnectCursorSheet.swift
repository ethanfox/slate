import AppKit
import SwiftUI

struct ConnectCursorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var key = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Cursor")
                .font(CraftFont.title)
            Text("Create an API key in the Cursor dashboard, then paste it here. It’s stored in your keychain.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Cursor Dashboard") {
                NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard/integrations")!)
            }
            SecureField("API key", text: $key)
                .textFieldStyle(.plain)
                .font(CraftFont.body)
                .padding(10)
                .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(CraftColor.hairline))
                .onSubmit(addKey)
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Key", action: addKey)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 8)
        }
        .textSelection(.enabled)
        .padding(20)
        .frame(width: 440)
    }

    private func addKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try app.saveAPIKey(trimmed)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
