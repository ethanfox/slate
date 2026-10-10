import SwiftData
import SwiftUI

/// Connects one persisted conversation to its runtime, messages, and shared input.
struct ConversationChat: View {
    @Bindable var conversation: Conversation
    var project: Project?
    var compact = false
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var confirmDelete = false

    private var hostProject: Project? { project ?? conversation.project }

    private var deletionMark: DeletionMark? {
        guard let hostProject else { return nil }
        return DeletionMarks.existing(for: conversation.id, in: hostProject)
    }

    var body: some View {
        VStack(spacing: 0) {
            if project != nil, !compact {
                ChatTitleBar(title: conversation.title, onStartRun: startRun)
            }
            if !compact, let mark = deletionMark {
                DeletionBanner(mark: mark, onKeep: keepMark, onDelete: { confirmDelete = true })
            }
            ConversationSessionView(
                runtime: app.chatRuntime(for: conversation, project: project),
                compact: compact,
                onStartRun: compact ? startRun : nil
            )
        }
        .alert("Delete this conversation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: deleteMarked)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from this Mac. Decisions, notes, and tracks from it stay.")
        }
    }

    private func startRun() {
        let brief = conversation.orderedMessages.last(where: { $0.role == .user })?.content ?? ""
        app.presentNewRun(origin: .chat, project: hostProject, chat: conversation, brief: brief)
    }

    private func keepMark() {
        guard let mark = deletionMark else { return }
        DeletionMarks.keep(mark, in: context)
        hostProject?.touch()
        try? context.save()
    }

    private func deleteMarked() {
        let project = hostProject
        if app.selectedConversation == conversation.id { app.selectedConversation = nil }
        DeletionMarks.remove(targetingIDs: [conversation.id], in: context)
        context.delete(conversation)
        project?.touch()
        try? context.save()
    }
}

struct ChatTitleBar: View {
    var title: String
    var onStartRun: (() -> Void)? = nil

    private var displayTitle: String {
        title.isEmpty ? "New chat" : title
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(displayTitle)
                .font(CraftFont.title)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onStartRun {
                Button("Start Run…", action: onStartRun)
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 32)
        .frame(height: 52)
        .background(CraftColor.canvas)
        .overlay(alignment: .bottom) {
            Hairline()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ConversationSessionView: View {
    @Bindable var runtime: ChatRuntime
    var compact = false
    var onStartRun: (() -> Void)? = nil
    @Environment(AppModel.self) private var app

    private var session: ChatEngine { runtime.session }

    var body: some View {
        VStack(spacing: 0) {
            ChatMessages(
                session: session,
                compact: compact,
                turn: runtime.bridge.turn,
                turnUserID: runtime.bridge.turnUserID,
                turnText: runtime.bridge.turnText,
                waitState: runtime.bridge.waitState,
                sources: runtime.bridge.sources,
                thinking: runtime.bridge.thinkingText,
                workedSeconds: runtime.bridge.workedSeconds,
                answers: runtime.answers
            )
            ChatInput(
                text: $runtime.draft,
                modelID: Bindable(runtime).modelID,
                providerID: .constant(runtime.providerID),
                allowsProviderChange: false,
                isGenerating: session.isGenerating,
                changes: runtime.bridge.changes,
                errorMessage: session.error?.localizedDescription,
                onSend: send,
                onStop: { session.cancel() },
                onRetryStuck: retryStuck,
                onStartRun: onStartRun,
                debugLog: runtime.bridge.debugLog,
                draftKind: "chat",
                draftObjectID: runtime.conversationID.uuidString,
                draftRuntime: DraftTrace.runtimeID(runtime)
            )
            .padding(.horizontal, compact ? 16 : 32)
            .padding(.vertical, 14)
        }
        .onAppear {
            ChatTrace.event("chat appear conversation=\(runtime.conversationID) generating=\(session.isGenerating) hasKey=\(app.hasAPIKey) pending=\(app.pendingSend != nil)")
            app.revealChat(runtime)
            runtime.consumePending(from: app)
        }
        .onDisappear {
            runtime.persist()
        }
        .onChange(of: app.pendingSend) { _, _ in runtime.consumePending(from: app) }
        .onChange(of: runtime.modelID) { _, _ in runtime.applyModel() }
        .onChange(of: session.isGenerating) { _, generating in
            runtime.bridge.debugLog.snapshot(session, label: "generating=\(generating) entries=\(session.entries.count)")
            if !generating { runtime.rememberAnswer() }
        }
    }

    private func send(_ text: String) -> Bool {
        ChatTrace.event("composer send chars=\(text.count) generating=\(session.isGenerating)")
        let sent = runtime.send(text)
        ChatTrace.event("composer session.send=\(sent)")
        return sent
    }

    private func retryStuck() {
        ChatTrace.event("composer retry stuck run")
        guard let text = runtime.lastUserText, !text.isEmpty else { return }
        _ = send(text)
    }
}
