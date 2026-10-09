import Foundation
import SwiftData

enum WorkerPath: String, CaseIterable, Identifiable {
    case local
    case cloud

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ProjectCodeRoot: Codable, Hashable, Sendable {
    var title: String
    var locator: String = ""
    var path: String

    func matches(_ requested: String) -> Bool {
        let needle = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return title.lowercased() == needle
            || locator.lowercased() == needle
            || path.lowercased() == needle
            || locator.lowercased().hasSuffix("/" + needle)
            || title.lowercased().hasSuffix("/" + needle)
            || path.lowercased().hasSuffix("/" + needle)
    }

    static func resolve(_ roots: [ProjectCodeRoot], requested: String?) -> [ProjectCodeRoot] {
        let needle = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !needle.isEmpty else { return roots }
        let matches = roots.filter { $0.matches(needle) }
        if !matches.isEmpty { return matches }
        return roots.count == 1 ? roots : []
    }
}

enum WorkerRegistry {
    static func paths(for providerID: String) -> [WorkerPath] {
        switch TalkProvider(rawValue: providerID) {
        case .cursor: [.local, .cloud]
        case .chatgpt: [.local]
        default: []
        }
    }
}

@MainActor
enum ProjectCodeWorkspace {
    static func prepare(for project: Project?, storeURL: URL?) async throws -> [ProjectCodeRoot] {
        guard let project else { return [] }
        var roots: [ProjectCodeRoot] = []
        var failures: [String] = []
        let attachments = attachments(on: project)
        for attachment in attachments.sorted(by: { $0.createdAt < $1.createdAt }) {
            switch attachment.kind {
            case .folder:
                if let root = localRoot(for: attachment) {
                    roots.append(root)
                }
            case .github, .gitlab:
                guard let storeURL else {
                    failures.append("\(attachment.locator): the knowledge base location is missing.")
                    continue
                }
                let snapshot = RemoteSnapshot(attachment: attachment, projectID: project.id, storeURL: storeURL)
                do {
                    let url = try await ManagedCloneService.prepare(snapshot)
                    roots.append(root(for: attachment, path: url.path))
                } catch {
                    ChatTrace.event("managed clone \(attachment.locator) failed: \(error.localizedDescription)")
                    failures.append("\(attachment.locator): \(error.localizedDescription)")
                }
            }
        }
        if roots.isEmpty, !attachments.isEmpty {
            let detail = failures.isEmpty
                ? "Couldn’t open the attached code."
                : failures.joined(separator: "\n")
            throw ProjectWorkspaceError(detail)
        }
        return roots
    }

    static func localRoots(for project: Project?) -> [ProjectCodeRoot] {
        guard let project else { return [] }
        return attachments(on: project)
            .filter { $0.kind == .folder }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap(localRoot(for:))
    }

    /// Currently readable attachments for this project: local folders plus remote snapshots already on disk.
    /// Uses the same persisted attachment fetch as `list_code_references`. Does not download remotes.
    static func authorizedRoots(for project: Project?, storeURL: URL?) -> [ProjectCodeRoot] {
        guard let project else { return [] }
        var roots: [ProjectCodeRoot] = []
        for attachment in attachments(on: project).sorted(by: { $0.createdAt < $1.createdAt }) {
            switch attachment.kind {
            case .folder:
                if let root = localRoot(for: attachment) {
                    roots.append(root)
                }
            case .github, .gitlab:
                guard let storeURL else { continue }
                let snapshot = RemoteSnapshot(attachment: attachment, projectID: project.id, storeURL: storeURL)
                let marker = snapshot.destination.appendingPathComponent(".slate-snapshot")
                if FileManager.default.fileExists(atPath: marker.path) {
                    roots.append(root(for: attachment, path: snapshot.destination.path))
                }
            }
        }
        return roots
    }

