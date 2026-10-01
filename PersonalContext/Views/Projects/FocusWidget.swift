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
        Array(matching.prefix(Self.itemLimit(for: size)))
    }

    private static func itemLimit(for size: OverviewWidgetSize) -> Int {
        switch size {
        case .small, .medium: 2
        case .large: 4
        }
    }

    private func pillColumn(_ pills: [ProjectThread], compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 8) {
            if pills.isEmpty {
                WidgetRowPill(
                    title: "No tracks",
                    meta: "",
                    compact: compact,
                    interactive: false,
                    action: {}
                )
            } else {
                ForEach(pills) { track in
                    WidgetRowPill(
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

            WidgetGradientFields(gradient: $settings.gradient)
        }
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
