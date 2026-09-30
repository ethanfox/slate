import SwiftData
import SwiftUI

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusName: Bool

    @State private var name = ""
    @State private var symbol = "folder"
    @State private var summary = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(CraftFont.title)

            ModalField("Name") {
                TextField("Article One", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focusName)
            }

            ModalField("Icon", boxed: false) {
                SymbolPicker(selection: $symbol)
            }

            ModalField("Description") {
                TextField("What this project is", text: $summary, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...6)
            }

            ModalFooter(actionTitle: "Create", actionEnabled: canCreate, action: create)
        }
        .onAppear { focusName = true }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let project = Project(name: trimmed, symbol: symbol, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(project)
        try? context.save()
        app.open(project, tab: .overview)
        modalDismiss()
    }
}
