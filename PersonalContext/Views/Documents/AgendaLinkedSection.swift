import SwiftData
import SwiftUI

struct AgendaMarks: View {
    var item: AgendaItem?

    var body: some View {
        if let item, hasContent(item) {
            HStack(spacing: 6) {
                if let project = item.project {
                    Label(project.displayName, systemImage: project.symbol.isEmpty ? "square.stack" : project.symbol)
                }
                ForEach(item.tags.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) { tag in
                    Label(tag.displayName, systemImage: tag.symbol.isEmpty ? "tag" : tag.symbol)
                }
                ForEach(item.liveTracks, id: \.id) { thread in
                    Label(thread.title.isEmpty ? "Untitled" : thread.title, systemImage: thread.kind.symbol)
                }
                if !item.noteLinks.isEmpty {
                    Label("\(item.noteLinks.count)", systemImage: "note.text")
                }
            }
            .labelStyle(.titleAndIcon)
            .font(CraftFont.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }

    private func hasContent(_ item: AgendaItem) -> Bool {
        item.project != nil || !item.tags.isEmpty || !item.liveTracks.isEmpty || !item.noteLinks.isEmpty
    }
}

struct EventAgendaMarks: View {
    var kind: AgendaKind
    var eventKitID: String

    @Query private var items: [AgendaItem]

    init(kind: AgendaKind, eventKitID: String) {
        self.kind = kind
        self.eventKitID = eventKitID
        let id = eventKitID
        let raw = kind.rawValue
        _items = Query(filter: #Predicate<AgendaItem> { $0.eventKitID == id && $0.kindRaw == raw })
    }

    var body: some View {
        AgendaMarks(item: items.first)
    }
}

struct AgendaLinkedSection: View {
    var items: [AgendaItem]
    var childTrackName: ((AgendaItem) -> String?)? = nil

    @Environment(AppModel.self) private var app

    var body: some View {
        if !items.isEmpty {
            DocumentSection("Tasks & events") {
                ForEach(items) { item in
                    RecordRow(
                        systemImage: item.kind == .event ? "calendar" : "checklist",
                        title: item.displayTitle,
                        subtitle: subtitle(item)
                    ) {
                        AgendaMarks(item: item)
                    } action: {
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
        return parts.joined(separator: " · ")
    }

    private func open(_ item: AgendaItem) {
        switch item.kind {
        case .task:
            app.present(.editTask(item))
        case .reminder:
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
