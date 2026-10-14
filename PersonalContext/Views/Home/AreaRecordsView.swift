import SwiftData
import SwiftUI

/// How an Area's records are laid out. Membrae picks one for each type; the page does not offer the others.
enum AreaRecordsLayout: String, CaseIterable, Identifiable {
    case table
    case cards
    case board
    case calendar

    var id: String { rawValue }
}

/// What gets logged in an Area, as far as a view needs to know: which entries, and a number to plot if there is one.
struct AreaLog: Equatable {
    var eventKey: String
    var name: String
    /// A number each entry records, such as a weight. Nil when entries are only counted.
    var numberField: String?
}

/// One record, with what each field shows as text.
struct AreaRecordRow: Identifiable {
    var record: SpaceRecord
    var title: String
    var imageID: String?
    /// Stars out of five, when the type has a rating.
    var rating: Double?
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

    static func ratingField(_ schema: SpaceSchema) -> SpaceField? {
        schema.liveFields.first { $0.kind == .rating }
    }

    static func imageField(_ schema: SpaceSchema) -> SpaceField? {
        schema.liveFields.first { $0.kind == .image }
    }

    /// Fields with a fixed set of answers, which is what a filter needs.
    static func filterFields(_ schema: SpaceSchema) -> [SpaceField] {
        schema.liveFields.filter { ($0.kind == .choice || $0.kind == .tags) && !$0.options.isEmpty }
    }

    /// The stage or status a board groups by: the first choice field.
    static func boardField(_ schema: SpaceSchema) -> SpaceField? {
        schema.liveFields.first { $0.kind == .choice && !$0.options.isEmpty }
    }

    /// The date a calendar places records on: the first date field.
    static func dateField(_ schema: SpaceSchema) -> SpaceField? {
        schema.liveFields.first { $0.kind == .date }
    }

    /// What to chart and list: the first kind of entry that records a number, else the first kind at all.
    static func log(from eventTypes: [(key: String, name: String, schema: SpaceSchema)]) -> AreaLog? {
        let numeric: [SpaceFieldKind] = [.number, .money, .duration, .rating]
        for type in eventTypes {
            if let field = type.schema.liveFields.first(where: { numeric.contains($0.kind) }) {
                return AreaLog(eventKey: type.key, name: type.name, numberField: field.id)
            }
        }
        return eventTypes.first.map { AreaLog(eventKey: $0.key, name: $0.name, numberField: nil) }
    }

    /// The layouts the data suits. A table always works; cards need a picture or only a few details,
    /// a board a stage, a calendar a date.
    static func layouts(for schema: SpaceSchema, chosenCard: Bool = false) -> [AreaRecordsLayout] {
        var layouts: [AreaRecordsLayout] = [.table]
        if chosenCard || imageField(schema) != nil || columns(schema).count <= 4 { layouts.append(.cards) }
        if boardField(schema) != nil { layouts.append(.board) }
        if dateField(schema) != nil { layouts.append(.calendar) }
        return layouts
    }

    /// The one layout the page uses. What Membrae chose for the type wins while the data still suits it.
    /// Otherwise cards when there is a picture or cards were set up, a board when the type has a stage, else a table.
    static func layout(for schema: SpaceSchema, chosen: String = "", chosenCard: Bool = false) -> AreaRecordsLayout {
        if let chosen = AreaRecordsLayout(rawValue: chosen), layouts(for: schema, chosenCard: chosenCard).contains(chosen) {
            return chosen
        }
        if chosenCard || imageField(schema) != nil { return .cards }
        let stages = ["status", "stage", "state", "progress"]
        if let field = boardField(schema), stages.contains(field.name.lowercased()) { return .board }
        return .table
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
        var rating: Double?
        if let field = ratingField(schema), case .number(let stars) = values[field.id] {
            rating = stars
        }
        return AreaRecordRow(
            record: record,
            title: record.displayTitle,
            imageID: imageID,
            rating: rating,
            cells: cells,
            options: options
        )
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
    @State private var period = SpaceCalcRequest.Period.month
    /// How wide the card grid is, so the number of columns is worked out here and its changes can animate.
    @State private var cardsWidth: CGFloat = 0

    private var schema: SpaceSchema { context.schema }

    private var log: AreaLog? {
        AreaRecords.log(from: context.eventTypes.map { (key: $0.key, name: $0.name, schema: $0.schema) })
    }

    private var layout: AreaRecordsLayout {
        AreaRecords.layout(for: schema, chosen: context.type.layoutRaw, chosenCard: context.type.cardFields != nil)
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
            }

            // What is logged here is charted above the records, once there is something to chart.
            if !context.events.isEmpty {
                logged
            }

            if all.isEmpty {
                EmptyLine(text: "Nothing here yet. Tell Membrae what to add, or use New.")
            } else {
                controls
                if shown.isEmpty {
                    EmptyLine(text: "Nothing matches.")
                } else {
                    switch layout {
                    case .cards: cards(shown)
                    case .board: board(shown)
                    case .calendar: calendar(shown)
                    default: table(shown)
                    }
                }
            }
        }
        .onChange(of: context.type.id) { _, _ in
            search = ""
            filters = [:]
        }
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

