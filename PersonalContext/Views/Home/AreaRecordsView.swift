import SwiftData
import SwiftUI

/// How an Area's records are laid out. The app offers the ones that suit the data; nobody builds them.
enum AreaRecordsLayout: String, CaseIterable, Identifiable {
    case table
    case cards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .table: "Table"
        case .cards: "Cards"
        }
    }

    var symbol: String {
        switch self {
        case .table: "tablecells"
        case .cards: "square.grid.2x2"
        }
    }
}

/// One record, with what each field shows as text.
struct AreaRecordRow: Identifiable {
    var record: SpaceRecord
    var title: String
    var imageID: String?
    /// Field id to display text, for the fields worth a column.
    var cells: [String: String]
    /// Field id to the raw option id or ids, for the fields that can be filtered.
    var options: [String: [String]]

    var id: UUID { record.id }
}

enum AreaRecords {
    /// The most columns a table shows. The rest are on the record itself.
    static let columnLimit = 5

    /// Fields that hold one value worth reading in a row.
    static func columns(_ schema: SpaceSchema) -> [SpaceField] {
        schema.liveFields.filter { field in
            switch field.kind {
            case .group, .richText, .image, .file: false
            default: true
            }
        }
    }

    static func imageField(_ schema: SpaceSchema) -> SpaceField? {
        schema.liveFields.first { $0.kind == .image }
    }

    /// Fields with a fixed set of answers, which is what a filter needs.
    static func filterFields(_ schema: SpaceSchema) -> [SpaceField] {
        schema.liveFields.filter { ($0.kind == .choice || $0.kind == .tags) && !$0.options.isEmpty }
    }

    /// A table always works. Cards suit records with a picture or only a few details.
    static func layouts(for schema: SpaceSchema) -> [AreaRecordsLayout] {
        imageField(schema) != nil || columns(schema).count <= 4 ? [.table, .cards] : [.table]
    }

    static func preferred(for schema: SpaceSchema) -> AreaRecordsLayout {
        imageField(schema) == nil ? .table : .cards
    }

    static func row(
        _ record: SpaceRecord,
        schema: SpaceSchema,
        values: [String: SpaceValue],
        titles: [String: String]
    ) -> AreaRecordRow {
        var cells: [String: String] = [:]
        for field in columns(schema) {
            if let value = values[field.id] {
                cells[field.id] = schema.display(value, for: field, titles: titles)
            }
        }
        var options: [String: [String]] = [:]
        for field in filterFields(schema) {
            guard case .text(let raw) = values[field.id] else { continue }
            options[field.id] = field.kind == .tags ? SpaceTags.ids(raw) : [raw]
        }
        var imageID: String?
        if let image = imageField(schema), case .text(let asset) = values[image.id], !asset.isEmpty {
            imageID = asset
        }
        return AreaRecordRow(record: record, title: record.displayTitle, imageID: imageID, cells: cells, options: options)
    }

