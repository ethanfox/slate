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
}

enum OverviewWidgetMetrics {
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
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let dark = scheme == .dark
        content
            .background {
                ZStack {
                    shape.fill(
                        LinearGradient(
                            colors: [gradient.startColor, gradient.endColor],
                            startPoint: gradient.startPoint,
                            endPoint: gradient.endPoint
                        )
                    )
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
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CraftColor.hairline, lineWidth: 2)
            }
        }
    }
}
