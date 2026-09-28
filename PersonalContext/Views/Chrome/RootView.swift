import AppKit
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

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Query private var projects: [Project]
    @Query private var conversations: [Conversation]

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: app.sidebarCollapsed ? 0 : 232, alignment: .leading)
                .clipped()
                .opacity(app.sidebarCollapsed ? 0 : 1)
                .allowsHitTesting(!app.sidebarCollapsed)
                .accessibilityHidden(app.sidebarCollapsed)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: app.toggleSidebar) {
                        Image(systemName: "sidebar.leading")
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: Circle())
                    .help(app.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar")
                    .accessibilityLabel(app.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar")
                    Image(systemName: pageSymbol)
                        .font(CraftFont.titleIcon)
                        .frame(width: 22, height: 22)
                    Text(pageTitle)
                        .font(CraftFont.title)
                    Spacer()
                    paneAction
                }
                .padding(.leading, app.sidebarCollapsed ? 78 : 16)
                .padding(.trailing, 16)
                .frame(height: 52)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(WindowDragGesture())
                }

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(pane)
                    .background(pane.fill(CraftColor.canvas).shadow(color: .black.opacity(0.18), radius: 10, y: 3))
                    .overlay(pane.strokeBorder(CraftColor.hairline))
            }
            .padding(.leading, app.sidebarCollapsed ? 10 : 0)
            .padding(.trailing, 10)
            .padding(.bottom, 10)
        }
        .ignoresSafeArea()
        .containerBackground(for: .window) {
            WindowGlass()
        }
        .sheet(isPresented: Bindable(app).isPresentingNewProject) {
            NewProjectSheet()
        }
        .sheet(item: Bindable(app).saveKind) { kind in
            if let conversation = activeConversation {
                SaveSheet(
                    kind: kind,
                    text: app.activeReply,
                    project: conversation.project ?? openProject,
                    conversation: conversation
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                GlassEffectContainer {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: Capsule())
                }
                .padding(.bottom, 18)
            }
        }
    }

    private var pane: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    @ViewBuilder
    private var paneAction: some View {
        if case .projects = app.destination {
            GlassEffectContainer {
                HStack(spacing: 10) {
                    ProjectsLayoutControl(selection: Bindable(app).projectsLayout)
                    Button {
                        app.isPresentingNewProject = true
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
        } else if let project = openProject {
            Button {
                app.selectedConversation = nil
                app.tabs[project.id] = .chat
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

    private var activeConversation: Conversation? {
        guard let id = app.chatConversationID else { return nil }
        return conversations.first { $0.id == id }
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
