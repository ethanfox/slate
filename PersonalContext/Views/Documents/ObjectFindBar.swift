import AppKit
import SwiftUI

struct ObjectFindBar: View {
    var session: ObjectFindSession
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ObjectFindSearchField(
                text: Binding(get: { session.query }, set: session.setQuery),
                focused: fieldFocused,
                onSubmit: session.next,
                onCancel: session.close
            )
            .frame(width: 188, height: 28)
            .focused($fieldFocused)

            if !session.status.isEmpty {
                Text(session.status)
                    .font(CraftFont.caption)
                    .foregroundStyle(session.matches.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .frame(minWidth: 72, alignment: .leading)
                    .accessibilityLabel(session.status)
            }

            Button(action: session.previous) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.matches.isEmpty)
            .help("Find Previous (⇧⌘G)")
            .accessibilityLabel("Find Previous")

            Button(action: session.next) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.matches.isEmpty)
            .help("Find Next (⌘G)")
            .accessibilityLabel("Find Next")
        }
        .onChange(of: session.wantsFocus) { _, wants in
            guard wants else { return }
            fieldFocused = true
            session.wantsFocus = false
        }
    }
}

private struct ObjectFindSearchField: NSViewRepresentable {
    @Binding var text: String
    var focused: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = FindSearchField()
        field.placeholderString = "Find"
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .default
        field.controlSize = .regular
        field.font = .systemFont(ofSize: 13)
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if focused, field.window?.firstResponder !== field.currentEditor() {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ObjectFindSearchField

        init(_ parent: ObjectFindSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }

        @objc func submit() {
            parent.onSubmit()
        }
    }
}

private final class FindSearchField: NSSearchField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "f" {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}
