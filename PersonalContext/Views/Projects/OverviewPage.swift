import SwiftData
import SwiftUI

struct OverviewPage: View {
    @Bindable var project: Project
    /// A full list showing in place of the overview: all tracks, all decisions, and so on.
    @State var listing: TitleIndexKind?

    var body: some View {
        Group {
            if let listing {
                ProjectListPage(project: project, kind: listing) { self.listing = nil }
            } else {
                ProjectOverview(project: project) { listing = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .captureBar(project: project, placeholder: "Tell Membrae anything about \(project.name)")
        .onAppear {
            NavTrace.event("overview appear")
            NavTrace.afterTurn("overview.runloop")
        }
    }
}

/// The one input. Whatever is typed, pasted, or dropped here is handed to the agent without leaving
/// the page. The exchange shows as bubbles above the bar; a long reply moves to the chat view.
struct CaptureBar: View {
    var project: Project?
    /// The Space the user is looking at, so the agent knows where the message most likely belongs.
    var spaceID: UUID?
    var placeholder = "Tell Membrae anything"
    /// True while the page behind is fading out on the way to the chat view.
    @Binding var dissolving: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var draft = ""
    @State private var draftAttachments: [ComposerAttachment] = []
    @State private var composerID = UUID()
    @State private var savedLink: String?

    private var input: some View {
        ChatInput(
            text: $draft,
            modelID: Bindable(app).talkModelID,
            providerID: Bindable(app).talkProviderID,
            placeholder: placeholder,
            onSend: send,
            composerOwnerID: composerID,
            attachments: $draftAttachments,
            draftKind: project == nil ? "capture" : "overview",
            draftObjectID: project?.id.uuidString ?? "capture"
        )
        .frame(maxWidth: 680)
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let savedLink {
                Label("Saved \(savedLink) to the Library", systemImage: "books.vertical")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CraftColor.elevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(CraftColor.hairline))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation(.easeOut(duration: 0.25)) { self.savedLink = nil }
                    }
            } else if let id = app.quickChatID {
                QuickReply(conversationID: id, dissolving: $dissolving)
                    .padding(.horizontal, 32)
                    .zIndex(1)
            }
            input
        }
    }

    /// A pasted link on its own goes straight to the Library. No chat is opened.
    private func save(_ link: URL) {
        var arguments: [String: Any] = ["url": link.absoluteString]
        if let project { arguments["project_ids"] = [project.id.uuidString] }
        let result = Tools.call(
            "create_source",
            arguments: arguments,
            container: context.container,
            announce: false,
            origin: ActionOrigin(client: "membrae")
        )
        guard result["isError"] as? Bool != true else { return }
        SourceFetcher.fillPending(container: context.container)
        try? FileStore.default(context: context).release(ownerKind: .composer, ownerID: composerID)
        composerID = UUID()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            savedLink = link.host() ?? "the link"
        }
    }

    /// Files dropped with nothing typed go straight to the Library, each with its text. No chat is opened.
    private func keep(_ files: [ChatAttachmentRef]) -> Bool {
        let saved = SourceFetcher.save(files, project: project, container: context.container)
        guard !saved.isEmpty else { return false }
        try? FileStore.default(context: context).release(ownerKind: .composer, ownerID: composerID)
        composerID = UUID()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            savedLink = saved.count == 1 ? saved[0] : "\(saved.count) files"
        }
        return true
    }

    /// The exchange already showing, when it belongs to the same place as this bar.
    private var current: Conversation? {
        guard let id = app.quickChatID else { return nil }
        let found = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first
        guard let found, found.project?.id == project?.id else { return nil }
        return found
    }

    private func send(_ submission: ChatSubmission) -> Bool {
        if submission.attachments.isEmpty, let link = SourceFetcher.link(in: submission.trimmedText) {
            save(link)
            return true
        }
        let continuing = current
        if continuing == nil, submission.trimmedText.isEmpty, !submission.attachments.isEmpty {
            return keep(submission.attachments)
        }
        if let continuing, app.chatRuntime(for: continuing, project: project).session.isGenerating {
            return false
        }
        let conversation = continuing ?? app.makeConversation(in: project, context: context, opens: false)
        if continuing == nil, project == nil, let spaceID {
            conversation.spaceIDString = SpaceJSON.key(spaceID)
        }
        let store = FileStore.default(context: context)
        try? store.retain(
            assetIDs: submission.attachments.map(\.id),
            ownerKind: .chatDraft,
            ownerID: conversation.id
        )
        try? store.release(ownerKind: .composer, ownerID: composerID)
        let sent = app.chatRuntime(for: conversation, project: project).send(submission)
        app.quickChatID = conversation.id
        ChatTrace.event("capture sent=\(sent) conversation=\(conversation.id) project=\(project?.name ?? "none") chars=\(submission.trimmedText.count) files=\(submission.attachments.count)")
        composerID = UUID()
        return true
    }
}

