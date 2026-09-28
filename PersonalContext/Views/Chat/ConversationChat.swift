import AIChatCore
import AIChatUI
import Combine
import SwiftData
import SwiftUI

struct ConversationChat: View {
    @Bindable var conversation: Conversation
    var project: Project?
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @StateObject private var session: ChatSession

    init(conversation: Conversation, project: Project?) {
        self.conversation = conversation
        self.project = project
        _session = StateObject(wrappedValue: Self.makeSession(conversation: conversation, project: project ?? conversation.project))
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationTimeline(session: session)
            chatBox
        }
            .onChange(of: session.isGenerating) { _, generating in
                publishChrome()
                if !generating { persist() }
            }
            .onChange(of: session.entries.count) { _, _ in
                publishChrome()
            }
            .onChange(of: lastReply) { _, _ in
                publishChrome()
            }
            .onAppear {
                ChatTrace.event("chat appear conversation=\(conversation.id) messages=\(conversation.messages.count) model=\(conversation.model) hasKey=\(app.hasAPIKey) connection=\(String(describing: app.connection)) pending=\(app.pendingSend != nil)")
                publishChrome()
                consumePending()
                if app.hasAPIKey, app.models.isEmpty, app.connection != .checking {
                    app.refreshConnection()
                }
            }
            .onDisappear {
                if app.chatConversationID == conversation.id {
                    app.chatConversationID = nil
                    app.activeReply = ""
                    app.chatGenerating = false
                }
            }
            .onChange(of: app.pendingSend) { _, _ in consumePending() }
            .onChange(of: conversation.model) { _, newValue in session.model = newValue }
    }

    private var chatBox: some View {
        ComposerPlate {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ModelPicker(selection: Bindable(conversation).model)
                    Spacer(minLength: 8)
                }
                ChatComposerField(session: session)
                if let message = session.error?.localizedDescription {
                    Text(message)
                        .font(CraftFont.caption)
                        .foregroundStyle(.red)
                        .onAppear { ChatTrace.event("chat ui error: \(message)") }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
    }

    private func publishChrome() {
        app.chatConversationID = conversation.id
        app.chatGenerating = session.isGenerating
        app.activeReply = lastReply
    }

    private var lastReply: String {
        for entry in session.entries.reversed() {
            if case .aiMessage(let reply) = entry, !reply.text.isEmpty { return reply.text }
        }
        return ""
    }

    private static func makeSession(conversation: Conversation, project: Project?) -> ChatSession {
        let bridge = CursorConversationBridge(conversation: conversation, project: project)
        let session = ChatSession(provider: CursorChatProvider(bridge: bridge), model: conversation.model)
        var entries: [ChatSession.Entry] = []
        var history: [AIChatCore.ChatMessage] = []
        for message in conversation.orderedMessages where !message.content.isEmpty {
            switch message.role {
            case .user:
                entries.append(.userMessage(.init(id: message.id, text: message.content)))
                history.append(.init(id: message.id, role: .user, content: message.content))
            case .assistant:
                entries.append(.aiMessage(.init(id: message.id, text: message.content, isStreaming: false)))
                history.append(.init(id: message.id, role: .assistant, content: message.content))
            }
        }
        session.loadSnapshot(entries: entries, history: history)
        return session
    }

    private func persist() {
        let known = Set(conversation.messages.map(\.id))
        for entry in session.entries {
            let stored: ChatMessage?
            switch entry {
            case .userMessage(let user) where !user.isCancelled && !user.isFailed:
                stored = ChatMessage(id: user.id, role: .user, content: user.text)
            case .aiMessage(let reply) where !reply.text.isEmpty:
                stored = ChatMessage(id: reply.id, role: .assistant, content: reply.text)
            default:
                stored = nil
            }
            guard let stored, !known.contains(stored.id) else { continue }
            conversation.messages.append(stored)
        }
        conversation.updatedAt = .now
        try? context.save()
    }

    private func consumePending() {
        guard let pending = app.pendingSend else {
            ChatTrace.event("consumePending skip conversation=\(conversation.id) reason=none")
            return
        }
        guard pending.conversationID == conversation.id else {
            ChatTrace.event("consumePending skip conversation=\(conversation.id) pending=\(pending.conversationID)")
            return
        }
        app.pendingSend = nil
        ChatTrace.event("consumePending send conversation=\(conversation.id) chars=\(pending.text.count) generating=\(session.isGenerating)")
        let sent = session.send(pending.text)
        ChatTrace.event("consumePending session.send=\(sent)")
    }
}

