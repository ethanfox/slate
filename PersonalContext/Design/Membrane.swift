import SwiftUI

/// The logo as a living thing: soft cells packed inside a circle, pressing on each other. Each cell
/// takes the room its share asks for, and the others give way.
struct MembraneView: View {
    var model: MembraneModel
    /// The least time between frames. A small membrane does not need every frame.
    var frameInterval: Double?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
            Canvas { context, size in
                model.isDark = colorScheme == .dark
                model.advance(to: timeline.date)
                MembraneRenderer.draw(model, in: &context, size: size)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { model.pointer = $0.location }
                .onEnded { _ in model.pointer = nil }
        )
        .accessibilityHidden(true)
    }
}

/// One of the user's things, as the membrane needs it.
struct MembraneThing: Equatable {
    var id: String
    var color: SIMD3<Double>
    /// How much room it asks for next to the others. 1 is ordinary.
    var weight: Double
}

struct MembraneCell {
    var id: Int
    /// The thing this cell stands for. The logo's own cells have none.
    var key: String?
    /// In the circle's own space: the center is zero and the edge is at 1.
    var position: SIMD2<Double>
    var velocity: SIMD2<Double> = .zero
    /// What the cell pushes with. Raised or lowered until the cell is the size its share asks for.
    var power = 0.0
    var share: Double
    var shareVelocity = 0.0
    var targetShare: Double
    var color: SIMD3<Double>
    var targetColor: SIMD3<Double>
    /// The color it takes when it is in focus, or always if it was added.
    var hue: SIMD3<Double>
    var restShare: Double
    var isLogo: Bool
    var isLeaving = false
    var phase: Double
    var area = 0.0
    var outline: [SIMD2<Double>] = []
}

final class MembraneModel {
    private(set) var cells: [MembraneCell] = []
    private(set) var isFocused = false
    /// On a dark page the logo's cells are light, so they do not sink into it.
    var isDark = false {
        didSet { if isDark != oldValue { applyLook() } }
    }
    /// Where the pointer is held down, in the view's points.
    var pointer: CGPoint?
    var viewSize: CGSize = .zero

    private var focused: Set<Int> = []
    private var grabbed: Int?
    private var nextID = 0
    private var lastDate: Date?
    private var time = 0.0

    static let gap = 0.045
    static let graphite = SIMD3(0.14, 0.14, 0.16)
    static let chalk = SIMD3(0.9, 0.9, 0.88)
    static let pale = SIMD3(0.87, 0.87, 0.85)
    static let hues: [SIMD3<Double>] = [
        SIMD3(0.91, 0.39, 0.23), SIMD3(0.29, 0.33, 0.85), SIMD3(0.12, 0.37, 0.39), SIMD3(0.0, 0.48, 1.0),
        SIMD3(0.93, 0.68, 0.22), SIMD3(0.78, 0.27, 0.52), SIMD3(0.33, 0.63, 0.42),
    ]
    /// Where the logo's four cells sit, and how big each is.
    private static let logo: [(SIMD2<Double>, Double)] = [
        (SIMD2(-0.30, 0.41), 1.35), (SIMD2(0.56, 0.62), 0.45), (SIMD2(0.52, -0.41), 1.3), (SIMD2(-0.55, -0.45), 0.9),
    ]

    init() {
        reset()
    }

    func reset() {
        cells = []
        focused = []
        isFocused = false
        for (position, share) in Self.logo {
            append(at: position, share: share, startShare: share, isLogo: true)
        }
    }

    /// Squeezes a new cell in from the edge. Without a color it takes the next one in the list.
    func add(hue: SIMD3<Double>? = nil) {
        let angle = Double.random(in: 0..<(2 * .pi))
        append(at: SIMD2(cos(angle), sin(angle)) * 0.82, share: 0.8, startShare: 0.02, isLogo: false, hue: hue)
        applyLook()
    }

