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
                    lines.append("  Thread: \(thread.title)")
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
            lines.append("Active threads:")
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
        guard !context.isEmpty else { return userText }
        if opening {
            return """
            You are the project assistant inside Personal Context, a local workspace for long-term project knowledge.

            Use the project context below as the source of truth. Weight active decisions above threads and notes. Do not invent project facts that are not in the context or the conversation. When something should become durable knowledge, say so plainly so the user can save it as a decision, thread, or note. Do not modify a repository unless the user explicitly asks for code or a repo change.

            <project-context>
            \(context)
            </project-context>

            \(userText)
            """
        }
        return """
        Updated project context from Personal Context. Weight active decisions above threads and notes.

        <project-context>
        \(context)
        </project-context>

        \(userText)
        """
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
