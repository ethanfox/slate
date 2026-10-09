import AppKit
import SwiftData
import SwiftUI

private enum TabDragSpace {
    static let name = "windowTabs"
    static let slot: CGFloat = 156
    static let chip = CGSize(width: 148, height: 28)
}

struct WindowTabStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var projects: [Project]
    @Query private var notes: [Note]
    @Query private var threads: [ProjectThread]
    @Query private var decisions: [Decision]
    @Query private var conversations: [Conversation]
    @Query private var runs: [AgentRun]
    @State private var draggingID: UUID?
    @State private var previewIDs: [UUID]?
    @State private var frames: [UUID: CGRect] = [:]
    @State private var liftFrame: CGRect = .zero
    @State private var dragX: CGFloat = 0
    @State private var hoveredID: UUID?
    @State private var hoverWait: Task<Void, Never>?
    @State private var overflowLeading = false
    @State private var overflowTrailing = false
    @State private var stripWidth: CGFloat = 0
    @State private var scrollX: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            TabHistoryControls()
            if app.windowTabs.count < 2 {
                single
            } else {
                strip
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: TabDragSpace.chip.height)
            }
        }
        .frame(maxWidth: app.windowTabs.count < 2 ? nil : .infinity, alignment: .leading)
    }

    private var single: some View {
        HStack(spacing: 8) {
            Image(systemName: label(for: app.windowTabs.first ?? .home()).symbol)
                .font(CraftFont.titleIcon)
                .frame(width: 22, height: 22)
            Text(label(for: app.windowTabs.first ?? .home()).title)
                .font(CraftFont.title)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var displayedTabs: [WindowTab] {
        let tabs = app.windowTabs
        guard let previewIDs else { return tabs }
        return previewIDs.compactMap { id in tabs.first { $0.id == id } }
    }

    private var stripMotion: Animation? {
        reduceMotion ? nil : Motion.snappy
    }

    private var showingEdgeBlur: Bool {
        !reduceMotion && stripWidth > 0 && (overflowLeading || overflowTrailing)
    }

    @ViewBuilder
    private func tabRow(interactive: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(displayedTabs) { tab in
                tabChip(tab, drag: interactive)
                    .id(tab.id)
                    .opacity(interactive && draggingID == tab.id ? 0.35 : 1)
                    .onGeometryChange(for: CGRect.self) { geo in
                        geo.frame(in: .named(TabDragSpace.name))
                    } action: { frame in
                        guard interactive else { return }
                        frames[tab.id] = frame
                    }
            }
        }
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                tabRow(interactive: true)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(draggingID != nil)
            .coordinateSpace(name: TabDragSpace.name)
            .frame(height: TabDragSpace.chip.height)
            .mask {
                TabScrollViewportMask(
                    mode: .sharp,
                    stripWidth: stripWidth,
                    overflowLeading: overflowLeading,
                    overflowTrailing: overflowTrailing,
                    active: showingEdgeBlur
                )
            }
            .overlay(alignment: .topLeading) {
                if showingEdgeBlur {
                    tabRow(interactive: false)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, TabScrollBlur.radius)
                        .padding(.vertical, TabScrollBlur.radius)
                        .offset(x: -scrollX)
                        .compositingGroup()
                        .blur(radius: TabScrollBlur.radius)
                        .padding(.horizontal, -TabScrollBlur.radius)
                        .padding(.vertical, -TabScrollBlur.radius)
                        .frame(width: stripWidth, height: TabDragSpace.chip.height, alignment: .leading)
                        .mask {
                            TabScrollViewportMask(
                                mode: .blur,
                                stripWidth: stripWidth,
                                overflowLeading: overflowLeading,
                                overflowTrailing: overflowTrailing,
                                active: true
                            )
                        }
                        .allowsHitTesting(false)
                }
            }
            .onScrollGeometryChange(for: TabScrollMetrics.self) { geometry in
                let leadingInset = geometry.contentInsets.leading
                let trailingInset = geometry.contentInsets.trailing
                return TabScrollMetrics(
                    leading: geometry.contentOffset.x + leadingInset > 0.5,
                    trailing: geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - trailingInset - 0.5,
                    width: geometry.containerSize.width,
                    scrollX: geometry.visibleRect.minX
                )
            } action: { _, metrics in
                overflowLeading = metrics.leading
                overflowTrailing = metrics.trailing
                stripWidth = metrics.width
                scrollX = metrics.scrollX
            }
            .overlay(alignment: .topLeading) { lift }
            .overlay(alignment: .topLeading) { hoverPane }
            .onAppear { scroll(proxy) }
            .onChange(of: app.selectedTabID) { _, _ in
                guard draggingID == nil else { return }
                scroll(proxy)
            }
        }
    }

    @ViewBuilder
    private var hoverPane: some View {
        if draggingID == nil, let hoveredID, let tab = app.windowTabs.first(where: { $0.id == hoveredID }) {
            let info = label(for: tab)
            TabHoverPane(
                title: info.title,
                projectName: info.projectName,
                projectSymbol: info.projectSymbol
            )
            .offset(
                x: frames[hoveredID]?.minX ?? 0,
                y: TabDragSpace.chip.height + 6
            )
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private func setHover(_ id: UUID, _ hovering: Bool) {
        hoverWait?.cancel()
        if hovering {
            hoverWait = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(380))
                guard !Task.isCancelled, draggingID == nil else { return }
                withAnimation(reduceMotion ? nil : Motion.hover) {
                    hoveredID = id
                }
            }
        } else {
            withAnimation(reduceMotion ? nil : Motion.hover) {
                if hoveredID == id { hoveredID = nil }
            }
        }
    }

    @ViewBuilder
    private var lift: some View {
        if let draggingID, let tab = app.windowTabs.first(where: { $0.id == draggingID }) {
            WindowTabChip(
                title: label(for: tab).title,
                symbol: label(for: tab).symbol,
                isSelected: true,
                isGenerating: false,
                allowsDrag: false,
                onSelect: {},
                onClose: {},
                onDrag: { _ in },
                onDragEnd: {}
            )
            .offset(x: liftFrame.minX + dragX, y: liftFrame.minY)
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            .allowsHitTesting(false)
        }
    }

    private func dragMoved(_ id: UUID, _ dx: CGFloat) {
        if draggingID == nil {
            draggingID = id
            hoveredID = nil
            hoverWait?.cancel()
            liftFrame = frames[id] ?? CGRect(origin: .zero, size: TabDragSpace.chip)
            previewIDs = app.windowTabs.map(\.id)
        }
        dragX = dx
        let next = previewOrder(dragging: id, dx: dx)
        guard next != previewIDs else { return }
        withAnimation(stripMotion) {
            previewIDs = next
        }
    }

    private func commitDrag() {
        let ids = previewIDs
        draggingID = nil
        previewIDs = nil
        dragX = 0
        if let ids {
            app.reorderTabs(ids)
        }
    }

    private func previewOrder(dragging: UUID, dx: CGFloat) -> [UUID] {
        let ids = app.windowTabs.map(\.id)
        guard let from = ids.firstIndex(of: dragging) else { return ids }
        let to = min(ids.count - 1, max(0, from + Int((dx / TabDragSpace.slot).rounded())))
        var next = ids
        next.remove(at: from)
        next.insert(dragging, at: to)
        return next
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(app.selectedTabID, anchor: .center)
    }

    private func tabChip(_ tab: WindowTab, drag: Bool) -> WindowTabChip {
        WindowTabChip(
            title: label(for: tab).title,
            symbol: label(for: tab).symbol,
            isSelected: tab.id == app.selectedTabID,
            isGenerating: isGenerating(tab),
            allowsDrag: drag,
            onSelect: { app.selectTab(tab.id) },
            onClose: { app.closeTab(tab.id) },
            onDrag: { dragMoved(tab.id, $0) },
            onDragEnd: commitDrag,
            onHoverChange: { setHover(tab.id, $0) }
        )
    }

    private func isGenerating(_ tab: WindowTab) -> Bool {
        guard let id = tab.generatingID else { return false }
        if app.runningChats.contains(where: { $0.id == id }) { return true }
        return app.runCoordinator.running.contains { $0.id == id }
    }

    private func runTitle(_ id: UUID) -> String {
        runs.first { $0.id == id }?.displayTitle ?? "New run"
    }

    private func label(for tab: WindowTab) -> TabLabel {
        switch tab.destination {
        case .home:
            return TabLabel(title: "Home", symbol: "house")
        case .projects:
            return TabLabel(title: "Projects", symbol: "square.stack")
        case .tasks:
            return TabLabel(title: "Tasks", symbol: "checklist")
        case .calendar:
            return TabLabel(title: "Calendar", symbol: "calendar")
        case .chats:
            return TabLabel(title: "Chats", symbol: "bubble.left.and.bubble.right")
        case .runs:
            return TabLabel(title: "Runs", symbol: "play.circle")
        case .run(let id):
            return TabLabel(title: runTitle(id), symbol: "play.circle")
        case .settings:
            return TabLabel(title: "Settings", symbol: "gearshape")
        case .quickAsk(let id):
            if let conversation = conversations.first(where: { $0.id == id }), !conversation.title.isEmpty {
                return TabLabel(title: conversation.title, symbol: "bubble.left")
            }
            return TabLabel(title: "Quick Ask", symbol: "bubble.left")
        case .project(let id):
            let project = projects.first { $0.id == id }
            let projectName = project?.name.isEmpty == false ? project!.name : "Untitled"
            let projectSymbol = project?.symbol.isEmpty == false ? project!.symbol : "folder"
            switch tab.viewKey {
            case .thread(let threadID):
                let title = threads.first { $0.id == threadID }?.title
                return TabLabel(
                    title: title?.isEmpty == false ? title! : "Untitled",
                    symbol: TrackStyle.symbol,
                    projectName: projectName,
                    projectSymbol: projectSymbol
                )
            case .note(let noteID):
                let title = notes.first { $0.id == noteID }?.displayTitle
                return TabLabel(
                    title: title?.isEmpty == false ? title! : "Untitled",
                    symbol: "note.text",
                    projectName: projectName,
                    projectSymbol: projectSymbol
                )
            case .decision(let decisionID):
                let title = decisions.first { $0.id == decisionID }?.title
                return TabLabel(
                    title: title?.isEmpty == false ? title! : "Untitled",
                    symbol: "checkmark.seal",
                    projectName: projectName,
                    projectSymbol: projectSymbol
                )
            case .conversation(let conversationID):
                let title = conversations.first { $0.id == conversationID }?.title
                return TabLabel(
                    title: title?.isEmpty == false ? title! : "Chat",
                    symbol: "bubble.left",
                    projectName: projectName,
                    projectSymbol: projectSymbol
                )
            case .run(let runID):
                return TabLabel(
                    title: runTitle(runID),
                    symbol: "play.circle",
                    projectName: projectName,
                    projectSymbol: projectSymbol
                )
            case .projectRuns:
                return TabLabel(
                    title: "\(projectName): Runs",
                    symbol: "play.circle",
                    projectName: projectName,
                    projectSymbol: projectSymbol
                )
            case .projectTasks:
                return TabLabel(
                    title: "\(projectName): Tasks",
                    symbol: "checklist",
                    projectName: projectName,
                    projectSymbol: projectSymbol
                )
            default:
                return TabLabel(title: projectName, symbol: projectSymbol)
            }
        }
    }
}

