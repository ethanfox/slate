import SwiftData
import SwiftUI

struct SpaceRecordView: View {
    var spaceID: UUID
    var recordID: UUID

    var body: some View {
        ScrollView {
            PageBody {
                SpaceRecordContent(spaceID: spaceID, recordID: recordID)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
        .captureBar(spaceID: spaceID)
    }
}

/// One record. Every object gets the same page: its picture, its properties as a list, then its
/// lists and long text. Switches, choices and ratings change in place; Edit opens the full form.
struct SpaceRecordContent: View {
    var spaceID: UUID
    var recordID: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var records: [SpaceRecord]
    @Query(sort: \SpaceType.createdAt) private var types: [SpaceType]
    @Query private var spaces: [Space]
    @Query private var events: [SpaceEvent]
    @State private var screenState = SpaceScreenState()

    private var record: SpaceRecord? {
        records.first { $0.id == recordID }
    }

    private var accent: Color {
        spaces.first { $0.id == spaceID }?.gradient.accent ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let record, let type = types.first(where: { $0.id == record.typeID }) {
                VStack(alignment: .leading, spacing: 24) {
                    Text(record.displayTitle)
                        .font(.system(size: 28, weight: .semibold))
                        .opacity(record.isArchived ? 0.5 : 1)
                    content(record, schema: type.schema)
                    logged(record, type: type)
                }
                .frame(maxWidth: 640, alignment: .leading)
            } else {
                EmptyLine(text: "This record no longer exists.")
            }
        }
    }

    /// What gets logged about this record: a button to log it, and the entries so far.
    @ViewBuilder
    private func logged(_ record: SpaceRecord, type: SpaceType) -> some View {
        let spaceKey = type.spaceIDString
        let eventTypes = SpaceScreens.eventTypes(beside: type, in: types)
        let screen = SpaceScreenContext(
            kind: .detail,
            type: type,
            schema: type.schema,
            eventTypes: eventTypes,
            records: [],
            events: events.filter { $0.spaceIDString == spaceKey },
            record: record,
            titles: SpaceSelection.titles(in: spaceKey, records: records),
            lookup: SpaceLookup(spaceKey: spaceKey, records: records, types: types),
            accent: accent,
            state: screenState,
            context: context,
            open: { app.navigate(to: .spaceRecord(space: spaceID, record: $0.id)) },
            present: { app.present($0) }
        )
        ForEach(eventTypes) { eventType in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Text(eventType.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    SpaceComponentView(
                        component: SpaceComponent("action", ["event": .text(eventType.key), "label": .text("Log \(eventType.name)")]),
                        context: screen
                    )
                }
                SpaceComponentView(
                    component: SpaceComponent("timeline", ["events": .text(eventType.key)]),
                    context: screen
                )
            }
        }
    }

