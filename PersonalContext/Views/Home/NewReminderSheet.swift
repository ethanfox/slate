import SwiftData
import SwiftUI

struct NewTaskSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @Environment(\.openURL) private var openURL

    var reminder: ReminderItem?
    var task: AgendaItem?
    var sourceNote: Note?

    @FocusState private var focusTitle: Bool
    @State private var title = ""
    @State private var itemType: AgendaKind = .task
    @State private var listID = ""
    @State private var hasDueDate = false
    @State private var due = Date.now
    @State private var notes = ""
    @State private var repeatRule: TaskRepeat = .none
    @State private var confirmDelete = false
    @State private var pickingDue = false
    @State private var agenda: AgendaItem?
    @State private var createdAgenda = false
    @State private var saved = false
    @State private var conflict: AssociationConflict?
    @State private var resolveConflict: (() -> Void)?

    private var isEditing: Bool { reminder != nil || task != nil }
    private var allowsEditing: Bool { reminder?.allowsEditing ?? true }
    private var canSave: Bool {
        let named = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard named, allowsEditing else { return false }
        if itemType == .reminder { return !listID.isEmpty }
        return true
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
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(headerTitle)
                .font(CraftFont.title)

            ViewThatFits(in: .vertical) {
                fields
                ModalScroll { fields }
            }

            if let meeting = meetingURL {
                ModalActionRow(title: meetingTitle(meeting), systemImage: "video") {
                    openURL(meeting)
                }
                .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            ModalFooter(actionTitle: isEditing ? "Save" : "Create", actionEnabled: canSave, action: save) {
                if isEditing, allowsEditing {
                    ModalFooterButton(title: "Delete", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .onAppear {
            load()
            prepareAgenda()
            focusTitle = true
        }
        .onDisappear { discardIfNeeded() }
        .onChange(of: itemType) { _, newType in
            if newType == .reminder {
                Task { await ensureReminderAccess() }
            }
        }
        .onChange(of: hasDueDate) { _, on in
            if !on { repeatRule = .none }
        }
        .onChange(of: repeatRule) { _, rule in
            if rule != .none, !hasDueDate {
                hasDueDate = true
                due = .now
            }
        }
        .confirmationDialog(deletePrompt, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(deleteActionTitle, role: .destructive) { deleteItem() }
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
            Text("This belongs to a different project. Switching moves this item and drops links that don’t belong.")
        }
    }

    private var headerTitle: String {
        if !isEditing { return "New Task" }
        return itemType.label
    }

    private var deletePrompt: String {
        itemType == .reminder ? "Delete this reminder?" : "Delete this task?"
    }

    private var deleteActionTitle: String {
        itemType == .reminder ? "Delete Reminder" : "Delete Task"
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModalField("Title") {
                TextField("Task", text: $title)
                    .textFieldStyle(.plain)
                    .focused($focusTitle)
            }

            ModalControlRow("Type") {
                Picker("Type", selection: $itemType) {
                    Text("Task").tag(AgendaKind.task)
                    Text("Reminder").tag(AgendaKind.reminder)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(!allowsEditing)
            }

            if itemType == .reminder, !lists.isEmpty {
                ModalControlRow("List") {
                    Picker("List", selection: $listID) {
                        ForEach(lists) { list in
                            Text(list.title).tag(list.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!allowsEditing)
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

                ModalControlRow("Repeat") {
                    Picker("Repeat", selection: $repeatRule) {
                        ForEach(TaskRepeat.pickerCases(including: repeatRule)) { rule in
                            Text(rule.label).tag(rule)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!allowsEditing)
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
        }
    }

    private func load() {
        if let task {
            title = task.title
            itemType = .task
            hasDueDate = task.due != nil
            due = task.due ?? .now
            notes = task.notes
            repeatRule = task.repeatRule
            return
        }
        if let reminder {
            title = reminder.title
            itemType = .reminder
            listID = reminder.listID
            hasDueDate = reminder.due != nil
            due = reminder.due ?? .now
            notes = reminder.notes
            repeatRule = reminder.repeatRule
            return
        }
        itemType = .task
        if listID.isEmpty {
            listID = app.eventKit.defaultReminderListID
        }
    }

    private func prepareAgenda() {
        if let task {
            agenda = task
            return
        }
        if let reminder, let existing = AgendaStore.item(kind: .reminder, eventKitID: reminder.id, in: context) {
            agenda = existing
            return
        }
        let item = AgendaItem(
            kind: reminder == nil ? .task : .reminder,
            eventKitID: reminder?.id ?? "",
            title: title.isEmpty ? (sourceNote?.displayTitle ?? "") : title
        )
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
        context.delete(agenda)
        try? context.save()
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

    private func ensureReminderAccess() async {
        if !app.eventKit.canWriteReminders {
            await app.eventKit.requestRemindersAccess()
        }
        if app.eventKit.canWriteReminders {
            await app.eventKit.prepareReminders()
            if listID.isEmpty {
                listID = app.eventKit.defaultReminderListID
            }
            if listID.isEmpty {
                itemType = .task
                app.flash("No Reminders list available.")
            }
        } else {
            app.eventKit.openSettings(for: .reminder)
            itemType = .task
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if itemType == .task {
                try saveTask(title: trimmed)
            } else {
                try saveReminder(title: trimmed)
            }
            saved = true
            modalDismiss()
        } catch {
            app.flash(error.localizedDescription)
        }
    }

    private func saveTask(title: String) throws {
        let completed = reminder?.isCompleted
        if let reminder {
            try app.eventKit.deleteReminder(reminder)
        }
        guard let agenda else { return }
        if let completed { agenda.isCompleted = completed }
        agenda.kind = .task
        agenda.eventKitID = ""
        agenda.title = title
        agenda.due = hasDueDate ? due : nil
        agenda.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        agenda.repeatRule = hasDueDate ? repeatRule : .none
        agenda.touch()
        try context.save()
    }

    private func saveReminder(title: String) throws {
        let dueDate = hasDueDate ? due : nil
        let scratch = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = hasDueDate ? repeatRule : .none
        let created: ReminderItem
        if let reminder {
            try app.eventKit.updateReminder(reminder, title: title, listID: listID, due: dueDate, notes: scratch, repeatRule: rule)
            created = reminder
        } else {
            created = try app.eventKit.createReminder(title: title, listID: listID, due: dueDate, notes: scratch, repeatRule: rule)
        }
        guard let agenda else { return }
        agenda.kind = .reminder
        agenda.title = title
        if hasAssociations || !createdAgenda || task != nil {
            agenda.eventKitID = created.id
            agenda.due = dueDate
            agenda.notes = scratch
            agenda.repeatRule = rule == .custom ? .none : rule
            agenda.touch()
            try context.save()
        } else {
            context.delete(agenda)
            try context.save()
        }
    }

    private func deleteItem() {
        if let task {
            context.delete(task)
            try? context.save()
            saved = true
            modalDismiss()
            return
        }
        guard let reminder else { return }
        do {
            try app.eventKit.deleteReminder(reminder)
            if let agenda {
                context.delete(agenda)
                try? context.save()
            }
            saved = true
            modalDismiss()
        } catch {
            app.flash(error.localizedDescription)
        }
    }
}
