import SwiftUI

struct SymbolPicker: View {
    @Binding var selection: String

    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 6), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(ProjectSymbols.all, id: \.self) { symbol in
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(CraftFont.sidebarIcon)
                        .frame(width: 32, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selection == symbol ? CraftColor.selection : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
            }
        }
    }
}
enum ProjectSymbols {
    static let all = [
        "folder", "doc.text", "newspaper", "book.closed", "text.book.closed",
        "lightbulb", "sparkles", "flag", "star", "cube",
        "leaf", "hammer", "wrench.and.screwdriver", "paintbrush", "music.note",
        "camera", "chart.bar", "person.2", "building.2", "shippingbox",
        "globe", "note.text", "checklist", "brain.head.profile", "target",
        "briefcase", "graduationcap", "quote.bubble", "square.stack.3d.up", "bolt"
    ]
}
