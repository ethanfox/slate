import SwiftUI

struct NewReminderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modalDismiss) private var modalDismiss

    var reminder: ReminderItem?

    @FocusState private var focusTitle: Bool
    @State private var title = ""
    @State private var listID = ""
    @State private var hasDueDate = false
    @State private var due = Date.now
    @State private var confirmDelete = false

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
                    DatePicker("Due", selection: $due, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
            }

            ModalFooter(actionTitle: isEditing ? "Save" : "Create", actionEnabled: canSave, action: save) {
                if isEditing, reminder?.allowsEditing == true {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .onAppear {
            load()
            focusTitle = true
        }
        .confirmationDialog("Delete this reminder?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Reminder", role: .destructive) { deleteReminder() }
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
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if let reminder {
                try app.eventKit.updateReminder(reminder, title: trimmed, listID: listID, due: hasDueDate ? due : nil)
            } else {
                try app.eventKit.createReminder(title: trimmed, listID: listID, due: hasDueDate ? due : nil)
            }
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
