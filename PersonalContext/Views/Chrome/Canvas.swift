import SwiftUI

/// Solid page surface. Use this inside scroll content, which is laid out
/// below the toolbar. It is not a background on the detail column.
struct PageBody<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            CraftColor.canvas
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