/// Decides when a reply has outgrown bubbles and needs the chat view.
enum QuickReplyRule {
    static func needsChatView(_ text: String) -> Bool {
        if text.count > 700 { return true }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > 8 { return true }
        if lines.contains(where: { $0.hasPrefix("#") }) { return true }
        return ChatMarkdown.segments(in: text).contains { segment in
            if case .prose = segment { return false }
            return true
        }
    }
}

/// The exchange from the one input, as bubbles floating above it.
struct QuickReply: View {
    var conversationID: UUID
    @Binding var dissolving: Bool

    @Environment(AppModel.self) private var app
    @Query private var conversations: [Conversation]

    init(conversationID: UUID, dissolving: Binding<Bool>) {
        self.conversationID = conversationID
        _dissolving = dissolving
        _conversations = Query(filter: #Predicate<Conversation> { $0.id == conversationID })
    }

    var body: some View {
        if let conversation = conversations.first {
            QuickReplyBubbles(
                conversation: conversation,
                runtime: app.chatRuntime(for: conversation, project: conversation.project),
                dissolving: $dissolving
            )
        }
    }
}

private struct QuickReplyBubbles: View {
    var conversation: Conversation
    var runtime: ChatRuntime
    @Binding var dissolving: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The latest message and what came back for it. Older turns live in the chat.
    private var entries: [ChatEntry] {
        let all = runtime.session.entries
        let start = all.lastIndex { entry in
            if case .userMessage = entry { return true }
            return false
        }
        return Array(all[(start ?? max(all.count - 2, 0))...])
    }