    func remove() {
        guard let index = cells.lastIndex(where: { !$0.isLeaving }), cells.count(where: { !$0.isLeaving }) > 1 else { return }
        cells[index].isLeaving = true
        cells[index].targetShare = 0
        focused.remove(cells[index].id)
    }

    /// Makes the cells match the user's things: new ones squeeze in, missing ones leave.
    func sync(_ things: [MembraneThing]) {
        let isFirst = !cells.contains { $0.key != nil }
        let wanted = Dictionary(things.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in cells.indices {
            guard let key = cells[index].key else { continue }
            if let thing = wanted[key] {
                cells[index].hue = thing.color
                cells[index].restShare = thing.weight
                cells[index].isLeaving = false
            } else {
                cells[index].isLeaving = true
                cells[index].targetShare = 0
            }
        }
        let present = Set(cells.compactMap(\.key))
        for thing in things where !present.contains(thing.id) {
            // Placed from its id, so the membrane looks the same every time it is opened.
            let seed = Self.hash(thing.id)
            let angle = Double(seed % 3600) / 3600 * 2 * .pi
            let reach = isFirst ? 0.3 + Double(seed / 3600 % 100) / 100 * 0.5 : 0.82
            append(
                at: SIMD2(cos(angle), sin(angle)) * reach, share: thing.weight,
                startShare: isFirst ? thing.weight : 0.02, isLogo: false, hue: thing.color, key: thing.id
            )
        }
        applyLook()
        if isFirst {
            pack()
            for _ in 0..<240 { step(1.0 / 60) }
        }
    }

    private static func hash(_ text: String) -> UInt64 {
        text.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
    }

    func toggleFocus() {
        isFocused.toggle()
        if isFocused {
            let staying = cells.filter { !$0.isLeaving }.map(\.id).shuffled()
            focused = Set(staying.prefix(max(1, staying.count / 3)))
        } else {
            focused = []
        }
        applyLook()
    }

    private func append(at position: SIMD2<Double>, share: Double, startShare: Double, isLogo: Bool,
        hue: SIMD3<Double>? = nil, key: String? = nil
    ) {
        let hue = hue ?? Self.hues[nextID % Self.hues.count]
        let rest = isLogo ? logoColor : hue
        cells.append(MembraneCell(
            id: nextID, key: key, position: position, share: startShare, targetShare: share, color: rest, targetColor: rest,
            hue: hue, restShare: share, isLogo: isLogo, phase: Double.random(in: 0..<100)
        ))
        nextID += 1
    }

    private var logoColor: SIMD3<Double> {
        isDark ? Self.chalk : Self.graphite
    }

    private func applyLook() {
        for index in cells.indices where !cells[index].isLeaving {
            let cell = cells[index]
            if !isFocused {
                cells[index].targetShare = cell.restShare
                cells[index].targetColor = cell.isLogo ? logoColor : cell.hue
            } else if focused.contains(cell.id) {
                cells[index].targetShare = 2.3
                cells[index].targetColor = cell.hue
            } else {
                cells[index].targetShare = 0.5
                cells[index].targetColor = Self.pale
            }
        }
    }

    // MARK: Motion

    func advance(to date: Date) {
        let elapsed = min(lastDate.map { date.timeIntervalSince($0) } ?? 0, 1.0 / 20)
        lastDate = date
        if cells.first?.outline.isEmpty ?? true { pack() }
        var remaining = elapsed
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 120)
            step(dt)
            remaining -= dt
        }
    }

    /// The pointer in the circle's space, if it is held down.
    private var pointerInCircle: SIMD2<Double>? {
        guard let pointer, viewSize.width > 0 else { return nil }
        let radius = MembraneRenderer.radius(in: viewSize)
        return SIMD2((pointer.x - viewSize.width / 2) / radius, (pointer.y - viewSize.height / 2) / radius)
    }

    private func step(_ dt: Double) {
        time += dt
        let hold = pointerInCircle
        if let hold {
            if grabbed == nil {
                grabbed = cells.min { length($0.position - hold) < length($1.position - hold) }?.id
            }
        } else {
            grabbed = nil
        }

        let total = max(cells.reduce(0) { $0 + $1.share }, 0.001)
        for index in cells.indices {
            var cell = cells[index]
            let (area, center) = Self.measure(cell.outline) ?? (0, cell.position)
            cell.area = area
            cell.power += 9 * (cell.share / total * .pi - area) * dt

            // Pulled to the middle of its own room, which is what lets neighbors shove it around.
            var pull = 46 * (center - cell.position) - 6.5 * cell.velocity
            pull += 2.2 * SIMD2(sin(time * 0.53 + cell.phase), cos(time * 0.41 + cell.phase * 1.7))
            if let hold, grabbed == cell.id {
                pull += 160 * (hold - cell.position) - 10 * cell.velocity
            }
            cell.velocity += pull * dt
            cell.position += cell.velocity * dt
            let distance = length(cell.position)
            if distance > 0.94 {
                let out = cell.position / distance
                cell.position = out * 0.94
                cell.velocity -= out * max(dot(cell.velocity, out), 0)
            }

            // The size overshoots a little and settles, so a cell pops in rather than fading in.
            let breath = 1 + 0.05 * sin(time * 0.8 + cell.phase)
            cell.shareVelocity += (90 * (cell.targetShare * breath - cell.share) - 11 * cell.shareVelocity) * dt
            cell.share = max(cell.share + cell.shareVelocity * dt, 0.001)
            cell.color += (cell.targetColor - cell.color) * min(dt * 5, 1)
            cells[index] = cell
        }
        cells.removeAll { $0.isLeaving && $0.share < 0.03 }
        let mean = cells.reduce(0) { $0 + $1.power } / Double(max(cells.count, 1))
        for index in cells.indices { cells[index].power -= mean }
        pack()
    }

    /// Divides the circle between the cells. A cell with more power takes more of it.
    private func pack() {
        for index in cells.indices {
            cells[index].outline = outline(of: index, inset: 0)
        }
    }

    /// One cell's room, pulled in from every side by `inset`.
    func outline(of index: Int, inset: Double) -> [SIMD2<Double>] {
        let cell = cells[index]
        var shape = Self.circle.map { $0 * (1 - inset) }
        for other in cells where other.id != cell.id {
            let normal = other.position - cell.position
            let reach = length(normal)
            guard reach > 1e-6 else { continue }
            let limit = (length_squared(other.position) - length_squared(cell.position) + cell.power - other.power) / 2
            shape = Self.clip(shape, normal: normal, limit: limit - inset * reach)
            if shape.count < 3 { return [] }
        }
        return shape
    }

    private static let circle: [SIMD2<Double>] = (0..<72).map {
        let angle = Double($0) / 72 * 2 * .pi
        return SIMD2(cos(angle), sin(angle))
    }

    /// Keeps the part of a shape where `dot(point, normal) <= limit`.
    private static func clip(_ shape: [SIMD2<Double>], normal: SIMD2<Double>, limit: Double) -> [SIMD2<Double>] {
        var kept: [SIMD2<Double>] = []
        kept.reserveCapacity(shape.count + 2)
        for index in shape.indices {
            let a = shape[index]
            let b = shape[(index + 1) % shape.count]
            let (da, db) = (dot(a, normal) - limit, dot(b, normal) - limit)
            if da <= 0 { kept.append(a) }
            if (da < 0 && db > 0) || (da > 0 && db < 0) {
                kept.append(a + (b - a) * (da / (da - db)))
            }
        }
        return kept
    }

    private static func measure(_ shape: [SIMD2<Double>]) -> (area: Double, center: SIMD2<Double>)? {
        guard shape.count >= 3 else { return nil }
        var (doubled, sum) = (0.0, SIMD2<Double>.zero)
        for index in shape.indices {
            let a = shape[index]
            let b = shape[(index + 1) % shape.count]
            let cross = a.x * b.y - b.x * a.y
            doubled += cross
            sum += (a + b) * cross
        }
        guard abs(doubled) > 1e-9 else { return nil }
        return (abs(doubled) / 2, sum / (3 * doubled))
    }
}

