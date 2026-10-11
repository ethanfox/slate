import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TitleIndex> { $0.kindRaw == "project" }, sort: \TitleIndex.title)
    private var projects: [TitleIndex]
    @Query(filter: #Predicate<AgendaItem> { $0.kindRaw == "task" && $0.isCompleted == false })
    private var openTasks: [AgendaItem]
    @State private var pendingDelete: TitleIndex?

    private var orderedProjects: [TitleIndex] {
        projects.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row("You", "person", destination: .home, selected: isOnYou)

                    section("Workspace")
                    row("Projects", "square.stack", destination: .projects)
                    row("Tasks", "checklist", destination: .tasks, badge: dueCount)
                    row("Calendar", "calendar", destination: .calendar)
                    row("Chats", "bubble.left.and.bubble.right", destination: .chats, busy: !app.runningChats.isEmpty)
                    row("Runs", "play.circle", destination: .runs, busy: !app.runCoordinator.running.isEmpty)

                    if !orderedProjects.isEmpty {
                        section("Projects")
                        ForEach(orderedProjects) { project in
                            Button {
                                app.open(project)
                            } label: {
                                SidebarRow(
                                    title: project.displayTitle,
                                    systemImage: project.symbol.isEmpty ? "folder" : project.symbol,
                                    isSelected: app.destination == .project(project.id),
                                    showsPin: project.isPinned
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    if let record = TitleIndexStore.project(project.id, in: context) {
                                        app.present(.editProject(record))
                                    }
                                } label: {
                                    Label("Edit…", systemImage: "pencil")
                                }
                                Button {
                                    app.open(project, newTab: true)
                                } label: {
                                    Label("Open in New Tab", systemImage: "plus.square.on.square")
                                }
                                Button {
                                    if let record = TitleIndexStore.project(project.id, in: context) {
                                        record.isPinned.toggle()
                                        record.touch()
                                        try? context.persist()
                                    }
                                } label: {
                                    Label(project.isPinned ? "Unpin" : "Pin", systemImage: project.isPinned ? "pin.slash" : "pin")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    pendingDelete = project
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)

            row("Settings", "gearshape", destination: .settings)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
        }
        .alert(item: $pendingDelete) { row in
            Alert(
                title: Text("Delete \(row.displayTitle)?"),
                message: Text("Tracks, notes, decisions, and conversations in this project will be removed from this Mac."),
                primaryButton: .destructive(Text("Delete")) {
                    guard let project = TitleIndexStore.project(row.id, in: context) else { return }
                    RunStore.cancelActive(in: project, context: context)
                    app.closeTabs(forProject: project.id)
                    CodeReferenceStore.deleteOwnedReferences(in: project, context: context)
                    context.delete(project)
                    try? context.persist()
                },
                secondaryButton: .cancel()
            )
        }
        .task { await app.eventKit.prepareReminders() }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(CraftFont.section)
            .foregroundStyle(.secondary)
            .padding(.top, 20)
            .padding(.bottom, 4)
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
    }

    private func row(
        _ title: String,
        _ symbol: String,
        destination: Destination,
        badge: Int = 0,
        busy: Bool = false,
        selected: Bool? = nil
    ) -> some View {
        Button {
            app.navigate(to: destination)
        } label: {
            SidebarRow(
                title: title,
                systemImage: symbol,
                isSelected: selected ?? (app.destination == destination),
                badge: badge,
                isBusy: busy
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                app.navigate(to: destination, newTab: true)
            } label: {
                Label("Open in New Tab", systemImage: "plus.square.on.square")
            }
        }
        .accessibilityValue(busy ? "Working" : badge > 0 ? "\(badge) due" : "")
    }

    /// About you and Spaces are opened from You, so they keep its row lit.
    private var isOnYou: Bool {
        switch app.destination {
        case .home, .aboutYou, .space: true
        default: false
        }
    }

    private var dueCount: Int {
        let tasks = openTasks.filter { task in
            guard let due = task.due else { return false }
            return TaskDue.isOutstanding(due)
        }.count
        let reminders = app.eventKit.reminders.filter { ReminderItem.isAttention($0) }.count
        return tasks + reminders
    }
}
