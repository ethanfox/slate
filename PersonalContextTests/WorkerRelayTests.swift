import XCTest
@testable import Membrae

/// Runs inside the sandboxed app, so this is the same launch a session makes.
@MainActor
final class WorkerRelayTests: XCTestCase {
    func testAToolRunsOutsideTheSandboxAndItsOutputComesBack() async throws {
        let probe = "/Users/ethanfox/Code/PC-OS/.relay-test-probe"
        try? FileManager.default.removeItem(atPath: probe)
        let ticket = WorkerRelay.Ticket(
            id: "test-" + UUID().uuidString,
            executable: "/bin/sh",
            arguments: ["-c", "echo first; echo second; touch \(probe); exit 0"],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: "/Users/ethanfox/Code/PC-OS"
        )
        var reported: [String] = []
        let handle = try await WorkerRelay.launch(ticket) { reported.append($0) }
        var lines: [String] = []
        for await line in handle.lines { lines.append(line) }
        let status = await handle.exitStatus()
        let trail = reported.joined(separator: "\n")
        XCTAssertEqual(status, 0, trail)
        XCTAssertEqual(lines, ["first", "second"], trail)
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe), "the tool wrote into the repository\n" + trail)
        try? FileManager.default.removeItem(atPath: probe)
    }
}
