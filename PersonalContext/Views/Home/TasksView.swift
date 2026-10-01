import EventKit
import SwiftUI

struct TasksView: View {
    @Environment(AppModel.self) private var app
    @State private var completedOpen = false

    var body: some View {
        ScrollView {
            PageBody {
                content
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
        .task { await app.eventKit.prepareReminders() }
    }

    @ViewBuilder
    private var content: some View {
        switch app.eventKit.remindersAccess {
        case .fullAccess:
            lists
        case .notDetermined, .writeOnly:
            EventKitAccessLine(
                text: "Slate needs Reminders access to show your tasks.",
                actionTitle: "Allow Reminders Access"
            ) {
                Task { await app.eventKit.requestRemindersAccess() }
            }
        case .denied, .restricted:
            EventKitAccessLine(
                text: "Reminders access is off. Enable it in System Settings.",
                actionTitle: "Open Settings"
            ) {
                app.eventKit.openSettings(for: .reminder)
            }
        @unknown default:
            EventKitAccessLine(
                text: "Reminders access is off. Enable it in System Settings.",
                actionTitle: "Open Settings"
            ) {
                app.eventKit.openSettings(for: .reminder)
            }
        }
    }

    @ViewBuilder
    private var lists: some View {
        if openGroups.isEmpty && completedItems.isEmpty {
            EmptyLine(text: "No reminders.")
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(openGroups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(group.tint.color)
                                .frame(width: 6, height: 6)
                            Text(group.title)
                                .font(CraftFont.section)
                        }
                        .padding(.bottom, 8)
                        ForEach(group.items) { item in
                            ReminderRow(item: item, onToggle: { toggle(item) })
                        }
                    }
                }

                if !completedItems.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            completedOpen.toggle()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: completedOpen ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12)
                                Text("Completed")
                                    .font(CraftFont.section)
                                Text("\(completedItems.count)")
                                    .font(CraftFont.caption)
                                    .foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Completed")
                        .accessibilityValue(completedOpen ? "Expanded" : "Collapsed")
                        .accessibilityHint("Shows completed reminders")

                        if completedOpen {
                            ForEach(completedItems) { item in
                                ReminderRow(item: item, onToggle: { toggle(item) })
                            }
                            .padding(.top, 8)
                        }
                    }
                }
            }
        }
    }

    private var openGroups: [ReminderGroup] {
        groups(from: app.eventKit.reminders.filter { !$0.isCompleted })
    }

    private var completedItems: [ReminderItem] {
        app.eventKit.reminders.filter(\.isCompleted)
    }

    private func groups(from items: [ReminderItem]) -> [ReminderGroup] {
        let grouped = Dictionary(grouping: items, by: \.listID)
        return grouped.keys.compactMap { id -> ReminderGroup? in
            guard let items = grouped[id], let name = items.first?.listName else { return nil }
            return ReminderGroup(id: id, title: name, tint: items.first?.tint ?? .neutral, items: items)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func toggle(_ item: ReminderItem) {
        do {
            try app.eventKit.setCompleted(item, completed: !item.isCompleted)
        } catch {
            app.flash(error.localizedDescription)
        }
    }
}

private struct ReminderRow: View {
    @Environment(AppModel.self) private var app
    var item: ReminderItem
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.tint.color)
                    .opacity(item.isCompleted ? 0.45 : 1)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isCompleted ? "Mark incomplete" : "Mark complete")
            .accessibilityLabel(item.isCompleted ? "Mark \(title) incomplete" : "Mark \(title) complete")

            Button {
                app.present(.editReminder(item))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .strikethrough(item.isCompleted)
                            .foregroundStyle(item.isCompleted ? .tertiary : .primary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        EventAgendaMarks(kind: .reminder, eventKitID: item.id)
                    }
                    if !item.notes.isEmpty {
                        Text(item.notes)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let due = item.due {
                        Text(dueLabel(due))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit reminder")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? CraftColor.hover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }

    private var title: String {
        item.title.isEmpty ? "Untitled" : item.title
    }

    private func dueLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Due today"
        }
        if Calendar.current.isDateInTomorrow(date) {
            return "Due tomorrow"
        }
        return "Due \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct ReminderGroup: Identifiable {
    var id: String
    var title: String
    var tint: CalendarTint
    var items: [ReminderItem]
}
