import SwiftUI

struct ModelPicker: View {
    @Binding var selection: String
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            if app.talkProvider == .cursor {
                Button("Account default") { selection = "" }
            }
            if !selection.isEmpty, !app.talkModels.contains(where: { $0.id == selection }) {
                Button(app.modelName(for: selection)) { }
            }
            ForEach(app.talkModels, id: \.id) { model in
                Button(model.name) { selection = model.id }
            }
        } label: {
            HStack(spacing: 4) {
                Text(app.modelName(for: selection))
                    .font(CraftFont.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
