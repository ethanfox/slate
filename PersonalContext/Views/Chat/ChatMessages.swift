import AIChatCore
import AIChatUI
import SwiftUI

/// Renders the entries from one chat session without owning send or persistence behavior.
struct ChatMessages: View {
    @ObservedObject var session: ChatSession
    var compact = false
    var turn: [ChatTurnItem] = []
    var turnUserID: UUID?
    var turnText = ""
    var waitState: ChatWaitState = .starting
    var sources: [ChatSource] = []
    var thinking = ""
    var workedSeconds = 0
    var answers: [UUID: ChatTranscript.Unpacked] = [:]

    var body: some View {
        ChatMessageList(
            session: session,
            turn: turn,
            turnUserID: turnUserID,
            turnText: turnText,
            waitState: waitState,
            sources: sources,
            thinking: thinking,
            workedSeconds: workedSeconds,
            answers: answers
        )
        .environment(\.chatMessageLayout, compact ? .compact : .regular)
    }
}

private struct ChatMessageLayout {
    var pagePadding: CGFloat
    var pageMaxWidth: CGFloat
    var bubbleMaxWidth: CGFloat
    var userMaxWidth: CGFloat

    static let regular = ChatMessageLayout(
        pagePadding: 32,
        pageMaxWidth: 744,
        bubbleMaxWidth: 680,
        userMaxWidth: 480
    )
    static let compact = ChatMessageLayout(
        pagePadding: 16,
        pageMaxWidth: .infinity,
        bubbleMaxWidth: .infinity,
        userMaxWidth: .infinity
    )
}

private enum ChatMessageLayoutKey: EnvironmentKey {
    static let defaultValue = ChatMessageLayout.regular
}

private extension EnvironmentValues {
    var chatMessageLayout: ChatMessageLayout {
        get { self[ChatMessageLayoutKey.self] }
        set { self[ChatMessageLayoutKey.self] = newValue }
    }
}

