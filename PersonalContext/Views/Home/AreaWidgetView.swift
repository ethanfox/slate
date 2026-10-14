import Charts
import SwiftData
import SwiftUI

extension EnvironmentValues {
    /// How much bigger or smaller than normal widgets and Area cards draw. They lay out at this size, so text stays sharp.
    @Entry var cardScale: CGFloat = 1
}

/// The fixed geometry every widget shares. A definition places blocks; it never sets these.
enum AreaWidgetMetrics {
    static let cell: CGFloat = 164
    static let gap: CGFloat = 14
    static let padding: CGFloat = 14
    static let corner: CGFloat = 18

    static func size(_ size: AreaWidgetSize) -> CGSize {
        switch size {
        case .small: CGSize(width: cell, height: cell)
        case .wide: CGSize(width: cell * 2 + gap, height: cell)
        case .large: CGSize(width: cell * 2 + gap, height: cell * 2 + gap)
        }
    }

    /// How many records a list block shows.
    static func listLimit(_ size: AreaWidgetSize, rows: Int) -> Int {
        size == .large ? (rows <= 1 ? 8 : 4) : (rows <= 1 ? 4 : 2)
    }
}

/// One widget, by id, with live data. Used wherever a widget shows: an Area, the chat, the You page.
struct AreaWidgetHost: View {
    var id: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var widgets: [AreaWidget]
    @Query private var spaces: [Space]
    @Query(sort: \SpaceType.createdAt) private var types: [SpaceType]
    @Query private var records: [SpaceRecord]
    @Query private var events: [SpaceEvent]
    @State private var state = SpaceScreenState()

