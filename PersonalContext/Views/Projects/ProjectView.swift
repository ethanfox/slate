import SwiftData
import SwiftUI

struct ProjectView: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverExpanded = false
    @State private var ignoreHoverUntilExit = false

    private var pinned: Bool { !app.projectColumnCollapsed }
    private var reservedWidth: CGFloat {
        pinned ? ProjectColumnMetrics.expandedWidth : ProjectColumnMetrics.railWidth
    }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: reservedWidth)
                center
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }

            if pinned {
                column(compact: false)
            } else {
                column(compact: true)
                    .zIndex(1)
                    .onHover(perform: handleHover)

                if hoverExpanded {
                    column(compact: false)
                        .zIndex(2)
                        .onHover(perform: handleHover)
                        .transition(reduceMotion ? .opacity : .move(edge: .leading))
                }
            }
        }
        .clipped()
        .onChange(of: app.projectColumnCollapsed) { _, collapsed in
            if collapsed {
                ignoreHoverUntilExit = true
                hoverExpanded = false
            } else {
                hoverExpanded = false
            }
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

    private var tab: ProjectTab { app.tab(for: project.id) }

    private func column(compact: Bool) -> some View {
        ProjectColumn(project: project, compact: compact)
            .frame(
                width: compact ? ProjectColumnMetrics.railWidth : ProjectColumnMetrics.expandedWidth,
                alignment: .leading
            )
            .frame(maxHeight: .infinity)
            .background(CraftColor.canvas)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(CraftColor.hairline)
                    .frame(width: 1)
            }
    }

    private func handleHover(_ hovering: Bool) {
        if !hovering { ignoreHoverUntilExit = false }
        guard app.projectColumnCollapsed, !ignoreHoverUntilExit else {
            if !app.projectColumnCollapsed { hoverExpanded = false }
            return
        }
        if reduceMotion {
            hoverExpanded = hovering
        } else {
            withAnimation(hovering ? ProjectColumnMetrics.openMotion : ProjectColumnMetrics.closeMotion) {
                hoverExpanded = hovering
            }
        }
    }
}
