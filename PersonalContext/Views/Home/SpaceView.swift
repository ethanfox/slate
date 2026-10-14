import SwiftData
import SwiftUI

/// The inside of a Space: every kind of thing it holds on one page, each in the layout Membrae picked for it.
struct SpaceView: View {
    var id: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var spaces: [Space]
    @Query(sort: \SpaceType.createdAt) private var types: [SpaceType]
    @Query(sort: \SpaceRecord.updatedAt, order: .reverse) private var records: [SpaceRecord]
    @Query private var events: [SpaceEvent]
    @State private var pendingDelete: SpaceRecord?

    private var space: Space? {
        spaces.first { $0.id == id }
    }

    var body: some View {
        content
            .captureBar(spaceID: id, placeholder: "Tell Membrae anything about \(space?.displayName ?? "this Space")")
    }

    private var content: some View {
        let shown = SpaceSelection.pageTypes(in: id, types: types, records: records)
        return ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 36) {
                    AreaWidgetShelf(spaceID: id)
                    if let space {
                        if shown.isEmpty {
                            EmptyLine(text: "Nothing here yet. Tell Membrae what this Space is for.")
                        }
                        ForEach(shown) { type in
                            if type.role == .settings {
                                settings(type)
                            } else {
                                AreaTypeSection(space: space, type: type, types: types, records: records, events: events) {
                                    pendingDelete = $0
                                }
                            }
                        }
                    } else {
                        EmptyLine(text: "This Space no longer exists.")
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

    @ViewBuilder
    private func settings(_ type: SpaceType) -> some View {
        let record = records.first { $0.typeIDString == SpaceJSON.key(type.id) }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(type.name)
                    .font(.system(size: 22, weight: .semibold))
                if let record {
                    Button("Edit") { app.present(.editRecord(record)) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help("Change \(type.name)")
                }
            }
            if let record {
                SpaceRecordContent(spaceID: id, recordID: record.id)
            } else {
                EmptyLine(text: "Nothing set yet.")
                    .task(id: type.id) { try? SpaceStore.settingsRecord(of: type, in: context) }
            }
        }
    }
}

/// One kind of thing in a Space, with its own search and filters.
private struct AreaTypeSection: View {
    var space: Space
    var type: SpaceType
    var types: [SpaceType]
    var records: [SpaceRecord]
    var events: [SpaceEvent]
    var onDelete: (SpaceRecord) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var screenState = SpaceScreenState()

    var body: some View {
        AreaRecordsView(context: screenContext, onDelete: onDelete)
    }

    private var screenContext: SpaceScreenContext {
        let key = SpaceJSON.key(type.id)
        let spaceKey = type.spaceIDString
        let spaceID = space.id
        return SpaceScreenContext(
            kind: .collection,
            type: type,
            schema: type.schema,
            eventTypes: SpaceScreens.eventTypes(beside: type, in: types),
            records: records
                .filter { $0.typeIDString == key }
                // Archived records stay in every view, dimmed, after the current ones.
                .sorted { ($0.isArchived ? 1 : 0, $0.createdAt) < ($1.isArchived ? 1 : 0, $1.createdAt) },
            events: events.filter { $0.spaceIDString == spaceKey },
            record: nil,
            titles: SpaceSelection.titles(in: spaceKey, records: records),
            lookup: SpaceLookup(spaceKey: spaceKey, records: records, types: types),
            accent: space.gradient.accent,
            palette: space.gradient.hexes,
            portraitCards: space.hasPortraitCards,
            state: screenState,
            context: context,
            open: { app.navigate(to: .spaceRecord(space: spaceID, record: $0.id)) },
            present: { app.present($0) }
        )
    }
}

enum SpaceSelection {
    /// The chosen object type if it still belongs to the Space, else the first one.
    static func type(in spaceID: UUID, types: [SpaceType], chosen: UUID?) -> SpaceType? {
        let owned = objectTypes(in: spaceID, types: types)
        return owned.first { $0.id == chosen } ?? owned.first
    }