    var body: some View {
        if let widget = widgets.first(where: { $0.id == id }),
           let type = types.first(where: { SpaceJSON.key($0.id) == widget.typeIDString }),
           let space = spaces.first(where: { SpaceJSON.key($0.id) == widget.spaceIDString }) {
            Button {
                app.navigate(to: .space(space.id))
            } label: {
                AreaWidgetView(widget: widget, context: screenContext(type, space: space))
            }
            .buttonStyle(.plain)
            .help("Open \(space.displayName)")
        } else {
            Text("This widget is no longer here.")
                .font(CraftFont.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func screenContext(_ type: SpaceType, space: Space) -> SpaceScreenContext {
        let key = SpaceJSON.key(type.id)
        let spaceKey = type.spaceIDString
        return SpaceScreenContext(
            kind: .widget,
            type: type,
            schema: type.schema,
            eventTypes: SpaceScreens.eventTypes(beside: type, in: types),
            records: records.filter { $0.typeIDString == key && !$0.isArchived }.sorted { $0.createdAt < $1.createdAt },
            events: events.filter { $0.spaceIDString == spaceKey },
            record: nil,
            titles: SpaceSelection.titles(in: spaceKey, records: records),
            lookup: SpaceLookup(spaceKey: spaceKey, records: records, types: types),
            accent: space.gradient.accent,
            state: state,
            context: context,
            open: { app.navigate(to: .spaceRecord(space: space.id, record: $0.id)) }
        )
    }
}

/// Draws a widget from its rows. Padding, spacing and type sizes are set here, not by the definition.
struct AreaWidgetView: View {
    var widget: AreaWidget
    var context: SpaceScreenContext

    /// How much bigger or smaller than normal to draw, set by the page showing the widget.
    @Environment(\.cardScale) private var k

    private var size: AreaWidgetSize { widget.size }
    private var rows: [[SpaceComponent]] { widget.definition.rows }

    var body: some View {
        let frame = AreaWidgetMetrics.size(size)
        VStack(alignment: .leading, spacing: 8 * k) {
            Text(widget.name)
                .font(.system(size: 11 * k, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12 * k) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, block in
                        self.block(block, across: row.count)
                            .frame(maxWidth: .infinity, maxHeight: fills(block) ? .infinity : nil, alignment: .topLeading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(AreaWidgetMetrics.padding * k)
        .frame(width: frame.width * k, height: frame.height * k, alignment: .topLeading)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: AreaWidgetMetrics.corner * k, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AreaWidgetMetrics.corner * k, style: .continuous)
                .strokeBorder(CraftColor.hairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: AreaWidgetMetrics.corner * k, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(widget.name)
    }

    /// Charts and lists take whatever height is left. The rest are as tall as their text.
    private func fills(_ block: SpaceComponent) -> Bool {
        block.kind == "chart" || block.kind == "list"
    }

    @ViewBuilder
    private func block(_ block: SpaceComponent, across: Int) -> some View {
        switch block.kind {
        case "label": label(block)
        case "metric": metric(block, across: across)
        case "chart": chart(block)
        case "progress": progress(block)
        case "list": list(block)
        default: EmptyView()
        }
    }

    private func label(_ block: SpaceComponent) -> some View {
        Text(block.text("text") ?? "")
            .font(.system(size: 11 * k))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private func metric(_ block: SpaceComponent, across: Int) -> some View {
        let raw: String? = { if case .text(let raw) = block.props["value"] { raw } else { nil } }()
        return VStack(alignment: .leading, spacing: 1) {
            Text(context.metric(raw, about: nil))
                .font(.system(size: (size == .small || across > 1 ? 24 : 30) * k, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(block.text("label") ?? "")
                .font(.system(size: 11 * k))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func chart(_ block: SpaceComponent) -> some View {
        let points = context.chartPoints(block)
        if points.isEmpty {
            Text("Nothing logged yet")
                .font(.system(size: 11 * k))
                .foregroundStyle(.tertiary)
        } else {
            let asLine = (block.text("style") ?? (block.text("field") == nil ? "bar" : "line")) == "line"
            Chart(points, id: \.day) { point in
                if asLine {
                    LineMark(x: .value("Day", point.day, unit: .day), y: .value("Value", point.value))
                        .foregroundStyle(context.accent)
                        .interpolationMethod(.monotone)
                    if points.count == 1 {
                        PointMark(x: .value("Day", point.day, unit: .day), y: .value("Value", point.value))
                            .foregroundStyle(context.accent)
                    }
                } else {
                    BarMark(x: .value("Day", point.day, unit: .day), y: .value("Value", point.value))
                        .foregroundStyle(context.accent)
                }
            }
            .chartYScale(domain: .automatic(includesZero: !asLine))
            .chartXAxis(.hidden)
            .chartYAxis(size == .large ? .automatic : .hidden)
            .frame(minHeight: 30)
        }
    }

    private func progress(_ block: SpaceComponent) -> some View {
        let value = context.amount(block, "value") ?? 0
        let target = context.amount(block, "target")
        let unit = block.text("unit").map { " \($0)" } ?? ""
        let fraction = target.map { $0 > 0 ? min(max(value / $0, 0), 1) : 0 } ?? 0
        func text(_ number: Double) -> String { number.formatted(.number.precision(.fractionLength(0...1))) }
        return VStack(alignment: .leading, spacing: 5 * k) {
            Text(target.map { "\(text(value)) of \(text($0))\(unit)" } ?? "\(text(value))\(unit)")
                .font(.system(size: 13 * k, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(CraftColor.hairline)
                    Capsule()
                        .fill(context.accent)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6 * k)
            if let label = block.text("label"), !label.isEmpty {
                Text(label)
                    .font(.system(size: 11 * k))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func list(_ block: SpaceComponent) -> some View {
        let limit = AreaWidgetMetrics.listLimit(size, rows: rows.count)
        let shown = Array(context.sorted(context.records, by: block.text("sort")).prefix(limit))
        let subtitle = block.text("subtitle").map { [$0] } ?? []
        return VStack(alignment: .leading, spacing: 0) {
            if shown.isEmpty {
                Text("Nothing here yet")
                    .font(.system(size: 11 * k))
                    .foregroundStyle(.tertiary)
            }
            ForEach(shown) { record in
                HStack(spacing: 8 * k) {
                    Text(record.displayTitle)
                        .font(.system(size: 12 * k, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(context.subtitle(for: record, fields: subtitle))
                        .font(.system(size: 11 * k))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(height: 24 * k)
            }
        }
    }
}

/// Lays widgets out left to right and wraps to a new row when the width runs out.
struct WidgetFlow: Layout {
    var spacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        return rows.filter { !$0.isEmpty }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let height = rows.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map { $0.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += (row.map(\.size.height).max() ?? 0) + spacing
        }
    }
}

/// An Area's widgets in a row, above its records.
struct AreaWidgetShelf: View {
    var spaceID: UUID

    @Environment(\.modelContext) private var context
    @Query(sort: \AreaWidget.createdAt) private var widgets: [AreaWidget]

    var body: some View {
        let key = SpaceJSON.key(spaceID)
        let owned = widgets.filter { $0.spaceIDString == key }
        if !owned.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: AreaWidgetMetrics.gap) {
                    ForEach(owned) { widget in
                        AreaWidgetHost(id: widget.id)
                            .contextMenu {
                                Button {
                                    widget.isOnYou.toggle()
                                    widget.updatedAt = .now
                                    try? context.persist()
                                } label: {
                                    Label(
                                        widget.isOnYou ? "Remove from You" : "Add to You",
                                        systemImage: widget.isOnYou ? "minus.circle" : "plus.circle"
                                    )
                                }
                            }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}