private struct TabLabel {
    var title: String
    var symbol: String
    var projectName: String?
    var projectSymbol: String?
}

private struct TabScrollMetrics: Equatable {
    var leading: Bool
    var trailing: Bool
    var width: CGFloat
    var scrollX: CGFloat
}

private enum TabScrollBlur {
    static let fade: CGFloat = 56
    static let radius: CGFloat = 10
}

private enum TabScrollViewportMaskMode {
    case sharp
    case blur
}

private struct TabScrollViewportMask: View {
    var mode: TabScrollViewportMaskMode
    var stripWidth: CGFloat
    var overflowLeading: Bool
    var overflowTrailing: Bool
    var active: Bool

    var body: some View {
        if active, stripWidth > 0 {
            Rectangle()
                .fill(.linearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
        } else {
            Color.white
        }
    }

    private var fade: CGFloat {
        min(TabScrollBlur.fade / stripWidth, 0.5)
    }

    private var stops: [Gradient.Stop] {
        let f = fade
        let peak = f * 0.42

        switch mode {
        case .sharp:
            var s: [Gradient.Stop] = []
            if overflowLeading {
                s += [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: f),
                ]
            } else {
                s.append(.init(color: .white, location: 0))
            }
            if overflowTrailing {
                s += [
                    .init(color: .white, location: 1 - f),
                    .init(color: .clear, location: 1),
                ]
            } else {
                s.append(.init(color: .white, location: 1))
            }
            return s.sorted { $0.location < $1.location }

        case .blur:
            var s: [Gradient.Stop] = []
            if overflowLeading {
                s += [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: peak),
                    .init(color: .clear, location: f),
                ]
            } else {
                s.append(.init(color: .clear, location: 0))
            }
            if overflowTrailing {
                s += [
                    .init(color: .clear, location: 1 - f),
                    .init(color: .white, location: 1 - peak),
                    .init(color: .clear, location: 1),
                ]
            } else {
                s.append(.init(color: .clear, location: 1))
            }
            return s.sorted { $0.location < $1.location }
        }
    }
}

