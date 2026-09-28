import SwiftUI

struct SidebarSectionHeader<Trailing: View>: View {
    @Environment(\.appearsActive) private var appearsActive
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(CraftFont.section)
                .foregroundStyle(appearsActive ? .secondary : .tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }
}
