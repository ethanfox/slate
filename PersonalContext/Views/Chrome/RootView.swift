import AppKit
import EventKit
import SwiftData
import SwiftUI

private struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private enum LayoutMetrics {
    static let sidebarWidth: CGFloat = 232
    static let columnWidth: CGFloat = 250
    static let documentMinWidth: CGFloat = 400
    static let detailMinWidth = columnWidth + documentMinWidth
    static let chatMin: CGFloat = 300
    static let chatMax: CGFloat = 450
    static let inspectorWidth: CGFloat = 250
    static let gap: CGFloat = 8
    static let edgePad: CGFloat = 10
    static let chatMotionDuration = 0.3
    static let chatMotion = Animation.easeInOut(duration: chatMotionDuration)

    static func windowMin(sidebar: Bool, chat: Bool, inspector: Bool = false) -> CGFloat {
        (sidebar ? sidebarWidth : edgePad)
            + detailMinWidth
            + (chat ? gap + chatMin : 0)
            + (inspector ? gap + inspectorWidth : 0)
            + edgePad
    }
}

/// Detail fills the row but never goes below its minimum. Chat takes what is left, from 300 to 450.
/// `progress` slides the chat in from the trailing edge at its final width so its content never reflows.
private struct PaneRowLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: max(proposal.width ?? LayoutMetrics.detailMinWidth, LayoutMetrics.detailMinWidth),
            height: proposal.height ?? 500
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        let chatWidth = min(LayoutMetrics.chatMax, max(LayoutMetrics.chatMin, width - LayoutMetrics.gap - LayoutMetrics.detailMinWidth))
        let hasChat = subviews.count > 1
        let reserved = hasChat ? (LayoutMetrics.gap + chatWidth) * progress : 0
        let detailWidth = max(LayoutMetrics.detailMinWidth, width - reserved)

        subviews[0].place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: detailWidth, height: bounds.height)
        )
        if hasChat {
            subviews[1].place(
                at: CGPoint(x: bounds.minX + detailWidth + LayoutMetrics.gap, y: bounds.minY),
                proposal: ProposedViewSize(width: chatWidth, height: bounds.height)
            )
        }
    }
}

