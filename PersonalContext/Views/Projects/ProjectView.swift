import AppKit
import SwiftData
import SwiftUI

/// One project. Its overview is the page that stands for it; a track, note, decision, chat, or run
/// opens over it, and there is no side column of lists.
struct ProjectView: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        center
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear {
                NavTrace.event("project.view appear tab=\(tab.rawValue) thread=\(app.selectedThread?.uuidString ?? "-") note=\(app.selectedNote?.uuidString ?? "-")")
            }
    }

    @ViewBuilder
    private var center: some View {
        switch tab {
        case .overview:
            OverviewPage(project: project)
        case .tasks:
            ProjectTasksBoard(project: project)
        case .threads:
            if let id = app.selectedThread, let thread = TitleIndexStore.thread(id, in: context) {
                ThreadPage(thread: thread, project: project).id(thread.id)
            } else {
                OverviewPage(project: project, listing: .track)
            }
        case .notes:
            if let id = app.selectedNote, let note = TitleIndexStore.note(id, in: context) {
                NotePage(note: note, project: project).id(note.id)
            } else {
                OverviewPage(project: project, listing: .note)
            }
        case .decisions:
            if let id = app.selectedDecision, let decision = TitleIndexStore.decision(id, in: context) {
                DecisionPage(decision: decision, project: project).id(decision.id)
            } else {
                OverviewPage(project: project, listing: .decision)
            }
        case .chat:
            if app.selectedConversation != nil {
                ProjectChatCenter(project: project)
            } else {
                OverviewPage(project: project, listing: .chat)
            }
        case .runs:
            if let id = app.selectedRun, let run = TitleIndexStore.run(id, in: context) {
                RunPage(run: run).id(run.id)
            } else {
                OverviewPage(project: project, listing: .run)
            }
        }
    }

    private var tab: ProjectTab { app.tab(for: project.id) }
}

