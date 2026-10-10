import Foundation

enum ContextBuilder {
    static let knowledgeRules = "Feature and problem specs belong in track bodies. Notes hold reference material. Work to do is a task: create it with create_task and link governing tracks through track_ids; linked notes are supplementary. Whether work is done lives only on the task. Never write built, not built, shipped, or pending into a note, a thread summary, or the task notes field."

    static func identity(for project: Project) -> String {
        var lines: [String] = []
        lines.append("Project: \(project.name) (id \(project.id.uuidString))")
        lines.append("Status: \(project.status.label)")
        if !project.summary.isEmpty {
            lines.append("Summary: \(clip(project.summary, 900))")
        }
        if !project.currentDirection.isEmpty {
            lines.append("Current direction: \(clip(project.currentDirection, 900))")
        }
        let code = project.codeAttachments.sorted { $0.createdAt < $1.createdAt }
        if !code.isEmpty {
            lines.append("Attached code:")
            for attachment in code {
                let root = attachment.locator.isEmpty ? attachment.title : attachment.locator
                let published = attachment.modelContext.flatMap { CodeReferenceStore.published(on: attachment, in: $0) }
                var line = "- \(attachment.kind.title): \(root)\(attachment.defaultBranch.isEmpty ? "" : " (\(attachment.defaultBranch))") (attachment id \(attachment.id.uuidString)). Use root \"\(root)\"."
                if let published {
                    let count = attachment.modelContext.map { CodeReferenceStore.entries(on: published, in: $0).count } ?? 0
                    line += " Published architecture reference: \(count) entries, \(published.coverage.label.lowercased())."
                } else {
                    line += " No published architecture reference yet."
                }
                lines.append(line)
            }
            lines.append("Call list_code_references with this project_id to discover published reference entries, then get_code_reference_entry. Do not ask the user to paste the reference. For source files, call project_list_files, project_search_code, project_read_file, or project_git_log. Do not use a shell or invent missing attachments.")
        }
        if !project.workerProviderID.isEmpty {
            lines.append("A project Worker can inspect the attached code. Call consult_code with a brief when you need a repo pass. Do not call it for decisions, tracks, notes, or tasks — use the Membrae tools.")
        }
        return lines.joined(separator: "\n")
    }

