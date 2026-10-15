import SwiftData
import SwiftUI

private enum OverviewInspectorTab: String, Hashable {
    case subject
    case insert
}

struct OverviewInspector: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var tab = OverviewInspectorTab.subject

    private var selectedPlate: OverviewPlate? {
        guard let id = app.selectedOverviewPlate else { return nil }
        return project.overviewPlates.first(where: { $0.id == id })
    }

    private var tabs: [InspectorTab<OverviewInspectorTab>] {
        [
            InspectorTab(id: .subject, title: selectedPlate?.kind.label ?? "Settings")
        ]
    }

    var body: some View {
        InspectorPanel(tabs: tabs, selection: $tab) { tab in
            switch tab {
            case .subject:
                subject
            case .insert:
                OverviewInspectorInsert(project: project)
            }
        }
        .onChange(of: app.selectedOverviewPlate) { _, id in
            if id != nil { tab = .subject }
        }
        .onChange(of: project.overviewLayoutJSON) { _, _ in
            if let id = app.selectedOverviewPlate,
               !project.overviewPlates.contains(where: { $0.id == id }) {
                app.selectedOverviewPlate = nil
            }
        }
    }

    @ViewBuilder
    private var subject: some View {
        let plate = selectedPlate
        Group {
            if let plate {
                OverviewInspectorWidget(project: project, plate: plate)
                    .id(plate.id)
                    .transition(.opacity)
            } else {
                OverviewInspectorSettings(project: project)
                    .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: plate?.id)
    }
}

extension AppModel {
    /// A Space's settings live in the pane beside its page. There is no modal for them.
    func showSpaceSettings(_ space: Space) {
        open(space, tab: .overview, newTab: false)
        selectedOverviewPlate = nil
        if !inspectorOpen { toggleInspector() }
    }

    /// The gear on the page: shows the settings, or hides them when they are already showing.
    func toggleSpaceSettings() {
        if inspectorOpen, selectedOverviewPlate == nil {
            toggleInspector()
        } else {
            selectedOverviewPlate = nil
            if !inspectorOpen { toggleInspector() }
        }
    }
}

private struct OverviewInspectorWidget: View {
    @Bindable var project: Project
    var plate: OverviewPlate
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                app.selectOverviewPlate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Space")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                        Text(project.displayName)
                            .font(CraftFont.body)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Deselect widget")

            InspectorChoiceGroup(
                "Size",
                items: OverviewWidgetSize.allCases,
                selection: sizeBinding,
                label: \.label,
                accessibilityName: \.spokenLabel
            )

            fields
        }
    }

    private var sizeBinding: Binding<OverviewWidgetSize> {
        Binding(
            get: { project.overviewPlates.first(where: { $0.id == plate.id })?.size ?? plate.size },
            set: { project.setOverviewPlate(plate.id, size: $0) }
        )
    }

    @ViewBuilder
    private var fields: some View {
        switch plate.kind {
        case .focus:
            FocusWidgetFields(settings: project.overviewSettings(
                plate.id,
                decode: FocusWidgetSettings.decode,
                encode: { $0.encoded }
            ))
        case .notes:
            NotesWidgetFields(settings: project.overviewSettings(
                plate.id,
                decode: NotesWidgetSettings.decode,
                encode: { $0.encoded }
            ))
        case .countdown:
            CountdownWidgetFields(settings: project.overviewSettings(
                plate.id,
                decode: CountdownWidgetSettings.decode,
                encode: { $0.encoded }
            ))
        default:
            Text("This widget has no settings yet.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
        }
    }
}

/// Everything about a Space the user sets by hand. What it holds is set by filing things in it.
private struct OverviewInspectorSettings: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

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

            inspectorField("Color") {
                HStack(spacing: 6) {
                    ForEach(SpaceGradient.allCases) { option in
                        Button {
                            project.gradientRaw = option.rawValue
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(option.fill)
                                .frame(width: 22, height: 28)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.primary, lineWidth: project.gradient == option ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(option.label)
                        .accessibilityLabel(option.label)
                    }
                }
            }

            inspectorField("Description") {
                TextField("What this Space is", text: $project.summary, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(CraftFont.body)
                    .lineLimit(2...8)
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

            if project.collects {
                inspectorField("Pictures on cards") {
                    Picker("Pictures on cards", selection: $project.hasPortraitCards) {
                        Text("Landscape").tag(false)
                        Text("Portrait").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            inspectorField("Sync") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Sync to Cloudflare", isOn: Binding(
                        get: { project.isSynced },
                        set: { try? SpaceStore.setSynced($0, on: project, in: context) }
                    ))
                    .toggleStyle(.switch)
                    Text(project.isSynced
                         ? "Everything in this Space is stored in Cloudflare too, where Membrae's servers can read it. That is what lets web AIs and jobs work with it when this Mac is off."
                         : "This Space stays on this Mac. Turn sync on to reach it from web AIs and other devices.")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            inspectorField("Notes for Membrae") {
                TextField("What you call things here, units you use, and anything Membrae should remember", text: $project.agentNotes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(CraftFont.body)
                    .lineLimit(2...8)
            }

            inspectorField("Code") {
                ProjectCodeSection(project: project)
            }

            inspectorField("MCP") {
                ProjectMCPToggles(project: project)
            }
        }
        .onChange(of: project.name) { _, _ in project.touch() }
        .onChange(of: project.symbol) { _, _ in project.touch() }
        .onChange(of: project.gradientRaw) { _, _ in project.touch() }
        .onChange(of: project.summary) { _, _ in project.touch() }
        .onChange(of: project.cardShapeRaw) { _, _ in project.touch() }
        .onChange(of: project.agentNotes) { _, notes in
            if notes.count > Space.agentNotesLimit {
                project.agentNotes = String(notes.prefix(Space.agentNotesLimit))
            }
            project.touch()
        }
        .onChange(of: project.statusRaw) { _, _ in
            project.touch()
            TaskStore.syncProjectStatus(project, in: context)
        }
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

/// Which connected MCP servers this Space's chats may use.
struct ProjectMCPToggles: View {
    var project: Project
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if app.talkProvider == .compatible {
                Text("The compatible endpoint cannot run MCP tools.")
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if app.mcp.store.enabledConnections.isEmpty {
                Text("Connect a server in Settings → MCP, then enable it here.")
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(app.mcp.store.enabledConnections) { record in
                    Toggle(record.name, isOn: Binding(
                        get: { app.mcp.store.allows(record.id, in: project.id) },
                        set: { app.mcp.store.setAllowed(record.id, in: project.id, allowed: $0) }
                    ))
                    .toggleStyle(.switch)
                }
            }
        }
    }
}

private struct OverviewInspectorInsert: View {
    var project: Project
    @Environment(AppModel.self) private var app

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
            ForEach(OverviewWidgetKind.allCases) { kind in
                OverviewInsertTile(kind: kind) {
                    let id = project.addOverviewPlate(kind)
                    app.selectOverviewPlate(id)
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
