import SwiftData
import SwiftUI

struct ProjectView: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app

    private var tab: ProjectTab { app.tab(for: project.id) }

    var body: some View {
        HStack(spacing: 0) {
                ProjectColumn(project: project)
                    .frame(width: 250)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(CraftColor.hairline)
                            .frame(width: 1)
                    }
                    .zIndex(1)
                center
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
        }
    }

    @ViewBuilder
    private var center: some View {
        switch tab {
        case .overview:
            OverviewPage(project: project)
        case .threads:
            if let thread = project.threads.first(where: { $0.id == app.selectedThread }) {
                ThreadPage(thread: thread, project: project).id(thread.id)
            } else {
                ProjectChatCenter(project: project)
            }
        case .notes:
            if let note = project.notes.first(where: { $0.id == app.selectedNote }) {
                NotePage(note: note, project: project).id(note.id)
            } else {
                ProjectChatCenter(project: project)
            }
        case .decisions:
            if let decision = project.decisions.first(where: { $0.id == app.selectedDecision }) {
                DecisionPage(decision: decision, project: project).id(decision.id)
            } else {
                ProjectChatCenter(project: project)
            }
        case .chat:
            ProjectChatCenter(project: project)
        }
    }
}
