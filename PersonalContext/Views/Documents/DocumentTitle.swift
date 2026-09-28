import SwiftUI

struct DocumentTitle: View {
    @Binding var text: String
    var placeholder = "Untitled"

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(CraftFont.title)
    }
}
