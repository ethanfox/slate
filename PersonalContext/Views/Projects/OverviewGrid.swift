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
    var kind: OverviewWidgetKind
    var settingsJSON: String

    init(
        id: UUID = UUID(),
        size: OverviewWidgetSize,
        kind: OverviewWidgetKind = .focus,
        settingsJSON: String = ""
    ) {
        self.id = id
        self.size = size
        self.kind = kind
        self.settingsJSON = settingsJSON
    }

    enum CodingKeys: String, CodingKey {
        case id, size, kind, settingsJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        size = try container.decode(OverviewWidgetSize.self, forKey: .size)
        kind = try container.decodeIfPresent(OverviewWidgetKind.self, forKey: .kind) ?? .focus
        settingsJSON = try container.decodeIfPresent(String.self, forKey: .settingsJSON) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(size, forKey: .size)
        try container.encode(kind, forKey: .kind)
        try container.encode(settingsJSON, forKey: .settingsJSON)
    }

    static let starter: [OverviewPlate] = [
        OverviewPlate(size: .medium),
        OverviewPlate(size: .small),
        OverviewPlate(size: .small),
        OverviewPlate(size: .large),
        OverviewPlate(size: .small),
        OverviewPlate(size: .medium)
    ]

    static func moving(_ plates: [OverviewPlate], id: UUID?, before target: UUID?) -> [OverviewPlate] {
        guard let id, let target, id != target else { return plates }
        var next = plates
        guard let from = next.firstIndex(where: { $0.id == id }) else { return plates }
        let plate = next.remove(at: from)
        guard let dest = next.firstIndex(where: { $0.id == target }) else { return plates }
        next.insert(plate, at: dest)
        return next
    }
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
        updateOverviewPlate(id, size: size)
    }

    func updateOverviewPlate(
        _ id: UUID,
        size: OverviewWidgetSize? = nil,
        kind: OverviewWidgetKind? = nil,
        settingsJSON: String? = nil
    ) {
        var plates = overviewPlates
        guard let index = plates.firstIndex(where: { $0.id == id }) else { return }
        if let size { plates[index].size = size }
        if let kind { plates[index].kind = kind }
        if let settingsJSON { plates[index].settingsJSON = settingsJSON }
        overviewPlates = plates
        touch()
    }

    func removeOverviewPlate(_ id: UUID) {
        overviewPlates = overviewPlates.filter { $0.id != id }
        touch()
    }

    func moveOverviewPlate(_ id: UUID, before target: UUID) {
        let next = OverviewPlate.moving(overviewPlates, id: id, before: target)
        guard next != overviewPlates else { return }
        overviewPlates = next
        touch()
    }
}

private enum OverviewDragSpace {
    static let name = "overviewGrid"
}

