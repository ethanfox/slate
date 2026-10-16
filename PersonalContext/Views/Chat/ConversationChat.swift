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
                ChatTitleBar(title: conversation.title)
            }
            if !compact, let mark = deletionMark {
                DeletionBanner(mark: mark, onKeep: keepMark, onDelete: { confirmDelete = true })
            }
            ConversationSessionView(
                runtime: app.chatRuntime(for: conversation, project: project),
                compact: compact
            )
        }
        .alert("Delete this conversation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: deleteMarked)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from this Mac. Decisions, notes, and tracks from it stay.")
        }
    }

    private func keepMark() {
        guard let mark = deletionMark else { return }
        DeletionMarks.keep(mark, in: context)
        hostProject?.touch()
        try? context.persist()
    }

    private func deleteMarked() {
        let project = hostProject
        if app.selectedConversation == conversation.id { app.selectedConversation = nil }
        DeletionMarks.remove(targetingIDs: [conversation.id], in: context)
        try? FileStore.default(context: context).releaseConversation(conversation)
        context.delete(conversation)
        project?.touch()
        try? context.persist()
    }
}

struct ChatTitleBar: View {
    var title: String
    var conversation: Conversation? = nil
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayTitle: String {
        title.isEmpty ? "New chat" : title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(displayTitle)
                    .font(CraftFont.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .blur(radius: shown || reduceMotion ? 0 : 10)
                    .opacity(shown ? 1 : 0)
                    .onAppear {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { shown = true }
                    }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 32)
            .frame(height: 52)

            if let conversation {
                TagBar(tags: conversation.tags, size: .compact) {
                    conversation.tags = $0
                    conversation.updatedAt = .now
                    conversation.project?.touch()
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 10)
            }
        }
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
    @Environment(AppModel.self) private var app

    private var session: ChatEngine { runtime.session }

    var body: some View {
        // The input floats over the messages, which scroll underneath it.
        ChatMessages(session: session, compact: compact).safeAreaInset(edge: .bottom, spacing: 0) {
            // Sending while the answer is still writing queues the message; it goes when the turn ends.
            VStack(alignment: .leading, spacing: 8) {
                if let queued = runtime.queued {
                    QueuedMessageBubble(
                        text: queued.trimmedText,
                        attachments: queued.attachments,
                        onSendNow: runtime.sendQueuedNow,
                        onClear: runtime.clearQueued
                    )
                    .padding(.horizontal, 4)
                }
                ChatInput(
                    text: $runtime.draft,
                    modelID: Bindable(runtime).modelID,
                    providerID: Bindable(runtime).providerID,
                    placeholder: session.isGenerating ? "It goes when the answer ends, or stop the answer to send it now." : "Message",
                    isGenerating: session.isGenerating,
                    errorMessage: session.error?.localizedDescription,
                    onSend: send,
                    composerOwnerID: runtime.conversationID,
                    composerOwnerKind: .chatDraft,
                    attachments: Bindable(runtime).draftAttachments,
                    onStop: runtime.stop,
                    onRetryStuck: retryStuck,
                    debugLog: runtime.debugLog,
                    draftKind: "chat",
                    draftObjectID: runtime.conversationID.uuidString,
                    draftRuntime: DraftTrace.runtimeID(runtime),
                    allowsSendWhileGenerating: true
                )
            }
            .frame(maxWidth: compact ? .infinity : 680)
            .padding(.horizontal, compact ? 16 : 32)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
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
        .onChange(of: runtime.providerID) { _, _ in runtime.applyProvider() }
        .onChange(of: session.isGenerating) { _, generating in
            runtime.debugLog.snapshot(session, label: "generating=\(generating) entries=\(session.entries.count)")
        }
    }

    private func send(_ submission: ChatSubmission) -> Bool {
        ChatTrace.event("composer send chars=\(submission.trimmedText.count) files=\(submission.attachments.count) generating=\(session.isGenerating)")
        let sent = runtime.send(submission)
        ChatTrace.event("composer session.send=\(sent)")
        return sent
    }

    private func retryStuck() {
        ChatTrace.event("composer retry stuck run")
        guard let text = runtime.lastUserText, !text.isEmpty else { return }
        _ = send(ChatSubmission(text: text))
    }
}