    @ViewBuilder
    private func content(_ record: SpaceRecord, schema: SpaceSchema) -> some View {
        let values = SpaceLookup(spaceKey: record.spaceIDString, records: records, types: types).resolved(record)
        let titles = SpaceSelection.titles(in: record.spaceIDString, records: records)
        let live = schema.liveFields
        ForEach(live.filter { $0.kind == .image }) { field in
            if case .text(let assetID) = values[field.id], !assetID.isEmpty {
                SpaceImageView(assetID: assetID, tint: accent)
                    .frame(width: 280, height: 200)
            }
        }
        let single = live.filter { $0.kind != .group && $0.kind != .richText && $0.kind != .image && $0.kind != .file }
        if !single.isEmpty {
            VStack(spacing: 0) {
                ForEach(single) { field in
                    HStack(alignment: .center, spacing: 16) {
                        Text(field.name)
                            .font(CraftFont.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .leading)
                        property(field, value: values[field.id], record: record, schema: schema, titles: titles)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 36)
                    Hairline()
                }
            }
        }
        ForEach(live.filter { ($0.kind == .group || $0.kind == .richText) && values[$0.id] != nil }) { field in
            VStack(alignment: .leading, spacing: 8) {
                Text(field.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if case .rows(let rows) = values[field.id] {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            groupRow(row, index: index, field: field, schema: schema, titles: titles)
                            Hairline()
                        }
                    }
                } else if case .text(let text) = values[field.id] {
                    Text(text)
                        .font(CraftFont.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A value as the user reads it, or as the control that changes it when one click is enough.
    @ViewBuilder
    private func property(
        _ field: SpaceField,
        value: SpaceValue?,
        record: SpaceRecord,
        schema: SpaceSchema,
        titles: [String: String]
    ) -> some View {
        switch field.kind {
        case .boolean:
            Toggle(field.name, isOn: Binding(
                get: { value == .boolean(true) },
                set: { save(.boolean($0), to: field, on: record) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        case .choice where !field.options.isEmpty:
            let chosen: SpaceOption? = {
                guard case .text(let id) = value else { return nil }
                return field.options.first { $0.id == id }
            }()
            Menu {
                ForEach(field.options) { option in
                    Button(option.name) { save(.text(option.id), to: field, on: record) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(chosen?.name ?? "Choose")
                        .font(CraftFont.body)
                        .foregroundStyle(chosen == nil ? .tertiary : .primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(field.name)
        case .rating:
            let stars: Double = { if case .number(let number) = value { return number } else { return 0 } }()
            SpaceStars(stars: stars, accent: accent) { save(.number($0), to: field, on: record) }
        default:
            let text = value.map { schema.display($0, for: field, titles: titles) } ?? ""
            Text(text.isEmpty ? "Empty" : text)
                .font(CraftFont.body)
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save(_ value: SpaceValue, to field: SpaceField, on record: SpaceRecord) {
        try? SpaceStore.update(record, values: [field.id: value], in: context)
    }

    private func groupRow(_ row: [String: SpaceValue], index: Int, field: SpaceField, schema: SpaceSchema, titles: [String: String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if field.isOrdered {
                Text("\(index + 1)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, alignment: .leading)
            }
            ForEach(field.fields.filter { !$0.isRemoved }) { column in
                if let value = row[column.id] {
                    if column.kind == .quantity || column.kind == .number {
                        Text(schema.display(value, for: column))
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 84, alignment: .leading)
                    } else {
                        Text(schema.display(value, for: column, titles: titles))
                            .font(CraftFont.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .textSelection(.enabled)
    }
}

struct SpaceRecordToolbar: View {
    var recordID: UUID

    @Environment(AppModel.self) private var app
    @Query private var records: [SpaceRecord]

    var body: some View {
        if let record = records.first(where: { $0.id == recordID }) {
            Button {
                app.present(.editRecord(record))
            } label: {
                Text("Edit")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())
            .help("Edit this record")
        }
    }
}

/// Logs an event with its values, or changes one already logged: when it happened and what it recorded.
struct SpaceEventForm: View {
    var type: SpaceType
    var record: SpaceRecord?
    var event: SpaceEvent?

    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @State private var date = Date.now
    @State private var values: [String: SpaceValue] = [:]
    @State private var error = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(event == nil ? "Log \(type.name.lowercased())" : "Edit \(type.name.lowercased())")
                .font(CraftFont.title)

            ModalScroll {
                VStack(alignment: .leading, spacing: 16) {
                    ModalControlRow("When") {
                        DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                    ForEach(type.schema.liveFields.filter { $0.kind != .calc && $0.kind != .image }) { field in
                        SpaceFieldEditor(
                            field: field,
                            spaceKey: type.spaceIDString,
                            value: Binding(get: { values[field.id] }, set: { values[field.id] = $0 }),
                            importImage: { _ in nil }
                        )
                    }
                }
            }

            if !error.isEmpty {
                Text(error)
                    .font(CraftFont.caption)
                    .foregroundStyle(.red)
            }

            ModalFooter(actionTitle: event == nil ? "Log" : "Save", actionEnabled: true, action: save) {
                if event != nil {
                    ModalFooterButton(title: "Delete", role: .destructive) {
                        if let event { try? SpaceStore.delete(event, in: context) }
                        modalDismiss()
                    }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let event {
                date = event.occurredAt
                let schema = type.schema
                values = event.values.filter { schema.field($0.key)?.isRemoved == false }
            }
        }
    }

    private func save() {
        let cleaned = SpaceRecordForm.cleaned(values)
        do {
            if let event {
                try SpaceStore.update(event, at: date, values: cleaned, in: context)
            } else if let record {
                try SpaceStore.logEvent(of: type, at: date, values: cleaned, about: [record], in: context)
            }
            modalDismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The schema-generated form for creating and editing a record by hand.
struct SpaceRecordForm: View {
    var type: SpaceType
    var record: SpaceRecord?

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusName: Bool
    @State private var title = ""
    @State private var values: [String: SpaceValue] = [:]
    @State private var error = ""
    @State private var loaded = false
    /// Owns images picked in this form until it is saved, so they are not swept as orphans.
    @State private var formID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(record == nil ? "New in \(type.name)" : "Edit")
                .font(CraftFont.title)

            ModalScroll {
                VStack(alignment: .leading, spacing: 16) {
                    if type.role != .settings {
                        ModalField("Name") {
                            TextField("Name", text: $title)
                                .textFieldStyle(.plain)
                                .focused($focusName)
                        }
                    }
                    ForEach(type.schema.liveFields.filter { $0.kind != .calc }) { field in
                        SpaceFieldEditor(
                            field: field,
                            spaceKey: type.spaceIDString,
                            value: binding(field.id),
                            importImage: importImage,
                            importFile: importFile
                        )
                    }
                    let worked = type.schema.liveFields.filter { $0.kind == .calc }
                    if !worked.isEmpty {
                        Text("\(worked.map(\.name).formatted(.list(type: .and))) \(worked.count == 1 ? "is" : "are") worked out for you.")
                            .font(CraftFont.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !error.isEmpty {
                Text(error)
                    .font(CraftFont.caption)
                    .foregroundStyle(.red)
            }

            ModalFooter(actionTitle: record == nil ? "Create" : "Save", actionEnabled: canSave, action: save) {
                if record != nil, type.role != .settings {
                    ModalFooterButton(title: "Delete", role: .destructive, action: delete)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            title = record?.title ?? ""
            let schema = type.schema
            if record == nil { values = schema.defaults() }
            guard record != nil else {
                focusName = true
                return
            }
            values = (record?.values ?? [:]).filter {
                guard let field = schema.field($0.key) else { return false }
                return !field.isRemoved && field.kind != .calc
            }
            focusName = record == nil
        }
        .onDisappear {
            // Saved images are claimed by the record by now. Anything else was abandoned.
            try? FileStore.default(context: context).release(ownerKind: .spaceForm, ownerID: formID)
        }
    }

    /// Copies a picked file into the file store and returns its asset id.
    private func importImage(_ url: URL) -> String? {
        let store = FileStore.default(context: context)
        do {
            let asset = try store.importFile(url: url, ownerKind: .spaceForm, ownerID: formID, orderIndex: 0)
            guard asset.kind == .image else {
                try? store.release(assetID: asset.id, ownerKind: .spaceForm, ownerID: formID)
                error = "\(url.lastPathComponent) is not an image."
                return nil
            }
            error = ""
            return SpaceJSON.key(asset.id)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Copies any picked file into the file store and returns its asset id.
    private func importFile(_ url: URL) -> String? {
        do {
            let asset = try FileStore.default(context: context).importFile(url: url, ownerKind: .spaceForm, ownerID: formID, orderIndex: 0)
            error = ""
            return SpaceJSON.key(asset.id)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func binding(_ id: String) -> Binding<SpaceValue?> {
        Binding(get: { values[id] }, set: { values[id] = $0 })
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = SpaceRecordForm.cleaned(values)
        do {
            if let record {
                try SpaceStore.replaceValues(of: record, title: name, values: cleaned, in: context)
            } else {
                let created = try SpaceStore.createRecord(of: type, title: name, values: cleaned, in: context)
                if let spaceID = created.spaceID {
                    app.navigate(to: .spaceRecord(space: spaceID, record: created.id), newTab: false)
                }
            }
            modalDismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() {
        guard let record else { return }
        let spaceID = record.spaceID
        try? SpaceStore.delete(record, in: context)
        if let spaceID {
            app.navigate(to: .space(spaceID), newTab: false)
        }
        modalDismiss()
    }

    /// Drops blank text and empty group rows so nothing hollow is stored.
    static func cleaned(_ values: [String: SpaceValue]) -> [String: SpaceValue] {
        var result: [String: SpaceValue] = [:]
        for (id, value) in values {
            switch value {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result[id] = .text(trimmed) }
            case .rows(let rows):
                let kept = rows.map(cleaned).filter { !$0.isEmpty }
                if !kept.isEmpty { result[id] = .rows(kept) }
            default:
                result[id] = value
            }
        }
        return result
    }
}

private struct SpaceFieldEditor: View {
    var field: SpaceField
    var spaceKey: String
    @Binding var value: SpaceValue?
    var importImage: (URL) -> String?
    var importFile: (URL) -> String? = { _ in nil }
    @State private var choosingImage = false
    @State private var choosingFile = false

    var body: some View {
        switch field.kind {
        case .text, .url:
            ModalField(field.name) { SpaceCell(field: field, value: $value) }
        case .money, .duration:
            ModalField(field.name, boxed: false) {
                SpaceCell(field: field, value: $value)
                    .boxed()
                    .fixedSize()
            }
        case .rating:
            ModalControlRow(field.name) {
                SpaceStars(stars: { if case .number(let stars) = value { stars } else { 0 } }(), accent: .primary) { picked in
                    value = picked == 0 ? nil : .number(picked)
                }
            }
        case .time:
            ModalControlRow(field.name) {
                if case .number(let minutes) = value {
                    HStack(spacing: 8) {
                        DatePicker("", selection: Binding(
                            get: { SpaceClock.date(minutes) },
                            set: { value = .number(SpaceClock.minutes($0)) }
                        ), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        Button("Clear") { value = nil }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Add time") { value = .number(9 * 60) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        case .dateRange:
            ModalControlRow(field.name) {
                if case .text(let raw) = value, let range = SpaceDateRange(raw) {
                    HStack(spacing: 6) {
                        DatePicker("", selection: Binding(
                            get: { range.start },
                            set: { value = .text(SpaceDateRange(start: $0, end: max($0, range.end)).raw) }
                        ), displayedComponents: .date)
                        .labelsHidden()
                        Text("to")
                            .foregroundStyle(.tertiary)
                        DatePicker("", selection: Binding(
                            get: { range.end },
                            set: { value = .text(SpaceDateRange(start: min($0, range.start), end: $0).raw) }
                        ), displayedComponents: .date)
                        .labelsHidden()
                        Button("Clear") { value = nil }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Add dates") {
                        let today = Calendar.current.startOfDay(for: .now)
                        value = .text(SpaceDateRange(start: today, end: today).raw)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        case .tags:
            ModalField(field.name, boxed: false) {
                let chosen: [String] = { if case .text(let raw) = value { SpaceTags.ids(raw) } else { [] } }()
                FlowTags(options: field.options, chosen: chosen) { id in
                    var next = chosen
                    if let index = next.firstIndex(of: id) { next.remove(at: index) } else { next.append(id) }
                    // Kept in the order the options are listed, so the same picks always store the same text.
                    let ordered = field.options.map(\.id).filter(next.contains)
                    value = ordered.isEmpty ? nil : .text(SpaceTags.raw(ordered))
                }
            }
        case .file:
            ModalField(field.name, boxed: false) {
                HStack(spacing: 12) {
                    if case .text(let assetID) = value {
                        SpaceFileButton(assetID: assetID, accent: .primary)
                        Button("Replace") { choosingFile = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        Button("Remove") { value = nil }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Choose a file") { choosingFile = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, let id = importFile(url) else { return false }
                    value = .text(id)
                    return true
                }
                .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
                    if case .success(let url) = result, let id = importFile(url) {
                        value = .text(id)
                    }
                }
            }
        case .richText:
            ModalField(field.name) {
                TextField("", text: text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
            }
        case .number, .quantity:
            ModalField(field.name, boxed: false) {
                SpaceCell(field: field, value: $value)
                    .boxed()
                    .frame(maxWidth: 200, alignment: .leading)
            }
        case .boolean:
            ModalControlRow(field.name) {
                Toggle("", isOn: Binding(
                    get: { if case .boolean(let flag) = value { flag } else { false } },
                    set: { value = .boolean($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        case .date:
            ModalControlRow(field.name) {
                if case .date(let date) = value {
                    HStack(spacing: 8) {
                        DatePicker("", selection: Binding(get: { date }, set: { value = .date($0) }), displayedComponents: .date)
                            .labelsHidden()
                        Button("Clear") { value = nil }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Add date") { value = .date(Calendar.current.startOfDay(for: .now)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        case .choice:
            ModalField(field.name, boxed: false) {
                HStack(spacing: 6) {
                    ForEach(field.options) { option in
                        let isSelected = value == .text(option.id)
                        Button {
                            value = isSelected ? nil : .text(option.id)
                        } label: {
                            ChoiceCapsule(title: option.name, isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .link:
            ModalField(field.name, boxed: false) {
                SpaceCell(field: field, spaceKey: spaceKey, value: $value)
                    .boxed()
                    .frame(maxWidth: 280, alignment: .leading)
            }
        case .calc:
            EmptyView()
        case .schedule:
            ModalField(field.name, boxed: false) { SpaceScheduleEditor(value: $value) }
        case .image:
            ModalField(field.name, boxed: false) { imageEditor }
        case .group:
            ModalField(field.name, boxed: false) { groupEditor }
        }
    }

    private var text: Binding<String> {
        Binding(
            get: { if case .text(let text) = value { text } else { "" } },
            set: { value = $0.isEmpty ? nil : .text($0) }
        )
    }

    private var imageEditor: some View {
        let assetID: String? = { if case .text(let id) = value { id } else { nil } }()
        return HStack(spacing: 12) {
            Button {
                choosingImage = true
            } label: {
                Group {
                    if assetID != nil {
                        SpaceImageView(assetID: assetID, tint: .secondary, cornerRadius: 10)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: 56, height: 56)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(assetID == nil ? "Choose an image" : "Replace the image")

            if assetID == nil {
                Text("Drop an image or choose a file")
                    .font(CraftFont.body)
                    .foregroundStyle(.tertiary)
            } else {
                Button("Replace") { choosingImage = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Remove") { value = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, let id = importImage(url) else { return false }
            value = .text(id)
            return true
        }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let id = importImage(url) {
                value = .text(id)
            }
        }
    }

    private var rows: [[String: SpaceValue]] {
        if case .rows(let rows) = value { rows } else { [] }
    }

    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 6) {
                    if field.isOrdered {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .leading)
                    }
                    ForEach(field.fields.filter { !$0.isRemoved && $0.kind != .calc }) { column in
                        SpaceCell(field: column, spaceKey: spaceKey, value: cell(index, column.id))
                            .boxed()
                            .frame(maxWidth: column.kind == .text ? .infinity : nil)
                    }
                    Button {
                        var next = rows
                        next.remove(at: index)
                        value = next.isEmpty ? nil : .rows(next)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove row")
                }
            }
            Button {
                value = .rows(rows + [[:]])
            } label: {
                Label("Add row", systemImage: "plus")
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func cell(_ index: Int, _ id: String) -> Binding<SpaceValue?> {
        Binding(
            get: { index < rows.count ? rows[index][id] : nil },
            set: { new in
                var next = rows
                guard index < next.count else { return }
                next[index][id] = new
                value = .rows(next)
            }
        )
    }
}

/// One single-value input, used on its own and inside group rows.
private struct SpaceCell: View {
    var field: SpaceField
    var spaceKey: String = ""
    @Binding var value: SpaceValue?

    var body: some View {
        switch field.kind {
        case .choice:
            SpacePickerMenu(
                placeholder: field.name,
                options: field.options.map { ($0.id, $0.name) },
                value: $value
            )
        case .link:
            SpaceLinkPicker(field: field, spaceKey: spaceKey, value: $value)
        case .number, .rating, .time:
            TextField(field.name, value: number, format: .number)
                .textFieldStyle(.plain)
                .frame(width: 72)
        case .money:
            HStack(spacing: 6) {
                TextField(field.name, value: number, format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 84)
                Text(field.unit.isEmpty ? (Locale.current.currency?.identifier ?? "USD") : field.unit.uppercased())
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
        case .duration:
            HStack(spacing: 4) {
                TextField("0", value: hours, format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 32)
                Text("h").foregroundStyle(.tertiary)
                TextField("0", value: minutes, format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 32)
                Text("m").foregroundStyle(.tertiary)
            }
        case .quantity:
            HStack(spacing: 6) {
                TextField("Amount", value: amount, format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 56)
                Rectangle()
                    .fill(CraftColor.hairline)
                    .frame(width: 1, height: 14)
                TextField("Unit", text: unit)
                    .textFieldStyle(.plain)
                    .frame(width: 56)
            }
        default:
            TextField(field.name, text: text)
                .textFieldStyle(.plain)
        }
    }

    private var text: Binding<String> {
        Binding(
            get: { if case .text(let text) = value { text } else { "" } },
            set: { value = $0.isEmpty ? nil : .text($0) }
        )
    }

    private var number: Binding<Double?> {
        Binding(
            get: { if case .number(let number) = value { number } else { nil } },
            set: { value = $0.map(SpaceValue.number) }
        )
    }

    private var totalMinutes: Int {
        if case .number(let number) = value { Int(number.rounded()) } else { 0 }
    }

    private var hours: Binding<Int?> {
        Binding(
            get: { value == nil ? nil : totalMinutes / 60 },
            set: { value = .number(Double(max($0 ?? 0, 0) * 60 + totalMinutes % 60)) }
        )
    }

    private var minutes: Binding<Int?> {
        Binding(
            get: { value == nil ? nil : totalMinutes % 60 },
            set: { value = .number(Double(totalMinutes / 60 * 60 + min(max($0 ?? 0, 0), 59))) }
        )
    }

    private var quantity: SpaceQuantity? {
        if case .quantity(let quantity) = value { quantity } else { nil }
    }

    private var amount: Binding<Double?> {
        Binding(
            get: { quantity?.amount },
            set: { new in
                value = new.map { .quantity(SpaceQuantity(amount: $0, unit: quantity?.unit ?? "", scales: quantity?.scales ?? true)) }
            }
        )
    }

    private var unit: Binding<String> {
        Binding(
            get: { quantity?.unit ?? "" },
            set: { value = .quantity(SpaceQuantity(amount: quantity?.amount ?? 0, unit: $0, scales: quantity?.scales ?? true)) }
        )
    }
}

private extension View {
    func boxed() -> some View {
        self
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(CraftColor.hairline))
    }
}


/// A pop-up of named options that stores the chosen id as text.
private struct SpacePickerMenu: View {
    var placeholder: String
    var options: [(id: String, name: String)]
    @Binding var value: SpaceValue?

    private var chosen: String? {
        guard case .text(let id) = value else { return nil }
        return options.first { $0.id == id }?.name
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button(option.name) { value = .text(option.id) }
            }
            if value != nil {
                Divider()
                Button("None") { value = nil }
            }
        } label: {
            HStack(spacing: 6) {
                Text(chosen ?? placeholder)
                    .foregroundStyle(chosen == nil ? .tertiary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(minWidth: 96)
    }
}

/// Picks one record of the type a link field points at. Only records of that type are offered.
private struct SpaceLinkPicker: View {
    var field: SpaceField
    var spaceKey: String
    @Binding var value: SpaceValue?

    @Query(sort: \SpaceType.createdAt) private var types: [SpaceType]
    @Query(sort: \SpaceRecord.title) private var records: [SpaceRecord]

    var body: some View {
        let target = types.first { $0.spaceIDString == spaceKey && $0.key == field.target }
        let typeKey = target.map { SpaceJSON.key($0.id) }
        let options = records
            .filter { $0.typeIDString == typeKey }
            .map { (id: SpaceJSON.key($0.id), name: $0.displayTitle) }
        SpacePickerMenu(
            placeholder: options.isEmpty ? "No \(target?.name.lowercased() ?? "records") yet" : field.name,
            options: options,
            value: $value
        )
        .disabled(options.isEmpty)
    }
}


/// Every day, some number of times a week, or chosen weekdays.
private struct SpaceScheduleEditor: View {
    @Binding var value: SpaceValue?

    private var schedule: SpaceSchedule? {
        if case .text(let raw) = value { SpaceSchedule(raw) } else { nil }
    }

    private func set(_ rule: SpaceSchedule.Rule?) {
        value = rule.map { .text(SpaceSchedule($0).raw) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                option("Every day", isOn: schedule?.rule == .daily) { set(.daily) }
                option("Times a week", isOn: isPerWeek) { set(.perWeek(3)) }
                option("Set days", isOn: isWeekdays) { set(.weekdays([2, 4, 6])) }
            }
            if case .perWeek(let times) = schedule?.rule {
                Stepper(times == 1 ? "Once a week" : "\(times) times a week", value: Binding(
                    get: { times },
                    set: { set(.perWeek(min(max($0, 1), 6))) }
                ), in: 1...6)
                .font(CraftFont.body)
                .fixedSize()
            }
            if case .weekdays(let days) = schedule?.rule {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let isOn = days.contains(day)
                        Button {
                            var next = days
                            if isOn { next.remove(day) } else { next.insert(day) }
                            if !next.isEmpty { set(.weekdays(next)) }
                        } label: {
                            ChoiceCapsule(title: SpaceSchedule.dayNames[day - 1].capitalized, isSelected: isOn)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var isPerWeek: Bool {
        if case .perWeek = schedule?.rule { true } else { false }
    }

    private var isWeekdays: Bool {
        if case .weekdays = schedule?.rule { true } else { false }
    }

    private func option(_ title: String, isOn: Bool, choose: @escaping () -> Void) -> some View {
        Button {
            if isOn { set(nil) } else { choose() }
        } label: {
            ChoiceCapsule(title: title, isSelected: isOn)
        }
        .buttonStyle(.plain)
    }
}


/// Options as capsules that wrap onto more lines. Any number can be on.
private struct FlowTags: View {
    var options: [SpaceOption]
    var chosen: [String]
    var toggle: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(options) { option in
                Button {
                    toggle(option.id)
                } label: {
                    ChoiceCapsule(title: option.name, isSelected: chosen.contains(option.id))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
