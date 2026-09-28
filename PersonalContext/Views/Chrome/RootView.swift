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
                .frame(width: 232)

            VStack(spacing: 0) {
                HStack {
                    Text(pageTitle)
                        .font(CraftFont.title)
                    Spacer()
                    paneAction
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(pane)
                    .background(pane.fill(CraftColor.canvas).shadow(color: .black.opacity(0.18), radius: 10, y: 3))
                    .overlay(pane.strokeBorder(CraftColor.hairline))
            }
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
            Button("New Project", systemImage: "plus") {
                app.isPresentingNewProject = true
            }
            .help("New Project (⌘N)")
        } else if let project = openProject {
            Button("New Chat", systemImage: "square.and.pencil") {
                app.selectedConversation = nil
                app.tabs[project.id] = .chat
            }
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
