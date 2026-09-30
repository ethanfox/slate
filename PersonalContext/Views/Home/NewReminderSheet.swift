import SwiftData
import SwiftUI

struct NewReminderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @Environment(\.openURL) private var openURL

    var reminder: ReminderItem?
    var sourceNote: Note?

    @FocusState private var focusTitle: Bool
    @State private var title = ""
    @State private var listID = ""
    @State private var hasDueDate = false
    @State private var due = Date.now
    @State private var notes = ""
    @State private var confirmDelete = false
    @State private var pickingDue = false
    @State private var agenda: AgendaItem?
    @State private var createdAgenda = false
    @State private var saved = false
    @State private var conflict: AssociationConflict?
    @State private var resolveConflict: (() -> Void)?

    private var isEditing: Bool { reminder != nil }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (reminder?.allowsEditing ?? true)
    }

    private var lists: [EventKitList] {
        var lists = app.eventKit.reminderLists
        if let reminder, !lists.contains(where: { $0.id == reminder.listID }) {
            lists.append(EventKitList(id: reminder.listID, title: reminder.listName, tint: reminder.tint))
            lists.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return lists
    }

    var body: some View {
        form
            .overlay {
                ModalCalendarOverlay(isPresented: pickingDue, onDismiss: { pickingDue = false }) {
                    ModalCalendarPanel(date: $due, includesTime: true, onDismiss: { pickingDue = false })
                }
            }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Reminder" : "New Reminder")
                .font(CraftFont.title)

            ModalField("Title") {
                TextField("Reminder", text: $title)
                    .textFieldStyle(.plain)
                    .focused($focusTitle)
            }

            if !lists.isEmpty {
                ModalControlRow("List") {
                    Picker("List", selection: $listID) {
                        ForEach(lists) { list in
                            Text(list.title).tag(list.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!(reminder?.allowsEditing ?? true))
                }
            }

            ModalControlRow("Due date") {
                Toggle("Due date", isOn: $hasDueDate)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if hasDueDate {
                ModalField("Due", boxed: false) {
                    ModalDateField(date: $due, includesTime: true, isPresented: $pickingDue)
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

            if let meeting = meetingURL {
                ModalActionRow(title: meetingTitle(meeting), systemImage: "video") {
                    openURL(meeting)
                }
                .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            ModalFooter(actionTitle: isEditing ? "Save" : "Create", actionEnabled: canSave, action: save) {
                if isEditing, reminder?.allowsEditing == true {
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
        .confirmationDialog("Delete this reminder?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Reminder", role: .destructive) { deleteReminder() }
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
            Text("This belongs to a different project. Switching moves this reminder and drops links that don’t belong.")
        }
    }

    private func load() {
        guard let reminder else {
            if listID.isEmpty {
                listID = app.eventKit.defaultReminderListID
            }
            return
        }
        title = reminder.title
        listID = reminder.listID
        hasDueDate = reminder.due != nil
        due = reminder.due ?? .now
        notes = reminder.notes
    }

    private func prepareAgenda() {
        if let reminder, let existing = AgendaStore.item(kind: .reminder, eventKitID: reminder.id, in: context) {
            agenda = existing
            return
        }
        let item = AgendaItem(kind: .reminder, eventKitID: reminder?.id ?? "", title: title.isEmpty ? (sourceNote?.displayTitle ?? "") : title)
        context.insert(item)
        createdAgenda = true
        if let sourceNote {
            if title.isEmpty { title = sourceNote.displayTitle }
            item.title = sourceNote.displayTitle
            AssociationService.applyLink(note: sourceNote, onto: item)
        }
        agenda = item
    }

    private var hasAssociations: Bool {
        guard let agenda else { return false }
        return agenda.project != nil || !agenda.tags.isEmpty || !agenda.trackLinks.isEmpty || !agenda.noteLinks.isEmpty
    }

    private func discardIfNeeded() {
        guard !saved, createdAgenda, let agenda else { return }
        if reminder == nil || !hasAssociations {
            context.delete(agenda)
            try? context.save()
        }
    }

    private var meetingURL: URL? {
        CalendarLink.meeting(preferred: reminder?.url, texts: [title, notes])
    }

    private func meetingTitle(_ url: URL) -> String {
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Meeting"
        if host.contains("zoom") { return "Join Zoom" }
        if host.contains("meet.google") { return "Join Google Meet" }
        if host.contains("teams") { return "Join Teams" }
        if host.contains("webex") { return "Join Webex" }
        return "Join Meeting"
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let created: ReminderItem
            if let reminder {
                try app.eventKit.updateReminder(reminder, title: trimmed, listID: listID, due: hasDueDate ? due : nil, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
                created = reminder
            } else {
                created = try app.eventKit.createReminder(title: trimmed, listID: listID, due: hasDueDate ? due : nil, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let agenda {
                agenda.title = trimmed
                if hasAssociations || !createdAgenda {
                    agenda.eventKitID = created.id
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

    private func deleteReminder() {
        guard let reminder else { return }
        do {
            try app.eventKit.deleteReminder(reminder)
            modalDismiss()
        } catch {
            app.flash(error.localizedDescription)
        }
    }
}