    /// The reply being written, or the last one written.
    private var reply: String {
        for entry in runtime.session.entries.reversed() {
            if case .aiMessage(let message) = entry {
                return ChatTranscript.unpack(message.text).text
            }
        }
        return ""
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(entries) { entry in
                bubble(entry)
            }
            if worksBelow {
                workingLabel
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(CraftColor.elevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(CraftColor.hairline))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                control("Open as a chat", symbol: "arrow.up.left.and.arrow.down.right") {
                    openChat()
                }
                control("Close", symbol: "xmark") {
                    app.quickChatID = nil
                }
            }
            .opacity(dissolving ? 0 : 1)
            .allowsHitTesting(!dissolving)
        }
        .frame(maxWidth: 680)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.82), value: worksBelow)
        .onChange(of: reply) { _, text in
            if QuickReplyRule.needsChatView(text) {
                openChat()
            }
        }
    }

    /// The page behind blurs and fades to the chat's background while the messages and the input
    /// hold still. Then the chat takes their place. A reply still arriving keeps streaming throughout.
    private func openChat() {
        guard !dissolving else { return }
        guard !reduceMotion else {
            app.open(conversation, newTab: false)
            app.quickChatID = nil
            return
        }
        withAnimation(.easeInOut(duration: 0.6)) {
            dissolving = true
        } completion: {
            guard app.quickChatID == conversation.id else {
                dissolving = false
                return
            }
            withAnimation(.easeInOut(duration: 0.35)) {
                app.open(conversation, newTab: false)
                app.quickChatID = nil
            } completion: {
                dissolving = false
            }
        }
    }

    /// The tool at work, when there is one worth naming.
    private var working: String? {
        runtime.session.currentTurn.tools.last { $0.status == .running }?.title
    }

    /// Whether the dots sit under the reply. Before any reply text, the reply bubble itself holds them.
    private var worksBelow: Bool {
        guard runtime.session.isGenerating else { return false }
        if case .aiMessage(let message) = entries.last {
            return !ChatTranscript.unpack(message.text).text.isEmpty
        }
        return true
    }

    /// The dots, with the tool in use named beside them.
    private var workingLabel: some View {
        HStack(spacing: 8) {
            TypingDots()
            if let working {
                Text(working)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .id(working)
                    .transition(.opacity)
            }
        }
        .frame(minHeight: 20)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: working)
    }

    @ViewBuilder
    private func bubble(_ entry: ChatEntry) -> some View {
        switch entry {
        case .userMessage(let message):
            Text(message.text.isEmpty ? "Sent \(message.attachments.count) file\(message.attachments.count == 1 ? "" : "s")" : message.text)
                .font(CraftFont.chatBody)
                .foregroundStyle(.white)
                .lineLimit(6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(app.accent.color, in: RoundedRectangle(cornerRadius: CraftRadius.bubble, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .opacity(message.isCancelled || message.isFailed ? 0.55 : 1)
                .frame(maxWidth: 440, alignment: .trailing)
                .modifier(BubbleEntrance(sent: true))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .aiMessage(let message):
            let text = ChatTranscript.unpack(message.text).text
            // The dots pill grows into the reply: the shape animates its size and clips what is arriving.
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    workingLabel
                        .transition(.opacity)
                } else {
                    AssistantMarkdown(text: text, sources: message.sources, streaming: message.isStreaming)
                        .transition(.opacity.animation(.easeOut(duration: 0.25).delay(0.1)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(CraftColor.elevated)
            .clipShape(RoundedRectangle(cornerRadius: CraftRadius.bubble, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CraftRadius.bubble, style: .continuous).strokeBorder(CraftColor.hairline))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .frame(maxWidth: 520, alignment: .leading)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: text.isEmpty)
            .modifier(BubbleEntrance(sent: false))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .activity(let activity):
            Text(activity.text)
                .font(.system(size: 12))
                .foregroundStyle(activity.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(CraftColor.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(CraftColor.hairline))
                .modifier(BubbleEntrance(sent: false))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func control(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(CraftColor.elevated, in: Circle())
                .overlay(Circle().strokeBorder(CraftColor.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// How a bubble arrives. A sent one rises out of the input; a received one grows from its corner.
private struct BubbleEntrance: ViewModifier {
    var sent: Bool

    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let settled = arrived || reduceMotion
        content
            .scaleEffect(settled ? 1 : (sent ? 0.94 : 0.5), anchor: sent ? .bottomTrailing : .bottomLeading)
            .offset(y: settled ? 0 : (sent ? 72 : 10))
            .opacity(arrived ? 1 : (sent ? 0.6 : 0))
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78).delay(sent ? 0 : 0.12)) {
                    arrived = true
                }
            }
    }
}

/// Three dots that pulse in turn while a reply is on its way.
private struct TypingDots: View {
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? 1 : 0.3)
                    .scaleEffect(pulsing ? 1 : 0.8)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.55).repeatForever().delay(Double(index) * 0.18),
                        value: pulsing
                    )
            }
        }
        .onAppear { pulsing = true }
        .accessibilityLabel("Working")
    }
}

extension View {
    /// Floats the input over the bottom of a page. The page scrolls underneath it.
    func captureBar(
        project: Project? = nil,
        spaceID: UUID? = nil,
        placeholder: String = "Tell Membrae anything"
    ) -> some View {
        modifier(CaptureBarHost(project: project, spaceID: spaceID, placeholder: placeholder))
    }
}

