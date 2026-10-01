import SwiftData
import SwiftUI

private enum OverviewInspectorTab: String, Hashable {
    case settings
    case insert
}

struct OverviewInspector: View {
    @Bindable var project: Project
    @State private var tab = OverviewInspectorTab.settings

    private let tabs = [
        InspectorTab(id: OverviewInspectorTab.settings, title: "Settings"),
        InspectorTab(id: OverviewInspectorTab.insert, title: "Insert")
    ]

    var body: some View {
        InspectorPanel(tabs: tabs, selection: $tab) { tab in
            switch tab {
            case .settings:
                OverviewInspectorSettings(project: project)
            case .insert:
                OverviewInspectorInsert(project: project)
            }
        }
    }
}

private struct OverviewInspectorSettings: View {
    @Bindable var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            inspectorField("Name") {
                TextField("Untitled", text: $project.name)
                    .textFieldStyle(.plain)
                    .font(CraftFont.body)
            }

            inspectorField("Icon") {
                SymbolPicker(selection: $project.symbol, columns: 6)
            }

            inspectorField("Status") {
                Picker("Status", selection: $project.status) {
                    ForEach(ProjectStatus.allCases) { status in
                        Text(status.label).tag(status)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            HStack {
                Text("Pinned")
                    .font(CraftFont.body)
                Spacer()
                Toggle("Pinned", isOn: $project.isPinned)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            inspectorField("Overview width") {
                OverviewWidthControl(project: project)
            }
        }
        .onChange(of: project.name) { _, _ in project.touch() }
        .onChange(of: project.symbol) { _, _ in project.touch() }
        .onChange(of: project.statusRaw) { _, _ in project.touch() }
        .onChange(of: project.isPinned) { _, _ in project.touch() }
        .onChange(of: project.overviewWidthRaw) { _, _ in project.touch() }
    }

    private func inspectorField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct GlassCapsuleSwitcher<Value: Hashable & Identifiable>: View {
    var items: [Value]
    @Binding var selection: Value
    var symbol: (Value) -> String
    var label: (Value) -> String
    var accessibilityLabel: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Button {
                    selection = item
                } label: {
                    Image(systemName: symbol(item))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(label(item))
                .foregroundStyle(selection == item ? .primary : .secondary)
                .accessibilityLabel(label(item))
            }
        }
        .padding(2)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct OverviewWidthControl: View {
    @Bindable var project: Project

    var body: some View {
        GlassCapsuleSwitcher(
            items: OverviewWidth.allCases,
            selection: $project.overviewWidth,
            symbol: \.symbol,
            label: \.label,
            accessibilityLabel: "Overview width"
        )
    }
}

private struct OverviewInspectorInsert: View {
    var project: Project

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
            ForEach(OverviewWidgetSize.allCases) { size in
                Button {
                    project.addOverviewPlate(size)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: size.symbol)
                            .font(CraftFont.sidebarIcon)
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular, in: Circle())
                        Text(size.label)
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Insert \(size.label)")
            }
        }
    }
}
