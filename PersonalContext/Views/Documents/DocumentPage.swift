import SwiftUI

struct DocumentPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            PageBody {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: 744, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
    }
}
