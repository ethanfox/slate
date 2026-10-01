import SwiftData
import SwiftUI

enum OverviewWidgetSize: String, Codable, CaseIterable, Identifiable, Hashable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var columns: Int {
        switch self {
        case .small: 1
        case .medium, .large: 2
        }
    }

    var rows: Int {
        switch self {
        case .small, .medium: 1
        case .large: 2
        }
    }

    var label: String { "\(columns)×\(rows)" }

    var symbol: String {
        switch self {
        case .small: "square"
        case .medium: "rectangle"
        case .large: "square.grid.2x2"
        }
    }

    func span(in columns: Int) -> OverviewSpan {
        OverviewSpan(columns: min(self.columns, max(1, columns)), rows: rows)
    }
}

struct OverviewPlate: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var size: OverviewWidgetSize

    init(id: UUID = UUID(), size: OverviewWidgetSize) {
        self.id = id
        self.size = size
    }

    static let starter: [OverviewPlate] = [
        OverviewPlate(size: .medium),
        OverviewPlate(size: .small),
        OverviewPlate(size: .small),
        OverviewPlate(size: .large),
        OverviewPlate(size: .small),
        OverviewPlate(size: .medium)
    ]
}

struct OverviewSpan: Equatable {
    var columns: Int
    var rows: Int
}

struct OverviewPacked: Equatable {
    var column: Int
    var row: Int
    var columnSpan: Int
    var rowSpan: Int
}

enum OverviewGridMetrics {
    static let minCell: CGFloat = 180
    static let gap: CGFloat = 16
    static let maxColumns = 6

    static func columns(for width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        return min(maxColumns, max(1, Int(width / minCell)))
    }

    struct Resolved {
        var cell: CGFloat
        var gap: CGFloat

        func height(rows: Int) -> CGFloat {
            guard rows > 0 else { return 0 }
            return CGFloat(rows) * cell + CGFloat(rows - 1) * gap
        }

        func frame(for placement: OverviewPacked, origin: CGPoint) -> CGRect {
            let x = origin.x + CGFloat(placement.column) * (cell + gap)
            let y = origin.y + CGFloat(placement.row) * (cell + gap)
            let width = CGFloat(placement.columnSpan) * cell + CGFloat(placement.columnSpan - 1) * gap
            let height = CGFloat(placement.rowSpan) * cell + CGFloat(placement.rowSpan - 1) * gap
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    static func resolved(width: CGFloat, columns: Int) -> Resolved {
        let cols = max(1, columns)
        let gaps = gap * CGFloat(cols - 1)
        return Resolved(cell: max(1, (width - gaps) / CGFloat(cols)), gap: gap)
    }
}

enum OverviewPacker {
    static func pack(spans: [OverviewSpan], columns: Int) -> (placements: [OverviewPacked], rows: Int) {
        let columns = max(1, columns)
        var occupied: [[Bool]] = []
        var placements: [OverviewPacked] = []

        for span in spans {
            let span = OverviewSpan(columns: min(max(1, span.columns), columns), rows: max(1, span.rows))
            var placed = false
            var row = 0
            while !placed {
                ensureRows(row + span.rows, columns: columns, occupied: &occupied)
                for column in 0...(columns - span.columns) {
                    guard fits(row: row, column: column, span: span, occupied: occupied) else { continue }
                    occupy(row: row, column: column, span: span, occupied: &occupied)
                    placements.append(
                        OverviewPacked(
                            column: column,
                            row: row,
                            columnSpan: span.columns,
                            rowSpan: span.rows
                        )
                    )
                    placed = true
                    break
                }
                row += 1
            }
        }

        return (placements, occupied.count)
    }

    private static func ensureRows(_ count: Int, columns: Int, occupied: inout [[Bool]]) {
        while occupied.count < count {
            occupied.append(Array(repeating: false, count: columns))
        }
    }

    private static func fits(row: Int, column: Int, span: OverviewSpan, occupied: [[Bool]]) -> Bool {
        for r in row..<(row + span.rows) {
            for c in column..<(column + span.columns) {
                if occupied[r][c] { return false }
            }
        }
        return true
    }