struct OverviewCanvas: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingDelete: UUID?
    @State private var frames: [UUID: CGRect] = [:]
    @State private var draggingID: UUID?
    @State private var hoverID: UUID?
    @State private var liftFrame: CGRect = .zero
    @State private var dragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let paneWidth = geo.size.width
            let measureWidth = Self.measureWidth(paneWidth: paneWidth, fraction: project.overviewWidth.fraction)
            let columns = OverviewGridMetrics.columns(for: measureWidth)
            let plates = OverviewPlate.moving(project.overviewPlates, id: draggingID, before: hoverID)

            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    OverviewPackLayout(columns: columns, width: measureWidth) {
                        ForEach(plates) { plate in
                            OverviewPlateView(
                                project: project,
                                plate: plate,
                                editing: app.inspectorOpen,
                                isGhost: draggingID == plate.id,
                                onSize: { project.setOverviewPlate(plate.id, size: $0) },
                                onEdit: {
                                    app.present(.editOverviewWidget(project, plate.id, frames[plate.id]?.size ?? .zero))
                                },
                                onDelete: { pendingDelete = plate.id },
                                onFrame: { frames[plate.id] = $0 },
                                onDragChanged: { dragChanged(plate.id, $0) },
                                onDragEnded: commitDrag
                            )
                            .layoutValue(key: OverviewSpanKey.self, value: plate.size.span(in: columns))
                            .transition(.opacity.combined(with: .scale(0.96)))
                        }
                    }
                    .frame(width: measureWidth)
                    .animation(gridMotion, value: hoverID)
                    .animation(gridMotion, value: project.overviewLayoutJSON)

                    if let draggingID, let plate = project.overviewPlates.first(where: { $0.id == draggingID }) {
                        OverviewWidgetFace(project: project, plate: plate, editing: true, interactive: false)
                            .frame(width: max(liftFrame.width, 1), height: max(liftFrame.height, 1))
                            .offset(
                                x: liftFrame.minX + dragTranslation.width,
                                y: liftFrame.minY + dragTranslation.height
                            )
                            .compositingGroup()
                            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: OverviewDragSpace.name)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(width: paneWidth, alignment: .center)
                .animation(gridMotion, value: project.overviewWidth)
                .animation(gridMotion, value: measureWidth)
                .animation(gridMotion, value: app.inspectorOpen)
            }
            .scrollContentBackground(.hidden)
        }
        .clipped()
        .onAppear(perform: project.seedOverviewPlatesIfNeeded)
        .onChange(of: app.inspectorOpen) { _, open in
            if !open { clearDrag() }
        }
        .alert(
            "Delete this plate?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive, action: confirmDelete)
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It will be removed from this overview.")
        }
    }

    private var gridMotion: Animation? {
        reduceMotion ? nil : Motion.snappy
    }

    private func dragChanged(_ id: UUID, _ value: DragGesture.Value) {
        if draggingID == nil {
            draggingID = id
            liftFrame = frames[id] ?? CGRect(origin: value.startLocation, size: .zero)
        }
        dragTranslation = value.translation
        let hit = frames.first { key, rect in
            key != id && rect.contains(value.location)
        }?.key
        if let hit, hoverID != hit {
            hoverID = hit
        }
    }

    private func commitDrag() {
        let id = draggingID
        let target = hoverID
        dragTranslation = .zero
        draggingID = nil
        hoverID = nil
        if let id, let target {
            withAnimation(gridMotion) {
                project.moveOverviewPlate(id, before: target)
            }
        }
    }

    private func clearDrag() {
        draggingID = nil
        hoverID = nil
        dragTranslation = .zero
    }

    private func confirmDelete() {
        let id = pendingDelete
        pendingDelete = nil
        withAnimation(gridMotion) {
            if let id {
                project.removeOverviewPlate(id)
            }
        }
    }

    private static func measureWidth(paneWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        guard paneWidth > 64 else { return OverviewGridMetrics.minCell }
        let available = paneWidth - 64
        return min(available, max(OverviewGridMetrics.minCell, available * fraction))
    }
}

private struct OverviewPlateView: View {
    var project: Project
    var plate: OverviewPlate
    var editing: Bool
    var isGhost: Bool
    var onSize: (OverviewWidgetSize) -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onFrame: (CGRect) -> Void
    var onDragChanged: (DragGesture.Value) -> Void
    var onDragEnded: () -> Void

    var body: some View {
        OverviewWidgetFace(project: project, plate: plate, editing: editing, interactive: !editing)
            .opacity(isGhost ? 0.35 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(OverviewDragSpace.name))
            } action: { onFrame($0) }
            .gesture(drag, including: editing ? .all : .subviews)
            .overlay(alignment: .topTrailing) {
                if editing, !isGhost {
                    plateButton("xmark", label: "Delete plate", action: onDelete)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if editing, !isGhost {
                    plateButton("ellipsis", label: "Edit widget", action: onEdit)
                }
            }
            .contextMenu {
                Button("Edit") { onEdit() }
                ForEach(OverviewWidgetSize.allCases) { size in
                    Button(size.label) { onSize(size) }
                }
            }
            .accessibilityLabel("\(plate.kind.label) \(plate.size.label)")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(OverviewDragSpace.name))
            .onChanged(onDragChanged)
            .onEnded { _ in onDragEnded() }
    }

    private func plateButton(_ systemImage: String, label: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.clear)
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Circle())
        .contentShape(Circle())
        .padding(6)
        .accessibilityLabel(label)
    }
}
