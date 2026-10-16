import XCTest
@testable import Membrae

final class TrackBranchesTests: XCTestCase {
    /// Runs inside the sandboxed app: git goes through the helper, the same way a session's does.
    @MainActor
    func testATrackGetsItsOwnBranchAndWorktreeAndComesBackIntoMain() async throws {
        let base = "/private/tmp/membrae-branch-test-\(UUID().uuidString.prefix(8))"
        let repo = base + "/repo"
        func git(_ arguments: [String], in directory: String = repo) async throws -> GitRelay.Result {
            try await GitRelay.run(arguments, in: directory)
        }
        // The test host is sandboxed and cannot write there itself, so files are written the way git is run.
        func sh(_ script: String) async throws {
            let ticket = WorkerRelay.Ticket(id: "test-" + UUID().uuidString, executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"], directory: "/private/tmp")
            let handle = try await WorkerRelay.launch(ticket) { _ in }
            for await _ in handle.lines {}
            _ = await handle.exitStatus()
        }
        _ = try await GitRelay.run(["init", "-q", "-b", "main", repo], in: "/private/tmp")
        _ = try await git(["config", "user.email", "test@membrae.com"])
        _ = try await git(["config", "user.name", "Membrae Test"])
        _ = try await git(["commit", "-q", "--allow-empty", "-m", "start"])
        defer { Task { try? await sh("rm -rf \(base)") } }

        let track = ProjectThread(title: "Cloud sync", kind: .feature, project: Project(name: "Harbor", symbol: "folder", summary: ""))
        let isRepository = await TrackBranches.isRepository(repo)
        XCTAssertTrue(isRepository)
        let first = try await TrackBranches.prepare(track: track, repository: repo)
        XCTAssertEqual(first, TrackBranches.Checkout(path: repo + "-cloud-sync", branch: "cloud-sync", base: "main"))
        let head = try await git(["symbolic-ref", "--short", "HEAD"], in: first.path)
        XCTAssertEqual(head.output.trimmingCharacters(in: .whitespacesAndNewlines), "cloud-sync")
        let main = await TrackBranches.mainRepository(ofWorktree: first.path)
        XCTAssertEqual(main, repo)

        // Preparing again finds the worktree it made.
        track.branch = first.branch
        track.worktreePath = first.path
        let again = try await TrackBranches.prepare(track: track, repository: repo)
        XCTAssertEqual(again, first)

        // A turn's commits are measured from the head before it.
        let before = await TrackBranches.head(in: first.path)
        _ = try await git(["commit", "-q", "--allow-empty", "-m", "first turn"], in: first.path)
        let commits = await TrackBranches.commits(since: before, in: first.path)
        XCTAssertEqual(commits.count, 1)
        XCTAssertTrue(commits[0].hasSuffix(" first turn"), commits[0])
        let remote = await TrackBranches.remote(in: first.path)
        XCTAssertNil(remote)

        // The branch comes into main in the user's own folder.
        let merged = try await TrackBranches.mergeIntoBase(branch: "cloud-sync", base: "main", repository: repo)
        XCTAssertEqual(merged, .merged)
        let log = try await git(["log", "--oneline"])
        XCTAssertTrue(log.output.contains("first turn"), log.output)

        // The same line changed on both sides is a conflict, named and left for a session to reconcile.
        _ = try await git(["-c", "core.quotepath=off", "checkout", "-q", "main"])
        try await sh("printf 'main line\\n' > \(repo)/shared.txt")
        _ = try await git(["add", "shared.txt"])
        _ = try await git(["commit", "-q", "-m", "main edits shared"])
        try await sh("printf 'track line\\n' > \(first.path)/shared.txt")
        _ = try await git(["add", "shared.txt"], in: first.path)
        _ = try await git(["commit", "-q", "-m", "track edits shared"], in: first.path)
        let conflicted = try await TrackBranches.mergeIntoBase(branch: "cloud-sync", base: "main", repository: repo)
        XCTAssertEqual(conflicted, .conflicts(["shared.txt"]))
        let clean = try await git(["status", "--porcelain"])
        XCTAssertEqual(clean.output, "", "the failed merge was aborted")
        let elsewhere = try await TrackBranches.mergeIntoBase(branch: "cloud-sync", base: "develop", repository: repo)
        XCTAssertEqual(elsewhere, .elsewhere("main"))
    }

    func testATrackTitleBecomesABranchName() {
        XCTAssertEqual(TrackBranches.slug("Cloud sync, sign-in, and privacy"), "cloud-sync-sign-in-and-privacy")
        XCTAssertEqual(TrackBranches.slug("  Agent Runs & capabilities!  "), "agent-runs-capabilities")
        XCTAssertEqual(TrackBranches.slug("///"), "track")
        XCTAssertLessThanOrEqual(TrackBranches.slug(String(repeating: "long word ", count: 20)).count, 40)
        XCTAssertFalse(TrackBranches.slug(String(repeating: "abcd ", count: 20)).hasSuffix("-"))
    }

    func testTheWorktreeSitsBesideTheRepository() {
        XCTAssertEqual(
            TrackBranches.worktreePath(repository: "/Users/me/Code/PC-OS", branch: "cloud-sync"),
            "/Users/me/Code/PC-OS-cloud-sync"
        )
    }

    func testAGitHubRemoteGivesAPullRequestPage() {
        XCTAssertEqual(
            TrackBranches.pullRequestURL(remote: "git@github.com:ethanfox/PC-OS.git", branch: "cloud-sync")?.absoluteString,
            "https://github.com/ethanfox/PC-OS/compare/cloud-sync?expand=1"
        )
        XCTAssertEqual(
            TrackBranches.pullRequestURL(remote: "https://github.com/ethanfox/PC-OS", branch: "cloud-sync")?.absoluteString,
            "https://github.com/ethanfox/PC-OS/compare/cloud-sync?expand=1"
        )
        XCTAssertNil(TrackBranches.pullRequestURL(remote: "git@gitlab.com:ethanfox/PC-OS.git", branch: "cloud-sync"))
    }

    func testConflictsAreKeptOnTheTrack() {
        let track = ProjectThread(title: "Cloud sync", kind: .feature, project: Project(name: "Harbor", symbol: "folder", summary: ""))
        XCTAssertFalse(track.hasBranch)
        track.mergeConflicts = ["a.swift", "b/c.swift"]
        XCTAssertEqual(track.mergeConflicts, ["a.swift", "b/c.swift"])
        track.mergeConflicts = []
        XCTAssertEqual(track.mergeConflictsJSON, "")
    }
}