private struct ChatMessageList: View {
    @ObservedObject var session: ChatSession
    var turn: [ChatTurnItem]
    var turnUserID: UUID?
    var turnText: String
    var waitState: ChatWaitState
    var sources: [ChatSource]
    var thinking: String
    var workedSeconds: Int
    var answers: [UUID: ChatTranscript.Unpacked]
    @Environment(\.chatMessageLayout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app
    @State private var followBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(session.entries.enumerated()), id: \.element.id) { index, entry in
                        Group {
                            if !hideCurrentTurn(entry, index: index) {
                                row(entry)
                                    .id(entry.id)
                            }
                            if index == lastUserIndex, showTurn {
                                turnRows.id(turnSlotID)
                            }
                        }
                    }
                    if lastUserIndex == nil, showTurn {
                        turnRows.id(turnSlotID)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, layout.pagePadding)
                .padding(.vertical, layout.pagePadding)
                .frame(maxWidth: layout.pageMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(followBottom ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visible = geometry.contentOffset.y + geometry.containerSize.height
                return visible >= geometry.contentSize.height - 56
            } action: { _, nearBottom in
                followBottom = nearBottom
            }
            .onChange(of: session.entries.count) { _, _ in
                pinToBottom(proxy, animated: !session.isGenerating)
            }
            .onChange(of: session.isGenerating) { _, generating in
                if generating { pinToBottom(proxy, animated: false) }
            }
        }
    }

    private func pinToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        followBottom = true
        if reduceMotion || !animated {
            proxy.scrollTo("bottom", anchor: .bottom)
        } else {
            withAnimation(Motion.smooth) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var turnSlotID: String {
        guard let lastUserIndex, case .userMessage(let user) = session.entries[lastUserIndex] else {
            return "turn"
        }
        return "turn-\(user.id.uuidString)"
    }

    private var lastUserIndex: Int? {
        session.entries.lastIndex { entry in
            switch entry {
            case .userMessage, .knowledgeRetrieval: true
            default: false
            }
        }
    }

    private var showTurn: Bool {
        session.isGenerating || !liveTurn.isEmpty
    }

    private var liveTurn: [ChatTurnItem] {
        guard let lastUserIndex, case .userMessage(let user) = session.entries[lastUserIndex] else {
            return []
        }
        guard turnUserID == user.id else { return [] }
        return turn
    }

    private func hideCurrentTurn(_ entry: ChatSession.Entry, index: Int) -> Bool {
        guard showTurn, let lastUserIndex, index > lastUserIndex else { return false }
        switch entry {
        case .aiMessage, .reasoning: return true
        default: return false
        }
    }

    private var tools: [ChatToolActivity] {
        liveTurn.compactMap { item in
            if case .tool(let tool) = item.kind { return tool }
            return nil
        }
    }

    private var lastTextID: String? {
        liveTurn.last(where: { item in
            if case .text = item.kind { return true }
            return false
        })?.id
    }

    private var liveTurnText: String {
        liveTurn.compactMap { item in
            if case .text(let text) = item.kind { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    private var turnRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            if session.isGenerating || !thinking.isEmpty || !tools.isEmpty || workedSeconds > 0 {
                WorkAccordion(
                    isGenerating: session.isGenerating,
                    waitState: waitState,
                    seconds: workedSeconds,
                    thinking: thinking,
                    tools: [],
                    liveTitle: tools.last(where: { $0.status == .running })?.title
                )
            }
            ForEach(liveTurn) { item in
                switch item.kind {
                case .text(let text):
                    AssistantMarkdown(
                        text: text,
                        sources: sources,
                        pinUnused: item.id == lastTextID,
                        streaming: session.isGenerating && item.id == lastTextID
                    )
                    .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
                case .tool(let tool):
                    ChatToolRow(tool: tool)
                }
            }
            if !session.isGenerating, !liveTurnText.isEmpty {
                MessageActionRow {
                    MessageActionButton(title: "Copy", systemImage: "doc.on.doc", confirms: true) {
                        CraftClipboard.copy(liveTurnText)
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

    private func save(_ kind: SaveKind) {
        app.activeReply = liveTurnText
        app.present(.save(kind))
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
                AssistantMessageBlock(message: message, stored: answers[message.id], showWork: !showTurn)
            }
        case .reasoning:
            EmptyView()
        case .toolCall:
            EmptyView()
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
}

private struct WorkAccordion: View {
    var isGenerating: Bool
    var waitState: ChatWaitState
    var seconds: Int
    var thinking: String
    var tools: [ChatToolActivity]
    var liveTitle: String?
    @State private var opened: Bool?

    private var expanded: Bool { opened ?? isGenerating }

    private var label: String {
        if isGenerating {
            if let liveTitle, !liveTitle.isEmpty { return liveTitle }
            return waitState.label
        }
        return seconds <= 0 ? "Worked" : "Worked for \(seconds)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(label)
                        .font(CraftFont.body)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(expanded ? [.isSelected] : [])

            if expanded, hasBody {
                VStack(alignment: .leading, spacing: 10) {
                    if !thinking.isEmpty {
                        Text(thinking)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tools) { tool in
                        ChatToolRow(tool: tool)
                    }
                }
            }
        }
        .onChange(of: isGenerating) { _, generating in
            opened = generating
        }
        .animation(Motion.quick, value: expanded)
        .animation(Motion.quick, value: label)
    }

    private var hasBody: Bool {
        !thinking.isEmpty || !tools.isEmpty
    }

    private func toggle() {
        opened = !expanded
    }
}

private struct ChatToolRow: View {
    var tool: ChatToolActivity

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ChatToolMark(symbol: tool.symbol)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.title)
                        .font(CraftFont.body)
                        .foregroundStyle(.secondary)
                    if tool.status == .running {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if !tool.detail.isEmpty {
                    Text(tool.detail)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tool.detail.isEmpty ? tool.title : "\(tool.title). \(tool.detail)")
    }
}

private struct ChatToolMark: View {
    var symbol: String

    var body: some View {
        if symbol == "chevron.left.forwardslash.chevron.right" {
            Text("C")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .frame(width: 16, height: 16)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cursor")
        } else {
            Image(systemName: symbol)
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }
}

private struct UserMessageBubble: View {
    let message: ChatSession.UserEntry
    @Environment(\.chatMessageLayout) private var layout

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
    var stored: ChatTranscript.Unpacked?
    var showWork = true
    @Environment(AppModel.self) private var app
    @Environment(\.chatMessageLayout) private var layout

    private var answer: ChatTranscript.Unpacked {
        stored ?? ChatTranscript.unpack(message.text)
    }

    var body: some View {
        if message.text.isEmpty, message.isStreaming {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if showWork, let work = answer.work, work.hasContent {
                    WorkAccordion(
                        isGenerating: false,
                        waitState: .thinking,
                        seconds: work.seconds,
                        thinking: work.thinking,
                        tools: work.tools,
                        liveTitle: nil
                    )
                }
                AssistantMarkdown(text: answer.text, sources: answer.sources, pinUnused: true)
                    .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
                if !answer.text.isEmpty {
                    MessageActionRow {
                        MessageActionButton(title: "Copy", systemImage: "doc.on.doc", confirms: true) {
                            CraftClipboard.copy(answer.text)
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
        app.activeReply = answer.text
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
