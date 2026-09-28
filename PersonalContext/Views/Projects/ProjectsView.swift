import SwiftData
import SwiftUI

struct ProjectsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var projects: [Project]
    @State private var pendingDelete: Project?

    private var ordered: [Project] {
        projects.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    var body: some View {
        PageBody {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if ordered.isEmpty {
                        EmptyLine(text: "Create a project with a name, an icon, and a short description.")
                    } else {
                        ForEach(ordered) { project in
                            Button {
                                app.open(project)
                            } label: {
                                ProjectLine(project: project)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(project.isPinned ? "Unpin" : "Pin") {
                                    project.isPinned.toggle()
                                    project.touch()
                                }
                                Button("Delete", role: .destructive) {
                                    pendingDelete = project
                                }
                            }
                            if project.id != ordered.last?.id {
                                Hairline(leading: 30)
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .alert(
            "Delete \(pendingDelete?.name ?? "this project")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let project = pendingDelete {
                    context.delete(project)
                    try? context.save()
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Threads, notes, decisions, and conversations in this project will be removed from this Mac.")
        }
    }
}