private struct HostWindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.schedule(view: view, onResolve: onResolve)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.schedule(view: view, onResolve: onResolve)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var last: NSWindow?

        func schedule(view: NSView, onResolve: @escaping (NSWindow?) -> Void) {
            DispatchQueue.main.async {
                let window = view.window
                guard window !== self.last else { return }
                self.last = window
                onResolve(window)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var projects: [Project]
    @Query private var conversations: [Conversation]
    @State private var hostWindow: NSWindow?
    @State private var windowWidth: CGFloat = 0
    @State private var chatProgress: CGFloat = 0
    @State private var chatMounted = false
    @State private var chatSettled = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: sidebarHidden ? 0 : LayoutMetrics.sidebarWidth, alignment: .leading)
                .clipped()
                .opacity(sidebarHidden ? 0 : 1)
                .allowsHitTesting(!sidebarHidden)
                .accessibilityHidden(sidebarHidden)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: toggleSidebar) {
                        Image(systemName: "sidebar.leading")
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: Circle())
                    .help(sidebarHidden ? "Show Sidebar" : "Hide Sidebar")
                    .accessibilityLabel(sidebarHidden ? "Show Sidebar" : "Hide Sidebar")
                    Image(systemName: pageSymbol)
                        .font(CraftFont.titleIcon)
                        .frame(width: 22, height: 22)
                    Text(pageTitle)
                        .font(CraftFont.title)
                    Spacer()
                    paneAction
                }
                .padding(.leading, sidebarHidden ? 78 : 16)
                .padding(.trailing, 16)
                .frame(height: 52)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(WindowDragGesture())
                }

                HStack(spacing: showingInspector ? LayoutMetrics.gap : 0) {
                    PaneRowLayout(progress: chatProgress) {
                        detail
                            .modifier(PaneChrome())

                        if chatMounted, let project = openProject, let thread = focusedThread {
                            ThreadChatPane(thread: thread, project: project)
                                .modifier(PaneChrome())
                                .allowsHitTesting(chatSettled)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    SlideInspector(isOpen: showingInspector) {
                        if let project = openProject {
                            OverviewInspector(project: project)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.leading, sidebarHidden ? LayoutMetrics.edgePad : 0)
            .padding(.trailing, LayoutMetrics.edgePad)
            .padding(.bottom, LayoutMetrics.edgePad)
        }
        .ignoresSafeArea()
        .overlay {
            HostWindowAccessor { hostWindow = $0 }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .frame(minWidth: windowMinimum, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            windowWidth = width
        }
        .onChange(of: showingTrackChat) { _, open in
            open ? openChat() : closeChat()
        }
        .onChange(of: app.inspectorOpen) { _, open in
            if open {
                growWindow(to: LayoutMetrics.windowMin(sidebar: !sidebarHidden, chat: showingTrackChat, inspector: true))
            }
        }
        .containerBackground(for: .window) {
            WindowGlass()
        }
        .overlay {
            SlateModalPresenter(modal: app.modal(in: .main), onDismiss: app.dismissModal) { modal in
                modalContent(modal)
            }
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if let toast = app.toast {
                    GlassEffectContainer {
                        Text(toast)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassEffect(.regular, in: Capsule())
                    }
                    .padding(.bottom, 18)
                    .transition(toastTransition)
                }
            }
            .animation(toastAnimation, value: app.toast)
        }
    }

    @ViewBuilder
    private var paneAction: some View {
        if case .projects = app.destination {
            GlassEffectContainer {
                HStack(spacing: 10) {
                    ProjectsLayoutControl(selection: Bindable(app).projectsLayout)
                    Button {
                        app.present(.newProject)
                    } label: {
                        Label("New Project", systemImage: "plus")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: Capsule())
                    .help("New Project (⌘N)")
                }
            }
        } else if case .calendar = app.destination {
            Button {
                Task { await presentNewEvent() }
            } label: {
                Label("New Event", systemImage: "plus")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())
            .help("New Event")
        } else if case .tasks = app.destination {
            Button {
                app.present(.newTask)
            } label: {
                Label("New Task", systemImage: "plus")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())
            .help("New Task")
        } else if focusedThread != nil {
            Button {
                app.trackChatOpen.toggle()
            } label: {
                Label(app.trackChatOpen ? "Hide Chat" : "Ask Slate", systemImage: "bubble.left")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())
            .help(app.trackChatOpen ? "Hide track chat" : "Ask Slate")
            .accessibilityLabel(app.trackChatOpen ? "Hide track chat" : "Ask Slate")
        } else if let project = openProject, app.tab(for: project.id) == .overview {
            Button(action: toggleInspector) {
                Image(systemName: "sidebar.trailing")
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
            .help(app.inspectorOpen ? "Hide Inspector" : "Show Inspector")
            .accessibilityLabel(app.inspectorOpen ? "Hide Inspector" : "Show Inspector")
        } else if openProject != nil {
            Button {
                app.selectedConversation = nil
                if let project = openProject {
                    app.tabs[project.id] = .chat
                }
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())
            .help("New Chat")
        }
    }

    private var pageTitle: String {
        switch app.destination {
        case .home: "Home"
        case .projects: "Projects"
        case .tasks: "Tasks"
        case .calendar: "Calendar"
        case .settings: "Settings"
        case .project(let id):
            projectTitle(id)
        case .quickAsk:
            "Quick Ask"
        }
    }

    private var pageSymbol: String {
        switch app.destination {
        case .home: "house"
        case .projects: "square.stack"
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .settings: "gearshape"
        case .project(let id):
            projectSymbol(id)
        case .quickAsk:
            "bubble.left"
        }
    }

    private func projectSymbol(_ id: UUID) -> String {
        let symbol = projects.first { $0.id == id }?.symbol ?? ""
        return symbol.isEmpty ? "folder" : symbol
    }

    private func projectTitle(_ id: UUID) -> String {
        let name = projects.first { $0.id == id }?.name ?? ""
        return name.isEmpty ? "Untitled" : name
    }

    private var openProject: Project? {
        guard case .project(let id) = app.destination else { return nil }
        return projects.first { $0.id == id }
    }

    private var showingTrackChat: Bool {
        app.trackChatOpen && focusedThread != nil
    }

    private var showingInspector: Bool {
        guard let project = openProject else { return false }
        return app.inspectorOpen && app.tab(for: project.id) == .overview
    }

    /// The sidebar hides when the user collapsed it or the window is too narrow to fit it beside the panes' minimums.
    private var sidebarHidden: Bool {
        app.sidebarCollapsed
            || (windowWidth > 0 && windowWidth < LayoutMetrics.windowMin(sidebar: true, chat: showingTrackChat, inspector: showingInspector))
    }

    /// The window can shrink to the panes' minimums with the sidebar hidden. Chat counts once it has finished opening.
    private var windowMinimum: CGFloat {
        LayoutMetrics.windowMin(sidebar: false, chat: chatSettled, inspector: showingInspector)
    }

    private func presentNewEvent() async {
        if !app.eventKit.canWriteEvents {
            await app.eventKit.requestEventsAccess()
        }
        if app.eventKit.canWriteEvents {
            app.present(.newEvent)
        } else {
            app.eventKit.openSettings(for: .event)
        }
    }

    private func toggleInspector() {
        if !app.inspectorOpen {
            growWindow(to: LayoutMetrics.windowMin(sidebar: !sidebarHidden, chat: showingTrackChat, inspector: true))
        }
        app.toggleInspector()
    }

    private func toggleSidebar() {
        if sidebarHidden {
            if app.sidebarCollapsed { app.toggleSidebar() }
            growWindow(to: LayoutMetrics.windowMin(sidebar: true, chat: showingTrackChat, inspector: showingInspector))
        } else {
            app.toggleSidebar()
        }
    }

    private func openChat() {
        chatMounted = true
        growWindow(to: LayoutMetrics.windowMin(sidebar: false, chat: true, inspector: showingInspector))
        withAnimation(reduceMotion ? nil : LayoutMetrics.chatMotion) {
            chatProgress = 1
        } completion: {
            if showingTrackChat { chatSettled = true }
        }
    }

    private func closeChat() {
        chatSettled = false
        withAnimation(reduceMotion ? nil : LayoutMetrics.chatMotion) {
            chatProgress = 0
        } completion: {
            if !showingTrackChat { chatMounted = false }
        }
    }

    private var focusedThread: ProjectThread? {
        guard let project = openProject, app.tab(for: project.id) == .threads,
              let id = app.selectedThread else { return nil }
        return project.threads.first { $0.id == id }
    }

    /// Widens the window to the right only when it is narrower than `width`. It never shrinks or moves the window
    /// unless the screen edge leaves no room on the right.
    private func growWindow(to width: CGFloat) {
        guard let window = hostWindow, window.frame.width < width else { return }
        var frame = window.frame
        frame.size.width = width
        if let screen = window.screen?.visibleFrame, frame.maxX > screen.maxX {
            frame.origin.x = max(screen.minX, screen.maxX - width)
        }
        if reduceMotion {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = LayoutMetrics.chatMotionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    private var activeConversation: Conversation? {
        guard let id = app.chatConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    private var toastAnimation: Animation {
        if reduceMotion { return Motion.quick }
        return app.toast == nil ? Motion.quick : Motion.snappy
    }

    private var toastTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity
        )
    }

    @ViewBuilder
    private func modalContent(_ modal: AppModal) -> some View {
        switch modal {
        case .newProject:
            NewProjectSheet()
        case .newEvent:
            NewEventSheet()
        case .editEvent(let event):
            NewEventSheet(event: event)
        case .newTask:
            NewTaskSheet()
        case .newTaskFromNote(let note):
            NewTaskSheet(sourceNote: note)
        case .editReminder(let reminder):
            NewTaskSheet(reminder: reminder)
        case .editTask(let task):
            NewTaskSheet(task: task)
        case .save(let kind):
            if let conversation = activeConversation {
                SaveSheet(
                    kind: kind,
                    text: app.activeReply,
                    project: conversation.project ?? openProject,
                    conversation: conversation
                )
            }
        case .connectCursor:
            ConnectCursorSheet()
        case .editProject(let project):
            EditProjectModal(project: project)
        case .editConversation(let conversation):
            EditConversationModal(conversation: conversation)
        case .editThread(let thread):
            EditThreadModal(thread: thread)
        case .editDecision(let decision):
            EditDecisionModal(decision: decision)
        case .editNote(let note):
            EditNoteModal(note: note)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let storeError = app.storeError {
            Text("The local store couldn’t be opened. Nothing you do here will be saved. \(storeError)")
                .font(CraftFont.body)
                .foregroundStyle(.red)
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            destinationDetail
        }
    }

    @ViewBuilder
    private var destinationDetail: some View {
        switch app.destination {
        case .home:
            HomeView()
        case .projects:
            ProjectsView()
        case .tasks:
            TasksView()
        case .calendar:
            CalendarView()
        case .settings:
            SettingsView()
        case .project(let id):
            ProjectHost(id: id)
        case .quickAsk(let id):
            QuickAskHost(id: id)
        }
    }
}

private struct ProjectsLayoutControl: View {
    @Binding var selection: ProjectsLayout

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProjectsLayout.allCases) { layout in
                Button {
                    selection = layout
                } label: {
                    Image(systemName: layout.symbol)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(layout.label)
                .foregroundStyle(selection == layout ? .primary : .secondary)
                .accessibilityLabel(layout.label)
            }
        }
        .padding(2)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project view")
    }
}

private struct PaneChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .clipShape(shape)
            .background(shape.fill(CraftColor.canvas).shadow(color: .black.opacity(0.18), radius: 10, y: 3))
            .overlay(shape.strokeBorder(CraftColor.hairline))
    }
}
