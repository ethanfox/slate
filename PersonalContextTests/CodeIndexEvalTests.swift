import XCTest
@testable import Slate

@MainActor
final class CodeIndexEvalTests: XCTestCase {
    func testLiveSlateRepositoryIndex() async throws {
        guard CodeIndexEval.isRequested else {
            throw XCTSkip("Set TEST_RUNNER_SLATE_EVAL_INDEX=1 to run the live indexing evaluation.")
        }
        let model = ProcessInfo.processInfo.environment["SLATE_EVAL_MODEL"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_SLATE_EVAL_MODEL"]
            ?? "gpt-5.5"
        let repo = ProcessInfo.processInfo.environment["SLATE_EVAL_REPO"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_SLATE_EVAL_REPO"]
            ?? FileManager.default.currentDirectoryPath
        let result = try await CodeIndexEval.run(model: model, repoPath: repo)
        let report = CodeIndexEval.report(result)
        print(report)
        XCTAssertTrue(result.hardFailures.isEmpty, report)
    }
}
