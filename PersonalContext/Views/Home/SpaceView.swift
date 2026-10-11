import SwiftData
import SwiftUI

/// The inside of a Space: one type at a time, as a plain list of its records.
struct SpaceView: View {
    var id: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var spaces: [Space]
    @Query(sort: \SpaceType.createdAt) private var types: [SpaceType]
    @Query(sort: \SpaceRecord.updatedAt, order: .reverse) private var records: [SpaceRecord]
    @Query private var events: [SpaceEvent]
    @Query private var screens: [SpaceScreen]
    @State private var pendingDelete: SpaceRecord?
    @State private var screenState = SpaceScreenState()

    private var space: Space? {
        spaces.first { $0.id == id }
    }

    private var selectedType: SpaceType? {
        SpaceSelection.type(in: id, types: types, chosen: app.spaceTypeSelection[id])
    }

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 20) {
                    if space == nil {
                        EmptyLine(text: "This Space no longer exists.")
                    } else if let type = selectedType {
                        if let space, let definition = SpaceScreens.definition(for: type, kind: .collection, screens: screens, types: types) {
                            SpaceScreenView(definition: definition, context: screenContext(type, space: space))
                        } else {
                            list(type)
                        }
                    } else {
                        EmptyLine(text: "This Space has no types yet. An agent will be able to set one up.")
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
        .alert(
            "Delete \(pendingDelete?.displayTitle ?? "this record")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let record = pendingDelete {
                    try? SpaceStore.delete(record, in: context)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private func screenContext(_ type: SpaceType, space: Space) -> SpaceScreenContext {
        let key = SpaceJSON.key(type.id)
        let spaceKey = type.spaceIDString
        return SpaceScreenContext(
            kind: .collection,
            type: type,
            schema: type.schema,
            eventTypes: SpaceScreens.eventTypes(beside: type, in: types),
            records: records.filter { $0.typeIDString == key }.sorted { $0.createdAt < $1.createdAt },
            events: events.filter { $0.spaceIDString == spaceKey },
            record: nil,
            accent: space.gradient.accent,
            state: screenState,
            context: context,
            open: { app.navigate(to: .spaceRecord(space: id, record: $0.id)) }
        )
    }

    /// The plain list, shown when a type has no screen or its screen no longer fits.
    @ViewBuilder
    private func list(_ type: SpaceType) -> some View {
        let key = SpaceJSON.key(type.id)
        let rows = records.filter { $0.typeIDString == key }
        let schema = type.schema
        HStack(alignment: .firstTextBaseline) {
            Text(type.name)
                .font(CraftFont.section)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(rows.count == 1 ? "1 record" : "\(rows.count) records")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        if rows.isEmpty {
            EmptyLine(text: "Nothing here yet. Use New to add the first one.")
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { record in
                    Button {
                        app.navigate(to: .spaceRecord(space: id, record: record.id))
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.displayTitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                let subtitle = SpaceSelection.subtitle(for: record, schema: schema)
                                if !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(record.updatedAt.relativeLabel)
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            app.present(.editRecord(record))
                        } label: {
                            Label("Edit…", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingDelete = record
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    Hairline()
                }
            }
        }
    }
}

enum SpaceSelection {
    /// The chosen object type if it still belongs to the Space, else the first one.
    static func type(in spaceID: UUID, types: [SpaceType], chosen: UUID?) -> SpaceType? {
        let owned = objectTypes(in: spaceID, types: types)
        return owned.first { $0.id == chosen } ?? owned.first
    }

    static func objectTypes(in spaceID: UUID, types: [SpaceType]) -> [SpaceType] {
        let key = SpaceJSON.key(spaceID)
        return types.filter { $0.spaceIDString == key && $0.role == .object }
    }

    /// The first two single-value fields that hold something, for a list row.
    static func subtitle(for record: SpaceRecord, schema: SpaceSchema) -> String {
        let values = record.values
        return schema.liveFields
            .filter { $0.kind != .group && $0.kind != .richText && $0.kind != .image }
            .compactMap { field in values[field.id].map { schema.display($0, for: field) } }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " · ")
    }
}

/// Toolbar controls for a Space: its types, and New.
struct SpaceToolbar: View {
    var spaceID: UUID

    @Environment(AppModel.self) private var app
    @Query(sort: \SpaceType.createdAt) private var types: [SpaceType]

    var body: some View {
        let owned = SpaceSelection.objectTypes(in: spaceID, types: types)
        let selected = SpaceSelection.type(in: spaceID, types: types, chosen: app.spaceTypeSelection[spaceID])
        GlassEffectContainer {
            HStack(spacing: 10) {
                if owned.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(owned) { type in
                            Button {
                                app.spaceTypeSelection[spaceID] = type.id
                            } label: {
                                Text(type.name)
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(selected?.id == type.id ? .primary : .secondary)
                        }
                    }
                    .padding(2)
                    .glassEffect(.regular, in: Capsule())
                }
                if let selected {
                    Button {
                        app.present(.newRecord(selected))
                    } label: {
                        Label("New", systemImage: "plus")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: Capsule())
                    .help("New in \(selected.name)")
                }
            }
        }
    }
}

struct ChoiceCapsule: View {
    var title: String
    var isSelected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? CraftColor.canvas : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(isSelected ? Color.primary : CraftColor.elevated, in: Capsule())
            .overlay(Capsule().strokeBorder(CraftColor.hairline, lineWidth: isSelected ? 0 : 1))
            .contentShape(Capsule())
    }
}

struct NewSpaceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @Query private var spaces: [Space]
    @FocusState private var focusName: Bool

    @State private var name = ""
    @State private var symbol = "leaf"
    @State private var gradient: SpaceGradient?
    @State private var template = SpaceTemplate.empty

    private var chosen: SpaceGradient {
        gradient ?? SpaceGradient.next(after: spaces.map(\.gradientRaw))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Space")
                .font(CraftFont.title)

            ModalField("Name") {
                TextField("Kitchen", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focusName)
            }

            ModalField("Icon", boxed: false) {
                SymbolPicker(selection: $symbol)
            }

            ModalField("Color", boxed: false) {
                HStack(spacing: 8) {
                    ForEach(SpaceGradient.allCases) { option in
                        Button {
                            gradient = option
                        } label: {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(option.fill)
                                .frame(width: 36, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.primary, lineWidth: chosen == option ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(option.label)
                        .accessibilityLabel(option.label)
                    }
                }
            }

            ModalField("Start with", boxed: false) {
                HStack(spacing: 6) {
                    ForEach(SpaceTemplate.all) { option in
                        Button {
                            template = option
                        } label: {
                            ChoiceCapsule(title: option.name, isSelected: template == option)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ModalFooter(actionTitle: "Create", actionEnabled: canCreate, action: create)
        }
        .onAppear { focusName = true }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let space = try? SpaceStore.create(named: trimmed, symbol: symbol, gradient: chosen.rawValue, in: context) {
            try? SpaceStore.apply(template, to: space, in: context)
            app.navigate(to: .space(space.id), newTab: false)
        }
        modalDismiss()
    }
}
