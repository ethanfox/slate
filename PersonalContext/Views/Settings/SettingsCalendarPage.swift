import AppKit
import EventKit
import SwiftUI

struct SettingsCalendarPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsPage {
            SettingsGroup("Calendar and Reminders") {
                accessRow(
                    title: "Calendar",
                    status: app.eventKit.eventsAccess,
                    request: { await app.eventKit.requestEventsAccess() },
                    entity: .event
                )
                Hairline().padding(.horizontal, 16)
                accessRow(
                    title: "Reminders",
                    status: app.eventKit.remindersAccess,
                    request: { await app.eventKit.requestRemindersAccess() },
                    entity: .reminder
                )
            }

            ForEach(app.eventKit.sourceGroups) { group in
                SettingsGroup(group.title) {
                    ForEach(Array(group.lists.enumerated()), id: \.element.id) { index, list in
                        if index > 0 { Hairline().padding(.horizontal, 16) }
                        listRow(list)
                    }
                }
            }
        }
        .task {
            await app.eventKit.prepareEvents()
            await app.eventKit.prepareReminders()
        }
    }

    private func listRow(_ list: EventKitList) -> some View {
        let enabled = app.eventKit.isEnabled(id: list.id)
        return SettingsRow {
            CalendarColorDot(color: tintBinding(for: list))
            Text(list.title)
                .foregroundStyle(enabled ? .primary : .tertiary)
            Spacer(minLength: 16)
            if app.eventKit.hasTintOverride(id: list.id) {
                Button("Reset") { app.eventKit.clearTint(id: list.id) }
            }
            Toggle("Show \(list.title)", isOn: enabledBinding(for: list))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func tintBinding(for list: EventKitList) -> Binding<Color> {
        Binding(
            get: { list.tint.color },
            set: { app.eventKit.setTint(id: list.id, tint: CalendarTint($0)) }
        )
    }

    private func enabledBinding(for list: EventKitList) -> Binding<Bool> {
        Binding(
            get: { app.eventKit.isEnabled(id: list.id) },
            set: { app.eventKit.setEnabled(id: list.id, enabled: $0) }
        )
    }

    private func accessRow(
        title: String,
        status: EKAuthorizationStatus,
        request: @escaping () async -> Void,
        entity: EKEntityType
    ) -> some View {
        SettingsRow {
            Text(title)
            Spacer(minLength: 16)
            Text(app.eventKit.statusLabel(for: status))
                .foregroundStyle(.secondary)
            if let action = accessAction(for: status) {
                Button(action.title) {
                    if action.opensSettings {
                        app.eventKit.openSettings(for: entity)
                    } else {
                        Task { await request() }
                    }
                }
            }
        }
    }

    private func accessAction(for status: EKAuthorizationStatus) -> (title: String, opensSettings: Bool)? {
        switch status {
        case .fullAccess:
            nil
        case .notDetermined, .writeOnly:
            ("Allow…", false)
        case .denied, .restricted:
            ("Open Settings", true)
        @unknown default:
            ("Open Settings", true)
        }
    }
}

private struct CalendarColorDot: View {
    @Binding var color: Color
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .popover(isPresented: $open, arrowEdge: .leading) {
            CalendarColorPalette(color: $color) { open = false }
                .padding(12)
        }
        .help("Change color")
        .accessibilityLabel("Color")
    }
}

private struct CalendarColorPalette: View {
    @Binding var color: Color
    var onPick: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(22), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Self.swatches, id: \.self) { swatch in
                    Button {
                        color = swatch.color
                        onPick()
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 22, height: 22)
                            .overlay {
                                if CalendarTint(color).matches(swatch) {
                                    Circle()
                                        .strokeBorder(.white, lineWidth: 2)
                                        .frame(width: 22, height: 22)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color")
                }
            }
            Button("Custom…") {
                onPick()
                ColorPanelRelay.shared.show(starting: color) { color = $0 }
            }
            .buttonStyle(.plain)
            .font(CraftFont.body)
        }
    }

    private static let swatches: [CalendarTint] = [
        CalendarTint(red: 1.000, green: 0.231, blue: 0.188),
        CalendarTint(red: 1.000, green: 0.584, blue: 0.000),
        CalendarTint(red: 1.000, green: 0.800, blue: 0.000),
        CalendarTint(red: 0.204, green: 0.780, blue: 0.349),
        CalendarTint(red: 0.353, green: 0.784, blue: 0.980),
        CalendarTint(red: 0.000, green: 0.478, blue: 1.000),
        CalendarTint(red: 0.345, green: 0.337, blue: 0.839),
        CalendarTint(red: 0.686, green: 0.322, blue: 0.871),
        CalendarTint(red: 1.000, green: 0.176, blue: 0.333),
        CalendarTint(red: 0.635, green: 0.518, blue: 0.369),
        CalendarTint(red: 0.557, green: 0.557, blue: 0.576),
        CalendarTint(red: 0.235, green: 0.235, blue: 0.263)
    ]
}

@MainActor
private final class ColorPanelRelay: NSObject {
    static let shared = ColorPanelRelay()
    var onChange: ((Color) -> Void)?

    func show(starting color: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(color)
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func changed(_ sender: NSColorPanel) {
        onChange?(Color(nsColor: sender.color))
    }
}
