import SwiftUI

struct EmptyLine: View {
    var text: String

    var body: some View {
        Text(text)
            .font(CraftFont.body)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}
