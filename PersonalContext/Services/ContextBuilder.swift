import Foundation

enum ContextBuilder {
    static func package(for project: Project) -> String {
        var lines: [String] = []
        lines.append("Project: \(project.name) (id \(project.id.uuidString))")
        lines.append("Status: \(project.status.label)")
        if !project.summary.isEmpty {
            lines.append("Summary: \(clip(project.summary, 900))")
        }
        if !project.currentDirection.isEmpty {
            lines.append("Current direction: \(clip(project.currentDirection, 900))")
        }

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
            lines.append("Recent notes:")
            for note in notes.prefix(8) {
                lines.append("- \(note.displayTitle) (id \(note.id.uuidString)): \(clip(note.content, 400))")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func prompt(userText: String, context: String, opening: Bool) -> String {
        var parts: [String] = []
        if opening {
            parts.append("""
            You are the assistant inside Slate, the user's knowledge base for their projects. You have the Slate MCP tools, which read and change that knowledge base.

            When the user tells you something that should last (a fact, a decision, a change of direction, a new line of work), save it yourself with those tools right away, then say in one short line what you saved. Never ask the user to save anything. Update an existing decision, track, note, or project when it covers the same thing instead of adding a duplicate. When a new decision replaces an old one, pass supersedes_id. Use the ids shown in the project context.

            Treat the project context as the source of truth and weight active decisions above tracks and notes. Do not invent project facts. Do not create or edit files unless the user explicitly asks.
            """)
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
