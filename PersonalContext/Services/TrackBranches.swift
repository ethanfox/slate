import Foundation

/// A track is a branch. A session on a track in a git repository works in its own worktree on that branch,
/// Membrae pushes the branch after each turn when the repository has a remote, and the track arrives by
/// merging into the branch the user has checked out. A folder that is not a repository gets none of this.
enum TrackBranches {
    struct Checkout: Equatable {
        var path: String
        var branch: String
        var base: String
    }

    enum MergeOutcome: Equatable {
        case merged
        case conflicts([String])
        /// The user's own folder has uncommitted changes, so nothing was merged.
        case dirty
        /// The user's folder has another branch checked out, so nothing was merged.
        case elsewhere(String)
    }

    /// "Cloud sync, sign-in, and privacy" becomes "cloud-sync-sign-in-and-privacy".
    static func slug(_ title: String) -> String {
        var out = ""
        var dash = false
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !dash, !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 40 {
            out = String(out.prefix(40))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "track" : out
    }

    /// Where the worktree for a track goes: beside the repository, named after it and the branch.
    static func worktreePath(repository: String, branch: String) -> String {
        let repo = URL(fileURLWithPath: repository)
        return repo.deletingLastPathComponent().appending(path: repo.lastPathComponent + "-" + branch).path
    }

    static func isRepository(_ path: String) async -> Bool {
        (try? await GitRelay.run(["rev-parse", "--is-inside-work-tree"], in: path))?.status == 0
    }

    /// The branch the user has checked out in their own folder: what a track merges into.
    static func baseBranch(in repository: String) async -> String {
        let result = try? await GitRelay.run(["symbolic-ref", "--short", "HEAD"], in: repository)
        let name = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result?.status == 0 && !name.isEmpty ? name : "main"
    }

    /// The first remote, usually origin, or nil for a repository that lives only on the Mac.
    static func remote(in repository: String) async -> String? {
        guard let result = try? await GitRelay.run(["remote"], in: repository), result.status == 0 else { return nil }
        return result.output.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Makes the track's branch and worktree if they do not exist yet, and says where the worker goes.
    static func prepare(track: ProjectThread, repository: String) async throws -> Checkout {
        let branch = track.branch.isEmpty ? slug(track.title) : track.branch
        let path = track.worktreePath.isEmpty ? worktreePath(repository: repository, branch: branch) : track.worktreePath
        let base = await baseBranch(in: repository)
        let listed = try await GitRelay.run(["worktree", "list", "--porcelain"], in: repository)
        if listed.status == 0, listed.output.contains("worktree \(path)\n") || listed.output.hasSuffix("worktree \(path)") {
            return Checkout(path: path, branch: branch, base: base)
        }
        let exists = (try? await GitRelay.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repository))?.status == 0
        let added = try await GitRelay.run(exists ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path], in: repository)
        guard added.status == 0 else {
            throw TrackBranchError("git could not make the branch: \(added.lastLine)")
        }
        return Checkout(path: path, branch: branch, base: base)
    }

    /// The repository a worktree belongs to: the folder the user attached.
    static func mainRepository(ofWorktree path: String) async -> String? {
        guard let result = try? await GitRelay.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path), result.status == 0 else { return nil }
        let common = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard common.hasSuffix("/.git") else { return nil }
        return URL(fileURLWithPath: common).deletingLastPathComponent().path
    }

    /// HEAD's short hash, to measure a turn's commits.
    static func head(in path: String) async -> String? {
        guard let result = try? await GitRelay.run(["rev-parse", "--short", "HEAD"], in: path), result.status == 0 else { return nil }
        let sha = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Commits made since `sha`, newest first, as "hash subject".
    static func commits(since sha: String?, in path: String) async -> [String] {
        let range = sha.map { "\($0)..HEAD" } ?? "-20"
        guard let result = try? await GitRelay.run(["log", "--format=%h %s", range], in: path), result.status == 0 else { return [] }
        return result.output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// Pushes the track's branch, never anything else. Returns one line for the transcript.
    static func push(branch: String, in path: String, remote: String) async -> String {
        guard let result = try? await GitRelay.run(["push", "--set-upstream", remote, branch], in: path) else {
            return "Push did not run"
        }
        return result.status == 0 ? "Pushed \(branch) to \(remote)" : "Push failed: \(result.lastLine)"
    }

    /// Merges the track's branch into the user's checked-out branch, in the user's own folder.
    static func mergeIntoBase(branch: String, base: String, repository: String) async throws -> MergeOutcome {
        let current = await baseBranch(in: repository)
        if current != base { return .elsewhere(current) }
        let merge = try await GitRelay.run(["merge", "--no-ff", "--no-edit", branch], in: repository)
        if merge.status == 0 { return .merged }
        if (merge.output + merge.error).contains("would be overwritten") {
            return .dirty
        }
        let conflicts = (try? await GitRelay.run(["diff", "--name-only", "--diff-filter=U"], in: repository))?.output
            .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty } ?? []
        _ = try? await GitRelay.run(["merge", "--abort"], in: repository)
        guard !conflicts.isEmpty else {
            throw TrackBranchError("git could not merge: \(merge.lastLine)")
        }
        return .conflicts(conflicts)
    }

    /// GitHub's compare page for the branch, for a remote on GitHub.
    static func pullRequestURL(repository: String, branch: String) async -> URL? {
        guard let result = try? await GitRelay.run(["remote", "get-url", "origin"], in: repository), result.status == 0 else { return nil }
        return pullRequestURL(remote: result.output.trimmingCharacters(in: .whitespacesAndNewlines), branch: branch)
    }

    static func pullRequestURL(remote: String, branch: String) -> URL? {
        var path: String?
        if let range = remote.range(of: "github.com:") {
            path = String(remote[range.upperBound...])
        } else if let range = remote.range(of: "github.com/") {
            path = String(remote[range.upperBound...])
        }
        guard var slug = path else { return nil }
        if slug.hasSuffix(".git") { slug.removeLast(4) }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard slug.split(separator: "/").count == 2,
              let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://github.com/\(slug)/compare/\(encoded)?expand=1")
    }
}

struct TrackBranchError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One git command, run outside the sandbox through the worker helper, since the app cannot touch a worktree
/// beside the attached folder itself.
enum GitRelay {
    struct Result {
        var status: Int32
        var output: String
        var error: String
        var lastLine: String { error.isEmpty ? (output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(status)") : error }
    }

    @MainActor
    static func run(_ arguments: [String], in directory: String) async throws -> Result {
        let ticket = WorkerRelay.Ticket(
            id: "git-" + UUID().uuidString,
            executable: "/usr/bin/git",
            arguments: ["-C", directory] + arguments,
            environment: [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "HOME": LocalAgent.home,
                "GIT_TERMINAL_PROMPT": "0",
                "LANG": "en_US.UTF-8"
            ],
            directory: directory,
            parentPID: ProcessInfo.processInfo.processIdentifier
        )
        let handle = try await WorkerRelay.launch(ticket) { _ in }
        var lines: [String] = []
        for await line in handle.lines { lines.append(line) }
        let status = await handle.exitStatus()
        if status == WorkerRelay.neverStarted {
            throw TrackBranchError("The worker helper did not start, so git could not run.")
        }
        return Result(status: status, output: lines.joined(separator: "\n"), error: WorkerRelay.lastErrorLine(for: ticket.id))
    }
}
