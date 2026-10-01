import SwiftUI

enum OverviewWidgetKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case focus
    case notes
    case countdown
    case pinnedText
    case image
    case downloads

    var id: String { rawValue }

    var label: String {
        switch self {
        case .focus: "Focus"
        case .notes: "Recent notes"
        case .countdown: "Countdown"
        case .pinnedText: "Pinned text"
        case .image: "Image"
        case .downloads: "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .focus: "list.bullet.rectangle"
        case .notes: "note.text"
        case .countdown: "timer"
        case .pinnedText: "text.alignleft"
        case .image: "photo"
        case .downloads: "arrow.down.circle"
        }
    }

    var defaultSize: OverviewWidgetSize {
        switch self {
        case .focus, .notes, .pinnedText, .downloads: .medium
        case .countdown: .small
        case .image: .large
        }
    }

    var defaultSettingsJSON: String {
        switch self {
        case .notes: NotesWidgetSettings.default.encoded
        default: ""
        }
    }
}

enum OverviewWidgetMetrics {
    static let cornerRadius: CGFloat = 22

    static func previewSize(for size: OverviewWidgetSize) -> CGSize {
        let cell = OverviewGridMetrics.minCell
        let gap = OverviewGridMetrics.gap
        let width = CGFloat(size.columns) * cell + CGFloat(size.columns - 1) * gap
        let height = CGFloat(size.rows) * cell + CGFloat(size.rows - 1) * gap
        return CGSize(width: width, height: height)
    }
}

struct WidgetGradient: Codable, Equatable, Hashable {
    var startHex: String
    var endHex: String
    var startX: Double
    var startY: Double
    var endX: Double
    var endY: Double

    static let `default` = WidgetGradient(
        startHex: "54575E",
        endHex: "665C52",
        startX: 0.5,
        startY: 0,
        endX: 0.5,
        endY: 1
    )

    var startPoint: UnitPoint { UnitPoint(x: startX, y: startY) }
    var endPoint: UnitPoint { UnitPoint(x: endX, y: endY) }
    var startColor: Color { Color(hex: startHex) }
    var endColor: Color { Color(hex: endHex) }
    var fill: LinearGradient {
        LinearGradient(colors: [startColor, endColor], startPoint: startPoint, endPoint: endPoint)
    }

    mutating func randomizeColors() {
        startHex = Self.mutedHex()
        endHex = Self.mutedHex()
    }

    mutating func scramble() {
        startX = Double.random(in: 0...1)
        startY = Double.random(in: 0...1)
        repeat {
            endX = Double.random(in: 0...1)
            endY = Double.random(in: 0...1)
        } while hypot(endX - startX, endY - startY) < 0.35
    }

    private static func mutedHex() -> String {
        Color(
            hue: Double.random(in: 0...1),
            saturation: Double.random(in: 0.10...0.32),
            brightness: Double.random(in: 0.28...0.62)
        ).hexString
    }
}

struct WidgetSurface: ViewModifier {
    var gradient: WidgetGradient
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: OverviewWidgetMetrics.cornerRadius, style: .continuous)
        let dark = scheme == .dark
        content
            .background {
                ZStack {
                    shape.fill(gradient.fill)
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(dark ? 0.14 : 0.55), .white.opacity(0)],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
                }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(dark ? 0.28 : 0.08), radius: 14, y: 6)
    }
}

extension View {
    func widgetSurface(_ gradient: WidgetGradient = .default) -> some View {
        modifier(WidgetSurface(gradient: gradient))
    }
}

struct OverviewWidgetFace: View {
    var project: Project
    var plate: OverviewPlate
    var editing: Bool
    var interactive: Bool

    var body: some View {
        Group {
            switch plate.kind {
            case .focus:
                FocusWidgetView(
                    tracks: project.threads,
                    settings: FocusWidgetSettings.decode(plate.settingsJSON),
                    size: plate.size,
                    interactive: interactive
                )
            case .notes:
                NotesWidgetView(
                    notes: project.notes,
                    settings: NotesWidgetSettings.decode(plate.settingsJSON),
                    size: plate.size,
                    interactive: interactive
                )
            default:
                Text(plate.kind.label)
                    .font(CraftFont.section)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                    .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: OverviewWidgetMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(CraftColor.hairline, lineWidth: 2)
            }
        }
    }
}

struct WidgetRowPill: View {
    var title: String
    var meta: String
    var compact: Bool
    var interactive: Bool
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let row = HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: compact ? 13 : 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 12 : 14)
        .padding(.vertical, compact ? 8 : 11)
        .background(Color.white.opacity(fillOpacity), in: shape)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel(meta.isEmpty ? title : "\(title), \(meta)")

        if interactive {
            Button(action: action) { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }

    private var fillOpacity: Double {
        let rest = scheme == .dark ? 0.10 : 0.45
        let hover = scheme == .dark ? 0.20 : 0.68
        return hovering ? hover : rest
    }
}

struct WidgetGradientFields: View {
    @Binding var gradient: WidgetGradient

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gradient")
                .font(CraftFont.section)
            ModalControlRow("Start") {
                ColorPicker("Start", selection: hexBinding(\.startHex), supportsOpacity: false)
                    .labelsHidden()
            }
            ModalControlRow("End") {
                ColorPicker("End", selection: hexBinding(\.endHex), supportsOpacity: false)
                    .labelsHidden()
            }
            HStack(spacing: 10) {
                Button("Random") { gradient.randomizeColors() }
                Button("Scramble") { gradient.scramble() }
            }
            .buttonStyle(.plain)
            .font(CraftFont.body)
        }
    }

    private func hexBinding(_ keyPath: WritableKeyPath<WidgetGradient, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: gradient[keyPath: keyPath]) },
            set: { gradient[keyPath: keyPath] = $0.hexString }
        )
    }
}
