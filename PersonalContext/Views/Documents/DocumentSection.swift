import SwiftUI

struct DocumentSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(CraftFont.section)
                .padding(.bottom, 8)
            content()
        }
        .padding(.top, 24)
    }
}
