import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TitleIndex> { $0.kindRaw == "project" }, sort: \TitleIndex.title)
    private var projects: [TitleIndex]
    @Query(filter: Space.collecting, sort: \Space.createdAt) private var spaces: [Space]
    @Query(sort: \Pin.createdAt) private var pins: [Pin]
    @State private var pendingDelete: TitleIndex?
    @State private var pendingAreaDelete: Space?

    private struct PinnedItem: Identifiable {
        var id: UUID
        var kind: PinKind
        var title: String
        var symbol: String
        var open: (Bool) -> Void
        var shows: TabViewKey?
    }

    /// The pins that still point at something, oldest first, each with how to show and open it.
    private var pinned: [PinnedItem] {
        pins.compactMap { pin in
            guard let kind = pin.kind, let id = pin.targetID else { return nil }
            switch kind {
            case .space:
                guard let space = spaces.first(where: { $0.id == id }) else { return nil }
                return PinnedItem(id: id, kind: kind, title: space.displayName, symbol: space.symbol, open: { newTab in
                    app.navigate(to: .space(id), newTab: newTab)
                }, shows: .space(id))
            case .record:
                guard let record = SpaceStore.record(id, in: context), let space = record.spaceID else { return nil }
                return PinnedItem(id: id, kind: kind, title: record.displayTitle, symbol: "doc.text", open: { newTab in
                    app.navigate(to: .spaceRecord(space: space, record: id), newTab: newTab)
                }, shows: .spaceRecord(id))
            default:
                guard let row = try? context.fetch(FetchDescriptor<TitleIndex>(predicate: #Predicate { $0.id == id })).first else { return nil }
                let shows: TabViewKey? = switch kind {
                case .track: .thread(id)
                case .note: .note(id)
                case .decision: .decision(id)
                case .chat: .conversation(id)
                case .run: .run(id)
                default: nil
                }
                return PinnedItem(id: id, kind: kind, title: row.displayTitle, symbol: row.kind.symbol, open: { newTab in
                    app.open(row, newTab: newTab)
                }, shows: shows)
            }
        }
    }

    private var showing: TabViewKey? {
        app.windowTabs.first { $0.id == app.selectedTabID }?.viewKey
    }

    private var orderedProjects: [TitleIndex] {
        projects.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row("You", "person", destination: .home, selected: isOnYou)

                    if !pinned.isEmpty {
                        section("Pinned")
                        ForEach(pinned) { item in
                            Button {
                                item.open(false)
                            } label: {
                                SidebarRow(title: item.title, systemImage: item.symbol, isSelected: item.shows != nil && item.shows == showing)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    item.open(true)
                                } label: {
                                    Label("Open in New Tab", systemImage: "plus.square.on.square")
                                }
                                Button {
                                    app.togglePin(item.kind, item.id)
                                } label: {
                                    Label("Unpin", systemImage: "pin.slash")
                                }
                            }
                        }
                    }

                    if !spaces.isEmpty {
                        section("Areas")
                        ForEach(spaces) { space in
                            Button {
                                app.navigate(to: .space(space.id))
                            } label: {
                                SidebarRow(title: space.displayName, systemImage: space.symbol, isSelected: isOn(space))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    app.present(.editSpace(space))
                                } label: {
                                    Label("Edit…", systemImage: "pencil")
                                }
                                Button {
                                    app.navigate(to: .space(space.id), newTab: true)
                                } label: {
                                    Label("Open in New Tab", systemImage: "plus.square.on.square")
                                }
                                Button {
                                    app.togglePin(.space, space.id)
                                } label: {
                                    Label(app.isPinned(space.id) ? "Unpin" : "Pin", systemImage: app.isPinned(space.id) ? "pin.slash" : "pin")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    pendingAreaDelete = space
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    if !orderedProjects.isEmpty {
                        section("Projects")
                        ForEach(orderedProjects) { project in
                            Button {
                                app.open(project)
                            } label: {
                                SidebarRow(
                                    title: project.displayTitle,
                                    systemImage: project.symbol.isEmpty ? "folder" : project.symbol,
                                    isSelected: app.destination == .project(project.id),
                                    showsPin: project.isPinned
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    if let record = TitleIndexStore.project(project.id, in: context) {
                                        app.showProjectSettings(record)
                                    }
                                } label: {
                                    Label("Project Settings", systemImage: "gearshape")
                                }
                                Button {
                                    app.open(project, newTab: true)
                                } label: {
                                    Label("Open in New Tab", systemImage: "plus.square.on.square")
                                }
                                Button {
                                    if let record = TitleIndexStore.project(project.id, in: context) {
                                        record.isPinned.toggle()
                                        record.touch()
                                        try? context.persist()
                                    }
                                } label: {
                                    Label(project.isPinned ? "Unpin" : "Pin", systemImage: project.isPinned ? "pin.slash" : "pin")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    pendingDelete = project
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)
            .alert(
                "Delete \(pendingAreaDelete?.displayName ?? "this Area")?",
                isPresented: Binding(get: { pendingAreaDelete != nil }, set: { if !$0 { pendingAreaDelete = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    if let space = pendingAreaDelete {
                        try? SpaceStore.delete(space, in: context)
                    }
                    pendingAreaDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingAreaDelete = nil }
            } message: {
                Text("Everything in this Area will be deleted. This can’t be undone.")
            }

            row("Settings", "gearshape", destination: .settings)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
        }
        .alert(item: $pendingDelete) { row in
            Alert(
                title: Text("Delete \(row.displayTitle)?"),
                message: Text("Tracks, notes, decisions, and conversations in this project will be removed from this Mac."),
                primaryButton: .destructive(Text("Delete")) {
                    guard let project = TitleIndexStore.project(row.id, in: context) else { return }
                    RunStore.cancelActive(in: project, context: context)
                    app.closeTabs(forProject: project.id)
                    context.delete(project)
                    try? context.persist()
                },
                secondaryButton: .cancel()
            )
        }
        .task { await app.eventKit.prepareReminders() }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(CraftFont.section)
            .foregroundStyle(.secondary)
            .padding(.top, 20)
            .padding(.bottom, 4)
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
    }

    private func row(
        _ title: String,
        _ symbol: String,
        destination: Destination,
        badge: Int = 0,
        busy: Bool = false,
        selected: Bool? = nil
    ) -> some View {
        Button {
            app.navigate(to: destination)
        } label: {
            SidebarRow(
                title: title,
                systemImage: symbol,
                isSelected: selected ?? (app.destination == destination),
                badge: badge,
                isBusy: busy
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                app.navigate(to: destination, newTab: true)
            } label: {
                Label("Open in New Tab", systemImage: "plus.square.on.square")
            }
        }
        .accessibilityValue(busy ? "Working" : badge > 0 ? "\(badge) due" : "")
    }

    /// Everything without a row of its own is reached from You, so it keeps that row lit.
    private var isOnYou: Bool {
        switch app.destination {
        case .home, .aboutYou, .context, .tasks, .calendar, .chats, .runs, .projects, .library: true
        default: false
        }
    }

    private func isOn(_ space: Space) -> Bool {
        switch app.destination {
        case .space(let id), .spaceRecord(let id, _): id == space.id
        default: false
        }
    }
}
