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

struct InspectorChoiceGroup<Value: Hashable & Identifiable>: View {
    var title: String
    var items: [Value]
    @Binding var selection: Value
    var label: (Value) -> String
    var font: (Value) -> Font = { _ in CraftFont.body }
    var accessibilityName: (Value) -> String

    init(
        _ title: String,
        items: [Value],
        selection: Binding<Value>,
        label: @escaping (Value) -> String,
        font: @escaping (Value) -> Font = { _ in CraftFont.body },
        accessibilityName: @escaping (Value) -> String
    ) {
        self.title = title
        self.items = items
        self._selection = selection
        self.label = label
        self.font = font
        self.accessibilityName = accessibilityName
    }

    init(
        _ title: String,
        items: [Value],
        selection: Binding<Value>,
        label: @escaping (Value) -> String,
        font: @escaping (Value) -> Font = { _ in CraftFont.body }
    ) {
        self.init(
            title,
            items: items,
            selection: selection,
            label: label,
            font: font,
            accessibilityName: label
        )
    }

    @Namespace private var selectionSlide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(items) { item in
                    let selected = selection == item
                    Button {
                        selection = item
                    } label: {
                        Text(label(item))
                            .font(font(item))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if selected, !reduceMotion {
                            Capsule()
                                .fill(CraftColor.selection)
                                .matchedGeometryEffect(id: "choice", in: selectionSlide)
                        } else {
                            Capsule()
                                .fill(selected ? CraftColor.selection : Color.primary.opacity(0.06))
                        }
                    }
                    .accessibilityLabel(accessibilityName(item))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .animation(reduceMotion ? Motion.quick : Motion.snappy, value: selection)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
