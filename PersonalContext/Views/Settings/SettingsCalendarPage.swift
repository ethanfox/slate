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
        }
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
