import SwiftData
import SwiftUI

struct FocusWidgetSettings: Codable, Equatable, Hashable {
    var statuses: [ThreadStatus]
    var gradient: WidgetGradient

    static let `default` = FocusWidgetSettings(statuses: [.exploring, .active], gradient: .default)

    init(statuses: [ThreadStatus], gradient: WidgetGradient = .default) {
        self.statuses = statuses
        self.gradient = gradient
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statuses = try container.decodeIfPresent([ThreadStatus].self, forKey: .statuses) ?? Self.default.statuses
        gradient = try container.decodeIfPresent(WidgetGradient.self, forKey: .gradient) ?? .default
    }

    static func decode(_ raw: String) -> FocusWidgetSettings {
        guard let data = raw.data(using: .utf8),
              let settings = try? JSONDecoder().decode(FocusWidgetSettings.self, from: data)
        else { return .default }
        return settings
    }

    var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct FocusWidgetView: View {
    var tracks: [ProjectThread]
    var settings: FocusWidgetSettings
    var size: OverviewWidgetSize
    var interactive: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        pillColumn(visibleTracks, compact: size == .small)
            .padding(size == .small ? 14 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetSurface(settings.gradient)
    }

    private var matching: [ProjectThread] {
        let allowed = Set(settings.statuses)
        return tracks
            .filter { allowed.contains($0.status) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var visibleTracks: [ProjectThread] {
        Array(matching.prefix(pillLimit))
    }

    private var pillLimit: Int {
        switch size {
        case .small: 3
        case .medium: 3
        case .large: 5
        }
    }

    private func pillColumn(_ pills: [ProjectThread], compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 8) {
            if pills.isEmpty {
                FocusTrackPill(
                    title: "No tracks",
                    meta: "",
                    compact: compact,
                    interactive: false,
                    action: {}
                )
            } else {
                ForEach(pills) { track in
                    FocusTrackPill(
                        title: track.title.isEmpty ? "Untitled" : track.title,
                        meta: track.kind.label,
                        compact: compact,
                        interactive: interactive
                    ) {
                        app.open(track)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FocusTrackPill: View {
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

struct FocusWidgetFields: View {
    @Binding var settings: FocusWidgetSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Statuses")
                    .font(CraftFont.section)
                ForEach(ThreadStatus.allCases) { status in
                    ModalControlRow(status.label) {
                        Toggle(status.label, isOn: binding(for: status))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

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
                    Button("Random") { settings.gradient.randomizeColors() }
                    Button("Scramble") { settings.gradient.scramble() }
                }
                .buttonStyle(.plain)
                .font(CraftFont.body)
            }
        }
    }

    private func hexBinding(_ keyPath: WritableKeyPath<WidgetGradient, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: settings.gradient[keyPath: keyPath]) },
            set: { settings.gradient[keyPath: keyPath] = $0.hexString }
        )
    }

    private func binding(for status: ThreadStatus) -> Binding<Bool> {
        Binding(
            get: { settings.statuses.contains(status) },
            set: { on in
                if on {
                    if !settings.statuses.contains(status) {
                        settings.statuses.append(status)
                    }
                } else {
                    settings.statuses.removeAll { $0 == status }
                }
            }
        )
    }
}
