import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \TitleIndex.updatedAt, order: .reverse)
    private var rows: [TitleIndex]
    @State private var draft = ""
    @State private var draftAttachments: [ComposerAttachment] = []
    @State private var composerID = UUID()

    private var activeProjects: [TitleIndex] {
        rows.filter { $0.kind == .project && $0.projectStatus == .active }
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
                                    if let record = TitleIndexStore.project(project.id, in: context) {
                                        app.open(record, tab: .overview)
                                    }
                                } label: {
                                    ProjectLine(row: project)
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
        .onAppear { NavTrace.event("home appear rows=\(rows.count) projects=\(activeProjects.count)") }
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
                    title: item.title,
                    subtitle: item.subtitle,
                    meta: item.date.relativeLabel
                ) {
                    app.open(item.row)
                }
            }
        }
    }

    private var quickAsk: some View {
        ChatInput(
            text: $draft,
            modelID: Bindable(app).talkModelID,
            providerID: Bindable(app).talkProviderID,
            label: "Quick Ask",
            placeholder: "Ask anything, not attached to a project",
            lineLimit: 1...8,
            onSend: submitAsk,
            composerOwnerID: composerID,
            attachments: $draftAttachments,
            draftKind: "home",
            draftObjectID: "home"
        )
    }

    private var recentItems: [RecentItem] {
        rows
            .filter { kind in
                switch kind.kind {
                case .chat: return !kind.isArchived
                case .track, .note, .decision: return true
                default: return false
                }
            }
            .prefix(12)
            .map { row in
                RecentItem(
                    id: row.id,
                    title: row.displayTitle,
                    subtitle: row.owner.isEmpty ? row.kind.rawValue.capitalized : row.owner,
                    symbol: row.symbol.isEmpty ? row.kind.symbol : row.symbol,
                    date: row.updatedAt,
                    row: row
                )
            }
    }

    private func submitAsk(_ submission: ChatSubmission) -> Bool {
        let conversation = app.makeConversation(in: nil, context: context)
        transferDraft(to: conversation, attachments: submission.attachments)
        app.pendingSend = PendingSend(
            conversationID: conversation.id,
            text: submission.text,
            attachments: submission.attachments
        )
        ChatTrace.event("quick ask queued conversation=\(conversation.id) chars=\(submission.trimmedText.count) files=\(submission.attachments.count)")
        composerID = UUID()
        return true
    }

    private func transferDraft(to conversation: Conversation, attachments: [ChatAttachmentRef]) {
        let store = FileStore.default(context: context)
        try? store.retain(
            assetIDs: attachments.map(\.id),
            ownerKind: .chatDraft,
            ownerID: conversation.id
        )
        try? store.release(ownerKind: .composer, ownerID: composerID)
    }
}

private struct RecentItem: Identifiable {
    var id: UUID
    var title: String
    var subtitle: String
    var symbol: String
    var date: Date
    var row: TitleIndex
}
