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

/// What is in the one input before it is sent. Held by the app, not the view, so it outlives a remount.
struct CaptureDraft {
    var text = ""
    var attachments: [ComposerAttachment] = []
    var composerID = UUID()
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
    @State private var savedLink: String?

    /// One draft per page the bar sits on.
    private var draftKey: String {
        project?.id.uuidString ?? spaceID?.uuidString ?? "capture"
    }

    private var draft: String {
        get { app.captureDrafts[draftKey]?.text ?? "" }
        nonmutating set { app.captureDrafts[draftKey, default: CaptureDraft()].text = newValue }
    }

    private var draftAttachments: [ComposerAttachment] {
        get { app.captureDrafts[draftKey]?.attachments ?? [] }
        nonmutating set { app.captureDrafts[draftKey, default: CaptureDraft()].attachments = newValue }
    }

    private var composerID: UUID {
        get { app.captureDrafts[draftKey]?.composerID ?? UUID() }
        nonmutating set { app.captureDrafts[draftKey, default: CaptureDraft()].composerID = newValue }
    }

    private var input: some View {
        ChatInput(
            text: Binding(get: { draft }, set: { draft = $0 }),
            modelID: Bindable(app).talkModelID,
            providerID: Bindable(app).talkProviderID,
            placeholder: placeholder,
            onSend: send,
            composerOwnerID: composerID,
            attachments: Binding(get: { draftAttachments }, set: { draftAttachments = $0 }),
            draftKind: project == nil ? "capture" : "overview",
            draftObjectID: project?.id.uuidString ?? "capture"
        )
        .frame(maxWidth: 680)
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .onAppear {
            // Gives the draft a fixed owner id before anything is attached to it.
            if app.captureDrafts[draftKey] == nil { app.captureDrafts[draftKey] = CaptureDraft() }
        }
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
            conversation.project = SpaceStore.space(spaceID, in: context)
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

/// The page that stands for a project: where it is going, what is next, what changed, and what was decided.
/// How the work is filed (tracks, stops, themes) is the AI's business and stays under More.
struct ProjectOverview: View {
    var project: Project
    var list: (TitleIndexKind) -> Void

    @Environment(AppModel.self) private var app
    @Query private var rows: [TitleIndex]
    @Query private var plans: [CleanupPlan]
    @Environment(\.modelContext) private var context

    init(project: Project, list: @escaping (TitleIndexKind) -> Void) {
        self.project = project
        self.list = list
        let key = project.id.uuidString.lowercased()
        let waiting = CleanupPlanStatus.proposed.rawValue
        _plans = Query(
            filter: #Predicate<CleanupPlan> { $0.projectIDString == key && $0.statusRaw == waiting },
            sort: \CleanupPlan.createdAt,
            order: .reverse
        )
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
        let nextItem = TaskStore.nextTask(in: project)
        let open = upNext(of(.task).filter { $0.statusRaw != "done" }, nextID: nextItem?.id)
        let focus = nextItem ?? open.first.flatMap { TitleIndexStore.task($0.id, in: context) }
        let after = open.filter { $0.id != focus?.id }
        let decided = project.decisions.filter { $0.status == .active }.sorted { $0.createdAt > $1.createdAt }
        let lines = project.threads
            .filter { $0.status == .active || $0.status == .exploring }
            .sorted { $0.updatedAt > $1.updatedAt }
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 4) {
                            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 8)
                            iconButton("wand.and.stars", help: "Tidy Up: Membrae proposes what to merge, retire, and delete") {
                                app.presentNewRun(origin: .project, project: project, brief: ContextBuilder.cleanupBrief(for: project))
                            }
                            iconButton("gearshape", help: "Project Settings") { app.toggleProjectSettings() }
                        }
                        Text(headline)
                            .font(.system(size: 34, weight: .semibold))
                            .tracking(-0.85)
                            .lineSpacing(0)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 640, alignment: .leading)
                    }
                    .padding(.top, 28)

                    if let plan = plans.first {
                        CleanupPlanCard(plan: plan)
                    }

                    nextStep(focus)

                    HStack(alignment: .top, spacing: 40) {
                        column("After that", rows: after.prefix(3).map { row in
                            (row.displayTitle, { app.open(row) })
                        }, more: open.isEmpty ? nil : ("All \(open.count) tasks", { app.open(project, tab: .tasks, newTab: false) }))
                        column("Decided lately", rows: decided.prefix(3).map { decision in
                            (decision.title.isEmpty ? "Untitled" : decision.title, { app.open(decision) })
                        }, more: decided.isEmpty ? nil : ("All decisions", { list(.decision) }))
                        column("Lines of work", rows: lines.prefix(3).map { track in
                            (track.title.isEmpty ? "Untitled" : track.title, { app.open(track) })
                        }, more: lines.count > 3 ? ("\(lines.count - 3) more", { list(.track) }) : nil)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 36)
                // Room to scroll the last row clear of the composer that floats over the page.
                .padding(.bottom, 140)
                .frame(maxWidth: 940, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// The sentence Membrae wrote for this project. Until it has, the summary, or the direction's first sentence.
    private var headline: String {
        let written = project.brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !written.isEmpty { return written }
        let fallback = project.summary.isEmpty ? project.currentDirection : project.summary
        let first = fallback.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? project.name : trimmed + "."
    }

    /// The one task to do now, between two rules.
    private func nextStep(_ task: AgendaItem?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Next")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if let task {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.displayTitle)
                            .font(.system(size: 20, weight: .semibold))
                            .tracking(-0.2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let place = task.stop?.displayTitle ?? task.liveTracks.first?.title, !place.isEmpty {
                            Text(place)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Button {
                            app.presentNewRun(origin: .task, project: project, task: task)
                        } label: {
                            Text("Hand to an Agent")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(Color.accentColor, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            app.present(.editTask(task))
                        } label: {
                            Text("Open")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(CraftColor.elevated, in: Capsule())
                                .overlay(Capsule().strokeBorder(CraftColor.hairline))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .fixedSize()
                }
            } else {
                Text("Nothing open. Tell Membrae what you want to do next.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func column(
        _ title: String,
        rows: [(String, () -> Void)],
        more: (String, () -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("Nothing yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Button(action: row.1) {
                    Text(row.0)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let more {
                Button(action: more.1) {
                    Text(more.0)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Open tasks in the order to pick them up: the Next task, then what is under way, then the rest,
    /// with blocked ones last.
    private func upNext(_ rows: [TitleIndex], nextID: UUID?) -> [TitleIndex] {
        func rank(_ row: TitleIndex) -> Int {
            if row.id == nextID { return 0 }
            switch row.statusRaw {
            case TaskWorkflowStatus.inProgress.rawValue: return 1
            case TaskWorkflowStatus.blocked.rawValue: return 3
            default: return 2
            }
        }
        return rows.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}

/// A cleanup Membrae proposed for this project: what it would change and why, for the user to apply or dismiss.
private struct CleanupPlanCard: View {
    var plan: CleanupPlan
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var expanded = false

    private static let groups: [(action: CleanupChange.Action, title: String)] = [
        (.mergeTracks, "Merge"), (.retireDecision, "Retire"), (.delete, "Delete")
    ]

    var body: some View {
        let changes = plan.changes
        let accepted = changes.count { $0.isAccepted }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Membrae has a cleanup ready")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                Text(counts(changes))
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            if !plan.summary.isEmpty {
                Text(plan.summary)
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.groups, id: \.title) { group in
                        let rows = changes.filter { $0.action == group.action }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(group.title) (\(rows.count))")
                                    .font(CraftFont.section)
                                    .foregroundStyle(.secondary)
                                ForEach(rows) { change in
                                    row(change)
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button(accepted == changes.count ? "Apply All \(accepted)" : "Apply \(accepted) of \(changes.count)") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(accepted == 0)
                Button(expanded ? "Hide the List" : "Review the List") { expanded.toggle() }
                Button("Dismiss") { CleanupStore.dismiss(plan, in: context) }
                Spacer(minLength: 0)
            }
            Text("Nothing changes until you apply. Each change then shows in Lately, where you can take it back.")
                .font(CraftFont.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: 720, alignment: .leading)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CraftColor.hairline))
    }

    private func counts(_ changes: [CleanupChange]) -> String {
        Self.groups.compactMap { group in
            let count = changes.count { $0.action == group.action }
            return count == 0 ? nil : "\(count) to \(group.title.lowercased())"
        }
        .joined(separator: " · ")
    }

    private func row(_ change: CleanupChange) -> some View {
        Button {
            CleanupStore.setAccepted(!change.isAccepted, change: change.id, on: plan)
            try? context.persist()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: change.isAccepted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(change.isAccepted ? .secondary : .tertiary)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.sentence)
                        .font(.system(size: 13))
                        .foregroundStyle(change.isAccepted ? .primary : .secondary)
                        .multilineTextAlignment(.leading)
                    Text(change.reason)
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(change.sentence). \(change.reason)")
        .accessibilityAddTraits(change.isAccepted ? .isSelected : [])
    }

    private func apply() {
        try? context.persist()
        let result = CleanupStore.apply(plan.id, container: context.container)
        if result.failed == 0 {
            app.flash("Made \(result.done) changes. Take any of them back from Lately.")
        } else {
            app.flash("Made \(result.done) changes; \(result.failed) could not be made.")
        }
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
                    } else if kind == .track, !project.themes.isEmpty {
                        // Tracks are listed under their themes; the ones with no theme come last.
                        let themeOf = Dictionary(uniqueKeysWithValues: project.threads.compactMap { track in
                            track.theme.map { (track.id, $0.id) }
                        })
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(project.orderedThemes) { theme in
                                let group = items.filter { themeOf[$0.id] == theme.id }
                                if !group.isEmpty {
                                    themeHeader(theme.displayName, count: group.count)
                                    ForEach(group) { row in
                                        IndexRow(row: row, caption: caption(row))
                                        Hairline()
                                    }
                                }
                            }
                            let loose = items.filter { themeOf[$0.id] == nil }
                            if !loose.isEmpty {
                                themeHeader("No theme", count: loose.count)
                                ForEach(loose) { row in
                                    IndexRow(row: row, caption: caption(row))
                                    Hairline()
                                }
                            }
                        }
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

    private func themeHeader(_ name: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(CraftFont.section)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(CraftFont.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private func caption(_ row: TitleIndex) -> String {
        switch kind {
        case .track:
            ([row.id == project.activeTrackID ? "Active track" : ""]
                + [row.detailRaw.capitalized, row.statusRaw.capitalized])
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .run:
            row.runStatus.label
        case .decision:
            row.statusRaw.capitalized
        default:
            ""
        }
    }
}
