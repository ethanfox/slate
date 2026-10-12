import AppKit
import SwiftData
import SwiftUI

/// Renders the entries from one chat session without owning send or persistence behavior.
struct ChatMessages: View {
    var session: ChatEngine
    var compact = false

    var body: some View {
        ChatMessageList(session: session)
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
    @Environment(\.chatMessageLayout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(session.entries, id: \.id) { entry in
                        HistoryRow(entry: entry, showWork: true)
                            .equatable()
                            .id(entry.id)
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

}

private struct ScrollPin: Equatable {
    var offset: CGFloat
    var height: CGFloat
    var nearBottom: Bool
}

private struct HistoryRow: View, Equatable {
    var entry: ChatEntry
    var showWork: Bool
    @Environment(\.chatMessageLayout) private var layout

    static func == (lhs: HistoryRow, rhs: HistoryRow) -> Bool {
        lhs.showWork == rhs.showWork && sameEntry(lhs.entry, rhs.entry)
    }

    var body: some View {
        switch entry {
        case .userMessage(let message):
            UserMessageBubble(message: message)
        case .aiMessage(let message):
            AssistantMessageBlock(message: message, showWork: showWork)
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
        left.id == right.id
            && left.text == right.text
            && left.isStreaming == right.isStreaming
            && left.thinking == right.thinking
            && left.waitState == right.waitState
            && left.items == right.items
            && left.sources == right.sources
            && left.finishedAt == right.finishedAt
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
    @State private var hoveringPill = false

    private var canOpen: Bool { hasBody }
    private var expanded: Bool { opened && canOpen }
    private var currentTool: ChatToolActivity? {
        tools.last(where: { $0.status == .running }) ?? tools.last
    }
    private var extraToolCount: Int { max(tools.count - 1, 0) }
    private var pillTitle: String? {
        guard let currentTool else { return nil }
        if currentTool.pageURL != nil { return currentTool.displayTitle }
        if isGenerating {
            return ChatToolActivity.title(for: currentTool.name, status: .running)
        }
        return currentTool.title
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
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !thinking.isEmpty {
                        Text(thinking)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
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
                headerContent
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(expanded ? [.isSelected] : [])
            .accessibilityHint(expanded ? "Hides the tools that ran" : "Shows the tools that ran")
        } else {
            line(showsChevron: false)
        }
    }

    @ViewBuilder
    private var headerContent: some View {
        if isGenerating, let currentTool {
            currentToolPill(currentTool)
        } else {
            line(showsChevron: true)
        }
    }

    private func currentToolPill(_ tool: ChatToolActivity) -> some View {
        HStack(spacing: 6) {
            ChatToolMark(symbol: tool.symbol, pageURL: tool.pageURL)
            Text(pillTitle ?? tool.displayTitle)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .modifier(ActiveToolShimmer(active: isGenerating))
            if extraToolCount > 0 {
                Text("+\(extraToolCount)")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if isGenerating {
                ProgressView()
                    .controlSize(.small)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(CraftColor.selection, in: Capsule())
        .background {
            if hoveringPill {
                Capsule().fill(CraftColor.hover)
            }
        }
        .overlay {
            Capsule().strokeBorder(CraftColor.hairline)
        }
        .onHover { hoveringPill = $0 }
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pillLabel(for: tool))
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

    private func pillLabel(for tool: ChatToolActivity) -> String {
        let title = pillTitle ?? tool.displayTitle
        if extraToolCount == 0 { return title }
        return "\(title), \(extraToolCount) more"
    }

    private func toggle() {
        opened.toggle()
    }
}

private struct ActiveToolShimmer: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                let phase = CGFloat(cycle) * 1.7
                content.foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.secondary,
                            Color.primary.opacity(0.82),
                            Color.secondary
                        ],
                        startPoint: UnitPoint(x: phase - 0.55, y: 0.5),
                        endPoint: UnitPoint(x: phase + 0.12, y: 0.5)
                    )
                )
            }
        } else {
            content
        }
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

    private var titleLinked: Bool {
        destination != nil && !tool.showsDetail
    }

    private var rowLabel: String {
        if let url = tool.pageURL {
            return "\(tool.title), \(ChatToolActivity.compactPageURL(url))"
        }
        return tool.showsDetail ? "\(tool.title). \(tool.detail)" : tool.title
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
            ChatToolMark(symbol: tool.symbol, pageURL: tool.pageURL)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.displayTitle)
                        .font(CraftFont.body)
                        .foregroundStyle(titleLinked && hovering ? .primary : .secondary)
                        .underline(titleLinked && hovering)
                        .lineLimit(1)
                    if tool.status == .running {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if tool.showsDetail {
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
        .accessibilityLabel(rowLabel)
    }
}

private struct ChatToolMark: View {
    var symbol: String
    var pageURL: URL? = nil
    @State private var favicon: NSImage?

    var body: some View {
        Group {
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else if symbol == "chevron.left.forwardslash.chevron.right" {
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
        .task(id: pageURL) {
            favicon = nil
            guard let pageURL else { return }
            favicon = await FaviconStore.shared.image(for: pageURL)
        }
    }
}

private struct UserMessageBubble: View {
    let message: ChatEntry.User
    @Environment(AppModel.self) private var app
    @Environment(\.chatMessageLayout) private var layout
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !message.text.isEmpty {
                Text(message.text)
                    .font(CraftFont.chatBody)
                    .lineSpacing(7)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(app.accent.color, in: RoundedRectangle(cornerRadius: CraftRadius.bubble, style: .continuous))
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
                MessageActionRow(alignment: .trailing, visible: hovering) {
                    MessageActionButton(title: "Copy", systemImage: "doc.on.doc", confirms: true) {
                        CraftClipboard.copy(message.text)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
    var showWork = true
    @Environment(AppModel.self) private var app
    @Environment(\.chatMessageLayout) private var layout
    @State private var hovering = false

    private var text: String { message.displayText }
    private var sources: [ChatSource] { message.sources }
    private var lastTextID: String? {
        message.items.last(where: { item in
            if case .text = item.kind { return true }
            return false
        })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showWork, message.isStreaming || message.work.hasContent {
                WorkAccordion(
                    isGenerating: message.isStreaming,
                    waitState: message.waitState,
                    seconds: message.workedSeconds,
                    thinking: message.thinking,
                    tools: message.tools,
                    sources: sources
                )
            }
            ForEach(message.items) { item in
                if case .text(let itemText) = item.kind {
                    AssistantMarkdown(
                        text: itemText,
                        sources: sources,
                        pinUnused: item.id == lastTextID,
                        streaming: message.isStreaming && item.id == lastTextID
                    )
                    .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
                }
            }
            if !message.hasTextItems, !text.isEmpty {
                AssistantMarkdown(text: text, sources: sources, pinUnused: true)
                    .frame(maxWidth: layout.bubbleMaxWidth, alignment: .leading)
            }
            if !message.isStreaming, !text.isEmpty {
                MessageActionRow(visible: hovering) {
                    MessageActionButton(title: "Copy", systemImage: "doc.on.doc", confirms: true) {
                        CraftClipboard.copy(text)
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func save(_ kind: SaveKind) {
        app.activeReply = text
        app.present(.save(kind))
    }
}

private struct MessageActionRow<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    /// The actions stay out of sight until the pointer is over their message.
    var visible = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 2) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .opacity(visible ? 1 : 0)
        .animation(Motion.hover, value: visible)
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
