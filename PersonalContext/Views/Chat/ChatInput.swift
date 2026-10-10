import SwiftUI

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
    var onSend: (String) -> Bool
    var onStop: (() -> Void)?
    var onRetryStuck: (() -> Void)?
    var onStartRun: (() -> Void)?
    var debugLog: ChatDebugLog?
    var draftKind = "composer"
    var draftObjectID = ""
    var draftRuntime = "-"

    @Environment(AppModel.self) private var app
    @State private var showDebug = false
    @State private var draftMutationSource = "editor"

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
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
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(CraftColor.hairline))
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
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CraftFont.body)
                .lineLimit(lineLimit)
                .onSubmit(send)

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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        let accepted = onSend(trimmed)
        DraftTrace.send(
            kind: draftKind,
            object: draftObjectID,
            runtime: draftRuntime,
            chars: trimmed.count,
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
        }
    }

    private func isStuckRun(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("already has active run") || text.contains("agent_busy")
    }
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
