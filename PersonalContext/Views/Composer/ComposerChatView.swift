import SwiftData
import SwiftUI

struct ComposerChatPane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @FocusState private var fieldFocused: Bool

    private var session: ComposerSession { app.composer }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let runtime = session.runtime {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(runtime.session.entries, id: \.id) { entry in
                            turn(entry)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            followUp
        }
        .padding(20)
        .onAppear { fieldFocused = true }
        .onChange(of: session.focusNonceChat) { _, _ in
            fieldFocused = false
            Task { @MainActor in
                fieldFocused = true
            }
        }
    }

    @ViewBuilder
    private func turn(_ entry: ChatEntry) -> some View {
        switch entry {
        case .userMessage(let user):
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(session.visibleUserText[user.id] ?? user.text)
                        .font(CraftFont.chatBody)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(AccentPreference.blue.color, in: Capsule())
                    if let refs = session.turnMentions[user.id], !refs.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(refs) { hit in
                                ComposerFilterChip(title: "@\(hit.title)") {
                                    session.removeMention(hit)
                                }
                            }
                        }
                    }
                }
            }
        case .aiMessage(let reply):
            VStack(alignment: .leading, spacing: 10) {
                if session.isGenerating, reply.isStreaming {
                    HStack {
                        Text(session.runtime?.liveWaitLabel ?? "Working")
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop", action: session.stop)
                            .font(CraftFont.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                AssistantMarkdown(
                    text: ChatTranscript.unpack(reply.text).text,
                    sources: reply.sources,
                    streaming: reply.isStreaming
                )
                if !reply.sources.isEmpty {
                    HStack(spacing: 6) {
                        Text("Sources")
                            .font(CraftFont.caption)
                            .foregroundStyle(.tertiary)
                        ForEach(reply.sources) { source in
                            Button {
                                source.open(app: app, context: context)
                                session.close()
                            } label: {
                                SourceChipLabel(sources: [source])
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        case .activity(let activity) where activity.isError:
            Text(activity.text)
                .font(CraftFont.caption)
                .foregroundStyle(.primary)
        default:
            EmptyView()
        }
    }

    private var followUp: some View {
        TextField("Ask a follow-up", text: draftBinding, axis: .horizontal)
            .textFieldStyle(.plain)
            .font(CraftFont.body)
            .focused($fieldFocused)
            .onSubmit {
                session.send(app: app, context: context)
            }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { session.draft },
            set: { session.setField($0, context: context) }
        )
    }
}

struct ComposerSaveForm: View {
    var kind: ComposerSaveKind
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var destination: UUID?

    private var session: ComposerSession { app.composer }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title)
                .font(CraftFont.section)
            Text(copy)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
            if kind != .chat {
                Text(String(session.firstQuestion().prefix(80)))
                    .font(CraftFont.body)
            }
            VStack(spacing: 2) {
                if kind == .chat {
                    destinationRow(title: "Workspace", detail: "No project", id: nil)
                }
                ForEach(projects) { project in
                    destinationRow(
                        title: project.displayName,
                        detail: project.id == session.scope.projectID ? "Current project" : "Project",
                        id: project.id
                    )
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { session.cancelSave() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button(kind == .chat ? "Create chat" : "Review and create", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(kind != .chat && destination == nil)
            }
        }
        .padding(20)
        .onAppear {
            destination = session.scope.projectID ?? projects.first?.id
        }
    }

    private var copy: String {
        switch kind {
        case .chat:
            return "Pick where this chat lives. The exchange, messages, and references stay intact."
        case .track:
            return "Saves the whole conversation as a new track."
        case .note:
            return "Saves the whole conversation as a note."
        case .task:
            return "Saves the whole conversation as a task."
        }
    }

    private func destinationRow(title: String, detail: String, id: UUID?) -> some View {
        Button {
            destination = id
        } label: {
            HStack {
                Text(title)
                    .font(CraftFont.body)
                    .foregroundStyle(.primary)
                Spacer()
                Text(detail)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                destination == id ? CraftColor.selection : CraftColor.wash,
                in: RoundedRectangle(cornerRadius: CraftRadius.row, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func apply() {
        let project = destination.flatMap { id in projects.first { $0.id == id } }
        switch kind {
        case .chat:
            session.saveAsChat(project: project, app: app, context: context)
        case .note:
            guard let project else { return }
            session.saveAsNote(project: project, app: app, context: context)
        case .track:
            guard let project else { return }
            session.saveAsTrack(project: project, app: app, context: context)
        case .task:
            session.saveAsTask(project: project, app: app, context: context)
        }
    }
}
