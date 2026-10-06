import SwiftUI

/// The shared chat controls. Callers provide conversation-specific state and actions;
/// this view owns only the draft text and the controls' internal appearance.
struct ChatInput: View {
    @Binding var modelID: String
    var label: String?
    var placeholder = "Message"
    var lineLimit: ClosedRange<Int> = 1...6
    var isGenerating = false
    var changes: [String] = []
    var errorMessage: String?
    var onSend: (String) -> Bool
    var onStop: (() -> Void)?

    @Environment(AppModel.self) private var app
    @State private var text = ""

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ModelPicker(selection: $modelID)
                Spacer(minLength: 8)
                if let usage = app.usage {
                    ChatUsage(usage: usage)
                }
            }

            if let label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                    field
                }
            } else {
                field
            }

            if !changes.isEmpty {
                Label(changes.joined(separator: " · "), systemImage: "checkmark.circle")
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(CraftFont.caption)
                    .foregroundStyle(.red)
                    .onAppear { ChatTrace.event("chat ui error: \(errorMessage)") }
            }
        }
        .padding(12)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(CraftColor.hairline))
        .onAppear {
            if app.hasAPIKey, app.models.isEmpty, app.connection != .checking {
                app.refreshConnection()
            }
            app.refreshUsage()
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CraftFont.body)
                .lineLimit(lineLimit)
                .onSubmit(send)

            if isGenerating, let onStop {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        if onSend(trimmed) {
            text = ""
        }
    }
}

private struct ChatUsage: View {
    var usage: CursorUsage

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
        .font(CraftFont.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var text: String {
        if usage.isUnlimited { return "Unlimited usage" }
        return "Cursor Models: \(CursorUsage.percent(usage.cursorModels)) used · Other Models: \(CursorUsage.percent(usage.otherModels)) used"
    }
}
