import Foundation
import SwiftGitX

enum GitHistory {
    struct Commit {
        var sha: String
        var author: String
        var date: String
        var message: String
    }

    static func commits(in path: String, limit: Int = 20) throws -> [Commit] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if let blocked = inaccessibleGitDir(from: url) {
            throw ProjectWorkspaceError(
                "Git metadata for \(path) is at \(blocked), which is not accessible from the sandbox."
            )
        }
        let workTree = try discoverWorkTree(from: url)
        let repository: Repository
        do {
            repository = try Repository.open(at: workTree)
        } catch {
            throw ProjectWorkspaceError("Could not open git repository in \(path): \(error.localizedDescription)")
        }
        if repository.isEmpty || repository.isHEADUnborn {
            return []
        }
        let history: [SwiftGitX.Commit]
        do {
            history = Array(try repository.log().prefix(limit))
        } catch {
            throw ProjectWorkspaceError("Could not read git history in \(path): \(error.localizedDescription)")
        }
        return history.map { commit in
            Commit(
                sha: commit.id.hex,
                author: commit.author.name,
                date: iso8601(commit.author.date, timeZone: commit.author.timezone),
                message: commit.summary
            )
        }
    }

    private static func discoverWorkTree(from start: URL) throws -> URL {
        var current = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        throw ProjectWorkspaceError("No git repository in \(start.path) or its parents.")
    }

    private static func inaccessibleGitDir(from start: URL) -> String? {
        var current = start.standardizedFileURL
        while true {
            let marker = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return nil }
                guard let gitDir = gitDirPointer(in: marker) else {
                    return marker.path
                }
                return FileManager.default.isReadableFile(atPath: gitDir) ? nil : gitDir
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    private static func gitDirPointer(in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("gitdir:") else { continue }
            let raw = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            let url = URL(fileURLWithPath: raw, relativeTo: file.deletingLastPathComponent())
            return url.standardizedFileURL.path
        }
        return nil
    }

    private static func iso8601(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset >= 0 ? "+" : "-"
        let absolute = abs(offset)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0,
            sign,
            absolute / 3600,
            (absolute % 3600) / 60
        )
    }
}
