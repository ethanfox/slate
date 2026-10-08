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
    @State private var draggingID: UUID?
    @State private var previewIDs: [UUID]?
    @State private var frames: [UUID: CGRect] = [:]
    @State private var liftFrame: CGRect = .zero
    @State private var dragX: CGFloat = 0
    @State private var hoveredID: UUID?
    @State private var hoverWait: Task<Void, Never>?

    var body: some View {
        if app.windowTabs.count < 2 {
            single
        } else {
            strip
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: TabDragSpace.chip.height)
        }
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

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(displayedTabs) { tab in
                        WindowTabChip(
                            title: label(for: tab).title,
                            symbol: label(for: tab).symbol,
                            isSelected: tab.id == app.selectedTabID,
                            isGenerating: isGenerating(tab),
                            allowsDrag: true,
                            onSelect: { app.selectTab(tab.id) },
                            onClose: { app.closeTab(tab.id) },
                            onDrag: { dragMoved(tab.id, $0) },
                            onDragEnd: commitDrag,
                            onHoverChange: { setHover(tab.id, $0) }
                        )
                        .id(tab.id)
                        .opacity(draggingID == tab.id ? 0.35 : 1)
                        .onGeometryChange(for: CGRect.self) { geo in
                            geo.frame(in: .named(TabDragSpace.name))
                        } action: { frames[tab.id] = $0 }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(draggingID != nil)
            .coordinateSpace(name: TabDragSpace.name)
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

    private func isGenerating(_ tab: WindowTab) -> Bool {
        guard let id = tab.generatingID else { return false }
        return app.runningChats.contains { $0.id == id }
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
