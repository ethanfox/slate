import XCTest
@testable import Membrae
import SwiftGitX

@MainActor
final class GitHistoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("membrae-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testOrdinaryRepositoryAndSubdirectory() throws {
        let first = try commit("one.txt", message: "first")
        let second = try commit("two.txt", message: "second")
        let nested = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let fromRoot = try GitHistory.commits(in: root.path)
        XCTAssertEqual(fromRoot.map(\.message), ["second", "first"])
        XCTAssertEqual(fromRoot.map(\.sha), [second.id.hex, first.id.hex])
        XCTAssertEqual(fromRoot[0].author, "Membrae Test")
        XCTAssertTrue(fromRoot[0].date.contains("T"), fromRoot[0].date)

        let fromNested = try ProjectCodeWorkspace.gitHistory(
            for: [ProjectCodeRoot(title: "pc-os", locator: nested.path, path: nested.path)],
            requested: nil
        )
        XCTAssertEqual(fromNested.map { $0["message"] as? String }, ["second", "first"])
        XCTAssertEqual(fromNested.map { $0["root"] as? String }, ["pc-os", "pc-os"])
        XCTAssertEqual(fromNested.map { $0["sha"] as? String }, [second.id.hex, first.id.hex])
    }

    func testEmptyRepositoryIsEmptyHistoryNotFailure() throws {
        _ = try seededRepository()
        let commits = try GitHistory.commits(in: root.path)
        XCTAssertTrue(commits.isEmpty)
        let payload = try ProjectCodeWorkspace.gitHistory(
            for: [ProjectCodeRoot(title: "empty", locator: root.path, path: root.path)],
            requested: nil
        )
        XCTAssertTrue(payload.isEmpty)
    }

    func testDetachedHEAD() throws {
        let commit = try commit("head.txt", message: "detached")
        try "\(commit.id.hex)\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        let commits = try GitHistory.commits(in: root.path)
        XCTAssertEqual(commits.map(\.sha), [commit.id.hex])
        XCTAssertEqual(commits.map(\.message), ["detached"])
    }

    func testMissingRepositoryIsAFailure() {
        XCTAssertThrowsError(try GitHistory.commits(in: root.path)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains(root.path), text)
            XCTAssertTrue(text.contains("No git repository") || text.contains("Could not open git repository"), text)
            XCTAssertFalse(text.contains("xcrun"), text)
            XCTAssertFalse(text.contains("Git history is unavailable"), text)
        }
    }

    func testInaccessibleWorktreeGitDirIsReported() throws {
        let gitDir = "/private/var/folders/membrae-missing-gitdir-\(UUID().uuidString)"
        try "gitdir: \(gitDir)\n".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try GitHistory.commits(in: root.path)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains(gitDir), text)
            XCTAssertTrue(text.contains("not accessible"), text)
        }
    }

    func testSandboxCanReadAttachedPCOSHistory() throws {
        let repo = try XCTUnwrap(pcosRoot(), "Could not locate the PC-OS working tree from test sources")
        var isDirectory: ObjCBool = false
        let readable = FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path, isDirectory: &isDirectory)
        guard readable else {
            throw XCTSkip("Sandboxed test host cannot read the PC-OS .git folder without a security-scoped bookmark.")
        }
        let commits = try GitHistory.commits(in: repo.path)
        XCTAssertFalse(commits.isEmpty, "PC-OS should have commit history")
        XCTAssertLessThanOrEqual(commits.count, 20)
        XCTAssertEqual(commits[0].sha.count, 40)
        XCTAssertFalse(commits[0].message.isEmpty)
        XCTAssertFalse(commits.contains { $0.message.contains("xcrun") })
    }

    private func seededRepository() throws -> Repository {
        let repository = try Repository.create(at: root)
        try repository.config.set("user.name", to: "Membrae Test")
        try repository.config.set("user.email", to: "membrae@example.com")
        return repository
    }

    @discardableResult
    private func commit(_ file: String, message: String) throws -> SwiftGitX.Commit {
        let repository = try FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
            ? Repository.open(at: root)
            : seededRepository()
        try Data(file.utf8).write(to: root.appendingPathComponent(file))
        try repository.add(path: file)
        return try repository.commit(message: message)
    }

    private func pcosRoot() -> URL? {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }
}
