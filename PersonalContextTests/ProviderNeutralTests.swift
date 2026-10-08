import SwiftData
import XCTest
@testable import Slate

final class ProviderNeutralTests: XCTestCase {
    @MainActor
    func testConversationPersistsProviderModelAndExternalSession() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let conversation = Conversation(providerID: "chatgpt", modelID: "gpt-test")
        conversation.externalSessionID = "response-123"
        container.mainContext.insert(conversation)
        try container.mainContext.save()

        let stored = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(stored.providerID, "chatgpt")
        XCTAssertEqual(stored.modelID, "gpt-test")
        XCTAssertEqual(stored.externalSessionID, "response-123")
    }

    @MainActor
    func testIdentityListsAttachedCodeAndRequiresTools() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        container.mainContext.insert(project)
        container.mainContext.insert(CodeAttachment(
            kind: .github,
            title: "repo",
            locator: "owner/repo",
            defaultBranch: "main",
            project: project
        ))
        try container.mainContext.save()
        let text = ContextBuilder.identity(for: project)
        XCTAssertTrue(text.contains("owner/repo"))
        XCTAssertTrue(text.contains("project_git_log"))
    }

    @MainActor
    func testProjectWorkerDefaultsToChatModel() {
        let project = Project(name: "Test", symbol: "folder", summary: "")
        XCTAssertEqual(project.workerProviderID, "")
        XCTAssertEqual(project.workerModelID, "")
        XCTAssertEqual(project.workerPath, "")
    }

    func testCodeRootMatchesLocatorOrShortName() {
        let root = ProjectCodeRoot(title: "owner/repo", locator: "owner/repo", path: "/tmp/repo")
        XCTAssertTrue(root.matches("owner/repo"))
        XCTAssertTrue(root.matches("repo"))
        XCTAssertEqual(ProjectCodeRoot.resolve([root], requested: "Harbor").map(\.title), ["owner/repo"])
    }

    func testWorkerCapabilitiesAreProviderSpecific() {
        XCTAssertEqual(WorkerRegistry.paths(for: TalkProvider.cursor.rawValue), [.local, .cloud])
        XCTAssertEqual(WorkerRegistry.paths(for: TalkProvider.chatgpt.rawValue), [.local])
        XCTAssertTrue(WorkerRegistry.paths(for: TalkProvider.unconfigured.rawValue).isEmpty)
    }

    @MainActor
    func testProjectCodeToolsAreReadOnlyAndScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let answer = 42\n".write(
            to: root.appendingPathComponent("Answer.swift"),
            atomically: true,
            encoding: .utf8
        )

        let gateway = SlateToolGateway(
            roots: [.init(title: "Fixture", path: root.path)],
            includeSlateTools: false
        )
        let listed = try await gateway.execute(name: "project_list_files", arguments: [:])
        XCTAssertTrue(listed.contains("Answer.swift"))

        let searched = try await gateway.execute(
            name: "project_search_code",
            arguments: ["query": "answer"]
        )
        XCTAssertTrue(searched.contains("\"line\":1"))

        let read = try await gateway.execute(
            name: "project_read_file",
            arguments: ["path": "Answer.swift"]
        )
        XCTAssertEqual(read, "1: let answer = 42\n2: ")

        do {
            _ = try await gateway.execute(
                name: "project_read_file",
                arguments: ["path": "../outside"]
            )
            XCTFail("Expected traversal to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("outside"))
        }
    }

    func testChatGPTInferenceBodyMatchesPlanUsageContract() {
        let body = ChatGPTProvider.inferenceBody(
            model: "gpt-5.5",
            instructions: "Use Slate tools.",
            input: [["role": "user", "content": "hello"]],
            tools: [["type": "function", "name": "list_projects"]]
        )
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        XCTAssertNil(body["previous_response_id"])
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
    }

    func testChatGPTAPIErrorReadsDetailAndStructuredFields() {
        let detail = ChatGPTProvider.apiError(from: ["detail": "Unsupported parameter: store"])
        XCTAssertEqual(detail, "Unsupported parameter: store")

        let structured = ChatGPTProvider.apiError(from: [
            "error": [
                "message": "This capability is not supported.",
                "code": "subscription_sharing_unsupported_capability",
                "param": "tools"
            ]
        ])
        XCTAssertEqual(
            structured,
            "This capability is not supported. subscription_sharing_unsupported_capability param: tools"
        )

        let sse = ChatGPTProvider.apiError(from: Data("data: {\"detail\":\"Instructions are required\"}\n".utf8))
        XCTAssertEqual(sse, "Instructions are required")
    }

    func testChatGPTCatalogUsesAccountSlugsAndDisplayNames() {
        let models = ChatGPTSignIn.catalog(from: [
            "models": [
                ["slug": "gpt-5.5", "display_name": "GPT-5.5", "visibility": "list"],
                ["slug": "hidden", "display_name": "Hidden", "visibility": "hidden"]
            ]
        ])
        XCTAssertEqual(models.map(\.id), ["gpt-5.5"])
        XCTAssertEqual(models.map(\.displayName), ["GPT-5.5"])
    }

    func testCommitTipReadsGitHubAndGitLabShapes() throws {
        let github = try JSONSerialization.data(withJSONObject: [["sha": "deadbeef"]])
        XCTAssertEqual(ManagedCloneService.tipSHA(from: github), "deadbeef")
        let gitlab = try JSONSerialization.data(withJSONObject: [["id": "cafebabe"]])
        XCTAssertEqual(ManagedCloneService.tipSHA(from: gitlab), "cafebabe")
        XCTAssertNil(ManagedCloneService.tipSHA(from: Data("[]".utf8)))
    }

    func testManagedCloneIsCurrentWhenTipMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stored = try JSONSerialization.data(withJSONObject: [["sha": "abc123", "message": "tip"]])
        try stored.write(to: root.appendingPathComponent(".slate-commits.json"))
        let fetched = try JSONSerialization.data(withJSONObject: [["sha": "abc123"]])
        XCTAssertTrue(ManagedCloneService.isCurrent(at: root, commits: fetched))
        let other = try JSONSerialization.data(withJSONObject: [["sha": "def456"]])
        XCTAssertFalse(ManagedCloneService.isCurrent(at: root, commits: other))
    }

    @MainActor
    func testGatewayPreparesRootsOnlyForProjectTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "ok\n".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        var prepared = 0
        let gateway = SlateToolGateway(
            includeSlateTools: false,
            prepareRoots: {
                prepared += 1
                return [.init(title: "Fixture", path: root.path)]
            }
        )
        let tools = try await gateway.definitions()
        XCTAssertEqual(prepared, 0)
        XCTAssertTrue(tools.contains { $0["name"] as? String == "project_list_files" })
        let listed = try await gateway.execute(name: "project_list_files", arguments: [:])
        XCTAssertTrue(listed.contains("A.swift"))
        XCTAssertEqual(prepared, 1)
        _ = try await gateway.execute(name: "project_list_files", arguments: [:])
        XCTAssertEqual(prepared, 1)
    }

    @MainActor
    func testLocalRootsSkipRemoteAttachments() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        container.mainContext.insert(project)
        container.mainContext.insert(CodeAttachment(
            kind: .github,
            title: "repo",
            locator: "owner/repo",
            defaultBranch: "main",
            project: project
        ))
        try container.mainContext.save()
        XCTAssertTrue(ProjectCodeWorkspace.localRoots(for: project).isEmpty)
    }

    @MainActor
    func testManagedCloneDiagnostic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "Clone", symbol: "folder", summary: "")
        let attachment = CodeAttachment(
            kind: .github,
            title: "slate",
            locator: "ethanfox/slate",
            defaultBranch: "main",
            project: project
        )
        let snapshot = RemoteSnapshot(
            attachment: attachment,
            projectID: project.id,
            storeURL: root.appendingPathComponent("default.store")
        )
        let cloned = try await ManagedCloneService.prepare(snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloned.appendingPathComponent(".slate-snapshot").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloned.appendingPathComponent(".slate-commits.json").path))
    }

    func testUserBubbleWrapCapIgnoresInfiniteProposal() {
        XCTAssertEqual(ChatSelectableTextView.wrapWidth(proposed: .greatestFiniteMagnitude, cap: 456), 456)
        XCTAssertEqual(ChatSelectableTextView.wrapWidth(proposed: 900, cap: 456), 456)
        XCTAssertEqual(ChatSelectableTextView.wrapWidth(proposed: 300, cap: 456), 300)
        XCTAssertEqual(ChatSelectableTextView.wrapWidth(proposed: nil, cap: nil), 456)
    }

    func testChatMarkdownRendersTableCells() {
        let markdown = """
        | Target | What it is |
        | --- | --- |
        | PersonalContext | The Mac app. |
        """
        let text = ChatMarkdown.attributed(markdown).string
        XCTAssertTrue(text.contains("Target"))
        XCTAssertTrue(text.contains("What it is"))
        XCTAssertTrue(text.contains("PersonalContext"))
        XCTAssertFalse(text.contains("|---"))
    }
}
