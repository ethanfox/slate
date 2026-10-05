import SwiftUI

struct InspectorTab<ID: Hashable>: Identifiable {
    var id: ID
    var title: String
}

struct InspectorTabBar<ID: Hashable>: View {
    var tabs: [InspectorTab<ID>]
    @Binding var selection: ID

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ForEach(tabs) { tab in
                    Button(tab.title) {
                        selection = tab.id
                    }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .foregroundStyle(selection == tab.id ? .primary : .tertiary)
                }
                Spacer(minLength: 0)
            }
            Hairline()
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }
}

struct InspectorPanel<Tab: Hashable, Content: View>: View {
    var tabs: [InspectorTab<Tab>]
    @Binding var selection: Tab
    @ViewBuilder var content: (Tab) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorTabBar(tabs: tabs, selection: $selection)
            ScrollView {
                content(selection)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SlideInspector<Content: View>: View {
    var isOpen: Bool
    var width: CGFloat = 250
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: width, alignment: .leading)
            .frame(width: isOpen ? width : 0, alignment: .leading)
            .clipped()
            .opacity(isOpen ? 1 : 0)
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
    }
}