    /// Rows whose title or any shown value contains the search, and that carry every chosen option.
    static func filtered(_ rows: [AreaRecordRow], search: String, filters: [String: String]) -> [AreaRecordRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            for (field, option) in filters where !(row.options[field] ?? []).contains(option) {
                return false
            }
            guard !query.isEmpty else { return true }
            if row.title.localizedCaseInsensitiveContains(query) { return true }
            return row.cells.values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// Every record of one type in an Area, as a table or as cards, with search and filters.
struct AreaRecordsView: View {
    var context: SpaceScreenContext
    var onDelete: (SpaceRecord) -> Void

    @State private var search = ""
    @State private var filters: [String: String] = [:]
    @State private var chosenLayout: AreaRecordsLayout?

    private var schema: SpaceSchema { context.schema }

    private var layouts: [AreaRecordsLayout] { AreaRecords.layouts(for: schema) }

    private var layout: AreaRecordsLayout {
        if let chosenLayout, layouts.contains(chosenLayout) { return chosenLayout }
        return AreaRecords.preferred(for: schema)
    }

    private var rows: [AreaRecordRow] {
        context.records.map { record in
            AreaRecords.row(record, schema: schema, values: context.values(record), titles: context.titles)
        }
    }

    var body: some View {
        let all = rows
        let shown = AreaRecords.filtered(all, search: search, filters: filters)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(context.type.name)
                    .font(.system(size: 22, weight: .semibold))
                Text("\(all.count)")
                    .font(CraftFont.body)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 16)
                if layouts.count > 1 {
                    layoutSwitch
                }
            }

            if !all.isEmpty {
                controls
            }

            if all.isEmpty {
                EmptyLine(text: "Nothing here yet. Tell Membrae what to add, or use New.")
            } else if shown.isEmpty {
                EmptyLine(text: "Nothing matches.")
            } else {
                switch layout {
                case .table: table(shown)
                case .cards: cards(shown)
                }
            }
        }
        .onChange(of: context.type.id) { _, _ in
            search = ""
            filters = [:]
            chosenLayout = nil
        }
    }

    private var layoutSwitch: some View {
        HStack(spacing: 2) {
            ForEach(layouts) { option in
                Button {
                    chosenLayout = option
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(layout == option ? .primary : .tertiary)
                        .frame(width: 30, height: 24)
                        .background(
                            layout == option ? CraftColor.selection : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.title)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(layout == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(CraftColor.hairline))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Search \(context.type.name.lowercased())", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .frame(maxWidth: 320, alignment: .leading)
            .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(CraftColor.hairline))

            ForEach(AreaRecords.filterFields(schema)) { field in
                filterMenu(field)
            }
            Spacer(minLength: 0)
        }
    }

    private func filterMenu(_ field: SpaceField) -> some View {
        let chosen = filters[field.id].flatMap { id in field.options.first { $0.id == id } }
        return Menu {
            Button("Any") { filters[field.id] = nil }
            Divider()
            ForEach(field.options) { option in
                Button(option.name) { filters[field.id] = option.id }
            }
        } label: {
            HStack(spacing: 5) {
                Text(chosen.map { "\(field.name): \($0.name)" } ?? field.name)
                    .font(.system(size: 12, weight: chosen == nil ? .regular : .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(chosen == nil ? .secondary : .primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(CraftColor.elevated, in: Capsule())
            .overlay(Capsule().stroke(chosen == nil ? CraftColor.hairline : context.accent.opacity(0.6)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Filter by \(field.name)")
    }

    // MARK: Table

    private func table(_ shown: [AreaRecordRow]) -> some View {
        let columns = Array(AreaRecords.columns(schema).prefix(AreaRecords.columnLimit))
        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns) { field in
                    Text(field.name)
                        .lineLimit(1)
                        .frame(width: 130, alignment: Self.alignment(for: field))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
            Hairline()
            ForEach(shown) { row in
                Button {
                    context.open(row.record)
                } label: {
                    HStack(spacing: 16) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(columns) { field in
                            Text(row.cells[field.id] ?? "")
                                .font(CraftFont.body)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .frame(width: 130, alignment: Self.alignment(for: field))
                        }
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(row.record.isArchived ? 0.5 : 1)
                .contextMenu { menu(row.record) }
                Hairline()
            }
        }
    }

    /// Numbers read best lined up on the right.
    private static func alignment(for field: SpaceField) -> Alignment {
        switch field.kind {
        case .number, .calc, .money, .quantity, .duration, .rating: .trailing
        default: .leading
        }
    }

    // MARK: Cards

    private func cards(_ shown: [AreaRecordRow]) -> some View {
        let details = Array(AreaRecords.columns(schema).prefix(3))
        let hasImages = AreaRecords.imageField(schema) != nil
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14, alignment: .top)],
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(shown) { row in
                Button {
                    context.open(row.record)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        if hasImages {
                            SpaceImageView(assetID: row.imageID, tint: context.accent, cornerRadius: 0)
                                .frame(height: 120)
                                .frame(maxWidth: .infinity)
                                .clipped()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            ForEach(details) { field in
                                if let text = row.cells[field.id], !text.isEmpty {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(field.name)
                                            .foregroundStyle(.tertiary)
                                        Text(text)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .font(CraftFont.caption)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(CraftColor.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(CraftColor.hairline))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .opacity(row.record.isArchived ? 0.5 : 1)
                .contextMenu { menu(row.record) }
            }
        }
    }

    @ViewBuilder
    private func menu(_ record: SpaceRecord) -> some View {
        SpaceRecordMenu(record: record, context: context)
        Divider()
        Button(role: .destructive) {
            onDelete(record)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}