    // MARK: Board, calendar, chart

    /// The same context with only the records the search and filters leave.
    private func narrowed(to shown: [AreaRecordRow]) -> SpaceScreenContext {
        var copy = context
        copy.records = shown.map(\.record)
        return copy
    }

    @ViewBuilder
    private func board(_ shown: [AreaRecordRow]) -> some View {
        if let field = AreaRecords.boardField(schema) {
            let subtitle = AreaRecords.columns(schema).filter { $0.id != field.id }.prefix(2).map(\.id)
            SpaceComponentView(
                component: SpaceComponent("board", ["by": .text(field.id), "subtitle": .list(Array(subtitle))]),
                context: narrowed(to: shown)
            )
        }
    }

    @ViewBuilder
    private func calendar(_ shown: [AreaRecordRow]) -> some View {
        if let field = AreaRecords.dateField(schema) {
            SpaceComponentView(
                component: SpaceComponent("month", ["date": .text(field.id)]),
                context: narrowed(to: shown)
            )
        }
    }

    /// Logging is about a record. With one record it is a button; with several, a menu to pick which.
    @ViewBuilder
    private func logButton(_ log: AreaLog) -> some View {
        if context.records.count == 1, let only = context.records.first {
            Button("Log \(log.name)") { context.log(log.eventKey, about: only) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(CraftColor.elevated, in: Capsule())
                .overlay(Capsule().stroke(CraftColor.hairline))
        } else if context.records.count > 1 {
            Menu("Log \(log.name)") {
                ForEach(context.records) { record in
                    Button(record.displayTitle) { context.log(log.eventKey, about: record) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var logged: some View {
        if let log {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(log.name)
                        .font(CraftFont.body)
                        .foregroundStyle(.secondary)
                    logButton(log)
                    Spacer(minLength: 8)
                    Picker("Period", selection: $period) {
                        Text("Week").tag(SpaceCalcRequest.Period.week)
                        Text("Month").tag(SpaceCalcRequest.Period.month)
                        Text("Year").tag(SpaceCalcRequest.Period.year)
                        Text("All").tag(SpaceCalcRequest.Period.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                var props: [String: SpaceProp] = ["events": .text(log.eventKey), "period": .text(period.rawValue)]
                let _ = log.numberField.map { props["field"] = .text($0) }
                SpaceComponentView(component: SpaceComponent("chart", props), context: context)
            }
        }
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
        // A rating is drawn as stars, so it does not also take one of the text lines.
        let chosen = context.type.cardFields
        let fields = chosen.map { ids in ids.compactMap { id in AreaRecords.columns(schema).first { $0.id == id } } }
        let details = fields.map { $0.filter { $0.kind != .rating } }
            ?? Array(AreaRecords.columns(schema).filter { $0.kind != .rating }.prefix(3))
        let showsRating = fields.map { $0.contains { $0.kind == .rating } } ?? true
        let portrait = context.portraitCards
        let (narrowest, widest): (CGFloat, CGFloat) = portrait ? (230, 300) : (280, 380)
        let across = max(1, Int((cardsWidth + 16) / (narrowest + 16)))
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 120, maximum: widest), spacing: 16, alignment: .top), count: across),
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(shown) { row in
                Button {
                    context.open(row.record)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .aspectRatio(portrait ? 3.0 / 4.0 : 16.0 / 9.0, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .overlay {
                                if row.imageID != nil {
                                    SpaceImageView(assetID: row.imageID, tint: context.accent, cornerRadius: 0)
                                } else {
                                    LiquidSand(colors: context.palette, seed: LiquidSand.seed(for: row.record.id))
                                }
                            }
                            .clipped()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if showsRating, let rating = row.rating, rating > 0 {
                                HStack(spacing: 1) {
                                    ForEach(1...5, id: \.self) { star in
                                        Image(systemName: Double(star) <= rating ? "star.fill" : "star")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Double(star) <= rating ? context.accent : Color.secondary.opacity(0.4))
                                    }
                                }
                                .accessibilityLabel("\(Int(rating)) of 5 stars")
                            }
                            ForEach(details) { field in
                                if let text = row.cells[field.id], !text.isEmpty {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(field.name)
                                            .foregroundStyle(.tertiary)
                                        Text(text)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .font(.system(size: 12))
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(CraftColor.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(CraftColor.hairline))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .opacity(row.record.isArchived ? 0.5 : 1)
                .contextMenu { menu(row.record) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardsWidth = $0 }
        .animation(.snappy(duration: 0.28), value: across)
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