private func length(_ vector: SIMD2<Double>) -> Double {
    (vector * vector).sum().squareRoot()
}

private func length_squared(_ vector: SIMD2<Double>) -> Double {
    (vector * vector).sum()
}

private func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    (a * b).sum()
}

enum MembraneRenderer {
    static func radius(in size: CGSize) -> Double {
        min(size.width, size.height) / 2 * 0.93
    }

    static func draw(_ model: MembraneModel, in context: inout GraphicsContext, size: CGSize) {
        model.viewSize = size
        let radius = radius(in: size)
        guard radius > 8 else { return }
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)

        for index in model.cells.indices {
            let cell = model.cells[index]
            // Corners as round as the cell can afford: a small cell is nearly a pebble.
            let round = min(0.11, 0.42 * (cell.area / .pi).squareRoot())
            let core = model.outline(of: index, inset: MembraneModel.gap / 2 + round)
            guard core.count >= 3 else { continue }
            var path = Path()
            path.addLines(core.map { CGPoint(x: middle.x + $0.x * radius, y: middle.y + $0.y * radius) })
            path.closeSubpath()
            let shape = path.union(path.strokedPath(StrokeStyle(lineWidth: round * radius * 2, lineJoin: .round)))
            let box = shape.boundingRect

            var under = context
            under.addFilter(.shadow(color: .black.opacity(0.16), radius: radius * 0.03, y: radius * 0.02))
            under.fill(shape, with: .color(color(cell.color)))

            // Lit from the upper left.
            context.fill(shape, with: .linearGradient(
                Gradient(colors: [color(lit(cell.color, 0.2)), color(cell.color), color(cell.color * 0.86)]),
                startPoint: CGPoint(x: box.minX, y: box.minY),
                endPoint: CGPoint(x: box.maxX, y: box.maxY)
            ))
            var inside = context
            inside.clip(to: shape)
            let glow = CGPoint(x: box.minX + box.width * 0.3, y: box.minY + box.height * 0.22)
            inside.fill(Path(box), with: .radialGradient(
                Gradient(colors: [.white.opacity(0.22), .white.opacity(0)]),
                center: glow, startRadius: 0, endRadius: max(box.width, box.height) * 0.6
            ))
            if let grain = LiquidSandRenderer.grain {
                inside.blendMode = .overlay
                inside.opacity = 0.3
                inside.fill(Path(box), with: .tiledImage(Image(decorative: grain, scale: 2)))
            }
        }
    }

    private static func lit(_ value: SIMD3<Double>, _ amount: Double) -> SIMD3<Double> {
        value + (SIMD3(1, 1, 1) - value) * amount
    }

    private static func color(_ value: SIMD3<Double>) -> Color {
        Color(.sRGB, red: value.x, green: value.y, blue: value.z)
    }
}

/// A window for judging how the membrane feels in motion. Not part of the app's own screens.
struct MembraneLab: View {
    @State private var model = MembraneModel()
    @State private var isFocused = false

    var body: some View {
        VStack(spacing: 0) {
            MembraneView(model: model)
                .frame(minWidth: 420, minHeight: 420)
            HStack(spacing: 10) {
                Button("Add") { model.add() }
                Button("Remove") { model.remove() }
                Button(isFocused ? "Release" : "Focus") {
                    model.toggleFocus()
                    isFocused = model.isFocused
                }
                Spacer()
                Button("Reset") {
                    model.reset()
                    isFocused = false
                }
            }
            .padding(16)
        }
        .frame(minWidth: 460, minHeight: 520)
        .background(Color(hex: "F6F6F4"))
        .preferredColorScheme(.light)
    }
}
