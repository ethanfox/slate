import SwiftUI

struct ModelPicker: View {
    @Binding var selection: String
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            Button("Account default") { selection = "" }
            if !selection.isEmpty, !app.models.contains(where: { $0.id == selection }) {
                Button(selection) { }
            }
            ForEach(app.models) { model in
                Button(model.displayName) { selection = model.id }
            }
        } label: {
            Text(app.modelName(for: selection))
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }
}
