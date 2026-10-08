import SwiftData
import SwiftUI

private enum OverviewInspectorTab: String, Hashable {
    case subject
    case insert
}

struct OverviewInspector: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @State private var tab = OverviewInspectorTab.subject

    private var selectedPlate: OverviewPlate? {
        guard let id = app.selectedOverviewPlate else { return nil }
        return project.overviewPlates.first(where: { $0.id == id })
    }

    private var tabs: [InspectorTab<OverviewInspectorTab>] {
        [
            InspectorTab(id: .subject, title: selectedPlate?.kind.label ?? "Settings"),
            InspectorTab(id: .insert, title: "Insert")
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
                        Text("Project")
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

private struct OverviewInspectorSettings: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app

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

            InspectorChoiceGroup(
                "Overview width",
                items: OverviewWidth.allCases,
                selection: $project.overviewWidth,
                label: \.compactLabel,
                accessibilityName: \.label
            )

            inspectorField("Code") {
                ProjectCodeSection(project: project)
            }

            inspectorField("Worker") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Worker", selection: workerMode) {
                        Text("Use chat model").tag(false)
                        Text("Custom worker").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    if !project.workerProviderID.isEmpty {
                        Picker("Provider", selection: $project.workerProviderID) {
                            if let current = TalkProvider(rawValue: project.workerProviderID),
                               !app.availableTalkProviders.contains(current) {
                                Text("\(current.title) — disconnected").tag(current.rawValue)
                            }
                            ForEach(app.availableTalkProviders) { provider in
                                Text(provider.title).tag(provider.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("Model", selection: $project.workerModelID) {
                            if project.workerProviderID == TalkProvider.cursor.rawValue {
                                Text("Account default").tag("")
                            }
                            ForEach(app.models(for: project.workerProviderID), id: \.id) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("Run on", selection: $project.workerPath) {
                            ForEach(WorkerRegistry.paths(for: project.workerProviderID)) { path in
                                Text(path.title).tag(path.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        if project.workerPath == WorkerPath.cloud.rawValue,
                           project.workerProviderID == TalkProvider.cursor.rawValue,
                           !project.codeAttachments.contains(where: { $0.kind == .github }) {
                            Text("Cursor Cloud requires an attached GitHub repository.")
                                .font(CraftFont.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .onChange(of: project.name) { _, _ in project.touch() }
        .onChange(of: project.symbol) { _, _ in project.touch() }
        .onChange(of: project.statusRaw) { _, _ in project.touch() }
        .onChange(of: project.isPinned) { _, _ in project.touch() }
        .onChange(of: project.overviewWidthRaw) { _, _ in project.touch() }
        .onChange(of: project.workerProviderID) { _, _ in
            normalizeWorker()
            project.touch()
        }
        .onChange(of: project.workerModelID) { _, _ in project.touch() }
        .onChange(of: project.workerPath) { _, _ in project.touch() }
    }

    private var workerMode: Binding<Bool> {
        Binding(
            get: { !project.workerProviderID.isEmpty },
            set: { custom in
                if custom {
                    let provider = app.availableTalkProviders.contains(app.talkProvider)
                        ? app.talkProvider
                        : app.availableTalkProviders.first
                    project.workerProviderID = provider?.rawValue ?? ""
                    project.workerModelID = provider == app.talkProvider ? app.talkModelID : ""
                    project.workerPath = WorkerRegistry.paths(for: project.workerProviderID).first?.rawValue ?? ""
                } else {
                    project.workerProviderID = ""
                    project.workerModelID = ""
                    project.workerPath = ""
                }
                project.touch()
            }
        )
    }

    private func normalizeWorker() {
        guard !project.workerProviderID.isEmpty else { return }
        let paths = WorkerRegistry.paths(for: project.workerProviderID)
        if !paths.contains(where: { $0.rawValue == project.workerPath }) {
            project.workerPath = paths.first?.rawValue ?? ""
        }
        let models = app.models(for: project.workerProviderID)
        if project.workerProviderID == TalkProvider.chatgpt.rawValue,
           !models.contains(where: { $0.id == project.workerModelID }) {
            project.workerModelID = models.first?.id ?? ""
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
