import Charts
import SwiftData
import SwiftUI

/// What a viewer changes while looking at a screen. None of it is saved.
@Observable
final class SpaceScreenState {
    var search = ""
    var filters: [String: String] = [:]
    var steppers: [String: Double] = [:]
    var ticked: Set<String> = []
    var month = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    /// The day a day, week, or month view is on.
    var day = Calendar.current.startOfDay(for: .now)
    /// A sheet's sort, once the viewer clicks a heading.
    var sort: String?
}

/// Everything a component needs to draw itself and act.
struct SpaceScreenContext {
    var kind: SpaceScreenKind
    var type: SpaceType
    var schema: SpaceSchema
    var eventTypes: [SpaceType]
    var records: [SpaceRecord]
    var events: [SpaceEvent]
    var record: SpaceRecord?
    /// Record ids to names, for link fields.
    var titles: [String: String] = [:]
    /// Reaches linked and settings records, so calc fields can be worked out.
    var lookup: SpaceLookup?
    var accent: Color
    var state: SpaceScreenState
    var context: ModelContext
    var open: (SpaceRecord) -> Void
    var present: (AppModal) -> Void = { _ in }

    /// A record's values with calc fields filled in.
    func values(_ record: SpaceRecord?) -> [String: SpaceValue] {
        guard let record else { return [:] }
        return lookup?.resolved(record) ?? record.values
    }

    func eventType(_ key: String?) -> SpaceType? {
        guard let key else { return nil }
        return eventTypes.first { $0.key == key }
    }

    /// Events of one type, newest first, about `record` when given.
    func events(_ key: String?, about record: SpaceRecord?) -> [SpaceEvent] {
        guard let type = eventType(key) else { return [] }
        let typeKey = SpaceJSON.key(type.id)
        let recordKey = record.map { SpaceJSON.key($0.id) }
        return events
            .filter { $0.typeIDString == typeKey && (recordKey == nil || $0.recordIDsRaw.contains(recordKey!)) }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    /// Records after the search box and filter chips.
    var visibleRecords: [SpaceRecord] {
        let query = state.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            if !query.isEmpty, !record.title.localizedCaseInsensitiveContains(query) { return false }
            let values = record.values
            for (field, option) in state.filters where values[field] != .text(option) {
                return false
            }
            return true
        }
    }

    /// Something to order records by: a number where the field has one, else its text.
    private func sortKey(_ record: SpaceRecord, _ id: String) -> (number: Double?, text: String)? {
        if id == "title" { return (nil, record.displayTitle) }
        if id == "updated" { return (record.updatedAt.timeIntervalSince1970, "") }
        guard let field = schema.field(id), let value = values(record)[id] else { return nil }
        switch value {
        case .number(let number): return (number, "")
        case .quantity(let quantity): return (quantity.amount, "")
        case .date(let date): return (date.timeIntervalSince1970, "")
        case .boolean(let flag): return (flag ? 1 : 0, "")
        default: return (nil, schema.display(value, for: field, titles: titles))
        }
    }

    /// `sort` is a field id, `title`, or `updated`, with `-` in front for the reverse. Records without a value go last.
    func sorted(_ records: [SpaceRecord], by sort: String?) -> [SpaceRecord] {
        guard let sort, !sort.isEmpty else { return records }
        let descending = sort.hasPrefix("-")
        let id = descending ? String(sort.dropFirst()) : sort
        let keyed = records.map { ($0, sortKey($0, id)) }
        return keyed.sorted { left, right in
            guard let a = left.1 else { return false }
            guard let b = right.1 else { return true }
            let ascending: Bool
            if let x = a.number, let y = b.number {
                ascending = x < y
            } else {
                ascending = a.text.localizedCaseInsensitiveCompare(b.text) == .orderedAscending
            }
            return descending ? !ascending && (a.number != b.number || a.text != b.text) : ascending
        }.map(\.0)
    }

    /// The visible records sorted, and split under headings when the component groups them.
    func arranged(sort: String?, group: String?) -> [(title: String?, records: [SpaceRecord])] {
        let ordered = sorted(visibleRecords, by: sort)
        guard let group, let field = schema.field(group) else { return [(nil, ordered)] }
        var buckets: [String: [SpaceRecord]] = [:]
        for record in ordered {
            let key: String = { if case .text(let id) = values(record)[group] { id } else { "" } }()
            buckets[key, default: []].append(record)
        }
        let keys: [String]
        if field.kind == .choice {
            keys = field.options.map(\.id)
        } else {
            keys = buckets.keys.filter { !$0.isEmpty }.sorted { (titles[$0] ?? "") < (titles[$1] ?? "") }
        }
        var result: [(title: String?, records: [SpaceRecord])] = keys.compactMap { key in
            buckets[key].map { (schema.display(.text(key), for: field, titles: titles), $0) }
        }
        if let rest = buckets[""] { result.append(("No \(field.name.lowercased())", rest)) }
        return result
    }