    static func package(for project: Project) -> String {
        var lines: [String] = [identity(for: project)]

        let active = project.decisions
            .filter { $0.status == .active }
            .sorted { $0.createdAt > $1.createdAt }
        if !active.isEmpty {
            lines.append("")
            lines.append("Active decisions (highest priority):")
            for decision in active.prefix(15) {
                lines.append("- \(decision.title) (id \(decision.id.uuidString)): \(clip(decision.decision, 500))")
                if !decision.rationale.isEmpty {
                    lines.append("  Rationale: \(clip(decision.rationale, 400))")
                }
                if let thread = decision.thread {
                    lines.append("  Track: \(thread.title)")
                }
            }
        }

        let superseded = project.decisions
            .filter { $0.status == .superseded }
            .sorted { $0.createdAt > $1.createdAt }
        if !superseded.isEmpty {
            lines.append("")
            lines.append("Superseded decisions (do not treat as current):")
            for decision in superseded.prefix(6) {
                lines.append("- \(decision.title)")
            }
        }

        let threads = project.threads
            .filter { $0.status.isCurrent }
            .sorted { $0.createdAt < $1.createdAt }
        if !threads.isEmpty {
            lines.append("")
            lines.append("Active tracks:")
            for thread in threads.prefix(24) {
                let indent = String(repeating: "  ", count: min(depth(of: thread), 4))
                lines.append("\(indent)- [\(thread.kind.label)] \(thread.title) (\(thread.status.label), id \(thread.id.uuidString))")
                if !thread.summary.isEmpty {
                    lines.append("\(indent)  \(clip(thread.summary, 280))")
                }
            }
        }

        let notes = project.notes.sorted { $0.updatedAt > $1.updatedAt }
        if !notes.isEmpty {
            lines.append("")
            lines.append("Recent notes (reference material):")
            for note in notes.prefix(8) {
                lines.append("- \(note.displayTitle) (id \(note.id.uuidString))")
            }
        }

        let tasks = project.agendaItems.filter { $0.kind == .task }.sorted(by: TaskStore.boardSort)
        if !tasks.isEmpty {
            lines.append("")
            lines.append("Tasks:")
            if let next = TaskStore.nextTask(in: project) {
                lines.append("Next: \(next.displayTitle) (id \(next.id.uuidString))")
            }
            for task in tasks.prefix(20) {
                lines.append("- \(taskLine(task))")
            }
        }

        let marks = project.deletionMarks.sorted { $0.createdAt > $1.createdAt }
        if !marks.isEmpty {
            lines.append("")
            lines.append("Marked for deletion (waiting for the user to Keep or Delete). You cannot delete. Do not mark the same record again unless the reason changed:")
            for mark in marks.prefix(20) {
                lines.append("- \(mark.targetKind.label) \(mark.targetID.uuidString): \(clip(mark.reason, 280))")
                if let kind = mark.replacementKind, let id = mark.replacementID {
                    lines.append("  Replacement: \(kind.label) \(id.uuidString)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    static func prompt(userText: String, context: String, opening: Bool, focusedThread: ProjectThread? = nil) -> String {
        var parts: [String] = []
        if opening {
            parts.append("""
            You are the assistant inside Membrae, the user's knowledge base for their projects. You have the Membrae MCP tools, which read and change that knowledge base.

            When the user tells you something that should last (a fact, a decision, a change of direction, a new line of work, a task), save it yourself with those tools right away, then say in one short line what you saved. Never ask the user to save anything. Update an existing decision, track, note, task, or project when it covers the same thing instead of adding a duplicate. When a new decision replaces an old one, pass supersedes_id. Use the ids from the tools. Use the task tools to list, create, update, and complete Membrae tasks. complete_task records repeat history; do not set status to done on a repeating task. \(knowledgeRules)

            You cannot delete records. If something should go away, call mark_for_deletion with a required reason. Optionally pass replacement_type and replacement_id when another record replaces it. The user decides Keep or Delete. Archive is only for chats the user hides, not a substitute for delete.

            Look up decisions, tracks, notes, tasks, and published code references with the tools. Treat those records as the source of truth and weight active decisions above tracks and notes. get_project is lean and includes attachment ids; open a track with get_thread and list tasks with track_id. Call list_code_references with the project_id to read a published architecture reference, then get_code_reference_entry. Do not ask the user to paste the reference. Do not invent project facts. Do not create or edit files unless the user explicitly asks. If the project lists attached code, inspect files with the project_* tools instead of claiming you cannot see the repository. Fetch only what this message needs. Batch those calls. Do not walk the whole project. After a few tool rounds, answer.

            When you point the user at a note, track, decision, or other Membrae record, put a markdown link on its own line using the id from the tools: [Title](membrae://note/UUID), membrae://thread/UUID, membrae://decision/UUID, membrae://project/UUID, or membrae://conversation/UUID. The app turns that into a card they can open. Do not paste raw ids. Do not invent ids.
            """)
        } else {
            parts.append(knowledgeRules)
        }
        if let thread = focusedThread {
            parts.append(focusedTrackPrompt(for: thread))
        }
        if !context.isEmpty {
            parts.append("""
            <project-context>
            \(context)
            </project-context>
            """)
        }
        parts.append(userText)
        return parts.joined(separator: "\n\n")
    }

    static func focusedTrack(for thread: ProjectThread) -> String {
        var lines: [String] = []
        let title = thread.title.isEmpty ? "Untitled" : thread.title
        lines.append("Track: \(title) (id \(thread.id.uuidString))")
        lines.append("Kind: \(thread.kind.label)")
        lines.append("Status: \(thread.status.label)")
        if !thread.summary.isEmpty {
            lines.append("Summary: \(clip(thread.summary, 400))")
        }
        if !thread.body.isEmpty {
            lines.append("Body:")
            lines.append(clipPreservingBreaks(thread.body, 4000))
        }

        let decisions = thread.decisions
            .filter { $0.status == .active }
            .sorted { $0.createdAt > $1.createdAt }
        if !decisions.isEmpty {
            lines.append("Decisions:")
            for decision in decisions.prefix(8) {
                lines.append("- \(decision.title) (id \(decision.id.uuidString)): \(clip(decision.decision, 400))")
            }
        }

        let tasks = TaskStore.tasks(on: thread, includingDescendants: true)
        if !tasks.isEmpty {
            lines.append("Tasks:")
            for task in tasks.prefix(20) {
                lines.append("- \(taskLine(task))")
            }
        }

        let children = thread.orderedChildren
        if !children.isEmpty {
            lines.append("Child tracks:")
            for child in children {
                let childTitle = child.title.isEmpty ? "Untitled" : child.title
                lines.append("- [\(child.kind.label)] \(childTitle) (\(child.status.label), id \(child.id.uuidString))")
                if !child.summary.isEmpty {
                    lines.append("  \(clip(child.summary, 200))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func codeConsultationPrompt(userText: String, context: String) -> String {
        var parts = [
            "Inspect the attached project code in read-only mode. Do not edit files, create commits, or change Membrae records. Cite repository-relative paths and line numbers."
        ]
        if !context.isEmpty {
            parts.append("<project-context>\n\(context)\n</project-context>")
        }
        parts.append(userText)
        return parts.joined(separator: "\n\n")
    }

    private static func focusedTrackPrompt(for thread: ProjectThread) -> String {
        let title = thread.title.isEmpty ? "Untitled" : thread.title
        return """
        You are in the side chat on track "\(title)" (id \(thread.id.uuidString)). When the user asks you to add a requirement or append to this track, call update_thread on that id with append_to_body. When they ask you to rewrite or replace the spec, get the current body and call update_thread with body, keeping existing requirements unless they asked to remove them. When they ask for a task, call create_task with this id in track_ids. Answer questions and look up other project records with the tools. Do not create a new track for work that belongs here.

        <focused-track>
        \(focusedTrack(for: thread))
        </focused-track>
        """
    }

    private static func taskLine(_ task: AgendaItem) -> String {
        var line = "\(task.displayTitle) (id \(task.id.uuidString), \(task.workflowStatus.rawValue)"
        if task.isNext { line += ", next" }
        line += ")"
        let tracks = task.liveTracks.map { $0.title.isEmpty ? "Untitled" : $0.title }
        if !tracks.isEmpty {
            line += " tracks: \(tracks.joined(separator: ", "))"
        }
        let notes = task.liveNotes.map(\.displayTitle)
        if !notes.isEmpty {
            line += " notes: \(notes.joined(separator: ", "))"
        }
        return line
    }

    private static func clipPreservingBreaks(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
    }

    private static func depth(of thread: ProjectThread) -> Int {
        var count = 0
        var cursor = thread.parent
        while cursor != nil && count < 8 {
            count += 1
            cursor = cursor?.parent
        }
        return count
    }
}
