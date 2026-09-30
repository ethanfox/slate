import SwiftUI

struct NewEventSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalDismiss) private var modalDismiss

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

    private var isEditing: Bool { event != nil }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (event?.allowsEditing ?? true)
    }

    private var calendars: [EventKitList] {
        var lists = app.eventKit.eventCalendars
        if let event, !lists.contains(where: { $0.id == event.calendarID }) {
            lists.append(EventKitList(id: event.calendarID, title: event.calendarName, tint: event.tint))
            lists.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return lists
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Event" : "New Event")
                .font(CraftFont.title)

            ModalField("Title") {
                TextField("Event", text: $title)
                    .textFieldStyle(.plain)
                    .focused($focusTitle)
            }

            ModalField("Starts", boxed: false) {
                DatePicker(
                    "Starts",
                    selection: $start,
                    displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.field)
            }

            ModalField("Ends", boxed: false) {
                DatePicker(
                    "Ends",
                    selection: $end,
                    displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.field)
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

            ModalFooter(actionTitle: isEditing ? "Save" : "Create", actionEnabled: canSave, action: save) {
                if isEditing, event?.allowsEditing == true {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .onAppear {
            load()
            focusTitle = true
        }
        .onChange(of: start) { _, newStart in
            if end < newStart {
                end = allDay ? newStart : newStart.addingTimeInterval(3600)
            }
        }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Event", role: .destructive) { deleteEvent() }
        }
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

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
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
            } else {
                try app.eventKit.createEvent(
                    title: trimmed,
                    start: start,
                    end: end,
                    allDay: allDay,
                    calendarID: calendarID,
                    location: place,
                    notes: note
                )
            }
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
