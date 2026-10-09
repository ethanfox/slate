import AppKit
import SwiftData
import SwiftUI

struct ProjectView: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverExpanded = false
    @State private var ignoreHoverUntilExit = false
    @State private var expandTask: Task<Void, Never>?
    @State private var collapseTask: Task<Void, Never>?

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
                peekColumns
                HoverSensor(onHover: handleHover)
                    .frame(
                        width: hoverExpanded ? ProjectColumnMetrics.expandedWidth : ProjectColumnMetrics.railWidth
                    )
                    .frame(maxHeight: .infinity)
                    .transaction { $0.animation = nil }
            }
        }
        .clipped()
        .onChange(of: app.projectColumnCollapsed) { _, collapsed in
            cancelHoverTasks()
            hoverExpanded = false
            ignoreHoverUntilExit = collapsed
        }
        .onDisappear {
            cancelHoverTasks()
        }
    }

    private var peekColumns: some View {
        ZStack(alignment: .leading) {
            column(compact: true)

            if hoverExpanded {
                column(compact: false)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading))
            }
        }
        .zIndex(1)
    }

    @ViewBuilder
    private var center: some View {
        switch tab {
        case .overview:
            OverviewPage(project: project)
        case .tasks:
            ProjectTasksBoard(project: project)
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
        case .runs:
            if let run = project.runs.first(where: { $0.id == app.selectedRun }) {
                RunPage(run: run).id(run.id)
            } else {
                ProjectRunsEmpty(project: project)
            }
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
        if hovering {
            collapseTask?.cancel()
            collapseTask = nil
            guard app.projectColumnCollapsed, !ignoreHoverUntilExit else { return }
            guard !hoverExpanded else { return }
            expandTask?.cancel()
            expandTask = Task { @MainActor in
                try? await Task.sleep(for: ProjectColumnMetrics.hoverOpenDelay)
                guard !Task.isCancelled else { return }
                guard app.projectColumnCollapsed, !ignoreHoverUntilExit else { return }
                setExpanded(true)
            }
            return
        }

        ignoreHoverUntilExit = false
        expandTask?.cancel()
        expandTask = nil
        guard hoverExpanded else { return }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            guard app.projectColumnCollapsed else { return }
            setExpanded(false)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard hoverExpanded != expanded else { return }
        if reduceMotion {
            hoverExpanded = expanded
        } else {
            withAnimation(expanded ? ProjectColumnMetrics.openMotion : ProjectColumnMetrics.closeMotion) {
                hoverExpanded = expanded
            }
        }
    }

    private func cancelHoverTasks() {
        expandTask?.cancel()
        expandTask = nil
        collapseTask?.cancel()
        collapseTask = nil
    }
}

private struct HoverSensor: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> SensorView {
        let view = SensorView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: SensorView, context: Context) {
        view.onHover = onHover
    }

    final class SensorView: NSView {
        var onHover: ((Bool) -> Void)?
        private var inside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            rebuildTracking(sync: true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                report(false)
            } else {
                rebuildTracking(sync: true)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            rebuildTracking(sync: false)
        }

        override func mouseEntered(with event: NSEvent) {
            report(true)
        }

        override func mouseExited(with event: NSEvent) {
            report(false)
        }

        private var isMouseInside: Bool {
            guard let window, !bounds.isEmpty else { return false }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return bounds.contains(point)
        }

        private func rebuildTracking(sync: Bool) {
            trackingAreas.forEach(removeTrackingArea)
            guard window != nil, !bounds.isEmpty else { return }
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow]
            // Created under the cursor after collapse — without this, leave never fires
            // and the next enter is dropped.
            if isMouseInside {
                options.insert(.assumeInside)
            }
            addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self))
            guard sync else { return }
            if isMouseInside {
                report(true)
            } else if inside {
                report(false)
            }
        }

        private func report(_ hovering: Bool) {
            guard inside != hovering else { return }
            inside = hovering
            onHover?(hovering)
        }
    }
}