    static func encodedRoots(_ roots: [ProjectCodeRoot]) throws -> String {
        let payload = roots.map { ["title": $0.title, "locator": $0.locator, "path": $0.path] }
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    static func gitHistory(for roots: [ProjectCodeRoot], requested: String?) throws -> [[String: Any]] {
        let selected = ProjectCodeRoot.resolve(roots, requested: requested)
        guard !selected.isEmpty else {
            throw ProjectWorkspaceError(
                roots.isEmpty
                    ? "No code is attached to this Slate project."
                    : "Unknown code root. Use one of: \(roots.map(\.title).joined(separator: ", "))."
            )
        }
        var commits: [[String: Any]] = []
        for root in selected {
            commits += historyEntries(in: root)
        }
        guard !commits.isEmpty else {
            throw ProjectWorkspaceError("Git history is unavailable for this attachment.")
        }
        return commits
    }

    static func remoteSnapshots(for project: Project?, storeURL: URL?) -> [RunnerCodeSnapshot] {
        guard let project, let storeURL else { return [] }
        return attachments(on: project).compactMap { attachment in
            switch attachment.kind {
            case .folder:
                return nil
            case .github, .gitlab:
                let snapshot = RemoteSnapshot(attachment: attachment, projectID: project.id, storeURL: storeURL)
                return RunnerCodeSnapshot(
                    title: attachment.locator.isEmpty ? attachment.title : attachment.locator,
                    locator: attachment.locator,
                    kind: attachment.kind.rawValue,
                    branch: attachment.defaultBranch,
                    token: snapshot.token,
                    path: snapshot.destination.path,
                    archiveURL: snapshot.archiveURL?.absoluteString,
                    commitsURL: snapshot.commitsURL?.absoluteString
                )
            }
        }
    }

    static func attachments(on project: Project) -> [CodeAttachment] {
        if let context = project.modelContext {
            return CodeReferenceStore.attachmentsOn(project, in: context)
        }
        return project.codeAttachments
    }

    private static func localRoot(for attachment: CodeAttachment) -> ProjectCodeRoot? {
        if let url = resolveFolder(attachment) {
            let accessed = url.startAccessingSecurityScopedResource()
            if accessed || FileManager.default.fileExists(atPath: url.path) {
                return root(for: attachment, path: url.path)
            }
        }
        if FileManager.default.fileExists(atPath: attachment.locator) {
            return root(for: attachment, path: attachment.locator)
        }
        return nil
    }

    private static func historyEntries(in root: ProjectCodeRoot) -> [[String: Any]] {
        let stored = URL(fileURLWithPath: root.path).appendingPathComponent(".slate-commits.json")
        if let data = try? Data(contentsOf: stored),
           let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return items.map { item in
                var item = item
                item["root"] = root.title
                return item
            }
        }
        return gitLog(at: root.path, title: root.title)
    }

    private static func gitLog(at path: String, title: String) -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "log", "-20", "--pretty=format:%H%x1f%an%x1f%aI%x1f%s"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            return [
                "sha": parts[0],
                "author": parts[1],
                "date": parts[2],
                "message": parts[3],
                "root": title
            ]
        }
    }

    private static func root(for attachment: CodeAttachment, path: String) -> ProjectCodeRoot {
        let name = attachment.locator.isEmpty ? attachment.title : attachment.locator
        return .init(title: name, locator: attachment.locator, path: path)
    }

    static func stopAccessing(_ roots: [ProjectCodeRoot]) {
        for root in roots {
            URL(fileURLWithPath: root.path).stopAccessingSecurityScopedResource()
        }
    }

    private static func resolveFolder(_ attachment: CodeAttachment) -> URL? {
        guard let bookmark = attachment.bookmark else {
            return URL(fileURLWithPath: attachment.locator)
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        if stale, url.startAccessingSecurityScopedResource() {
            if let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                attachment.bookmark = refreshed
            }
        }
        return url
    }
}

struct RemoteSnapshot: Sendable {
    var kind: CodeAttachmentKind
    var locator: String
    var branch: String
    var token: String?
    var destination: URL

    @MainActor
    init(attachment: CodeAttachment, projectID: UUID, storeURL: URL) {
        kind = attachment.kind
        locator = attachment.locator
        branch = attachment.defaultBranch
        if let id = UUID(uuidString: attachment.tokenID) {
            let provider: ForgeProvider = attachment.kind == .gitlab ? .gitlab : .github
            token = KeychainStore.read(account: KeychainStore.forgeAccount(provider, id: id))
        } else {
            token = nil
        }
        destination = storeURL.deletingLastPathComponent()
            .appendingPathComponent("Repositories", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent(attachment.id.uuidString, isDirectory: true)
    }

    var remoteURL: String {
        switch kind {
        case .github: GitHubRemote.url(forLocator: locator) + ".git"
        case .gitlab: "https://gitlab.com/\(locator).git"
        case .folder: locator
        }
    }

    var archiveURL: URL? {
        let ref = branch.isEmpty ? "HEAD" : branch
        switch kind {
        case .github:
            return URL(string: "https://api.github.com/repos/\(locator)/zipball/\(ref)")
        case .gitlab:
            let encoded = locator.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics
            ) ?? locator
            return URL(string: "https://gitlab.com/api/v4/projects/\(encoded)/repository/archive.zip?sha=\(ref)")
        case .folder:
            return nil
        }
    }

