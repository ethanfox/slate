import SwiftData
import SwiftUI

struct NewEventSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @Environment(\.openURL) private var openURL

    var event: CalendarEvent?

    @FocusState private var focusTitle: Bool
    @State private var title = ""
    @State private var start = Date.now
    @State private var end = Date.now.addingTimeInterval(3600)
    @State private var allDay = false
    @State private var calendarID = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var confirmDelete = false
    @State private var picking: Picking?
    @State private var agenda: AgendaItem?
    @State private var createdAgenda = false
    @State private var saved = false
    @State private var conflict: AssociationConflict?
    @State private var resolveConflict: (() -> Void)?

    private var isEditing: Bool { event != nil }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (event?.allowsEditing ?? true)
    }

    private var meetingURL: URL? {
        CalendarLink.meeting(preferred: event?.url, texts: [location, notes])
    }

    private var mapsURL: URL? {
        CalendarLink.maps(for: location)
    }

    private var hasActions: Bool { meetingURL != nil || mapsURL != nil }

    private var locationTitle: String {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Open Location" : trimmed
    }

    private func meetingTitle(_ url: URL) -> String {
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Meeting"
        if host.contains("zoom") { return "Join Zoom" }
        if host.contains("meet.google") { return "Join Google Meet" }
        if host.contains("teams") { return "Join Teams" }
        if host.contains("webex") { return "Join Webex" }
        return "Join Meeting"
    }

    private var calendars: [EventKitList] {
        var lists = app.eventKit.eventCalendars
        if let event, !lists.contains(where: { $0.id == event.calendarID }) {
            lists.append(EventKitList(id: event.calendarID, title: event.calendarName, tint: event.tint))
            lists.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return lists
    }

    private enum Picking {
        case start
        case end
    }

    var body: some View {
        form
            .overlay {
                ModalCalendarOverlay(isPresented: picking != nil, onDismiss: { picking = nil }) {
                    ModalCalendarPanel(
                        date: picking == .end ? $end : $start,
                        includesTime: !allDay,
                        onDismiss: { picking = nil }
                    )
                }
            }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Event" : "New Event")
                .font(CraftFont.title)

            ModalField("Title") {
                TextField("Event", text: $title)
                    .textFieldStyle(.plain)
                    .focused($focusTitle)
            }

            ModalField("Starts", boxed: false) {
                ModalDateField(date: $start, includesTime: !allDay, isPresented: pickingBinding(.start))
            }

            ModalField("Ends", boxed: false) {
                ModalDateField(date: $end, includesTime: !allDay, isPresented: pickingBinding(.end))
            }

            ModalControlRow("All day") {
                Toggle("All day", isOn: $allDay)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            ModalField("Location") {
                TextField("Optional", text: $location)
                    .textFieldStyle(.plain)
            }

            if !calendars.isEmpty {
                ModalControlRow("Calendar") {
                    Picker("Calendar", selection: $calendarID) {
                        ForEach(calendars) { calendar in
                            Text(calendar.title).tag(calendar.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!(event?.allowsEditing ?? true))
                }
            }

            ModalField("Notes") {
                TextField("Optional", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...6)
            }

            if let agenda {
                AssociationFields(item: agenda) { incoming, apply in
                    conflict = incoming
                    resolveConflict = apply
                }
            }

            if hasActions {
                VStack(spacing: 0) {
                    if let meeting = meetingURL {
                        ModalActionRow(title: meetingTitle(meeting), systemImage: "video") {
                            openURL(meeting)
                        }
                    }
                    if meetingURL != nil, mapsURL != nil {
                        Hairline()
                    }
                    if let maps = mapsURL {
                        ModalActionRow(title: locationTitle, systemImage: "mappin.and.ellipse") {
                            openURL(maps)
                        }
                    }
                }
                .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            ModalFooter(actionTitle: isEditing ? "Save" : "Create", actionEnabled: canSave, action: save) {
                if isEditing, event?.allowsEditing == true {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.plain)
                        .frame(height: 40)
                }
            }
        }
        .onAppear {
            load()
            prepareAgenda()
            focusTitle = true
        }
        .onDisappear { discardIfNeeded() }
        .onChange(of: start) { _, newStart in
            if end < newStart {
                end = allDay ? newStart : newStart.addingTimeInterval(3600)
            }
        }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Event", role: .destructive) { deleteEvent() }
        }
        .confirmationDialog(
            conflict.map { "Switch to \($0.incoming.displayName)?" } ?? "Switch project?",
            isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
            titleVisibility: .visible
        ) {
            Button("Switch Project") {
                resolveConflict?()
                conflict = nil
                resolveConflict = nil
            }
            Button("Keep \(conflict?.current.displayName ?? "Project")", role: .cancel) {
                conflict = nil
                resolveConflict = nil
            }
        } message: {
            Text("This belongs to a different project. Switching moves this event and drops links that don’t belong.")
        }
    }

    private func pickingBinding(_ field: Picking) -> Binding<Bool> {
        Binding(
            get: { picking == field },
            set: { picking = $0 ? field : nil }
        )
    }

    private func load() {
        guard let event else {
            if calendarID.isEmpty {
                calendarID = app.eventKit.defaultEventCalendarID
            }
            return
        }
        title = event.title
        start = event.start
        end = event.displayEnd
        allDay = event.isAllDay
        calendarID = event.calendarID
        location = event.location
        notes = event.notes
    }

    private func prepareAgenda() {
        if let event, let existing = AgendaStore.item(kind: .event, eventKitID: event.seriesID, in: context) {
            agenda = existing
            return
        }
        let item = AgendaItem(kind: .event, eventKitID: event?.seriesID ?? "", title: title)
        context.insert(item)
        createdAgenda = true
        agenda = item
    }

    private var hasAssociations: Bool {
        guard let agenda else { return false }
        return agenda.project != nil || !agenda.tags.isEmpty || !agenda.trackLinks.isEmpty || !agenda.noteLinks.isEmpty
    }

    private func discardIfNeeded() {
        guard !saved, createdAgenda, let agenda else { return }
        if event == nil || !hasAssociations {
            context.delete(agenda)
            try? context.save()
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let seriesID: String
            if let event {
                try app.eventKit.updateEvent(
                    event,
                    title: trimmed,
                    start: start,
                    end: end,
                    allDay: allDay,
                    calendarID: calendarID,
                    location: place,
                    notes: note
                )
                seriesID = event.seriesID
            } else {
                let created = try app.eventKit.createEvent(
                    title: trimmed,
                    start: start,
                    end: end,
                    allDay: allDay,
                    calendarID: calendarID,
                    location: place,
                    notes: note
                )
                seriesID = created.seriesID
            }
            if let agenda {
                agenda.title = trimmed
                if hasAssociations || !createdAgenda {
                    agenda.eventKitID = seriesID
                    try? context.save()
                } else {
                    context.delete(agenda)
                    try? context.save()
                }
            }
            saved = true
            modalDismiss()
        } catch {
            app.flash(error.localizedDescription)
        }
    }

    private func deleteEvent() {
        guard let event else { return }
        do {
            try app.eventKit.deleteEvent(event)
            modalDismiss()
        } catch {
            app.flash(error.localizedDescription)
        }
    }
}
