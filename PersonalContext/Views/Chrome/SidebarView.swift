import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var projects: [Project]
    @State private var pendingDelete: Project?

    private var orderedProjects: [Project] {
        projects.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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
                    row("Home", "house", destination: .home)

                    section("Workspace")
                    row("Projects", "square.stack", destination: .projects)
                    row("Tasks", "checklist", destination: .tasks)
                    row("Calendar", "calendar", destination: .calendar)

                    if !orderedProjects.isEmpty {
                        section("Projects")
                        ForEach(orderedProjects) { project in
                            Button {
                                app.open(project)
                            } label: {
                                SidebarRow(
                                    title: project.name.isEmpty ? "Untitled" : project.name,
                                    systemImage: project.symbol,
                                    isSelected: app.destination == .project(project.id),
                                    showsPin: project.isPinned
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    app.present(.editProject(project))
                                } label: {
                                    Label("Edit…", systemImage: "pencil")
                                }
                                Button {
                                    project.isPinned.toggle()
                                    project.touch()
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
        .alert(item: $pendingDelete) { project in
            Alert(
                title: Text("Delete \(project.name)?"),
                message: Text("Tracks, notes, decisions, and conversations in this project will be removed from this Mac."),
                primaryButton: .destructive(Text("Delete")) {
                    if case .project(let id) = app.destination, id == project.id {
                        app.destination = .projects
                    }
                    context.delete(project)
                    try? context.save()
                },
                secondaryButton: .cancel()
            )
        }
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

    private func row(_ title: String, _ symbol: String, destination: Destination) -> some View {
        Button {
            app.destination = destination
        } label: {
            SidebarRow(title: title, systemImage: symbol, isSelected: app.destination == destination)
        }
        .buttonStyle(.plain)
    }
}
