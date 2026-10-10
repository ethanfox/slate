import Foundation
import SwiftData

enum RepositoryIndex {
    static let toolWrites = [
        "upsert_code_reference_entry",
        "set_code_reference_meta"
    ]

    static let toolReads = [
        "list_code_references",
        "get_code_reference_entry"
    ]

    static func locator(for attachment: CodeAttachment) -> String {
        CodeReferenceStore.locator(for: attachment)
    }

    static func draft(
        for attachment: CodeAttachment,
        project: Project,
        providerID: String,
        modelID: String
    ) -> NewRunDraft {
        var draft = NewRunDraft.blank(
            origin: .project,
            projectID: project.id,
            brief: brief(for: attachment),
            providerID: providerID,
            modelID: modelID,
            pathRaw: WorkerPath.local.rawValue
        )
        draft.purpose = .indexRepository
        draft.indexedAttachmentID = attachment.id
        draft.repositoryLocators = [locator(for: attachment)]
        return draft
    }

    static func brief(for attachment: CodeAttachment) -> String {
        let name = attachment.title.isEmpty ? attachment.locator : attachment.title
        return "Index repository \(name) and produce an architecture reference."
    }

    static func isIndexingBrief(_ brief: String) -> Bool {
        CodeReferenceStore.isIndexingBrief(brief)
    }

    static func prompt(brief: String, project: Project?, attachmentTitle: String) -> String {
        let identity = project.map(ContextBuilder.identity(for:)) ?? ""
        let body = """
        You are indexing one attached repository: \(attachmentTitle).
        Produce a durable architecture reference for later agents. This is not a file list, symbol index, or summary of every file.

        Work in this order:
        1. Establish a bounded inventory: structure, languages, build configuration, dependencies, entry points, and tests. Skip generated files, build output, vendored dependencies, binaries, and sensitive files.
        2. Read actual source with project_read_file. Identify components from the implementation, not a filename taxonomy. Record uncertainties and uninvestigated areas. Each implementation entry must cite the source you actually inspected.
        3. Write reference entries with upsert_code_reference_entry. Each entry is a coherent component: purpose, execution flow, state and persistence, dependencies, likely change locations, and relevant tests. Include at least one supporting source location for the files you read. Point at real paths and optional declaration names. Do not invent locations you did not inspect. Membrae records the content hash of the file version returned by project_read_file; do not supply hashes.
        4. Call set_code_reference_meta with coverage (inventory, partial, or complete), coverage notes, and what local changes you examined. Partial work must be labeled partial. Do not claim the reference is complete if areas remain uninvestigated.
        5. Call finish_run with a short summary. Publication happens only if Membrae validates the staged reference. Do not claim you published it.

        You may read this repository through project_list_files, project_search_code, project_read_file, and project_git_log.
        You may write only the staged code reference for this attachment.
        You cannot edit source, create notes or tracks, or change other Membrae records.

        \(brief)
        """
        if identity.isEmpty { return body }
        return "\(identity)\n\n\(body)"
    }

    static func fingerprint(at path: String) -> CodeSourceFingerprint {
        let sha = git(path, ["rev-parse", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = git(path, ["status", "--porcelain"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let local: String
        if sha.isEmpty && status.isEmpty {
            local = FileManager.default.fileExists(atPath: path)
                ? "Working tree examined; git metadata unavailable."
                : "Attachment path was missing when examined."
        } else if status.isEmpty {
            local = "Clean working tree."
        } else {
            let names = status
                .split(whereSeparator: \.isNewline)
                .prefix(12)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            local = "Local changes examined: \(names.joined(separator: "; "))."
        }
        var commit = sha
        if commit.isEmpty {
            commit = tipSHA(at: path) ?? ""
        }
        return CodeSourceFingerprint(commitSHA: commit, localChanges: local, capturedAt: .now)
    }

    private static func tipSHA(at path: String) -> String? {
        let file = Store.commitsFile(in: URL(fileURLWithPath: path))
        guard let data = try? Data(contentsOf: file) else { return nil }
        return ManagedCloneService.tipSHA(from: data)
    }

    private static func git(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
