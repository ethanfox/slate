import SwiftUI

struct NewReminderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var reminder: ReminderItem?

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

            field("Title") {
                TextField("Reminder", text: $title)
                    .textFieldStyle(.plain)
            }

            if !lists.isEmpty {
                HStack {
                    Text("List")
                        .font(CraftFont.body)
                    Spacer(minLength: 16)
                    Picker("List", selection: $listID) {
                        ForEach(lists) { list in
                            Text(list.title).tag(list.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!(reminder?.allowsEditing ?? true))
                }
            }

            HStack {
                Text("Due date")
                    .font(CraftFont.body)
                Spacer()
                Toggle("Due date", isOn: $hasDueDate)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if hasDueDate {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Due")
                        .font(CraftFont.section)
                    DatePicker("Due", selection: $due, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
            }

            HStack {
                if isEditing, reminder?.allowsEditing == true {
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
        .confirmationDialog("Delete this reminder?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Reminder", role: .destructive) { deleteReminder() }
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
            dismiss()
        } catch {
            app.flash(error.localizedDescription)
        }
    }

    private func deleteReminder() {
        guard let reminder else { return }
        do {
            try app.eventKit.deleteReminder(reminder)
            dismiss()
        } catch {
            app.flash(error.localizedDescription)
        }
    }
}