    private static func occupy(row: Int, column: Int, span: OverviewSpan, occupied: inout [[Bool]]) {
        for r in row..<(row + span.rows) {
            for c in column..<(column + span.columns) {
                occupied[r][c] = true
            }
        }
    }
}

private struct OverviewSpanKey: LayoutValueKey {
    static let defaultValue = OverviewSpan(columns: 1, rows: 1)
}

struct OverviewPackLayout: Layout {
    var columns: Int
    var width: CGFloat
    var gap: CGFloat = OverviewGridMetrics.gap

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let packed = OverviewPacker.pack(spans: subviews.map { $0[OverviewSpanKey.self] }, columns: columns)
        let metrics = OverviewGridMetrics.resolved(width: resolvedWidth, columns: columns)
        return CGSize(width: resolvedWidth, height: metrics.height(rows: packed.rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let packed = OverviewPacker.pack(spans: subviews.map { $0[OverviewSpanKey.self] }, columns: columns)
        let metrics = OverviewGridMetrics.resolved(width: resolvedWidth, columns: columns)
        for (index, subview) in subviews.enumerated() {
            let frame = metrics.frame(for: packed.placements[index], origin: bounds.origin)
            subview.place(at: frame.origin, proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private var resolvedWidth: CGFloat {
        max(width, OverviewGridMetrics.minCell)
    }
}

extension Project {
    var overviewWidth: OverviewWidth {
        get { OverviewWidth(rawValue: overviewWidthRaw) ?? .twoThirds }
        set { overviewWidthRaw = newValue.rawValue }
    }

    var overviewPlates: [OverviewPlate] {
        get {
            guard let data = overviewLayoutJSON.data(using: .utf8),
                  let plates = try? JSONDecoder().decode([OverviewPlate].self, from: data)
            else { return [] }
            return plates
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            overviewLayoutJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    func seedOverviewPlatesIfNeeded() {
        guard overviewLayoutJSON.isEmpty else { return }
        overviewPlates = OverviewPlate.starter
        touch()
    }

    func addOverviewPlate(_ size: OverviewWidgetSize) {
        var plates = overviewPlates
        plates.append(OverviewPlate(size: size))
        overviewPlates = plates
        touch()
    }

    func setOverviewPlate(_ id: UUID, size: OverviewWidgetSize) {
        var plates = overviewPlates
        guard let index = plates.firstIndex(where: { $0.id == id }) else { return }
        plates[index].size = size
        overviewPlates = plates
        touch()
    }

    func removeOverviewPlate(_ id: UUID) {
        overviewPlates = overviewPlates.filter { $0.id != id }
        touch()
    }
}

struct OverviewCanvas: View {
    @Bindable var project: Project

    var body: some View {
        GeometryReader { geo in
            let paneWidth = geo.size.width
            let measureWidth = Self.measureWidth(paneWidth: paneWidth, fraction: project.overviewWidth.fraction)
            let columns = OverviewGridMetrics.columns(for: measureWidth)

            ScrollView(.vertical) {
                OverviewPackLayout(columns: columns, width: measureWidth) {
                    ForEach(project.overviewPlates) { plate in
                        OverviewPlateView(plate: plate) { size in
                            project.setOverviewPlate(plate.id, size: size)
                        } onDelete: {
                            project.removeOverviewPlate(plate.id)
                        }
                        .layoutValue(key: OverviewSpanKey.self, value: plate.size.span(in: columns))
                    }
                }
                .frame(width: measureWidth)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(width: paneWidth, alignment: .center)
                .animation(Motion.snappy, value: project.overviewWidth)
                .animation(Motion.snappy, value: measureWidth)
            }
            .scrollContentBackground(.hidden)
        }
        .clipped()
        .onAppear(perform: project.seedOverviewPlatesIfNeeded)
    }

    private static func measureWidth(paneWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        guard paneWidth > 64 else { return OverviewGridMetrics.minCell }
        let available = paneWidth - 64
        return min(available, max(OverviewGridMetrics.minCell, available * fraction))
    }
}

private struct OverviewPlateView: View {
    var plate: OverviewPlate
    var onSize: (OverviewWidgetSize) -> Void
    var onDelete: () -> Void

    var body: some View {
        Text(plate.size.label)
            .font(CraftFont.section)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CraftColor.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                ForEach(OverviewWidgetSize.allCases) { size in
                    Button(size.label) { onSize(size) }
                }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }
            .accessibilityLabel("Plate \(plate.size.label)")
    }
}