private struct TabHistoryControls: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            TabHistoryButton(title: "Back", symbol: "chevron.backward", enabled: app.canGoBack) {
                app.goBack()
            }
            TabHistoryButton(title: "Forward", symbol: "chevron.forward", enabled: app.canGoForward) {
                app.goForward()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TabHistoryButton: View {
    var title: String
    var symbol: String
    var enabled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(CraftFont.tabIcon)
                .foregroundStyle(enabled ? .secondary : .tertiary)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(hovering && enabled ? CraftColor.hover : Color.clear)
                        .animation(Motion.hover, value: hovering)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
    }
}

private struct WindowTabChip: View {
    var title: String
    var symbol: String
    var isSelected: Bool
    var isGenerating: Bool
    var allowsDrag: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void
    var onHoverChange: (Bool) -> Void = { _ in }
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 10) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: symbol)
                        .font(CraftFont.tabIcon)
                        .frame(width: 12, height: 12)
                }
                Text(title)
                    .font(isSelected ? CraftFont.tab : CraftFont.tabIdle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .contentShape(Rectangle())
            .overlay {
                if allowsDrag {
                    TabDragHandle(onMoved: onDrag, onEnded: onDragEnd, onClick: onSelect)
                }
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Tab")
            .accessibilityLabel("Close \(title)")
        }
        .padding(.leading, 10.5)
        .padding(.trailing, 3)
        .frame(width: TabDragSpace.chip.width, height: TabDragSpace.chip.height)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? CraftColor.selection : Color.clear)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(!isSelected && hovering ? CraftColor.hover : Color.clear)
                .animation(Motion.hover, value: hovering)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { over in
            hovering = over
            onHoverChange(over)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TabHoverPane: View {
    var title: String
    var projectName: String?
    var projectSymbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CraftFont.body)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let projectName, let projectSymbol {
                HStack(spacing: 5) {
                    Image(systemName: projectSymbol)
                        .font(CraftFont.caption)
                        .frame(width: 12, height: 12)
                    Text(projectName)
                        .font(CraftFont.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 240, alignment: .leading)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CraftColor.hairline)
        }
    }
}

private struct TabDragHandle: NSViewRepresentable {
    var onMoved: (CGFloat) -> Void
    var onEnded: () -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> TabDragHandleView {
        let view = TabDragHandleView()
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: TabDragHandleView, context: Context) {
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onClick = onClick
    }
}

private final class TabDragHandleView: NSView {
    var onMoved: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?
    var onClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startX = event.locationInWindow.x
        var lifted = false
        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }

            if next.type == .leftMouseUp {
                if lifted {
                    onEnded?()
                } else {
                    onClick?()
                }
                return
            }

            let dx = next.locationInWindow.x - startX
            if !lifted {
                guard abs(dx) >= 4 else { continue }
                lifted = true
            }
            onMoved?(dx)
        }
    }
}
