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
    var accent: Color
    var state: SpaceScreenState
    var context: ModelContext
    var open: (SpaceRecord) -> Void

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

    func subtitle(for record: SpaceRecord, fields: [String]) -> String {
        let values = record.values
        return fields
            .compactMap { id in schema.field(id).flatMap { field in values[id].map { schema.display($0, for: field) } } }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func metric(_ raw: String?, about record: SpaceRecord?) -> String {
        guard let raw, let request = SpaceCalcRequest(raw) else { return "" }
        let dates = events(request.eventKey, about: record).map(\.occurredAt)
        switch request.name {
        case .count: return "\(dates.count)"
        case .latest: return SpaceCalc.dayLabel(dates.first)
        case .streak: return SpaceCalc.daysLabel(SpaceCalc.streak(dates))
        case .best: return SpaceCalc.daysLabel(SpaceCalc.best(dates))
        case .week: return "\(SpaceCalc.week(dates))"
        case .records: return "\(records.count)"
        case .today:
            let done = records.filter { hasEventToday(request.eventKey, about: $0) }.count
            return "\(done) of \(records.count)"
        }
    }

    func hasEventToday(_ key: String?, about record: SpaceRecord) -> Bool {
        events(key, about: record).contains { Calendar.current.isDateInToday($0.occurredAt) }
    }

    func log(_ key: String?, about record: SpaceRecord) {
        guard let type = eventType(key) else { return }
        try? SpaceStore.logEvent(of: type, about: [record], in: context)
    }

    /// One tap: log today's event, or take it back if it is already there.
    func toggleToday(_ key: String?, about record: SpaceRecord) {
        if let existing = events(key, about: record).first(where: { Calendar.current.isDateInToday($0.occurredAt) }) {
            try? SpaceStore.delete(existing, in: context)
        } else {
            log(key, about: record)
        }
    }

    func summary(of event: SpaceEvent) -> String {
        guard let type = eventTypes.first(where: { $0.id == event.typeID }) else { return "" }
        let schema = type.schema
        let values = event.values
        let parts = schema.liveFields.compactMap { field -> String? in
            guard let value = values[field.id] else { return nil }
            let text = schema.display(value, for: field)
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
        let records = context.visibleRecords
        let fields = component.list("subtitle")
        let image = component.text("image")
        return Group {
            if records.isEmpty {
                EmptyLine(text: context.records.isEmpty ? "Nothing here yet. Use New to add the first one." : "Nothing matches.")
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
                    }
                }
            }
        }
    }

    private var rows: some View {
        let records = context.visibleRecords
        let fields = component.list("subtitle")
        let action = component.text("action")
        let week = component.text("week")
        let trail: String? = { if case .text(let raw) = component.props["trail"] { raw } else { nil } }()
        return Group {
            if records.isEmpty {
                EmptyLine(text: context.records.isEmpty ? "Nothing here yet. Use New to add the first one." : "Nothing matches.")
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

    private func labelled(_ ids: [String], spacing: CGFloat) -> some View {
        let values = context.record?.values ?? [:]
        let shown = ids.compactMap { id in context.schema.field(id).flatMap { field in values[id].map { (field, $0) } } }
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 0) {
                    Text(pair.0.name)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                    Text(context.schema.display(pair.1, for: pair.0))
                        .font(CraftFont.body)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        let values = context.record?.values ?? [:]
        let shown = component.list("fields").compactMap { id in
            context.schema.field(id).flatMap { field in values[id].map { (field, $0) } }
        }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.0.name)
                            .font(CraftFont.caption)
                            .foregroundStyle(.tertiary)
                        Text(context.schema.display(pair.1, for: pair.0))
                            .font(CraftFont.body)
                            .textSelection(.enabled)
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
        guard let id, let field = context.schema.field(id), case .rows(let rows) = context.record?.values[id] else { return nil }
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
                    let done = context.state.ticked.contains(key)
                    Button {
                        if done { context.state.ticked.remove(key) } else { context.state.ticked.insert(key) }
                    } label: {
                        HStack(spacing: 10) {
                            SpaceCheckBox(isOn: done, accent: context.accent)
                            ForEach(columns) { column in
                                if let value = row[column.id] {
                                    if column.kind == .quantity || column.kind == .number {
                                        Text(context.schema.display(scaled(value), for: column))
                                            .font(.system(size: 13, weight: .semibold))
                                            .frame(width: 72, alignment: .leading)
                                    } else {
                                        Text(context.schema.display(value, for: column))
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
                        Text(columns.compactMap { column in row[column.id].map { context.schema.display($0, for: column) } }.joined(separator: " · "))
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
                    .contextMenu {
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
        let eventKeys = Set(types.filter { $0.spaceIDString == type.spaceIDString && $0.role == .event }.map(\.key))
        let problems = SpaceScreenCatalog.problems(in: definition, kind: kind, schema: type.schema, eventKeys: eventKeys)
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
