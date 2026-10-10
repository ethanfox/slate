import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class TrackFirstEvalTests: XCTestCase {
    func testScorerAcceptsAuthBodyEdit() throws {
        let (scenario, seed, container) = try prepared("1")
        seed.auth.body = HarborEvalFixture.authBodyWithOffline
        try container.mainContext.save()

        let score = TrackFirstEval.score(
            scenario,
            seed: seed,
            container: container,
            answer: "Updated the Auth track.",
            calls: [call("update_thread")]
        )
        XCTAssertEqual(score.total, 12)
        XCTAssertTrue(score.hardFailures.isEmpty)
    }

    func testScorerHardFailsLostSpec() throws {
        let (scenario, seed, container) = try prepared("1")
        seed.auth.body = "Sign-in must work offline."
        try container.mainContext.save()

        let score = TrackFirstEval.score(
            scenario,
            seed: seed,
            container: container,
            answer: "Rewrote Auth.",
            calls: [call("update_thread")]
        )
        XCTAssertTrue(score.failed)
        XCTAssertTrue(score.hardFailures.contains { $0.contains("Lost existing Auth spec") })
    }

    func testScorerRequiresTrackLinkedTask() throws {
        let (scenario, seed, container) = try prepared("2")
        let task = AgendaItem(kind: .task, eventKitID: "", title: "Offline sign-in")
        container.mainContext.insert(task)
        AssociationService.assignUserProject(seed.project, on: task)
        AssociationService.applyLink(thread: seed.auth, onto: task)
        try container.mainContext.save()

        let linked = TrackFirstEval.score(
            scenario,
            seed: seed,
            container: container,
            answer: "Created an offline sign-in task on Auth.",
            calls: [call("create_task")]
        )
        XCTAssertEqual(linked.linkage, 2)
        XCTAssertTrue(linked.hardFailures.isEmpty)

        let orphan = AgendaItem(kind: .task, eventKitID: "", title: "Another offline task")
        container.mainContext.insert(orphan)
        AssociationService.assignUserProject(seed.project, on: orphan)
        try container.mainContext.save()
        let unlinked = TrackFirstEval.score(
            scenario,
            seed: seed,
            container: container,
            answer: "Created a task.",
            calls: [call("create_task")]
        )
        XCTAssertTrue(unlinked.hardFailures.contains { $0.contains("governing Auth track") })
    }

    func testScorerRejectsVendorAsAuthority() throws {
        let (scenario, seed, container) = try prepared("3")
        seed.decision.decision = "Switch to hosted accounts."
        try container.mainContext.save()

        let score = TrackFirstEval.score(
            scenario,
            seed: seed,
            container: container,
            answer: "We should follow the vendor docs and host accounts.",
            calls: [call("update_decision")]
        )
        XCTAssertTrue(score.failed)
        XCTAssertTrue(score.hardFailures.contains { $0.contains("vendor reference") })
    }

    func testScorerSeesFreshAuthBodyOnSecondTurn() throws {
        let (scenario, seed, container) = try prepared("6")
        seed.auth.body = HarborEvalFixture.authBodyWithOffline
        try container.mainContext.save()

        let stale = TrackFirstEval.score(
            scenario,
            seed: seed,
            container: container,
            answer: "Use the existing local session store. Do not add a cloud account.",
            calls: []
        )
        XCTAssertTrue(stale.failed)

        let fresh = TrackFirstEval.score(
            scenario,
            seed: seed,
            container: container,
            answer: "Auth now also requires offline sign-in.",
            calls: []
        )
        XCTAssertFalse(fresh.failed)
        XCTAssertEqual(fresh.correctness, 2)
    }

    func testScorerRequiresSupportedCodeFindings() throws {
        let (scenario, seed, container) = try prepared("9")
        seed.auth.body = HarborEvalFixture.authBodyWithOffline
        try container.mainContext.save()

        let keywordsOnly = TrackFirstEval.score(
            scenario,
            seed: seed,
            container: container,
            answer: "This is hosted and cannot work offline.",
            calls: [call("project_read_file")],
            baselineAuth: HarborEvalFixture.authBodyWithOffline
        )
        XCTAssertTrue(keywordsOnly.failed)
        XCTAssertTrue(keywordsOnly.hardFailures.contains { $0.contains("hosted-account") })

        let supported = TrackFirstEval.score(
            scenario,
            seed: seed,
            container: container,
            answer: "SignIn.swift line 6 uses HostedAccountService and URLSession. That needs a network and has no offline local session.",
            calls: [call("project_read_file")],
            baselineAuth: HarborEvalFixture.authBodyWithOffline
        )
        XCTAssertTrue(supported.hardFailures.isEmpty)
        XCTAssertEqual(supported.correctness, 2)
    }

    func testLiveHarborScenarios() async throws {
        let model = ProcessInfo.processInfo.environment["SLATE_EVAL_MODEL"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_MEMBRAE_EVAL_MODEL"]
            ?? "gpt-5.5"
        let repeats = Int(
            ProcessInfo.processInfo.environment["SLATE_EVAL_REPEATS"]
                ?? ProcessInfo.processInfo.environment["TEST_RUNNER_MEMBRAE_EVAL_REPEATS"]
                ?? "1"
        ) ?? 1
        let ids = (ProcessInfo.processInfo.environment["SLATE_EVAL_IDS"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_MEMBRAE_EVAL_IDS"]
            ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let runs = try await TrackFirstEval.runAll(model: model, repeats: repeats, ids: ids)
        let report = TrackFirstEval.report(runs)
        print(report)
        XCTAssertFalse(runs.contains { $0.score.failed }, report)
    }

    private func prepared(_ id: String) throws -> (TrackFirstEval.Scenario, HarborEvalFixture.Seed, ModelContainer) {
        let scenario = try XCTUnwrap(TrackFirstEval.scenarios.first { $0.id == id })
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        try container.mainContext.save()
        return (scenario, seed, container)
    }

    private func call(_ name: String) -> TrackFirstEval.Call {
        TrackFirstEval.Call(name: name, arguments: [:], output: "{}", milliseconds: 0, bytes: 2)
    }
}
