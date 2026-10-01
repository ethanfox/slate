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

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
            ForEach(OverviewWidgetKind.allCases) { kind in
                OverviewInsertTile(kind: kind) {
                    project.addOverviewPlate(kind)
                }
            }
        }
    }
}

private struct OverviewInsertTile: View {
    var kind: OverviewWidgetKind
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let well = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 56, height: 56)
                    .background {
                        well.fill(Color.primary.opacity(hovering ? 0.10 : 0.06))
                    }
                    .overlay {
                        well.strokeBorder(Color.white.opacity(hovering ? 0.16 : 0.08), lineWidth: 1)
                    }
                Text(kind.label)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel("Insert \(kind.label)")
    }
}
