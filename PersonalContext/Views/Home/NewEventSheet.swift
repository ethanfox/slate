import SwiftUI

struct NewEventSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var event: CalendarEvent?

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

            field("Title") {
                TextField("Event", text: $title)
                    .textFieldStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Starts")
                    .font(CraftFont.section)
                DatePicker(
                    "Starts",
                    selection: $start,
                    displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.field)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Ends")
                    .font(CraftFont.section)
                DatePicker(
                    "Ends",
                    selection: $end,
                    displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.field)
            }

            HStack {
                Text("All day")
                    .font(CraftFont.body)
                Spacer()
                Toggle("All day", isOn: $allDay)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            field("Location") {
                TextField("Optional", text: $location)
                    .textFieldStyle(.plain)
            }

            if !calendars.isEmpty {
                HStack {
                    Text("Calendar")
                        .font(CraftFont.body)
                    Spacer(minLength: 16)
                    Picker("Calendar", selection: $calendarID) {
                        ForEach(calendars) { calendar in
                            Text(calendar.title).tag(calendar.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!(event?.allowsEditing ?? true))
                }
            }

            field("Notes") {
                TextField("Optional", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...)
            }

            HStack {
                if isEditing, event?.allowsEditing == true {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "Save" : "Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { load() }
        .onChange(of: start) { _, newStart in
            if end < newStart {
                end = allDay ? newStart : newStart.addingTimeInterval(3600)
            }
        }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Event", role: .destructive) { deleteEvent() }
        }
    }

    private func field<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(CraftFont.section)
            content()
                .padding(10)
                .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(CraftColor.hairline))
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
            dismiss()
        } catch {
            app.flash(error.localizedDescription)
        }
    }

    private func deleteEvent() {
        guard let event else { return }
        do {
            try app.eventKit.deleteEvent(event)
            dismiss()
        } catch {
            app.flash(error.localizedDescription)
        }
    }
}