    func subtitle(for record: SpaceRecord, fields: [String]) -> String {
        let values = values(record)
        return fields
            .compactMap { id in schema.field(id).flatMap { field in values[id].map { schema.display($0, for: field, titles: titles) } } }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func metric(_ raw: String?, about record: SpaceRecord?) -> String {
        guard let raw, let request = SpaceCalcRequest(raw) else { return "" }
        let dates = events(request.eventKey, about: record).map(\.occurredAt)
        switch request.name {
        case .count: return "\(dates.count)"
        case .latest: return SpaceCalc.dayLabel(dates.first)
        case .streak:
            if let schedule = schedule(of: record) { return SpaceCalc.streak(dates, schedule: schedule) }
            return SpaceCalc.daysLabel(SpaceCalc.streak(dates))
        case .pace: return SpaceCalc.pace(dates, schedule: schedule(of: record))
        case .best: return SpaceCalc.daysLabel(SpaceCalc.best(dates))
        case .week: return "\(SpaceCalc.week(dates))"
        case .records: return "\(records.count)"
        case .today:
            // Only what is meant to happen today counts, unless it was done anyway.
            let due = records.filter { schedule(of: $0)?.isDue(on: .now) != false || hasEventToday(request.eventKey, about: $0) }
            let done = due.filter { hasEventToday(request.eventKey, about: $0) }.count
            return "\(done) of \(due.count)"
        case .sum, .avg, .min, .max, .change:
            return number(request, about: record).map { SpaceCalc.label($0, signed: request.name == .change) } ?? "–"
        }
    }

    /// A calculation as a number, for progress bars. Nil when it has nothing to go on.
    func number(_ request: SpaceCalcRequest, about record: SpaceRecord?) -> Double? {
        let found = events(request.eventKey, about: record)
        switch request.name {
        case .count:
            let start = request.period.start()
            return Double(found.filter { start == nil || $0.occurredAt >= start! }.count)
        case .week:
            return Double(SpaceCalc.week(found.map(\.occurredAt)))
        case .sum, .avg, .min, .max, .change:
            let eventSchema = eventType(request.eventKey)?.schema
            let values = found.reversed().compactMap { event -> (date: Date, value: Double)? in
                logged(request, in: event, schema: eventSchema).map { (event.occurredAt, $0) }
            }
            return SpaceCalc.number(request.name, values, period: request.period)
        default:
            return nil
        }
    }

    func logged(_ request: SpaceCalcRequest, in event: SpaceEvent) -> Double? {
        logged(request, in: event, schema: eventType(request.eventKey)?.schema)
    }

    /// The number one event carries: its own field, or a field of the records it is about.
    private func logged(_ request: SpaceCalcRequest, in event: SpaceEvent, schema: SpaceSchema?) -> Double? {
        func plain(_ value: SpaceValue?) -> Double? {
            switch value {
            case .number(let number): number
            case .quantity(let quantity): quantity.amount
            default: nil
            }
        }
        guard request.onRecord else {
            let values = schema?.resolved(event.values, source: lookup) ?? event.values
            return plain(values[request.field])
        }
        let numbers = event.recordIDs.compactMap { id in
            lookup?.linked(SpaceJSON.key(id)).flatMap { found in
                plain(found.schema.resolved(found.values, source: lookup)[request.field])
            }
        }
        return numbers.isEmpty ? nil : numbers.reduce(0, +)
    }

    /// The record's schedule, from the first schedule field that has one.
    func schedule(of record: SpaceRecord?) -> SpaceSchedule? {
        guard let record else { return nil }
        let values = record.values
        for field in schema.liveFields where field.kind == .schedule {
            if case .text(let raw) = values[field.id], let schedule = SpaceSchedule(raw) { return schedule }
        }
        return nil
    }

    func hasEventToday(_ key: String?, about record: SpaceRecord) -> Bool {
        events(key, about: record).contains { Calendar.current.isDateInToday($0.occurredAt) }
    }

    /// Logs straight away when there is nothing to enter, and asks for the values when there is.
    func log(_ key: String?, about record: SpaceRecord) {
        guard let type = eventType(key) else { return }
        if type.schema.liveFields.contains(where: { $0.kind != .calc }) {
            present(.logSpaceEvent(type, record))
        } else {
            try? SpaceStore.logEvent(of: type, about: [record], in: context)
        }
    }

    /// One tap: log today's event, or take it back if it is already there.
    func toggleToday(_ key: String?, about record: SpaceRecord) {
        if let existing = events(key, about: record).first(where: { Calendar.current.isDateInToday($0.occurredAt) }) {
            try? SpaceStore.delete(existing, in: context)
        } else if let type = eventType(key) {
            // A check-in stays one tap. Its details can be filled in from the history afterwards.
            try? SpaceStore.logEvent(of: type, about: [record], in: context)
        }
    }

    func summary(of event: SpaceEvent) -> String {
        guard let type = eventTypes.first(where: { $0.id == event.typeID }) else { return "" }
        let schema = type.schema
        let values = event.values
        let parts = schema.liveFields.compactMap { field -> String? in
            guard let value = values[field.id] else { return nil }
            let text = schema.display(value, for: field, titles: titles)
            return field.kind == .number ? "\(text) \(field.name.lowercased())" : text
        }
        return parts.isEmpty ? type.name : parts.joined(separator: " · ")
    }
}

struct SpaceScreenView: View {
    var definition: SpaceScreenDefinition
    var context: SpaceScreenContext

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(Array(definition.components.enumerated()), id: \.offset) { _, component in
                SpaceComponentView(component: component, context: context)
            }
        }
    }
}

struct SpaceComponentView: View {
    var component: SpaceComponent
    var context: SpaceScreenContext

    var body: some View {
        switch component.kind {
        case "section": section
        case "columns": columns
        case "search": SpaceSearchBar(component: component, context: context)
        case "cards": cards
        case "rows": rows
        case "header": header
        case "fields": fields
        case "stepper": stepper
        case "checklist": checklist
        case "steps": steps
        case "timeline": timeline
        case "calendar": SpaceCompletionCalendar(dates: context.events(component.text("events"), about: context.record).map(\.occurredAt), accent: context.accent, state: context.state)
        case "metric": metric
        case "progress": progress
        case "table": table
        case "quickAdd": SpaceQuickAdd(placeholder: component.text("placeholder"), context: context)
        case "usedIn": usedIn
        case "board": board
        case "sheet": sheet
        case "chart": chart
        case "week": SpacePlanner(span: .week, component: component, context: context)
        case "day": SpacePlanner(span: .day, component: component, context: context)
        case "month": SpacePlanner(span: .month, component: component, context: context)
        case "action": action
        default: EmptyView()
        }
    }