    var commitsURL: URL? {
        let ref = branch.isEmpty ? "HEAD" : branch
        switch kind {
        case .github:
            return URL(string: "https://api.github.com/repos/\(locator)/commits?sha=\(ref)&per_page=20")
        case .gitlab:
            let encoded = locator.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics
            ) ?? locator
            return URL(string: "https://gitlab.com/api/v4/projects/\(encoded)/repository/commits?ref_name=\(ref)&per_page=20")
        case .folder:
            return nil
        }
    }

    func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Slate", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            switch kind {
            case .github:
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .gitlab:
                request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
            case .folder:
                break
            }
        }
        return request
    }
}

enum ManagedCloneService {
    static func tipSHA(from commits: Data) -> String? {
        guard let items = try? JSONSerialization.jsonObject(with: commits) as? [[String: Any]] else { return nil }
        for key in ["sha", "id"] {
            if let sha = items.first?[key] as? String, !sha.isEmpty { return sha }
        }
        return nil
    }

    static func isCurrent(at destination: URL, commits: Data) -> Bool {
        let stored = destination.appendingPathComponent(".slate-commits.json")
        guard let have = try? Data(contentsOf: stored),
              let tip = tipSHA(from: commits),
              let existing = tipSHA(from: have)
        else { return false }
        return tip == existing
    }

    static func prepare(_ snapshot: RemoteSnapshot) async throws -> URL {
        let marker = snapshot.destination.appendingPathComponent(".slate-snapshot")
        let fetched = try? await fetchCommits(snapshot)
        if let fetched, isCurrent(at: snapshot.destination, commits: fetched) {
            return snapshot.destination
        }
        if fetched == nil,
           FileManager.default.fileExists(atPath: snapshot.destination.path),
           FileManager.default.fileExists(atPath: marker.path) {
            return snapshot.destination
        }
        guard let archiveURL = snapshot.archiveURL else {
            throw ProjectWorkspaceError("This attachment cannot be downloaded.")
        }
        let (archive, response) = try await URLSession.shared.data(for: snapshot.authorizedRequest(url: archiveURL))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProjectWorkspaceError("Could not download \(snapshot.locator) (\(status)).")
        }
        var commits = fetched
        if commits == nil {
            commits = try? await fetchCommits(snapshot)
        }
        return try await Task.detached {
            let fm = FileManager.default
            let parent = snapshot.destination.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let archiveFile = parent.appendingPathComponent("\(UUID().uuidString).zip")
            let extracted = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? fm.removeItem(at: archiveFile)
                try? fm.removeItem(at: extracted)
            }
            try archive.write(to: archiveFile, options: .atomic)
            try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
            try extract(archiveFile, to: extracted)
            let children = try fm.contentsOfDirectory(
                at: extracted,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            guard let source = children.first else {
                throw ProjectWorkspaceError("The repository archive was empty.")
            }
            if fm.fileExists(atPath: snapshot.destination.path) {
                try fm.removeItem(at: snapshot.destination)
            }
            try fm.createDirectory(at: snapshot.destination, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil
            ) {
                try fm.moveItem(
                    at: item,
                    to: snapshot.destination.appendingPathComponent(item.lastPathComponent)
                )
            }
            if let commits {
                try commits.write(
                    to: snapshot.destination.appendingPathComponent(".slate-commits.json"),
                    options: .atomic
                )
            }
            try Data(snapshot.remoteURL.utf8).write(to: marker, options: .atomic)
            return snapshot.destination
        }.value
    }

    private static func fetchCommits(_ snapshot: RemoteSnapshot) async throws -> Data {
        guard let url = snapshot.commitsURL else { return Data("[]".utf8) }
        let (data, response) = try await URLSession.shared.data(for: snapshot.authorizedRequest(url: url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProjectWorkspaceError("Could not read commits for \(snapshot.locator) (\(status)).")
        }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return Data("[]".utf8)
        }
        let normalized: [[String: Any]] = items.map { item in
            if snapshot.kind == .github {
                let commit = item["commit"] as? [String: Any]
                let author = commit?["author"] as? [String: Any]
                return [
                    "sha": item["sha"] as? String ?? "",
                    "message": commit?["message"] as? String ?? "",
                    "author": author?["name"] as? String ?? "",
                    "date": author?["date"] as? String ?? "",
                    "url": item["html_url"] as? String ?? ""
                ]
            }
            return [
                "sha": item["id"] as? String ?? "",
                "message": item["message"] as? String ?? item["title"] as? String ?? "",
                "author": item["author_name"] as? String ?? "",
                "date": item["committed_date"] as? String ?? "",
                "url": item["web_url"] as? String ?? ""
            ]
        }
        return try JSONSerialization.data(withJSONObject: normalized)
    }

    private static func extract(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ProjectWorkspaceError(detail.isEmpty ? "Could not unpack the repository." : detail)
        }
    }
}

struct ProjectWorkspaceError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