/// Holds the bar over a page. When the exchange opens as a chat, the page blurs and fades to the
/// chat's background while the bubbles and the input hold still.
private struct CaptureBarHost: ViewModifier {
    var project: Project?
    var spaceID: UUID?
    var placeholder: String

    @State private var dissolving = false

    func body(content: Content) -> some View {
        content
            .blur(radius: dissolving ? 18 : 0)
            .overlay {
                CraftColor.canvas
                    .opacity(dissolving ? 1 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .allowsHitTesting(!dissolving)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CaptureBar(project: project, spaceID: spaceID, placeholder: placeholder, dissolving: $dissolving)
            }
            .onAppear { dissolving = false }
    }
}

extension TitleIndexKind {
    var label: String {
        switch self {
        case .project: "Project"
        case .track: "Track"
        case .note: "Note"
        case .decision: "Decision"
        case .chat: "Chat"
        case .task: "Task"
        case .run: "Run"
        }
    }

    var plural: String {
        switch self {
        case .project: "Projects"
        case .track: "Tracks"
        case .note: "Notes"
        case .decision: "Decisions"
        case .chat: "Chats"
        case .task: "Tasks"
        case .run: "Runs"
        }
    }
}

/// One record in a feed or list: what it is, its name, and when it last changed.
struct IndexRow: View {
    var row: TitleIndex
    /// Shown under the name, such as the kind or the project it belongs to.
    var caption = ""
    var trailing: String?

    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.open(row)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: row.kind.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.displayTitle)
                        .font(CraftFont.body)
                        .lineLimit(1)
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if app.isPinned(row.id) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(trailing ?? row.updatedAt.relativeLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minHeight: caption.isEmpty ? 36 : 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                app.open(row, newTab: true)
            } label: {
                Label("Open in New Tab", systemImage: "plus.square.on.square")
            }
            Button {
                app.togglePin(row)
            } label: {
                Label(app.isPinned(row.id) ? "Unpin" : "Pin", systemImage: app.isPinned(row.id) ? "pin.slash" : "pin")
            }
        }
    }
}

