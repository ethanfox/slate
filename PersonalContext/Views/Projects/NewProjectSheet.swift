import SwiftData
import SwiftUI

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var symbol = "folder"
    @State private var summary = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(CraftFont.title)

            field("Name") {
                TextField("Article One", text: $name)
                    .textFieldStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(CraftFont.section)
                SymbolPicker(selection: $symbol)
            }

            field("Description") {
                TextField("What this project is", text: $summary, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(CraftFont.section)
            content()
                .padding(10)
                .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(CraftColor.hairline))
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let project = Project(name: trimmed, symbol: symbol, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(project)
        try? context.save()
        app.open(project, tab: .overview)
        dismiss()
    }
}
