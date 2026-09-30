import SwiftData
import SwiftUI

struct AgendaLinkedSection: View {
    var items: [AgendaItem]
    var childTrackName: ((AgendaItem) -> String?)? = nil

    @Environment(AppModel.self) private var app

    var body: some View {
        if !items.isEmpty {
            DocumentSection("Reminders & events") {
                ForEach(items) { item in
                    RecordRow(
                        systemImage: item.kind == .event ? "calendar" : "checklist",
                        title: item.displayTitle,
                        subtitle: subtitle(item),
                        meta: item.tags.map(\.displayName).joined(separator: " · ")
                    ) {
                        open(item)
                    }
                }
            }
        }
    }

    private func subtitle(_ item: AgendaItem) -> String {
        var parts: [String] = []
        if let name = childTrackName?(item), !name.isEmpty {
            parts.append(name)
        }
        if let project = item.project {
            parts.append(project.displayName)
        }
        return parts.joined(separator: " · ")
    }

    private func open(_ item: AgendaItem) {
        switch item.kind {
        case .reminder, .task:
            if let reminder = app.eventKit.reminder(id: item.eventKitID) {
                app.present(.editReminder(reminder))
            } else {
                app.flash("This reminder is in Deleted.")
            }
        case .event:
            if let event = app.eventKit.event(seriesID: item.eventKitID) {
                app.present(.editEvent(event))
            } else {
                app.flash("This event is in Deleted.")
            }
        }
    }
}