/// What agents wrote lately, newest first, for one project or for everything.
struct ActionFeed: View {
    var empty: String
    private var showsPlace: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var actions: [AgentAction]
    @Query(filter: #Predicate<TitleIndex> { $0.kindRaw == "project" }) private var projects: [TitleIndex]
    @Query private var spaces: [Space]
    @State private var problem: String?

    init(projectID: UUID? = nil, empty: String) {
        self.empty = empty
        showsPlace = projectID == nil
        var descriptor = FetchDescriptor<AgentAction>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let key = projectID?.uuidString.lowercased() {
            descriptor.predicate = #Predicate { $0.projectIDString == key }
        }
        descriptor.fetchLimit = 40
        _actions = Query(descriptor)
    }

    /// Several writes in a row to one thing read as one line.
    private var lines: [AgentAction] {
        var kept: [AgentAction] = []
        for action in actions where kept.last?.targetIDString != action.targetIDString || action.targetIDString.isEmpty {
            kept.append(action)
        }
        return Array(kept.prefix(10))
    }

    var body: some View {
        if actions.isEmpty {
            EmptyLine(text: empty)
        }
        ForEach(lines) { action in
            Button {
                open(action, newTab: false)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.sentence)
                            .font(CraftFont.body)
                            .strikethrough(action.undoneAt != nil)
                            .foregroundStyle(action.undoneAt == nil ? .primary : .secondary)
                            .lineLimit(1)
                        if showsPlace, let place = place(of: action) {
                            Text(place)
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(action.undoneAt == nil ? action.createdAt.relativeLabel : "Taken back")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minHeight: showsPlace ? 44 : 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if action.canUndo {
                    Button {
                        takeBack(action)
                    } label: {
                        Label("Take Back", systemImage: "arrow.uturn.backward")
                    }
                }
                Button {
                    open(action, newTab: true)
                } label: {
                    Label("Open in New Tab", systemImage: "plus.square.on.square")
                }
                if let chat = row(action.conversationIDString) {
                    Button {
                        app.open(chat)
                    } label: {
                        Label("Open the Chat It Came From", systemImage: "bubble.left")
                    }
                }
            }
            Hairline()
        }
        .alert("Couldn’t take that back", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func takeBack(_ action: AgentAction) {
        do {
            try Tools.undo(action.id, container: context.container)
        } catch let error as ToolError {
            problem = error.message
        } catch {
            problem = error.localizedDescription
        }
    }

    private func place(of action: AgentAction) -> String? {
        if let space = spaces.first(where: { $0.id == action.spaceID }) { return space.displayName }
        return projects.first { $0.id == action.projectID }?.displayTitle
    }

    private func row(_ id: String) -> TitleIndex? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var descriptor = FetchDescriptor<TitleIndex>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func open(_ action: AgentAction, newTab: Bool) {
        if action.indexKind != nil, let target = row(action.targetIDString) {
            app.open(target, newTab: newTab)
        } else if action.kindRaw == "source" {
            app.navigate(to: .library, newTab: newTab)
        } else if let space = action.spaceID {
            if action.kindRaw == "record", let record = action.targetID {
                app.navigate(to: .spaceRecord(space: space, record: record), newTab: newTab)
            } else {
                app.navigate(to: .space(space), newTab: newTab)
            }
        }
    }
}

/// The page that stands for a project: where it is going, what changed, what is active, and what was
/// decided, with the full lists one click away.
struct ProjectOverview: View {
    var project: Project
    var list: (TitleIndexKind) -> Void

    @Environment(AppModel.self) private var app
    @Query private var rows: [TitleIndex]

    init(project: Project, list: @escaping (TitleIndexKind) -> Void) {
        self.project = project
        self.list = list
        let key = project.id.uuidString.lowercased()
        _rows = Query(
            filter: #Predicate<TitleIndex> { $0.projectIDString == key && $0.isArchived == false },
            sort: \TitleIndex.updatedAt,
            order: .reverse
        )
    }

    private func of(_ kind: TitleIndexKind) -> [TitleIndex] {
        rows.filter { $0.kind == kind }
    }

    var body: some View {
        let pinned = rows.filter { app.isPinned($0.id) }
        let tracks = of(.track).filter { $0.statusRaw == ThreadStatus.active.rawValue }
        let tasks = of(.task).filter { $0.statusRaw != "done" }
        let decisions = of(.decision).filter { $0.statusRaw != DecisionStatus.superseded.rawValue }
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: project.symbol.isEmpty ? "folder" : project.symbol)
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                            Text(project.name)
                                .font(.system(size: 28, weight: .semibold))
                            Spacer(minLength: 8)
                            Button {
                                app.present(.editProject(project))
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Project Settings")
                            .accessibilityLabel("Project Settings")
                        }
                        if !project.currentDirection.isEmpty {
                            Text(project.currentDirection)
                                .font(CraftFont.body)
                                .lineSpacing(3)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: 640, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !project.summary.isEmpty {
                            Text(project.summary)
                                .font(CraftFont.body)
                                .lineSpacing(3)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .frame(maxWidth: 640, alignment: .leading)
                        }
                    }

                    everything

                    if !pinned.isEmpty {
                        block("Pinned") {
                            ForEach(pinned) { row in
                                IndexRow(row: row, caption: row.kind.label)
                                Hairline()
                            }
                        }
                        .frame(maxWidth: 560, alignment: .leading)
                    }

                    HStack(alignment: .top, spacing: 48) {
                        block("Lately") {
                            ActionFeed(projectID: project.id, empty: "Nothing filed here yet. Tell Membrae something below.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 26) {
                            block("Active tracks", more: tracks.count > 5 ? .track : nil) {
                                if tracks.isEmpty { EmptyLine(text: "No track is active.") }
                                ForEach(tracks.prefix(5)) { row in
                                    IndexRow(row: row)
                                    Hairline()
                                }
                            }
                            block("Open tasks") {
                                if tasks.isEmpty { EmptyLine(text: "Nothing open.") }
                                ForEach(tasks.prefix(5)) { row in
                                    IndexRow(row: row)
                                    Hairline()
                                }
                                if tasks.count > 5 {
                                    moreButton("All \(tasks.count) open tasks") { app.open(project, tab: .tasks, newTab: false) }
                                }
                            }
                            block("Recent decisions", more: decisions.count > 5 ? .decision : nil) {
                                if decisions.isEmpty { EmptyLine(text: "No decisions yet.") }
                                ForEach(decisions.prefix(5)) { row in
                                    IndexRow(row: row)
                                    Hairline()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 36)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// The full lists, each with how many it holds.
    private var everything: some View {
        HStack(spacing: 6) {
            ForEach([TitleIndexKind.track, .decision, .note, .chat, .run]) { kind in
                let count = of(kind).count
                Button {
                    list(kind)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(kind.plural)
                            .font(CraftFont.body)
                        Text("\(count)")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(CraftColor.elevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(CraftColor.hairline))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("All \(kind.plural.lowercased())")
            }
            Button {
                app.open(project, tab: .tasks, newTab: false)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: TitleIndexKind.task.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Tasks")
                        .font(CraftFont.body)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(CraftColor.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(CraftColor.hairline))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("The task board")
        }
    }

    private func block<Content: View>(
        _ title: String,
        more: TitleIndexKind? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CraftFont.section)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            content()
            if let more {
                moreButton("All \(more.plural.lowercased())") { list(more) }
            }
        }
    }

    private func moreButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Every record of one kind in a project, searchable. Reached from the overview, not from a sidebar.
struct ProjectListPage: View {
    var project: Project
    var kind: TitleIndexKind
    var close: () -> Void

    @Environment(AppModel.self) private var app
    @Query private var rows: [TitleIndex]
    @State private var search = ""

    init(project: Project, kind: TitleIndexKind, close: @escaping () -> Void) {
        self.project = project
        self.kind = kind
        self.close = close
        let key = project.id.uuidString.lowercased()
        let raw = kind.rawValue
        _rows = Query(
            filter: #Predicate<TitleIndex> { $0.projectIDString == key && $0.kindRaw == raw && $0.isArchived == false },
            sort: \TitleIndex.updatedAt,
            order: .reverse
        )
    }

    private var shown: [TitleIndex] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? rows : rows.filter { $0.title.localizedCaseInsensitiveContains(query) }
        // Pinned first, then newest.
        return matching.filter { app.isPinned($0.id) } + matching.filter { !app.isPinned($0.id) }
    }

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 16) {
                    Button(action: close) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text(project.name)
                                .font(CraftFont.body)
                        }
                        .foregroundStyle(.secondary)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to the overview")

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(kind.plural)
                            .font(.system(size: 28, weight: .semibold))
                        Text("\(rows.count)")
                            .font(CraftFont.body)
                            .foregroundStyle(.tertiary)
                        if kind == .run {
                            Spacer(minLength: 16)
                            Button {
                                app.presentNewRun(origin: .project, project: project)
                            } label: {
                                Label("New Run", systemImage: "plus")
                                    .font(CraftFont.body)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular, in: Capsule())
                            .help("New Run")
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        TextField("Search \(kind.plural.lowercased())", text: $search)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .frame(maxWidth: 420, alignment: .leading)
                    .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(CraftColor.hairline))

                    let items = shown
                    if items.isEmpty {
                        EmptyLine(text: rows.isEmpty ? "No \(kind.plural.lowercased()) in this project yet." : "Nothing matches.")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { row in
                                IndexRow(row: row, caption: caption(row))
                                Hairline()
                            }
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 36)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func caption(_ row: TitleIndex) -> String {
        switch kind {
        case .track:
            [row.detailRaw.capitalized, row.statusRaw.capitalized].filter { !$0.isEmpty }.joined(separator: " · ")
        case .decision, .run:
            row.statusRaw.capitalized
        default:
            ""
        }
    }
}
