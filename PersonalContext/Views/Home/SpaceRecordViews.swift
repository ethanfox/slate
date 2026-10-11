import SwiftData
import SwiftUI

/// The plain detail view every record falls back to.
struct SpaceRecordView: View {
    var spaceID: UUID
    var recordID: UUID

    @Environment(\.modelContext) private var context
    @Query private var records: [SpaceRecord]
    @Query private var types: [SpaceType]
    @Query private var spaces: [Space]
    @Query private var events: [SpaceEvent]
    @Query private var screens: [SpaceScreen]
    @State private var screenState = SpaceScreenState()

    private var record: SpaceRecord? {
        records.first { $0.id == recordID }
    }

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 24) {
                    if let record, let type = types.first(where: { $0.id == record.typeID }) {
                        if let space = spaces.first(where: { $0.id == spaceID }),
                           let definition = SpaceScreens.definition(for: type, kind: .detail, screens: screens, types: types) {
                            SpaceScreenView(definition: definition, context: screenContext(record, type: type, space: space))
                        } else {
                            VStack(alignment: .leading, spacing: 24) {
                                Text(record.displayTitle)
                                    .font(.system(size: 28, weight: .semibold))
                                content(record, schema: type.schema)
                            }
                            .frame(maxWidth: 640, alignment: .leading)
                        }
                    } else {
                        EmptyLine(text: "This record no longer exists.")
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func screenContext(_ record: SpaceRecord, type: SpaceType, space: Space) -> SpaceScreenContext {
        let spaceKey = type.spaceIDString
        return SpaceScreenContext(
            kind: .detail,
            type: type,
            schema: type.schema,
            eventTypes: SpaceScreens.eventTypes(beside: type, in: types),
            records: [],
            events: events.filter { $0.spaceIDString == spaceKey },
            record: record,
            accent: space.gradient.accent,
            state: screenState,
            context: context,
            open: { _ in }
        )
    }

    /// The plain detail, shown when a type has no screen or its screen no longer fits.
    @ViewBuilder
    private func content(_ record: SpaceRecord, schema: SpaceSchema) -> some View {
        let values = record.values
        let filled = schema.liveFields.filter { values[$0.id] != nil }
        if filled.isEmpty {
            EmptyLine(text: "No details yet. Use Edit to add some.")
        }
        ForEach(filled.filter { $0.kind == .image }) { field in
            if case .text(let assetID) = values[field.id] {
                SpaceImageView(assetID: assetID, tint: .secondary)
                    .frame(width: 220, height: 160)
            }
        }
        let single = filled.filter { $0.kind != .group && $0.kind != .richText && $0.kind != .image }
        if !single.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .topLeading)], alignment: .leading, spacing: 14) {
                ForEach(single) { field in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(field.name)
                            .font(CraftFont.caption)
                            .foregroundStyle(.tertiary)
                        Text(values[field.id].map { schema.display($0, for: field) } ?? "")
                            .font(CraftFont.body)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        ForEach(filled.filter { $0.kind == .group || $0.kind == .richText }) { field in
            VStack(alignment: .leading, spacing: 8) {
                Text(field.name)
                    .font(CraftFont.section)
                    .foregroundStyle(.secondary)
                if case .rows(let rows) = values[field.id] {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            groupRow(row, index: index, field: field, schema: schema)
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

    private func groupRow(_ row: [String: SpaceValue], index: Int, field: SpaceField, schema: SpaceSchema) -> some View {
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
                        Text(schema.display(value, for: column))
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
                    ModalField("Name") {
                        TextField("Name", text: $title)
                            .textFieldStyle(.plain)
                            .focused($focusName)
                    }
                    ForEach(type.schema.liveFields) { field in
                        SpaceFieldEditor(field: field, value: binding(field.id), importImage: importImage)
                    }
                }
            }

            if !error.isEmpty {
                Text(error)
                    .font(CraftFont.caption)
                    .foregroundStyle(.red)
            }

            ModalFooter(actionTitle: record == nil ? "Create" : "Save", actionEnabled: canSave, action: save) {
                if record != nil {
                    ModalFooterButton(title: "Delete", role: .destructive, action: delete)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            title = record?.title ?? ""
            let schema = type.schema
            values = (record?.values ?? [:]).filter { schema.field($0.key)?.isRemoved == false }
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
    @Binding var value: SpaceValue?
    var importImage: (URL) -> String?
    @State private var choosingImage = false

    var body: some View {
        switch field.kind {
        case .text:
            ModalField(field.name) { SpaceCell(field: field, value: $value) }
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
                    ForEach(field.fields.filter { !$0.isRemoved }) { column in
                        SpaceCell(field: column, value: cell(index, column.id))
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
    @Binding var value: SpaceValue?

    var body: some View {
        switch field.kind {
        case .number:
            TextField(field.name, value: number, format: .number)
                .textFieldStyle(.plain)
                .frame(width: 72)
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
