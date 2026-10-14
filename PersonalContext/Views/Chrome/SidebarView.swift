import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TitleIndex> { $0.kindRaw == "space" }, sort: \TitleIndex.title)
    private var spaces: [TitleIndex]
    @Query(sort: \Pin.createdAt) private var pins: [Pin]
    @State private var pendingDelete: TitleIndex?

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
                return PinnedItem(id: id, kind: kind, title: space.displayTitle, symbol: symbol(space), open: { newTab in
                    app.openSpace(id, newTab: newTab)
                }, shows: nil)
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

    /// Every Space in one list, pinned first, then by name.
    private var ordered: [TitleIndex] {
        spaces.sorted { lhs, rhs in
            let left = app.isPinned(lhs.id)
            let right = app.isPinned(rhs.id)
            if left != right { return left && !right }
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
                                SidebarRow(
                                    title: item.title,
                                    systemImage: item.symbol,
                                    isSelected: item.kind == .space ? isOn(item.id) : item.shows != nil && item.shows == showing
                                )
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

                    if !ordered.isEmpty {
                        section("Spaces")
                        ForEach(ordered) { space in
                            Button {
                                app.openSpace(space.id)
                            } label: {
                                SidebarRow(
                                    title: space.displayTitle,
                                    systemImage: symbol(space),
                                    isSelected: isOn(space.id),
                                    showsPin: app.isPinned(space.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    if let record = TitleIndexStore.project(space.id, in: context) {
                                        app.showSpaceSettings(record)
                                    }
                                } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                                Button {
                                    app.openSpace(space.id, newTab: true)
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
                                    pendingDelete = space
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

            row("Settings", "gearshape", destination: .settings)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
        }
        .alert(item: $pendingDelete) { row in
            Alert(
                title: Text("Delete \(row.displayTitle)?"),
                message: Text(SpaceDeletion.message),
                primaryButton: .destructive(Text("Delete")) {
                    app.deleteSpace(row.id)
                },
                secondaryButton: .cancel()
            )
        }
        .task { await app.eventKit.prepareReminders() }
    }

    private func symbol(_ space: TitleIndex) -> String {
        space.symbol.isEmpty ? TitleIndexKind.space.symbol : space.symbol
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
        case .home, .aboutYou, .context, .tasks, .calendar, .chats, .runs, .spaces, .library: true
        default: false
        }
    }

    private func isOn(_ id: UUID) -> Bool {
        switch app.destination {
        case .space(let shown), .spaceRecord(let shown, _): shown == id
        default: false
        }
    }
}

enum SpaceDeletion {
    static let message = "Its tracks, notes, decisions, chats, records, and runs are removed from this Mac. Its tasks stay in Tasks."
}
