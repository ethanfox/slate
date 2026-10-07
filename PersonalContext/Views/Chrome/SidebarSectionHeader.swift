import SwiftUI

struct SidebarSectionHeader<Trailing: View>: View {
    @Environment(\.appearsActive) private var appearsActive
    var title: String
    var isExpanded: Bool?
    var onToggle: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        isExpanded: Bool? = nil,
        onToggle: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            if let isExpanded, let onToggle {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                        Text(title)
                            .font(CraftFont.section)
                            .foregroundStyle(appearsActive ? .secondary : .tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            } else {
                Text(title)
                    .font(CraftFont.section)
                    .foregroundStyle(appearsActive ? .secondary : .tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }
}