    /// The types a Space's page shows, in order: the ones that hold something first, then the empty ones,
    /// then settings.
    static func pageTypes(in spaceID: UUID, types: [SpaceType], records: [SpaceRecord]) -> [SpaceType] {
        let filled = Set(records.map(\.typeIDString))
        func rank(_ type: SpaceType) -> Int {
            if type.role == .settings { return 2 }
            return filled.contains(SpaceJSON.key(type.id)) ? 0 : 1
        }
        return objectTypes(in: spaceID, types: types)
            .enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    static func objectTypes(in spaceID: UUID, types: [SpaceType]) -> [SpaceType] {
        let key = SpaceJSON.key(spaceID)
        return types.filter { $0.spaceIDString == key && $0.role != .event }
    }

    /// The first two single-value fields that hold something, for a list row.
    /// Record ids to names across one Space, for showing links.
    static func titles(in spaceKey: String, records: [SpaceRecord]) -> [String: String] {
        var titles: [String: String] = [:]
        for record in records where record.spaceIDString == spaceKey {
            titles[SpaceJSON.key(record.id)] = record.displayTitle
        }
        return titles
    }

    static func subtitle(for record: SpaceRecord, schema: SpaceSchema, titles: [String: String] = [:]) -> String {
        let values = record.values
        return schema.liveFields
            .filter { $0.kind != .group && $0.kind != .richText && $0.kind != .image }
            .compactMap { field in values[field.id].map { schema.display($0, for: field, titles: titles) } }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " · ")
    }
}

/// Toolbar control for a Space: New, for whichever kind of thing it holds.
struct SpaceToolbar: View {
    var spaceID: UUID

    @Environment(AppModel.self) private var app
    @Query(sort: \SpaceType.createdAt) private var types: [SpaceType]

    var body: some View {
        let addable = SpaceSelection.objectTypes(in: spaceID, types: types).filter { $0.role != .settings }
        GlassEffectContainer {
            if addable.count == 1, let only = addable.first {
                Button {
                    app.present(.newRecord(only))
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Capsule())
                .help("New in \(only.name)")
            } else if addable.count > 1 {
                Menu {
                    ForEach(addable) { type in
                        Button(type.name) { app.present(.newRecord(type)) }
                    }
                } label: {
                    label
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .glassEffect(.regular, in: Capsule())
                .help("New")
            }
        }
    }

    private var label: some View {
        Label("New", systemImage: "plus")
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
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
    /// Set to rename, re-icon, or recolor an existing Space.
    var space: Space?

    /// The first message of a setup chat. The agent proposes, the user confirms, and only then is
    /// the Space created, so an abandoned chat leaves nothing behind.
    static func setupMessage(name: String, symbol: String, color: String, brief: String) -> String {
        """
        I want a new Area called “\(name)”.

        What it is for: \(brief.trimmingCharacters(in: .whitespacesAndNewlines))

        Tell me what you would make before you make anything, and wait for me to agree. When you create it, use the name “\(name)”, the symbol \(symbol), and the color \(color).
        """
    }

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @Query private var spaces: [Space]
    @FocusState private var focusName: Bool

    @State private var name = ""
    @State private var symbol = "leaf"
    @State private var gradient: SpaceGradient?
    @State private var template = SpaceTemplate.empty
    @State private var brief = ""
    @State private var notes = ""
    @State private var portrait = false

    private var chosen: SpaceGradient {
        gradient ?? SpaceGradient.next(after: spaces.map(\.gradientRaw))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(space == nil ? "New Area" : "Edit Area")
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

            if space == nil {
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

            ModalField("Or describe it") {
                TextField("Track the books I read, with notes and a rating", text: $brief, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...5)
            }
            }

            if space != nil {
                ModalField("Pictures on cards", boxed: false) {
                    HStack(spacing: 6) {
                        Button { portrait = false } label: { ChoiceCapsule(title: "Landscape", isSelected: !portrait) }
                            .buttonStyle(.plain)
                        Button { portrait = true } label: { ChoiceCapsule(title: "Portrait", isSelected: portrait) }
                            .buttonStyle(.plain)
                    }
                }
                ModalField("Notes for Membrae") {
                    TextField("What you call things here, units you use, and anything Membrae should remember", text: $notes, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...6)
                }
            }

            ModalFooter(
                actionTitle: space != nil ? "Save" : describing ? "Plan it with an agent" : "Create",
                actionEnabled: canCreate,
                action: create
            )
        }
        .onAppear {
            if let space, name.isEmpty {
                name = space.name
                symbol = space.symbol
                gradient = space.gradient
                notes = space.agentNotes
                portrait = space.hasPortraitCards
            }
            focusName = true
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A description hands the setup to an agent instead of a starting template.
    private var describing: Bool {
        !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let space {
            try? SpaceStore.update(space, name: trimmed, symbol: symbol, gradient: chosen.rawValue, notes: notes, portraitCards: portrait, in: context)
        } else if describing {
            let conversation = app.makeConversation(in: nil, context: context)
            conversation.title = "Set up \(trimmed)"
            app.pendingSend = PendingSend(
                conversationID: conversation.id,
                text: NewSpaceSheet.setupMessage(name: trimmed, symbol: symbol, color: chosen.rawValue, brief: brief)
            )
        } else if let space = try? SpaceStore.create(named: trimmed, symbol: symbol, gradient: chosen.rawValue, in: context) {
            try? SpaceStore.apply(template, to: space, in: context)
            app.navigate(to: .space(space.id), newTab: false)
        }
        modalDismiss()
    }
}
