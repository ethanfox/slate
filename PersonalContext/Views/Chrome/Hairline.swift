import SwiftUI

struct Hairline: View {
    var leading: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(CraftColor.hairline)
            .frame(height: 1)
            .padding(.leading, leading)
    }
}
