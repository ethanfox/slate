import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The shared chat controls. Callers provide conversation-specific state and actions;
/// this view owns only the controls' internal appearance.
struct ChatInput: View {
    @Binding var text: String
    @Binding var modelID: String
    @Binding var providerID: String
    var allowsProviderChange = true
    var label: String?
    var placeholder = "Message"
    var lineLimit: ClosedRange<Int> = 1...6
    var isGenerating = false
    var changes: [String] = []
    var errorMessage: String?
    var onSend: (ChatSubmission) -> Bool
    var composerOwnerID = UUID()
    var composerOwnerKind = AssetOwnerKind.composer
    @Binding var attachments: [ComposerAttachment]
    var onStop: (() -> Void)?
    var onRetryStuck: (() -> Void)?
    var onStartRun: (() -> Void)?
    var debugLog: ChatDebugLog?
    var draftKind = "composer"
    var draftObjectID = ""
    var draftRuntime = "-"

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var showDebug = false
    @State private var draftMutationSource = "editor"
    @State private var isDropTarget = false

    private var readyAttachments: [ChatAttachmentRef] {
        attachments.filter(\.isReady).map(\.ref)
    }

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !readyAttachments.isEmpty
    }

    private var canSend: Bool {
        hasContent
            && !isGenerating
            && attachments.allSatisfy(\.isReady)
            && !attachments.contains { if case .failed = $0.status { return true }; return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ModelPicker(
                    providerID: $providerID,
                    modelID: $modelID,
                    allowsProviderChange: allowsProviderChange
                )
                Spacer(minLength: 8)
                if let onStartRun {
                    Button("Start Run…", action: onStartRun)
                        .buttonStyle(.plain)
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                }
                if providerID == TalkProvider.cursor.rawValue, let usage = app.usage {
                    ChatUsage(usage: usage)
                }
                #if DEBUG
                if let debugLog {
                    Button {
                        showDebug.toggle()
                    } label: {
                        Image(systemName: "ladybug")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showDebug, arrowEdge: .top) {
                        ChatDebugPopover(log: debugLog)
                    }
                    .accessibilityLabel("Chat debug log")
                }
                #endif
            }

            ComposerAttachmentStrip(attachments: attachments, onRemove: removeAttachment)

            if let label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                    field
                }
            } else {
                field
            }

            if let disclosure = attachments.compactMap(\.disclosure).first {
                Text(disclosure)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !changes.isEmpty {
                Label(changes.joined(separator: " · "), systemImage: "checkmark.circle")
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                if isStuckRun(errorMessage), let onRetryStuck {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("The last reply is still running. Try again to take it over.")
                            .foregroundStyle(.red)
                        Button("Try again", action: onRetryStuck)
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                    }
                    .font(CraftFont.caption)
                    .onAppear { ChatTrace.event("chat ui error: \(errorMessage)") }
                } else {
                    Text(errorMessage)
                        .font(CraftFont.caption)
                        .foregroundStyle(.red)
                        .onAppear { ChatTrace.event("chat ui error: \(errorMessage)") }
                }
            }
        }
        .padding(12)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CraftColor.hairline, lineWidth: 1)
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
        .onPasteCommand(of: [.fileURL, .image, .png, .jpeg, .tiff], perform: handlePaste)
        .onAppear {
            prepareProviders()
            DraftTrace.appear(
                kind: draftKind,
                object: draftObjectID,
                runtime: draftRuntime,
                storeGeneration: app.storeGeneration,
                draftChars: text.count
            )
        }
        .onDisappear {
            DraftTrace.disappear(
                kind: draftKind,
                object: draftObjectID,
                runtime: draftRuntime,
                storeGeneration: app.storeGeneration,
                draftChars: text.count
            )
        }
        .onChange(of: text) { old, new in
            let source = draftMutationSource
            draftMutationSource = "editor"
            DraftTrace.change(
                kind: draftKind,
                object: draftObjectID,
                runtime: draftRuntime,
                oldChars: old.count,
                newChars: new.count,
                source: source,
                storeGeneration: app.storeGeneration
            )
        }
        .onChange(of: app.storeGeneration) { old, new in
            DraftTrace.event(
                "storeGeneration kind=\(draftKind) object=\(draftObjectID) runtime=\(draftRuntime) old=\(String(old.uuidString.prefix(8))) new=\(String(new.uuidString.prefix(8))) draftChars=\(text.count)"
            )
        }
        .onChange(of: providerID) { _, _ in
            prepareProviders()
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button(action: pickFiles) {
                Image(systemName: "paperclip")
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attach files")

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(CraftFont.body)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                ComposerField(
                    text: $text,
                    placeholder: placeholder,
                    lineLimit: lineLimit,
                    onAttachmentPaste: importFromPasteboard,
                    onSubmit: send
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isGenerating, let onStop {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: Circle())
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func prepareProviders() {
        if uses(.chatgpt) {
            app.refreshChatGPTModels()
        }
        if uses(.cursor) {
            if app.hasAPIKey, app.models.isEmpty, app.connection != .checking {
                app.refreshConnection()
            }
            app.refreshUsage()
        }
    }

    private func uses(_ provider: TalkProvider) -> Bool {
        providerID == provider.rawValue || (allowsProviderChange && app.availableTalkProviders.contains(provider))
    }

    private func send() {
        guard canSend else { return }
        let submission = ChatSubmission(text: text, attachments: readyAttachments)
        let accepted = onSend(submission)
        DraftTrace.send(
            kind: draftKind,
            object: draftObjectID,
            runtime: draftRuntime,
            chars: submission.trimmedText.count,
            accepted: accepted
        )
        if accepted {
            let oldChars = text.count
            draftMutationSource = "send-clear"
            DraftTrace.clear(
                kind: draftKind,
                object: draftObjectID,
                runtime: draftRuntime,
                oldChars: oldChars,
                source: "send-clear"
            )
            text = ""
            attachments = []
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ComposerImport.types
        guard panel.runModal() == .OK else { return }
        ComposerImport.importURLs(
            panel.urls,
            into: &attachments,
            ownerKind: composerOwnerKind,
            ownerID: composerOwnerID,
            context: context
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            ComposerImport.importURLs(
                urls,
                into: &attachments,
                ownerKind: composerOwnerKind,
                ownerID: composerOwnerID,
                context: context
            )
        }
        return true
    }

    private func handlePaste(_ items: [NSItemProvider]) {
        if importFromPasteboard() { return }
        if items.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            _ = handleDrop(items)
            return
        }
        for item in items where item.canLoadObject(ofClass: NSImage.self) {
            _ = item.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage, let data = ComposerPaste.pngData(from: image) else { return }
                DispatchQueue.main.async {
                    ComposerImport.importData(
                        data,
                        filename: "pasted-image.png",
                        into: &attachments,
                        ownerKind: composerOwnerKind,
                        ownerID: composerOwnerID,
                        context: context
                    )
                }
            }
        }
    }

    @discardableResult
    private func importFromPasteboard() -> Bool {
        guard let payload = ComposerPaste.payload(from: .general) else { return false }
        switch payload {
        case .files(let urls):
            ComposerImport.importURLs(
                urls,
                into: &attachments,
                ownerKind: composerOwnerKind,
                ownerID: composerOwnerID,
                context: context
            )
        case .image(let data, let filename):
            ComposerImport.importData(
                data,
                filename: filename,
                into: &attachments,
                ownerKind: composerOwnerKind,
                ownerID: composerOwnerID,
                context: context
            )
        }
        return true
    }

    private func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
        try? FileStore.default(context: context).release(
            assetID: id,
            ownerKind: composerOwnerKind,
            ownerID: composerOwnerID
        )
    }

    private func isStuckRun(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("already has active run") || text.contains("agent_busy")
    }
}

private struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var lineLimit: ClosedRange<Int>
    var onAttachmentPaste: () -> Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onAttachmentPaste: onAttachmentPaste, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> ComposerScrollField {
        let view = ComposerScrollField()
        view.lineLimit = lineLimit
        view.editor.delegate = context.coordinator
        view.editor.onAttachmentPaste = { context.coordinator.onAttachmentPaste() }
        view.editor.onSubmit = { context.coordinator.onSubmit() }
        view.editor.setAccessibilityLabel(placeholder)
        view.editor.setAccessibilityPlaceholderValue(placeholder)
        return view
    }

    func updateNSView(_ view: ComposerScrollField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onAttachmentPaste = onAttachmentPaste
        context.coordinator.onSubmit = onSubmit
        view.lineLimit = lineLimit
        view.editor.onAttachmentPaste = { context.coordinator.onAttachmentPaste() }
        view.editor.onSubmit = { context.coordinator.onSubmit() }
        view.editor.setAccessibilityLabel(placeholder)
        view.editor.setAccessibilityPlaceholderValue(placeholder)
        if view.editor.string != text {
            view.editor.string = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollField, context: Context) -> CGSize? {
        nsView.measuredSize(width: proposal.width ?? 240)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onAttachmentPaste: () -> Bool
        var onSubmit: () -> Void

        init(text: Binding<String>, onAttachmentPaste: @escaping () -> Bool, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onAttachmentPaste = onAttachmentPaste
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if text.wrappedValue != editor.string {
                text.wrappedValue = editor.string
            }
        }
    }
}

final class ComposerScrollField: NSScrollView {
    let editor = ComposerNSTextView()
    var lineLimit: ClosedRange<Int> = 1...6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        autohidesScrollers = true
        documentView = editor
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func measuredSize(width: CGFloat) -> CGSize {
        let width = max(width, 1)
        editor.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let used = editor.layoutManager?.usedRect(for: editor.textContainer!) ?? .zero
        let minHeight = lineHeight * CGFloat(lineLimit.lowerBound)
        let maxHeight = lineHeight * CGFloat(lineLimit.upperBound)
        let height = min(max(ceil(used.height), minHeight), maxHeight)
        hasVerticalScroller = used.height > maxHeight + 1
        return CGSize(width: width, height: height)
    }

    private var lineHeight: CGFloat {
        ceil(editor.font?.boundingRectForFont.height ?? 16)
    }
}

final class ComposerNSTextView: NSTextView {
    var onAttachmentPaste: (() -> Bool)?
    var onSubmit: (() -> Void)?

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        insertionPointColor = .labelColor
        focusRingType = .none
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        unregisterDraggedTypes()
        setAccessibilityRole(.textArea)
    }

    override func insertNewline(_ sender: Any?) {
        if NSEvent.modifierFlags.contains(.shift) {
            super.insertNewline(sender)
            return
        }
        onSubmit?()
    }

    override func paste(_ sender: Any?) {
        if onAttachmentPaste?() == true { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if onAttachmentPaste?() == true { return }
        super.pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}

private struct ChatUsage: View {
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

#if DEBUG
private struct ChatDebugPopover: View {
    var log: ChatDebugLog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chat events")
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    CraftClipboard.copy(log.copyText)
                }
                Button("Clear") {
                    log.clear()
                }
            }
            .buttonStyle(.plain)
            .font(CraftFont.caption)

            if let pace = log.pace {
                Text(pace.summary())
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(log.lines) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 460, height: 300)
        .onAppear { log.publish() }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            log.publish()
        }
    }
}
#endif
