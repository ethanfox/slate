import SwiftUI

enum DocumentMeasure {
    static let columnWidth: CGFloat = 744
    static let horizontalPadding: CGFloat = 32
    static let proseWidth: CGFloat = columnWidth - horizontalPadding * 2
}

struct DocumentPage<Content: View>: View {
    @Environment(\.objectFind) private var find
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            ScrollViewReader { proxy in
                PageBody {
                    VStack(alignment: .leading, spacing: 0) {
                        content()
                    }
                    .padding(.horizontal, DocumentMeasure.horizontalPadding)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: find?.revealToken) {
                    guard let id = find?.current?.field.id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}
