import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var projects: [Project]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \Decision.createdAt, order: .reverse) private var decisions: [Decision]
    @Query(sort: \ProjectThread.updatedAt, order: .reverse) private var threads: [ProjectThread]

    private var activeProjects: [Project] {
        projects
            .filter { $0.status == .active }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                PageBody {
                    VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Projects")
                            .font(CraftFont.section)
                            .padding(.bottom, 8)
                        if activeProjects.isEmpty {
                            EmptyLine(text: "Active projects will appear here.")
                        } else {
                            ForEach(activeProjects.prefix(6)) { project in
                                Button {
                                    app.open(project, tab: .overview)
                                } label: {
                                    ProjectLine(project: project)
                                }
                                .buttonStyle(.plain)
                                if project.id != activeProjects.prefix(6).last?.id {
                                    Hairline(leading: 30)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text("Recent")
                            .font(CraftFont.section)
                            .padding(.bottom, 8)
                        recentList
                    }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollContentBackground(.hidden)

            Hairline()
            quickAsk
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var recentList: some View {
        let items = recentItems
        if items.isEmpty {
            EmptyLine(text: "Conversations, tracks, notes, and decisions will appear here.")
        } else {
            ForEach(items) { item in
                RecordRow(
                    systemImage: item.symbol,
                    title: item.title.isEmpty ? "Untitled" : item.title,
                    subtitle: item.subtitle,
                    meta: item.date.relativeLabel
                ) {
                    open(item)
                }
            }
        }
    }

    private var quickAsk: some View {
        ChatInput(
            modelID: Bindable(app).talkModelID,
            label: "Quick Ask",
            placeholder: "Ask anything, not attached to a project",
            lineLimit: 1...8,
            onSend: submitAsk
        )
    }

    private var recentItems: [RecentItem] {
        var items: [RecentItem] = []
        for conversation in conversations.prefix(8) where !conversation.isArchived {
            items.append(RecentItem(
                id: "c-\(conversation.id)",
                title: conversation.title,
                subtitle: conversation.project?.name ?? "Quick Ask",
                symbol: "bubble.left",
                date: conversation.updatedAt,
                kind: .conversation(conversation.id)
            ))
        }
        for thread in threads.prefix(8) {
            items.append(RecentItem(
                id: "t-\(thread.id)",
                title: thread.title,
                subtitle: [thread.project?.name, thread.kind.label].compactMap { $0 }.joined(separator: " · "),
                symbol: TrackStyle.symbol,
                date: thread.updatedAt,
                kind: .thread(thread.id, thread.project?.id)
            ))
        }
        for note in notes.prefix(8) {
            items.append(RecentItem(
                id: "n-\(note.id)",
                title: note.displayTitle,
                subtitle: note.project?.name ?? "Note",
                symbol: "note.text",
                date: note.updatedAt,
                kind: .note(note.id, note.project?.id)
            ))
        }
        for decision in decisions.prefix(8) {
            items.append(RecentItem(
                id: "d-\(decision.id)",
                title: decision.title,
                subtitle: decision.project?.name ?? "Decision",
                symbol: "checkmark.seal",
                date: decision.createdAt,
                kind: .decision(decision.id, decision.project?.id)
            ))
        }
        return items.sorted { $0.date > $1.date }.prefix(12).map { $0 }
    }

    private func open(_ item: RecentItem) {
        switch item.kind {
        case .conversation(let id):
            if let conversation = conversations.first(where: { $0.id == id }) {
                app.open(conversation)
            }
        case .thread(let id, _):
            if let thread = threads.first(where: { $0.id == id }) {
                app.open(thread)
            }
        case .note(let id, _):
            if let note = notes.first(where: { $0.id == id }) {
                app.open(note)
            }
        case .decision(let id, _):
            if let decision = decisions.first(where: { $0.id == id }) {
                app.open(decision)
            }
        }
    }

    private func submitAsk(_ text: String) -> Bool {
        let conversation = app.makeConversation(in: nil, context: context)
        app.pendingSend = PendingSend(conversationID: conversation.id, text: text)
        ChatTrace.event("quick ask queued conversation=\(conversation.id) chars=\(text.count)")
        return true
    }
}

private struct RecentItem: Identifiable {
    enum Kind {
        case conversation(UUID)
        case thread(UUID, UUID?)
        case note(UUID, UUID?)
        case decision(UUID, UUID?)
    }

    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    var date: Date
    var kind: Kind
}
