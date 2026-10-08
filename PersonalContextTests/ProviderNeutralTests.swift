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
