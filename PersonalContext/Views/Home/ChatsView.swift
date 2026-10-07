import SwiftData
import SwiftUI

/// Workspace page for chats that are still generating, plus the most recent sessions.
struct ChatsView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 32) {
                    if running.isEmpty {
                        emptyState
                    } else {
                        runningSection
                    }
                    if !recent.isEmpty {
                        recentSection
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
            Text("Nothing running.")
                .font(CraftFont.title)
            Text("Chats that are still working will show up here.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Running")
                .font(CraftFont.section)
                .padding(.bottom, 8)
            ForEach(running) { conversation in
                row(conversation, busy: true)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(CraftFont.section)
                .padding(.bottom, 8)
            ForEach(recent) { conversation in
                row(conversation, busy: false)
            }
        }
    }

    private func row(_ conversation: Conversation, busy: Bool) -> some View {
        let label = app.runningChats.first { $0.id == conversation.id }?.label
        return RecordRow(
            systemImage: "bubble.left",
            title: conversation.title.isEmpty ? "New chat" : conversation.title,
            subtitle: conversation.project?.name ?? "Quick Ask",
            meta: busy ? (label ?? "Working") : conversation.updatedAt.relativeLabel,
            isBusy: busy
        ) {
            app.open(conversation)
        }
        .accessibilityHint(busy ? "Opens this running chat" : "Opens this chat")
    }

    private var runningIDs: Set<UUID> {
        Set(app.runningChats.map(\.id))
    }

    private var running: [Conversation] {
        conversations
            .filter { runningIDs.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var recent: [Conversation] {
        Array(
            conversations
                .filter { !$0.isArchived && !runningIDs.contains($0.id) }
                .prefix(10)
        )
    }
}
