import SwiftData
import SwiftUI

/// Finds the Space a tab shows and hands it to its page.
struct SpaceHost: View {
    var id: UUID
    @Query private var spaces: [Space]

    init(id: UUID) {
        self.id = id
        let spaceID = id
        _spaces = Query(filter: #Predicate<Space> { $0.id == spaceID })
    }

    var body: some View {
        if let space = spaces.first {
            SpaceView(space: space)
                .onAppear {
                    NavTrace.event("space.host appear id=\(id) name=\(space.name)")
                }
                .onAppear {
                    NavTrace.afterTurn("space.host.runloop id=\(id)")
                }
        } else {
            ScrollView {
                PageBody {
                    EmptyLine(text: "This Space is no longer here.")
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

/// One Space. Its page stands for it; a track, note, decision, chat, or run opens over it,
/// and there is no side column of lists.
struct SpaceView: View {
    @Bindable var space: Space
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        center
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear {
                NavTrace.event("space.view appear tab=\(tab.rawValue) thread=\(app.selectedThread?.uuidString ?? "-") note=\(app.selectedNote?.uuidString ?? "-")")
            }
    }

    @ViewBuilder
    private var center: some View {
        switch tab {
        case .overview:
            OverviewPage(project: space)
        case .tasks:
            ProjectTasksBoard(project: space)
        case .threads:
            if let id = app.selectedThread, let thread = TitleIndexStore.thread(id, in: context) {
                ThreadPage(thread: thread, project: space).id(thread.id)
            } else {
                TrackLanesPage(space: space)
            }
        case .notes:
            if let id = app.selectedNote, let note = TitleIndexStore.note(id, in: context) {
                NotePage(note: note, project: space).id(note.id)
            } else {
                OverviewPage(project: space, listing: .note)
            }
        case .decisions:
            if let id = app.selectedDecision, let decision = TitleIndexStore.decision(id, in: context) {
                DecisionPage(decision: decision, project: space).id(decision.id)
            } else {
                OverviewPage(project: space, listing: .decision)
            }
        case .chat:
            if app.selectedConversation != nil {
                ProjectChatCenter(project: space)
            } else {
                OverviewPage(project: space, listing: .chat)
            }
        case .runs:
            if let id = app.selectedRun, let run = TitleIndexStore.run(id, in: context) {
                RunPage(run: run).id(run.id)
            } else {
                OverviewPage(project: space, listing: .run)
            }
        }
    }

    private var tab: SpaceTab { app.tab(for: space.id) }
}

/// The records a Space collects: its widgets, then each of its types in the layout Membrae picked for it.
struct SpaceRecordsSection: View {
    var space: Space

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \SpaceType.createdAt) private var types: [SpaceType]
    @Query(sort: \SpaceRecord.updatedAt, order: .reverse) private var records: [SpaceRecord]
    @Query private var events: [SpaceEvent]
    @State private var pendingDelete: SpaceRecord?

    var body: some View {
        let shown = SpaceSelection.pageTypes(in: space.id, types: types, records: records)
        VStack(alignment: .leading, spacing: 36) {
            if shown.isEmpty {
                EmptyLine(text: "No records yet. Tell Membrae what this Space should hold.")
            }
            ForEach(shown) { type in
                if type.role == .settings {
                    settings(type)
                } else {
                    SpaceTypeSection(space: space, type: type, types: types, records: records, events: events) {
                        pendingDelete = $0
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                SpaceRecordContent(spaceID: space.id, recordID: record.id)
            } else {
                EmptyLine(text: "Nothing set yet.")
                    .task(id: type.id) { try? SpaceStore.settingsRecord(of: type, in: context) }
            }
        }
    }
}

/// One kind of thing in a Space, with its own search and filters.
private struct SpaceTypeSection: View {
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

    /// Record ids to names across one Space, for showing links.
    static func titles(in spaceKey: String, records: [SpaceRecord]) -> [String: String] {
        var titles: [String: String] = [:]
        for record in records where record.spaceIDString == spaceKey {
            titles[SpaceJSON.key(record.id)] = record.displayTitle
        }
        return titles
    }

    /// The first two single-value fields that hold something, for a list row.
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

/// Toolbar control for a Space that collects: New, for whichever kind of record it holds.
/// Nothing shows for a Space with no types.
struct SpaceToolbar: View {
    var spaceID: UUID

    @Environment(AppModel.self) private var app
    @Query(sort: \SpaceType.createdAt) private var types: [SpaceType]

    var body: some View {
        let addable = SpaceSelection.objectTypes(in: spaceID, types: types).filter { $0.role != .settings }
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
            .help("New record")
        }
    }

    private var label: some View {
        Label("New Record", systemImage: "plus")
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

/// The one way a Space is made by hand. What it holds comes afterwards: from a starting set of
/// types, from the agent, or from what gets filed in it. Changing a Space is done in its settings.
struct NewSpaceSheet: View {
    /// The first message of a setup chat. The agent proposes, the user confirms, and only then is
    /// the Space created, so an abandoned chat leaves nothing behind.
    static func setupMessage(name: String, symbol: String, color: String, brief: String) -> String {
        """
        I want a new Space called “\(name)”.

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
    @State private var symbol = "square.grid.2x2"
    @State private var gradient: SpaceGradient?
    @State private var summary = ""
    @State private var template = SpaceTemplate.empty
    @State private var brief = ""

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

            ModalField("Description") {
                TextField("What this Space is", text: $summary, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...5)
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

            ModalField("Or describe what it should hold") {
                TextField("Track the books I read, with notes and a rating", text: $brief, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...5)
            }

            ModalFooter(
                actionTitle: describing ? "Plan it with Membrae" : "Create",
                actionEnabled: canCreate,
                action: create
            )
        }
        .onAppear { focusName = true }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A description hands the setup to the agent instead of a starting set of types.
    private var describing: Bool {
        !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if describing {
            let conversation = app.makeConversation(in: nil, context: context)
            conversation.title = "Set up \(trimmed)"
            app.pendingSend = PendingSend(
                conversationID: conversation.id,
                text: NewSpaceSheet.setupMessage(name: trimmed, symbol: symbol, color: chosen.rawValue, brief: brief)
            )
        } else if let space = try? SpaceStore.create(
            named: trimmed,
            symbol: symbol,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            gradient: chosen.rawValue,
            in: context
        ) {
            try? SpaceStore.apply(template, to: space, in: context)
            app.open(space, tab: .overview, newTab: false)
        }
        modalDismiss()
    }
}