private struct ConversationTimeline: View {
    @ObservedObject var session: ChatSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(session.entries, id: \.id) { entry in
                        row(entry)
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: 744)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: session.entries.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: lastReply) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ChatSession.Entry) -> some View {
        switch entry {
        case .userMessage(let message):
            UserMessageBubble(message: message)
        case .aiMessage(let message):
            AssistantMessageBlock(message: message)
        case .reasoning(let reasoning):
            Button {
                if !reasoning.isThinking {
                    session.toggleThinking(id: reasoning.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        reasoning.isThinking ? "Thinking…" : "Reasoning",
                        systemImage: reasoning.isThinking ? "ellipsis" : "brain"
                    )
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
                    if reasoning.isExpanded, !reasoning.text.isEmpty {
                        Text(reasoning.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: 680, alignment: .leading)
                .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(reasoning.isThinking)
        case .toolCall(let tool):
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.name)
                    .font(.system(size: 13, weight: .medium))
                Text(toolStatus(tool.status))
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                if let result = tool.result, !result.isEmpty {
                    Text(result)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: 680, alignment: .leading)
            .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .knowledgeRetrieval(let knowledge):
            Button {
                session.toggleKnowledgeRetrieval(id: knowledge.id)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(knowledge.query.isEmpty ? "Retrieved context" : knowledge.query)
                        .font(.system(size: 13, weight: .medium))
                    if knowledge.isExpanded {
                        Text(knowledge.body)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: 680, alignment: .leading)
                .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        case .activity(let activity):
            Text(activity.text)
                .font(.system(size: 12))
                .foregroundStyle(activity.isError ? Color.primary : Color.secondary)
        }
    }

    private var lastReply: String {
        for entry in session.entries.reversed() {
            if case .aiMessage(let reply) = entry { return reply.text }
        }
        return ""
    }

    private func toolStatus(_ status: ChatSession.ToolCallEntry.Status) -> String {
        switch status {
        case .running: "Running"
        case .succeeded: "Complete"
        case .failed: "Failed"
        }
    }
}

private struct UserMessageBubble: View {
    let message: ChatSession.UserEntry

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(message.text)
                .font(CraftFont.chatBody)
                .lineSpacing(7)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(CraftColor.selection, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(CraftColor.hairline)
                )
                .frame(maxWidth: 480, alignment: .trailing)
                .opacity(message.isCancelled || message.isFailed ? 0.55 : 1)
            if message.isCancelled || message.isFailed {
                Text(message.isCancelled ? "Cancelled" : "Not answered")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            if !message.text.isEmpty {
                MessageActionRow(alignment: .trailing) {
                    MessageActionButton(title: "Copy", systemImage: "doc.on.doc", confirms: true) {
                        CraftClipboard.copy(message.text)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if message.isCancelled { return "\(message.text). Cancelled." }
        if message.isFailed { return "\(message.text). Not answered." }
        return message.text
    }
}

private struct AssistantMessageBlock: View {
    let message: ChatSession.AIEntry
    @Environment(AppModel.self) private var app

    var body: some View {
        if message.text.isEmpty, message.isStreaming {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: 680, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownMessageView(text: message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                if !message.text.isEmpty {
                    MessageActionRow {
                        MessageActionButton(title: "Copy", systemImage: "doc.on.doc", confirms: true) {
                            CraftClipboard.copy(message.text)
                        }
                        MessageActionButton(title: "Save to Notes", systemImage: "note.text") {
                            save(.note)
                        }
                        MessageActionButton(title: "Create Thread", systemImage: "point.3.connected.trianglepath.dotted") {
                            save(.thread)
                        }
                        MessageActionButton(title: "Add to Thread", systemImage: "text.append") {
                            save(.addToThread)
                        }
                        MessageActionButton(title: "Create Decision", systemImage: "checkmark.seal") {
                            save(.decision)
                        }
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private func save(_ kind: SaveKind) {
        app.activeReply = message.text
        app.saveKind = kind
    }
}

private struct MessageActionRow<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 2) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

private struct MessageActionButton: View {
    var title: String
    var systemImage: String
    var confirms = false
    var action: () -> Void
    @State private var didConfirm = false

    var body: some View {
        Button(action: run) {
            Image(systemName: didConfirm ? "checkmark" : systemImage)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didConfirm ? "Copied" : title)
        .tooltip(didConfirm ? "Copied" : title)
    }

    private func run() {
        action()
        guard confirms else { return }
        didConfirm = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            didConfirm = false
        }
    }
}

private struct ChatComposerField: View {
    @ObservedObject var session: ChatSession
    @State private var text = ""

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isGenerating
    }

    var body: some View {
        ComposerFieldRow(
            placeholder: "Message",
            text: $text,
            canSend: canSend,
            isGenerating: session.isGenerating,
            onSend: send,
            onStop: { session.cancel() }
        )
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        ChatTrace.event("composer send chars=\(trimmed.count) generating=\(session.isGenerating)")
        guard !trimmed.isEmpty, !session.isGenerating else { return }
        text = ""
        let sent = session.send(trimmed)
        ChatTrace.event("composer session.send=\(sent)")
    }
}
