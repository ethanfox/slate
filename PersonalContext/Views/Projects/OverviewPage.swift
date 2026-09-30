import SwiftData
import SwiftUI

struct OverviewPage: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @State private var overviewOpen = false

    private var openThreads: [ProjectThread] {
        project.threads
            .filter { $0.status.isCurrent }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var activeDecisions: [Decision] {
        project.decisions
            .filter { $0.status == .active }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var recentNotes: [Note] {
        Array(project.notes.sorted { $0.updatedAt > $1.updatedAt }.prefix(5))
    }

    private var recentChats: [Conversation] {
        Array(
            project.conversations
                .filter { !$0.isArchived }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(5)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            DocumentPage {
                HStack(spacing: 8) {
                    PropertyPill(title: project.status.label, systemImage: project.status.symbol) {
                        ForEach(ProjectStatus.allCases) { status in
                            Button(status.label, systemImage: status.symbol) {
                                project.status = status
                                project.touch()
                            }
                        }
                    }
                    Text("Updated \(project.lastActivity.relativeLabel)")
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    overviewOpen.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: overviewOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text("Overview")
                            .font(CraftFont.section)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 24)

                if overviewOpen {
                    MarkdownEditor(text: $project.summary, placeholder: "What this project is")
                        .padding(.top, 8)
                }

                DocumentSection("Current direction") {
                    MarkdownEditor(text: $project.currentDirection, placeholder: "What’s being pursued right now")
                        .padding(12)
                        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(CraftColor.hairline)
                        )
                }

                if !openThreads.isEmpty {
                    DocumentSection("Open tracks") {
                        ForEach(openThreads.prefix(8)) { thread in
                            RecordRow(
                                systemImage: thread.kind.symbol,
                                title: thread.title.isEmpty ? "Untitled" : thread.title,
                                subtitle: plainPreview(thread.summary.isEmpty ? thread.body : thread.summary),
                                meta: "\(thread.status.label) · \(thread.updatedAt.relativeLabel)"
                            ) {
                                app.selectedThread = thread.id
                                show(.threads)
                            }
                        }
                    }
                }

                if !activeDecisions.isEmpty {
                    DocumentSection("Decisions") {
                        ForEach(activeDecisions.prefix(8)) { decision in
                            RecordRow(
                                systemImage: "checkmark.seal",
                                title: decision.title.isEmpty ? "Untitled" : decision.title,
                                subtitle: plainPreview(decision.decision),
                                meta: decision.createdAt.relativeLabel
                            ) {
                                app.selectedDecision = decision.id
                                show(.decisions)
                            }
                        }
                    }
                }

                if !recentNotes.isEmpty {
                    DocumentSection("Recent notes") {
                        ForEach(recentNotes) { note in
                            RecordRow(
                                systemImage: "note.text",
                                title: note.displayTitle,
                                subtitle: plainPreview(note.content),
                                meta: note.updatedAt.relativeLabel
                            ) {
                                app.selectedNote = note.id
                                show(.notes)
                            }
                        }
                    }
                }

                AgendaLinkedSection(items: AgendaStore.items(in: project))

                if !recentChats.isEmpty {
                    DocumentSection("Recent chats") {
                        ForEach(recentChats) { conversation in
                            RecordRow(
                                systemImage: "bubble.left",
                                title: conversation.title,
                                subtitle: plainPreview(conversation.orderedMessages.last?.content ?? ""),
                                meta: conversation.updatedAt.relativeLabel
                            ) {
                                app.selectedConversation = conversation.id
                                show(.chat)
                            }
                        }
                    }
                }
            }
            PinnedComposer(project: project)
        }
        .onAppear {
            project.summary = project.summary.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            project.currentDirection = project.currentDirection.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
        .onChange(of: project.summary) { _, _ in project.touch() }
        .onChange(of: project.currentDirection) { _, _ in project.touch() }
    }

    private func show(_ tab: ProjectTab) {
        app.tabs[project.id] = tab
    }
}
