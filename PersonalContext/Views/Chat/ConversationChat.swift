import AIChatCore
import AIChatUI
import Combine
import SwiftData
import SwiftUI

struct ConversationChat: View {
    @Bindable var conversation: Conversation
    var project: Project?
    var compact = false
    @Environment(AppModel.self) private var app

    var body: some View {
        ConversationSessionView(
            runtime: app.chatRuntime(for: conversation, project: project),
            compact: compact
        )
    }
}

private struct ConversationSessionView: View {
    @Bindable var runtime: ChatRuntime
    var compact = false
    @Environment(AppModel.self) private var app
    @ObservedObject private var session: ChatSession

    init(runtime: ChatRuntime, compact: Bool) {
        self.runtime = runtime
        self.compact = compact
        _session = ObservedObject(wrappedValue: runtime.session)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationTimeline(session: session)
            chatBox
        }
        .environment(\.chatLayout, compact ? .compact : .regular)
        .onAppear {
            ChatTrace.event("chat appear conversation=\(runtime.conversationID) generating=\(session.isGenerating) hasKey=\(app.hasAPIKey) pending=\(app.pendingSend != nil)")
            app.revealChat(runtime)
            runtime.consumePending(from: app)
            if app.hasAPIKey, app.models.isEmpty, app.connection != .checking {
                app.refreshConnection()
            }
            app.refreshUsage()
        }
        .onDisappear {
            runtime.persist()
        }
        .onChange(of: app.pendingSend) { _, _ in runtime.consumePending(from: app) }
        .onChange(of: runtime.modelID) { _, _ in runtime.applyModel() }
    }

    private var chatBox: some View {
        ComposerPlate {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ModelPicker(selection: Bindable(runtime).modelID)
                    Spacer(minLength: 8)
                    if let usage = app.usage {
                        UsageLine(usage: usage)
                    }
                }
                ChatComposerField(session: session)
                if !runtime.bridge.changes.isEmpty {
                    Label(runtime.bridge.changes.joined(separator: " · "), systemImage: "checkmark.circle")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = session.error?.localizedDescription {
                    Text(message)
                        .font(CraftFont.caption)
                        .foregroundStyle(.red)
                        .onAppear { ChatTrace.event("chat ui error: \(message)") }
                }
            }
        }
        .padding(.horizontal, compact ? 16 : 32)
        .padding(.vertical, 14)
    }
}

private struct UsageLine: View {
    var usage: CursorUsage

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
        .font(CraftFont.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var text: String {
        if usage.isUnlimited { return "Unlimited usage" }
        return "Cursor Models: \(CursorUsage.percent(usage.cursorModels)) used · Other Models: \(CursorUsage.percent(usage.otherModels)) used"
    }
}

private struct ChatLayout {
    var pagePadding: CGFloat
    var pageMaxWidth: CGFloat
    var bubbleMaxWidth: CGFloat
    var userMaxWidth: CGFloat

    static let regular = ChatLayout(pagePadding: 32, pageMaxWidth: 744, bubbleMaxWidth: 680, userMaxWidth: 480)
    static let compact = ChatLayout(pagePadding: 16, pageMaxWidth: .infinity, bubbleMaxWidth: .infinity, userMaxWidth: .infinity)
}

private enum ChatLayoutKey: EnvironmentKey {
    static let defaultValue = ChatLayout.regular
}

extension EnvironmentValues {
    fileprivate var chatLayout: ChatLayout {
        get { self[ChatLayoutKey.self] }
        set { self[ChatLayoutKey.self] = newValue }
    }
}

private struct ConversationTimeline: View {
    @ObservedObject var session: ChatSession
    @Environment(\.chatLayout) private var layout
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(session.entries, id: \.id) { entry in
                        row(entry)
                            .id(entry.id)
                    }
                    if let live = liveOrb {
                        HStack(spacing: 10) {
                            ChatOrb(
                                state: live.state,
                                palette: app.orbPalette,
                                status: live.status,
                                size: 28,
                                showsStatus: false
                            )
                            Text(live.status)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .id("orb")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, layout.pagePadding)
                .padding(.vertical, layout.pagePadding)
                .frame(maxWidth: layout.pageMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: session.entries.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: lastReply) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: session.isGenerating) { _, generating in
                if generating { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ChatSession.Entry) -> some View {
        switch entry {
        case .userMessage(let message):
            UserMessageBubble(message: message)
        case .aiMessage(let message):
            if message.text.isEmpty, message.isStreaming {
                EmptyView()
            } else {
                AssistantMessageBlock(message: message)
            }
        case .reasoning(let reasoning):
            if reasoning.isThinking {
                EmptyView()
            } else {
                Button {
                    session.toggleThinking(id: reasoning.id)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Reasoning", systemImage: "brain")
                            .font(CraftFont.body)
                            .foregroundStyle(.secondary)
                        if reasoning.isExpanded, !reasoning.text.isEmpty {
                            Text(reasoning.text)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
                    .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
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
                }
            }
            .padding(12)
            .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
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
                    }
                }
                .padding(12)
                .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
                .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        case .activity(let activity):
            if activity.isError {
                Text(activity.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            } else {
                EmptyView()
            }
        }
    }

    private var lastReply: String {
        for entry in session.entries.reversed() {
            if case .aiMessage(let reply) = entry { return reply.text }
        }
        return ""
    }

    private var liveOrb: (state: OrbState, status: String)? {
        guard session.isGenerating else { return nil }
        for entry in session.entries.reversed() {
            switch entry {
            case .reasoning(let reasoning) where reasoning.isThinking:
                return (.thinking, OrbState.thinking.status)
            case .toolCall(let tool) where tool.status == .running:
                return (.working, tool.name.isEmpty ? OrbState.working.status : tool.name)
            case .activity(let activity) where !activity.isError:
                return (.working, activity.text.isEmpty ? OrbState.working.status : activity.text)
            case .aiMessage(let message) where message.isStreaming:
                if message.text.isEmpty {
                    return (.thinking, OrbState.thinking.status)
                }
                return (.streaming, OrbState.streaming.status)
            default:
                continue
            }
        }
        return (.thinking, OrbState.thinking.status)
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
    @Environment(\.chatLayout) private var layout

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            SelectableText(text: message.text, hugsWidth: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(CraftColor.selection, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(CraftColor.hairline)
                )
                .frame(maxWidth: layout.userMaxWidth, alignment: .trailing)
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
    @Environment(\.chatLayout) private var layout

    var body: some View {
        if message.text.isEmpty, message.isStreaming {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                AssistantMarkdown(text: message.text)
                    .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
                if !message.text.isEmpty {
                    MessageActionRow {
                        MessageActionButton(title: "Copy", systemImage: "doc.on.doc", confirms: true) {
                            CraftClipboard.copy(message.text)
                        }
                        MessageActionButton(title: "Save to Notes", systemImage: "note.text") {
                            save(.note)
                        }
                        MessageActionButton(title: "Create Track", systemImage: TrackStyle.symbol) {
                            save(.thread)
                        }
                        MessageActionButton(title: "Add to Track", systemImage: "text.append") {
                            save(.addToThread)
                        }
                        MessageActionButton(title: "Create Decision", systemImage: "checkmark.seal") {
                            save(.decision)
                        }
                    }
                }
            }
            .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
        }
    }

    private func save(_ kind: SaveKind) {
        app.activeReply = message.text
        app.present(.save(kind))
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
