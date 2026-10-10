import SwiftData
import SwiftUI

/// Renders the entries from one chat session without owning send or persistence behavior.
struct ChatMessages: View {
    var session: ChatEngine
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
    var session: ChatEngine
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
                    ForEach(visibleEntries, id: \.id) { entry in
                        HistoryRow(
                            entry: entry,
                            stored: storedAnswer(for: entry),
                            showWork: !showTurn
                        )
                        .equatable()
                        .id(entry.id)
                    }
                    if showTurn {
                        turnRows
                            .id(turnSlotID)
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
            .defaultScrollAnchor(followBottom && session.isGenerating ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: ScrollPin.self) { geometry in
                ScrollPin(
                    offset: geometry.contentOffset.y,
                    height: geometry.contentSize.height,
                    nearBottom: geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 56
                )
            } action: { old, new in
                guard abs(new.height - old.height) < 1 else { return }
                followBottom = new.nearBottom
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

    private var visibleEntries: [ChatEntry] {
        session.entries.enumerated().compactMap { index, entry in
            hideCurrentTurn(entry, index: index) ? nil : entry
        }
    }

    private var lastUserIndex: Int? {
        session.entries.lastIndex { entry in
            if case .userMessage = entry { return true }
            return false
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

    private func hideCurrentTurn(_ entry: ChatEntry, index: Int) -> Bool {
        guard showTurn, let lastUserIndex, index > lastUserIndex else { return false }
        if case .aiMessage = entry { return true }
        return false
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
                    tools: tools,
                    sources: sources
                )
            }
            ForEach(liveTurn) { item in
                if case .text(let text) = item.kind {
                    AssistantMarkdown(
                        text: text,
                        sources: sources,
                        pinUnused: item.id == lastTextID,
                        streaming: session.isGenerating && item.id == lastTextID
                    )
                    .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
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

    private func storedAnswer(for entry: ChatEntry) -> ChatTranscript.Unpacked? {
        if case .aiMessage(let message) = entry { return answers[message.id] }
        return nil
    }
}

private struct ScrollPin: Equatable {
    var offset: CGFloat
    var height: CGFloat
    var nearBottom: Bool
}

private struct HistoryRow: View, Equatable {
    var entry: ChatEntry
    var stored: ChatTranscript.Unpacked?
    var showWork: Bool
    @Environment(\.chatMessageLayout) private var layout

    static func == (lhs: HistoryRow, rhs: HistoryRow) -> Bool {
        lhs.showWork == rhs.showWork
            && lhs.stored == rhs.stored
            && sameEntry(lhs.entry, rhs.entry)
    }

    var body: some View {
        switch entry {
        case .userMessage(let message):
            UserMessageBubble(message: message)
        case .aiMessage(let message):
            if message.text.isEmpty, message.isStreaming {
                EmptyView()
            } else {
                AssistantMessageBlock(message: message, stored: stored, showWork: showWork)
            }
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

private func sameEntry(_ left: ChatEntry, _ right: ChatEntry) -> Bool {
    switch (left, right) {
    case (.userMessage(let left), .userMessage(let right)):
        left.id == right.id
            && left.text == right.text
            && left.attachments == right.attachments
            && left.isCancelled == right.isCancelled
            && left.isFailed == right.isFailed
    case (.aiMessage(let left), .aiMessage(let right)):
        left.id == right.id && left.text == right.text && left.isStreaming == right.isStreaming
    case (.activity(let left), .activity(let right)):
        left.id == right.id && left.text == right.text && left.isError == right.isError
    default:
        false
    }
}

private struct WorkAccordion: View {
    var isGenerating: Bool
    var waitState: ChatWaitState
    var seconds: Int
    var thinking: String
    var tools: [ChatToolActivity]
    var sources: [ChatSource] = []
    @State private var opened = false

    private var canOpen: Bool { !isGenerating && hasBody }
    private var expanded: Bool { opened && canOpen }
    private var currentTool: ChatToolActivity? {
        tools.last(where: { $0.status == .running }) ?? tools.last
    }

    private var label: String {
        if isGenerating {
            return waitState == .starting ? ChatWaitState.starting.label : ChatWaitState.thinking.label
        }
        return seconds <= 0 ? "Worked" : "Worked for \(seconds)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isGenerating, let currentTool {
                ChatToolRow(tool: currentTool, sources: sources)
                    .padding(.leading, 22)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !thinking.isEmpty {
                        Text(thinking)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tools) { tool in
                        ChatToolRow(tool: tool, sources: sources)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .onChange(of: isGenerating) { _, generating in
            if generating { opened = false }
        }
        .animation(Motion.quick, value: expanded)
        .animation(Motion.quick, value: currentTool?.id)
        .animation(Motion.quick, value: label)
    }

    @ViewBuilder
    private var header: some View {
        if canOpen {
            Button(action: toggle) {
                line(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(expanded ? [.isSelected] : [])
            .accessibilityHint(expanded ? "Hides the tools that ran" : "Shows the tools that ran")
        } else {
            line(showsChevron: false)
        }
    }

    private func line(showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            if isGenerating {
                ProgressView()
                    .controlSize(.small)
            }
            Text(label)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var hasBody: Bool {
        !thinking.isEmpty || !tools.isEmpty
    }

    private func toggle() {
        opened.toggle()
    }
}

private struct ChatToolRow: View {
    var tool: ChatToolActivity
    var sources: [ChatSource] = []
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var hovering = false

    var body: some View {
        if let destination {
            Button(action: open) {
                row
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovering = $0 }
            .accessibilityHint("Opens this \(destination.kindLabel)")
        } else {
            row
        }
    }

    private func open() {
        tool.destination(from: sources)?.open(app: app, context: modelContext)
    }

    private var destination: ChatSource? {
        tool.destination(from: sources)
    }

    private var row: some View {
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
                        .foregroundStyle(destination == nil ? .tertiary : hovering ? .primary : .secondary)
                        .underline(destination != nil && hovering)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
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
    let message: ChatEntry.User
    @Environment(\.chatMessageLayout) private var layout

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !message.text.isEmpty {
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
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: layout.userMaxWidth, alignment: .trailing)
                    .opacity(message.isCancelled || message.isFailed ? 0.55 : 1)
            }
            HistoryAttachmentStrip(attachments: message.attachments)
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
    let message: ChatEntry.Assistant
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
                        sources: answer.sources
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