    private var children: some View {
        ForEach(Array(component.children.enumerated()), id: \.offset) { _, child in
            SpaceComponentView(component: child, context: context)
        }
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(component.text("title") ?? "")
                .font(CraftFont.section)
                .foregroundStyle(.secondary)
            children
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columns: some View {
        let leading = component.number("leading").map { CGFloat($0) }
        let allMetrics = component.children.allSatisfy { $0.kind == "metric" }
        return HStack(alignment: .top, spacing: allMetrics ? 12 : 48) {
            ForEach(Array(component.children.enumerated()), id: \.offset) { index, child in
                SpaceComponentView(component: child, context: context)
                    .frame(width: index == 0 ? leading : nil, alignment: .topLeading)
                    .frame(maxWidth: index == 0 && leading != nil ? nil : .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Collection

    private var cards: some View {
        grouped { records in cardGrid(records) }
    }

    /// Runs `content` once, or once under each heading when the component groups its records.
    @ViewBuilder
    private func grouped<Content: View>(@ViewBuilder _ content: @escaping ([SpaceRecord]) -> Content) -> some View {
        let groups = context.arranged(sort: component.text("sort"), group: component.text("group"))
        if groups.allSatisfy({ $0.records.isEmpty }) {
            EmptyLine(text: context.records.isEmpty ? "Nothing here yet. Use New to add the first one." : "Nothing matches.")
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 10) {
                        if let title = group.title {
                            Text(title)
                                .font(CraftFont.section)
                                .foregroundStyle(.secondary)
                        }
                        content(group.records)
                    }
                }
            }
        }
    }

    private func cardGrid(_ records: [SpaceRecord]) -> some View {
        let fields = component.list("subtitle")
        let image = component.text("image")
        return Group {
            if records.isEmpty {
                EmptyView()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
                    ForEach(records) { record in
                        Button {
                            context.open(record)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                SpaceImageView(assetID: context.imageID(image, on: record), tint: context.accent)
                                    .frame(height: 140)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(record.displayTitle)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    let subtitle = context.subtitle(for: record, fields: fields)
                                    if !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { SpaceRecordMenu(record: record, context: context) }
                    }
                }
            }
        }
    }

    private var rows: some View {
        grouped { records in rowList(records) }
    }

    private func rowList(_ records: [SpaceRecord]) -> some View {
        let fields = component.list("subtitle")
        let action = component.text("action")
        let week = component.text("week")
        let trail: String? = { if case .text(let raw) = component.props["trail"] { raw } else { nil } }()
        return Group {
            if records.isEmpty {
                EmptyView()
            } else {
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        let done = action != nil && context.hasEventToday(action, about: record)
                        HStack(spacing: 14) {
                            if action != nil {
                                Button {
                                    context.toggleToday(action, about: record)
                                } label: {
                                    SpaceCheckCircle(isOn: done, accent: context.accent)
                                }
                                .buttonStyle(.plain)
                                .help(done ? "Undo" : context.eventType(action)?.name ?? "Log")
                            }
                            Button {
                                context.open(record)
                            } label: {
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(record.displayTitle)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(done ? .secondary : .primary)
                                            .lineLimit(1)
                                        let subtitle = context.subtitle(for: record, fields: fields)
                                        if !subtitle.isEmpty {
                                            Text(subtitle)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if week != nil {
                                        SpaceWeekDots(dates: context.events(week, about: record).map(\.occurredAt), accent: context.accent)
                                    }
                                    if let trail {
                                        Text(context.metric(trail, about: record))
                                            .font(.system(size: 13, weight: .semibold))
                                            .frame(width: 72, alignment: .trailing)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(height: 58)
                        .contextMenu { SpaceRecordMenu(record: record, context: context) }
                        Hairline()
                    }
                }
            }
        }
    }

    // MARK: Detail

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            if let assetID = context.imageID(component.text("image"), on: context.record) {
                SpaceImageView(assetID: assetID, tint: context.accent, cornerRadius: 14)
                    .frame(width: 104, height: 104)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(context.record?.displayTitle ?? "")
                    .font(.system(size: 28, weight: .semibold))
                labelled(component.list("fields"), spacing: 18)
            }
            Spacer(minLength: 12)
            if let event = component.text("action"), let record = context.record {
                SpaceActionButton(title: component.text("actionLabel") ?? context.eventType(event)?.name ?? "Log") {
                    context.log(event, about: record)
                }
            }
        }
    }

    private static let liveKinds: Set<SpaceFieldKind> = [.boolean, .choice, .rating]

    private func labelled(_ ids: [String], spacing: CGFloat) -> some View {
        let values = context.values(context.record)
        let shown: [(SpaceField, SpaceValue?)] = ids.compactMap { id in
            guard let field = context.schema.field(id) else { return nil }
            return values[id] != nil || Self.liveKinds.contains(field.kind) ? (field, values[id]) : nil
        }
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 0) {
                    Text(pair.0.name)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                    liveValue(pair.1, pair.0)
                }
            }
        }
    }

    /// A value as text. A link is a button that opens the record it points at.
    @ViewBuilder
    private func valueText(_ value: SpaceValue, _ field: SpaceField, font: Font = CraftFont.body) -> some View {
        if field.kind == .link, case .text(let id) = value, let target = context.lookup?.record(id) {
            Button {
                context.open(target)
            } label: {
                Text(target.displayTitle)
                    .font(font)
                    .foregroundStyle(context.accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .help("Open \(target.displayTitle)")
        } else if field.kind == .url, case .text(let raw) = value, let url = URL(string: raw.contains("://") ? raw : "https://\(raw)") {
            Link(context.schema.display(value, for: field), destination: url)
                .font(font)
                .foregroundStyle(context.accent)
                .help(raw)
        } else if field.kind == .file, case .text(let assetID) = value {
            SpaceFileButton(assetID: assetID, accent: context.accent)
        } else {
            Text(context.schema.display(value, for: field, titles: context.titles))
                .font(font)
                .textSelection(.enabled)
        }
    }

    /// A value the viewer can change where it stands: a switch, a pop-up of options, or stars.
    /// Everything else is shown as text and changed in the form.
    @ViewBuilder
    private func liveValue(_ value: SpaceValue?, _ field: SpaceField) -> some View {
        if let record = context.record, field.kind == .boolean {
            Toggle("", isOn: Binding(
                get: { value == .boolean(true) },
                set: { try? SpaceStore.update(record, values: [field.id: .boolean($0)], in: context.context) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        } else if let record = context.record, field.kind == .choice {
            Menu {
                ForEach(field.options) { option in
                    Button(option.name) {
                        try? SpaceStore.update(record, values: [field.id: .text(option.id)], in: context.context)
                    }
                }
            } label: {
                Text(value.map { context.schema.display($0, for: field) } ?? "Choose")
                    .font(CraftFont.body)
                    .foregroundStyle(value == nil ? .tertiary : .primary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Change \(field.name.lowercased())")
        } else if let record = context.record, field.kind == .rating {
            let stars: Double = { if case .number(let number) = value { number } else { 0 } }()
            SpaceStars(stars: stars, accent: context.accent) { picked in
                try? SpaceStore.update(record, values: [field.id: .number(picked)], in: context.context)
            }
        } else if let value {
            valueText(value, field)
        }
    }

    // MARK: Tables, boards, charts

    @ViewBuilder
    private var table: some View {
        if let (field, rows) = groupRows(component.text("rows")) {
            let columns = field.fields.filter { !$0.isRemoved }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                GridRow {
                    ForEach(columns) { column in
                        Text(column.name)
                            .font(CraftFont.caption)
                            .foregroundStyle(.tertiary)
                            .gridColumnAlignment(Self.isNumeric(column) ? .trailing : .leading)
                    }
                }
                .padding(.bottom, 6)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Hairline()
                        .gridCellColumns(max(columns.count, 1))
                    GridRow {
                        ForEach(columns) { column in
                            if let value = row[column.id] {
                                valueText(value, column, font: Self.isNumeric(column) ? .system(size: 13, weight: .semibold) : CraftFont.body)
                                    .monospacedDigit()
                            } else {
                                Text("")
                            }
                        }
                    }
                    .frame(minHeight: 34)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private static func isNumeric(_ field: SpaceField) -> Bool {
        field.kind == .number || field.kind == .quantity || field.kind == .calc
    }

    @ViewBuilder
    private var usedIn: some View {
        if let record = context.record, let typeKey = component.text("type") {
            let found = context.lookup?.linking(to: SpaceJSON.key(record.id), typeKey: typeKey) ?? []
            if found.isEmpty {
                EmptyLine(text: "Not used anywhere yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(found) { other in
                        Button {
                            context.open(other)
                        } label: {
                            HStack {
                                Text(other.displayTitle)
                                    .font(CraftFont.body)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Hairline()
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var board: some View {
        if let by = component.text("by"), let field = context.schema.field(by) {
            let records = context.sorted(context.visibleRecords, by: component.text("sort"))
            let fields = component.list("subtitle")
            let unsorted = records.filter { context.values($0)[by] == nil }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(field.options) { option in
                        boardColumn(option.name, records.filter { context.values($0)[by] == .text(option.id) }, fields: fields)
                            .dropDestination(for: String.self) { ids, _ in
                                for id in ids {
                                    guard let dropped = context.lookup?.record(id) else { continue }
                                    try? SpaceStore.update(dropped, values: [by: .text(option.id)], in: context.context)
                                }
                                return !ids.isEmpty
                            }
                    }
                    if !unsorted.isEmpty {
                        boardColumn("No \(field.name.lowercased())", unsorted, fields: fields)
                    }
                }
            }
        }
    }

    private func boardColumn(_ title: String, _ records: [SpaceRecord], fields: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(records.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            ForEach(records) { record in
                Button {
                    context.open(record)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayTitle)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        let subtitle = context.subtitle(for: record, fields: fields)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CraftColor.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .draggable(SpaceJSON.key(record.id))
                .contextMenu { SpaceRecordMenu(record: record, context: context) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 220, alignment: .topLeading)
        .frame(minHeight: 160, alignment: .topLeading)
        .background(CraftColor.field.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var sheet: some View {
        let columns = component.list("columns").compactMap { context.schema.field($0) }
        let sort = context.state.sort ?? component.text("sort")
        let records = context.sorted(context.visibleRecords, by: sort)
        if records.isEmpty {
            EmptyLine(text: context.records.isEmpty ? "Nothing here yet. Use New to add the first one." : "Nothing matches.")
        } else {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                GridRow {
                    sheetHeading("Name", id: "title", sort: sort)
                    ForEach(columns) { column in
                        sheetHeading(column.name, id: column.id, sort: sort)
                            .gridColumnAlignment(Self.isNumeric(column) ? .trailing : .leading)
                    }
                }
                .padding(.bottom, 6)
                ForEach(records) { record in
                    Hairline()
                        .gridCellColumns(columns.count + 1)
                    GridRow {
                        Button {
                            context.open(record)
                        } label: {
                            Text(record.displayTitle)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { SpaceRecordMenu(record: record, context: context) }
                        let values = context.values(record)
                        ForEach(columns) { column in
                            if let value = values[column.id] {
                                valueText(value, column)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            } else {
                                Text("")
                            }
                        }
                    }
                    .frame(minHeight: 36)
                }
            }
        }
    }

    private func sheetHeading(_ title: String, id: String, sort: String?) -> some View {
        let isUp = sort == id
        let isDown = sort == "-\(id)"
        return Button {
            context.state.sort = isUp ? "-\(id)" : id
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(CraftFont.caption)
                    .foregroundStyle(isUp || isDown ? .secondary : .tertiary)
                if isUp || isDown {
                    Image(systemName: isUp ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
    }

    @ViewBuilder
    private var chart: some View {
        let points = chartPoints
        if points.isEmpty {
            EmptyLine(text: "Nothing logged in this period yet.")
        } else {
            let asLine = (component.text("style") ?? (component.text("field") == nil ? "bar" : "line")) == "line"
            Chart(points, id: \.day) { point in
                if asLine {
                    LineMark(x: .value("Day", point.day, unit: .day), y: .value("Value", point.value))
                        .foregroundStyle(context.accent)
                    PointMark(x: .value("Day", point.day, unit: .day), y: .value("Value", point.value))
                        .foregroundStyle(context.accent)
                        .symbolSize(18)
                } else {
                    BarMark(x: .value("Day", point.day, unit: .day), y: .value("Value", point.value))
                        .foregroundStyle(context.accent)
                }
            }
            .chartYScale(domain: .automatic(includesZero: !asLine))
            .frame(height: 180)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    /// One point per day. A line keeps the day's last reading; bars add the day up.
    private var chartPoints: [(day: Date, value: Double)] {
        let period = component.text("period").flatMap(SpaceCalcRequest.Period.init(rawValue:)) ?? .month
        let start = period.start()
        let calendar = Calendar.current
        let field = component.text("field")
        let asLine = (component.text("style") ?? (field == nil ? "bar" : "line")) == "line"
        let request = field.flatMap { SpaceCalcRequest("sum:\(component.text("events") ?? "").\($0)") }
        var days: [Date: Double] = [:]
        for event in context.events(component.text("events"), about: context.record).reversed() {
            if let start, event.occurredAt < start { continue }
            let day = calendar.startOfDay(for: event.occurredAt)
            if let request {
                guard let value = context.logged(request, in: event) else { continue }
                days[day] = asLine ? value : (days[day] ?? 0) + value
            } else {
                days[day, default: 0] += 1
            }
        }
        return days.map { (day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
    }

    @ViewBuilder
    private var fields: some View {
        let values = context.values(context.record)
        let shown: [(SpaceField, SpaceValue?)] = component.list("fields").compactMap { id in
            guard let field = context.schema.field(id) else { return nil }
            return values[id] != nil || Self.liveKinds.contains(field.kind) ? (field, values[id]) : nil
        }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.0.name)
                            .font(CraftFont.caption)
                            .foregroundStyle(.tertiary)
                        liveValue(pair.1, pair.0)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func stored(_ id: String?) -> Double? {
        guard let id, case .number(let number) = context.record?.values[id] else { return nil }
        return number
    }

    @ViewBuilder
    private var stepper: some View {
        if let id = component.text("field"), let base = stored(id) {
            let current = context.state.steppers[id] ?? base
            HStack(spacing: 8) {
                Text(component.text("label") ?? context.schema.field(id)?.name ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 0) {
                    stepButton("minus") { context.state.steppers[id] = max(1, current - 1) }
                    Text(current.formatted(.number.precision(.fractionLength(0...1))))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 22)
                    stepButton("plus") { context.state.steppers[id] = current + 1 }
                }
                .frame(height: 26)
                .background(CraftColor.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(CraftColor.hairline))
                if current != base {
                    Button("Reset") { context.state.steppers[id] = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func groupRows(_ id: String?) -> (SpaceField, [[String: SpaceValue]])? {
        guard let id, let field = context.schema.field(id), case .rows(let rows) = context.values(context.record)[id] else { return nil }
        return (field, rows)
    }

    /// How much the viewer's stepper has scaled the stored number.
    private var scale: Double {
        guard let id = component.text("scaleBy"), let base = stored(id), base > 0 else { return 1 }
        return (context.state.steppers[id] ?? base) / base
    }

    @ViewBuilder
    private var checklist: some View {
        if let (field, rows) = groupRows(component.text("rows")) {
            let columns = field.fields.filter { !$0.isRemoved }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let key = "\(field.id)#\(index)"
                    let saves = component.text("saves")
                    let done = saves.map { row[$0] == .boolean(true) } ?? context.state.ticked.contains(key)
                    Button {
                        if let saves, let record = context.record, case .rows(var stored) = record.values[field.id], index < stored.count {
                            // A to-do list keeps its ticks on the record.
                            stored[index][saves] = .boolean(!done)
                            try? SpaceStore.update(record, values: [field.id: .rows(stored)], in: context.context)
                        } else if done {
                            context.state.ticked.remove(key)
                        } else {
                            context.state.ticked.insert(key)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            SpaceCheckBox(isOn: done, accent: context.accent)
                            ForEach(columns.filter { $0.id != saves }) { column in
                                if let value = row[column.id] {
                                    if column.kind == .quantity || column.kind == .number {
                                        Text(context.schema.display(scaled(value), for: column, titles: context.titles))
                                            .font(.system(size: 13, weight: .semibold))
                                            .frame(width: 72, alignment: .leading)
                                    } else {
                                        Text(context.schema.display(value, for: column, titles: context.titles))
                                            .font(CraftFont.body)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(done ? .tertiary : .primary)
                        .frame(minHeight: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Hairline()
                }
            }
        }
    }

    private func scaled(_ value: SpaceValue) -> SpaceValue {
        guard case .quantity(var quantity) = value, quantity.scales else { return value }
        quantity.amount *= scale
        return .quantity(quantity)
    }

    @ViewBuilder
    private var steps: some View {
        if let (field, rows) = groupRows(component.text("rows")) {
            let columns = field.fields.filter { !$0.isRemoved }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(CraftColor.elevated, in: Circle())
                            .overlay(Circle().strokeBorder(CraftColor.hairline))
                        Text(columns.compactMap { column in row[column.id].map { context.schema.display($0, for: column, titles: context.titles) } }.joined(separator: " · "))
                            .font(CraftFont.body)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        let events = context.events(component.text("events"), about: context.record)
        if events.isEmpty {
            EmptyLine(text: "Nothing logged yet.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.prefix(20).enumerated()), id: \.element.id) { index, event in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(context.accent)
                                .frame(width: 7, height: 7)
                            if index < min(events.count, 20) - 1 {
                                Rectangle()
                                    .fill(CraftColor.hairline)
                                    .frame(width: 1)
                            }
                        }
                        .frame(width: 9)
                        .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.summary(of: event))
                                .font(CraftFont.body)
                            Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.bottom, 10)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { context.present(.editSpaceEvent(event)) }
                    .help("Change this entry")
                    .contextMenu {
                        Button {
                            context.present(.editSpaceEvent(event))
                        } label: {
                            Label("Edit…", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            try? SpaceStore.delete(event, in: context.context)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var metric: some View {
        let raw: String? = { if case .text(let raw) = component.props["value"] { raw } else { nil } }()
        return VStack(alignment: .leading, spacing: 2) {
            Text(context.metric(raw, about: context.record))
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(component.text("label") ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CraftColor.hairline))
    }

    /// A progress setting: a calculation over logs, or a formula over the record's fields.
    private func formula(_ name: String) -> Double? {
        guard let raw = component.text(name) ?? component.number(name).map({ "\($0)" }) else { return nil }
        if raw.contains(":") {
            return SpaceCalcRequest(raw).flatMap { context.number($0, about: context.record) }
        }
        guard let formula = SpaceFormula(raw) else { return nil }
        return context.schema.value(of: formula, in: context.record?.values ?? [:], source: context.lookup)
    }

    private var progress: some View {
        let value = formula("value") ?? 0
        let target = formula("target")
        let unit = component.text("unit").map { " \($0)" } ?? ""
        let fraction = target.map { $0 > 0 ? min(max(value / $0, 0), 1) : 0 } ?? 0
        func text(_ number: Double) -> String { number.formatted(.number.precision(.fractionLength(0...1))) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(component.text("label") ?? "")
                    .font(CraftFont.body)
                Spacer(minLength: 8)
                Text(target.map { "\(text(value)) of \(text($0))\(unit)" } ?? "\(text(value))\(unit), no target set")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(CraftColor.hairline)
                    Capsule()
                        .fill(context.accent)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var action: some View {
        if let record = context.record {
            SpaceActionButton(title: component.text("label") ?? "Log") {
                context.log(component.text("event"), about: record)
            }
        }
    }
}

private struct SpaceSearchBar: View {
    var component: SpaceComponent
    var context: SpaceScreenContext

    var body: some View {
        @Bindable var state = context.state
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Search \(context.type.name.lowercased())", text: $state.search)
                    .textFieldStyle(.plain)
                    .font(CraftFont.body)
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 32)
            .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CraftColor.hairline))

            ForEach(component.list("filters").compactMap { context.schema.field($0) }) { field in
                chip("All", isSelected: state.filters[field.id] == nil) { state.filters[field.id] = nil }
                ForEach(field.options) { option in
                    chip(option.name, isSelected: state.filters[field.id] == option.id) {
                        state.filters[field.id] = state.filters[field.id] == option.id ? nil : option.id
                    }
                }
            }
            Spacer(minLength: 8)
            Text("\(context.visibleRecords.count) of \(context.records.count)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChoiceCapsule(title: title, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

private struct SpaceCompletionCalendar: View {
    var dates: [Date]
    var accent: Color
    var state: SpaceScreenState

    private var calendar: Calendar { .current }

    var body: some View {
        let marked = SpaceCalc.days(dates)
        let today = calendar.startOfDay(for: .now)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.month.formatted(.dateTime.month(.wide).year()))
                    .font(CraftFont.section)
                    .foregroundStyle(.secondary)
                Spacer()
                arrow("chevron.left", by: -1)
                arrow("chevron.right", by: 1)
            }
            HStack(spacing: 0) {
                ForEach(Array(calendar.veryShortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        Group {
                            if let day {
                                let isOn = marked.contains(day)
                                Text("\(calendar.component(.day, from: day))")
                                    .font(.system(size: 12, weight: isOn ? .medium : .regular))
                                    .foregroundStyle(isOn ? Color.white : day > today ? Color.secondary.opacity(0.6) : Color.primary)
                                    .frame(width: 30, height: 30)
                                    .background(isOn ? accent : Color.clear, in: Circle())
                                    .overlay(Circle().strokeBorder(accent, lineWidth: day == today ? 1.5 : 0).padding(-3))
                            } else {
                                Color.clear.frame(width: 30, height: 30)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    }
                }
            }
        }
    }

    private func arrow(_ symbol: String, by months: Int) -> some View {
        Button {
            if let next = calendar.date(byAdding: .month, value: months, to: state.month) {
                state.month = next
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weeks: [[Date?]] {
        guard let range = calendar.range(of: .day, in: .month, for: state.month) else { return [] }
        let lead = (calendar.component(.weekday, from: state.month) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for offset in 0..<range.count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: state.month))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}

private struct SpaceWeekDots: View {
    var dates: [Date]
    var accent: Color

    var body: some View {
        let calendar = Calendar.current
        let marked = SpaceCalc.days(dates)
        let today = calendar.startOfDay(for: .now)
        HStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { index in
                let day = calendar.date(byAdding: .day, value: index - 6, to: today) ?? today
                Circle()
                    .fill(marked.contains(day) ? accent : CraftColor.hairline)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SpaceCheckCircle: View {
    var isOn: Bool
    var accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? accent : Color.clear)
            Circle()
                .strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1.5)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 26, height: 26)
        .contentShape(Circle())
    }
}

private struct SpaceCheckBox: View {
    var isOn: Bool
    var accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isOn ? accent : Color.clear)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1.5)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct SpaceActionButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(CraftColor.canvas)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Color.primary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Records placed on days by one of their date fields: a day, a week, or a month at a time.
private struct SpacePlanner: View {
    enum Span { case day, week, month }

    var span: Span
    var component: SpaceComponent
    var context: SpaceScreenContext

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: .now) }

    private var byDay: [Date: [SpaceRecord]] {
        guard let field = component.text("date") else { return [:] }
        var result: [Date: [SpaceRecord]] = [:]
        for record in context.visibleRecords {
            if case .date(let date) = context.values(record)[field] {
                result[calendar.startOfDay(for: date), default: []].append(record)
            }
        }
        return result
    }

    private var target: Double? {
        guard let raw = component.text("target") ?? component.number("target").map({ "\($0)" }),
              let formula = SpaceFormula(raw) else { return nil }
        return context.schema.value(of: formula, in: [:], source: context.lookup)
    }

    private func total(_ records: [SpaceRecord]) -> Double? {
        guard let field = component.text("total") else { return nil }
        return records.reduce(0) { sum, record in
            switch context.values(record)[field] {
            case .number(let number): sum + number
            case .quantity(let quantity): sum + quantity.amount
            default: sum
            }
        }
    }

    var body: some View {
        let grouped = byDay
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(heading)
                    .font(CraftFont.section)
                    .foregroundStyle(.secondary)
                Spacer()
                if !isOnToday {
                    Button("Today") { move(to: today) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                arrow("chevron.left", by: -1)
                arrow("chevron.right", by: 1)
            }
            switch span {
            case .day:
                dayList(context.state.day, grouped[context.state.day] ?? [])
            case .week:
                HStack(alignment: .top, spacing: 8) {
                    ForEach(weekDays, id: \.self) { day in
                        weekColumn(day, grouped[day] ?? [])
                    }
                }
            case .month:
                monthGrid(grouped)
                dayList(context.state.day, grouped[context.state.day] ?? [])
            }
        }
    }

    private var heading: String {
        switch span {
        case .day:
            let day = context.state.day
            let name = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            return day == today ? "Today, \(name)" : name
        case .week:
            guard let first = weekDays.first, let last = weekDays.last else { return "" }
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) to \(last.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return context.state.month.formatted(.dateTime.month(.wide).year())
        }
    }

    private var isOnToday: Bool {
        switch span {
        case .day: context.state.day == today
        case .week: weekDays.contains(today)
        case .month: calendar.isDate(context.state.month, equalTo: today, toGranularity: .month) && context.state.day == today
        }
    }

    private var weekDays: [Date] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: context.state.day) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
    }

    private func move(to day: Date) {
        context.state.day = day
        context.state.month = calendar.dateInterval(of: .month, for: day)?.start ?? day
    }

    private func arrow(_ symbol: String, by step: Int) -> some View {
        Button {
            switch span {
            case .day:
                if let next = calendar.date(byAdding: .day, value: step, to: context.state.day) { move(to: next) }
            case .week:
                if let next = calendar.date(byAdding: .day, value: step * 7, to: context.state.day) { move(to: next) }
            case .month:
                if let next = calendar.date(byAdding: .month, value: step, to: context.state.month) { context.state.month = next }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(step < 0 ? "Earlier" : "Later")
    }

    @ViewBuilder
    private func totalLine(_ records: [SpaceRecord], compact: Bool) -> some View {
        if let sum = total(records) {
            let unit = component.text("unit").map { " \($0)" } ?? ""
            let goal = target
            VStack(alignment: .leading, spacing: 4) {
                Text(goal.map { "\(SpaceCalc.label(sum)) of \(SpaceCalc.label($0))\(unit)" } ?? "\(SpaceCalc.label(sum))\(unit)")
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let goal, goal > 0 {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(CraftColor.hairline)
                            Capsule()
                                .fill(context.accent)
                                .frame(width: proxy.size.width * min(max(sum / goal, 0), 1))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    private func recordButton(_ record: SpaceRecord, compact: Bool) -> some View {
        Button {
            context.open(record)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.displayTitle)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .lineLimit(compact ? 2 : 1)
                    .multilineTextAlignment(.leading)
                let subtitle = context.subtitle(for: record, fields: component.list("subtitle"))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, compact ? 8 : 0)
            .padding(.vertical, compact ? 6 : 8)
            .background(compact ? CraftColor.elevated : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { SpaceRecordMenu(record: record, context: context) }
    }

    private func dayList(_ day: Date, _ records: [SpaceRecord]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if span == .month {
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
            }
            if records.isEmpty {
                EmptyLine(text: "Nothing on this day.")
            } else {
                ForEach(records) { record in
                    recordButton(record, compact: false)
                    Hairline()
                }
            }
            totalLine(records, compact: false)
                .frame(maxWidth: 320, alignment: .leading)
                .padding(.top, 10)
        }
    }

    private func weekColumn(_ day: Date, _ records: [SpaceRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: day == today ? .semibold : .regular))
                    .foregroundStyle(day == today ? context.accent : .primary)
            }
            ForEach(records) { record in
                recordButton(record, compact: true)
            }
            Spacer(minLength: 0)
            totalLine(records, compact: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(day == today ? context.accent.opacity(0.5) : CraftColor.hairline)
        )
    }

    private func monthGrid(_ grouped: [Date: [SpaceRecord]]) -> some View {
        let month = context.state.month
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 0
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for offset in 0..<count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: month))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(calendar.veryShortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        Group {
                            if let day {
                                let isPicked = day == context.state.day
                                Button {
                                    context.state.day = day
                                } label: {
                                    VStack(spacing: 2) {
                                        Text("\(calendar.component(.day, from: day))")
                                            .font(.system(size: 12, weight: day == today ? .semibold : .regular))
                                            .foregroundStyle(isPicked ? Color.white : day == today ? context.accent : Color.primary)
                                        Circle()
                                            .fill(isPicked ? Color.white : context.accent)
                                            .frame(width: 4, height: 4)
                                            .opacity(grouped[day] == nil ? 0 : 1)
                                    }
                                    .frame(width: 32, height: 32)
                                    .background(isPicked ? context.accent : Color.clear, in: Circle())
                                    .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                            } else {
                                Color.clear.frame(width: 32, height: 32)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    }
                }
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

/// What can be done to a record from wherever it is listed.
struct SpaceRecordMenu: View {
    var record: SpaceRecord
    var context: SpaceScreenContext
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        Button {
            context.present(.editRecord(record))
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        if let app {
            Button {
                app.togglePin(.record, record.id)
            } label: {
                Label(app.isPinned(record.id) ? "Unpin" : "Pin", systemImage: app.isPinned(record.id) ? "pin.slash" : "pin")
            }
        }
        Button {
            try? SpaceStore.duplicate(record, in: context.context)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            try? SpaceStore.setArchived(!record.isArchived, on: record, in: context.context)
        } label: {
            Label(record.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
        }
    }
}

/// Type a name, press Return, and the record exists. Fields start from their defaults.
private struct SpaceQuickAdd: View {
    var placeholder: String?
    var context: SpaceScreenContext
    @State private var title = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            TextField(placeholder ?? "Add to \(context.type.name.lowercased())", text: $title)
                .textFieldStyle(.plain)
                .onSubmit(add)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: 420, alignment: .leading)
        .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(CraftColor.hairline))
    }

    private func add() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if (try? SpaceStore.createRecord(of: context.type, title: name, values: context.schema.defaults(), in: context.context)) != nil {
            title = ""
        }
    }
}

struct SpaceStars: View {
    var stars: Double
    var accent: Color
    var pick: (Double) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    pick(Double(star) == stars ? 0 : Double(star))
                } label: {
                    Image(systemName: Double(star) <= stars ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(Double(star) <= stars ? accent : Color.secondary.opacity(0.5))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(star == 1 ? "1 star" : "\(star) stars")
            }
        }
    }
}

/// A stored file by name. Clicking opens it in its own app.
struct SpaceFileButton: View {
    var assetID: String
    var accent: Color

    @Environment(\.modelContext) private var context

    var body: some View {
        let store = FileStore.default(context: context)
        let asset = UUID(uuidString: assetID).flatMap { store.asset(id: $0) }
        Button {
            if let asset { NSWorkspace.shared.open(store.resolve(asset)) }
        } label: {
            Label(asset?.filename ?? "Missing file", systemImage: "doc")
                .font(CraftFont.body)
                .foregroundStyle(asset == nil ? Color.secondary : accent)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(asset == nil)
        .help(asset.map { "Open \($0.filename)" } ?? "This file is gone")
    }
}

enum SpaceScreens {
    /// The stored screen for a type, or nil when there is none or it no longer fits the type.
    /// Nil means the plain view is shown instead.
    static func definition(
        for type: SpaceType,
        kind: SpaceScreenKind,
        screens: [SpaceScreen],
        types: [SpaceType]
    ) -> SpaceScreenDefinition? {
        let key = SpaceJSON.key(type.id)
        guard let screen = screens.first(where: { $0.typeIDString == key && $0.kind == kind }) else { return nil }
        let definition = screen.definition
        let eventTypes = types.filter { $0.spaceIDString == type.spaceIDString && $0.role == .event }
        let problems = SpaceScreenCatalog.problems(
            in: definition,
            kind: kind,
            schema: type.schema,
            eventKeys: Set(eventTypes.map(\.key)),
            events: Dictionary(eventTypes.map { ($0.key, $0.schema) }) { first, _ in first }
        )
        guard !definition.components.isEmpty, problems.isEmpty else { return nil }
        return definition
    }

    static func eventTypes(beside type: SpaceType, in types: [SpaceType]) -> [SpaceType] {
        types.filter { $0.spaceIDString == type.spaceIDString && $0.role == .event }
    }
}

enum SpaceImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ assetID: String) -> NSImage? {
        cache.object(forKey: assetID as NSString)
    }

    /// Decodes a downsized copy off the main thread. Screens never hold full-size photos.
    static func load(_ assetID: String, from url: URL, maxPixel: Int = 900) async -> NSImage? {
        if let hit = cached(assetID) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }.value
        if let image {
            cache.setObject(image, forKey: assetID as NSString)
        }
        return image
    }
}

/// An image field's picture, filling its frame. Shows the tint alone when there is no image.
struct SpaceImageView: View {
    var assetID: String?
    var tint: Color
    var cornerRadius: CGFloat = 12

    @Environment(\.modelContext) private var context
    @State private var image: NSImage?

    var body: some View {
        LinearGradient(
            colors: [tint.opacity(0.22), tint.opacity(0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: assetID) {
            guard let assetID, let id = UUID(uuidString: assetID) else {
                image = nil
                return
            }
            if let hit = SpaceImageCache.cached(assetID) {
                image = hit
                return
            }
            let store = FileStore.default(context: context)
            guard let asset = store.asset(id: id) else {
                image = nil
                return
            }
            image = await SpaceImageCache.load(assetID, from: store.resolve(asset))
        }
    }
}

extension SpaceScreenContext {
    /// The asset id an image field holds on a record, if any.
    func imageID(_ field: String?, on record: SpaceRecord?) -> String? {
        guard let field, case .text(let id) = record?.values[field] else { return nil }
        return id
    }
}
