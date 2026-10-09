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
    func testProviderTurnIsIdentityOnly() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let project = Project(name: "Harbor", symbol: "folder", summary: "A marina app.")
        let conversation = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test", project: project)
        container.mainContext.insert(project)
        container.mainContext.insert(conversation)
        container.mainContext.insert(Decision(
            title: "Use Swift",
            decision: "Ship the Mac app in Swift, not Electron.",
            project: project
        ))
        try container.mainContext.save()

        let bridge = CursorConversationBridge(conversation: conversation, project: project)
        let first = bridge.prepareProviderTurn(userText: "hi")
        XCTAssertTrue(first.contains("You are the assistant inside Slate"))
        XCTAssertTrue(first.contains("Do not walk the whole project"))
        XCTAssertTrue(first.contains("Harbor"))
        XCTAssertTrue(first.contains("<project-context>"))
        XCTAssertFalse(first.contains("Active decisions"))
        XCTAssertFalse(first.contains("Ship the Mac app in Swift"))

        let later = bridge.prepareProviderTurn(userText: "again")
        XCTAssertFalse(later.contains("You are the assistant inside Slate"))
        XCTAssertTrue(later.contains("Harbor"))
        XCTAssertFalse(later.contains("Active decisions"))
        XCTAssertFalse(later.contains("Ship the Mac app in Swift"))
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
        XCTAssertFalse(ProjectWorker.isConfigured(on: project))
    }

    @MainActor
    func testChatUsesPickedProviderWhenWorkerIsSet() {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        project.workerProviderID = TalkProvider.cursor.rawValue
        let conversation = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test")
        conversation.project = project
        let bridge = CursorConversationBridge(conversation: conversation, project: project)
        let provider = ChatRuntime.makeChatProvider(bridge: bridge, conversation: conversation)
        XCTAssertTrue(provider is ChatGPTProvider)
        XCTAssertEqual(provider.id, TalkProvider.chatgpt.rawValue)
    }

    @MainActor
    func testIdentityMentionsConsultCodeWhenWorkerIsSet() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        project.workerProviderID = TalkProvider.cursor.rawValue
        container.mainContext.insert(project)
        try container.mainContext.save()
        let text = ContextBuilder.identity(for: project)
        XCTAssertTrue(text.contains("consult_code"))
        XCTAssertFalse(ContextBuilder.identity(for: Project(name: "Bare", symbol: "folder", summary: "")).contains("consult_code"))
    }

    func testRunnerReuseKeyIgnoresPromptText() {
        let left = RunnerRequest(
            apiKey: "k",
            env: [:],
            name: "Chat",
            text: "hi",
            model: "auto",
            cwd: "/tmp",
            mcpCommand: "/mcp",
            codeRoots: [],
            includeSlateTools: true,
            includeProjectTools: true,
            runtime: "local",
            cloudRepos: []
        )
        var right = left
        right.text = "later"
        right.agentId = "agent-1"
        XCTAssertEqual(left.reuseKey, right.reuseKey)
        right.model = "other"
        XCTAssertNotEqual(left.reuseKey, right.reuseKey)
    }

    func testSlateMCPClientCachesToolList() async throws {
        let client = SlateMCPClient(command: nil)
        await client.useListProvider {
            [["name": "get_note", "description": "Read a note.", "inputSchema": ["type": "object"]]]
        }
        let first = try await client.toolDefinitions()
        let second = try await client.toolDefinitions()
        XCTAssertEqual(first.first?["name"] as? String, "get_note")
        XCTAssertEqual(second.first?["name"] as? String, "get_note")
        let calls = await client.listCalls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testGatewayUsesCachedSlateTools() async throws {
        let client = SlateMCPClient(command: nil)
        await client.useListProvider {
            [["name": "get_note", "description": "Read a note.", "inputSchema": ["type": "object"]]]
        }
        let gateway = SlateToolGateway(
            includeSlateTools: true,
            includeProjectTools: false,
            mcp: client
        )
        let tools = try await gateway.definitions()
        XCTAssertTrue(tools.contains { $0["name"] as? String == "get_note" })
        _ = try await gateway.definitions()
        let calls = await client.listCalls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testGatewayConsultCodeIsOnDemand() async throws {
        var briefs: [String] = []
        let gateway = SlateToolGateway(
            includeSlateTools: false,
            includeProjectTools: false,
            consult: { brief in
                briefs.append(brief)
                return "found \(brief)"
            }
        )
        let tools = try await gateway.definitions()
        XCTAssertTrue(tools.contains { $0["name"] as? String == "consult_code" })
        XCTAssertTrue(briefs.isEmpty)
        let result = try await gateway.execute(name: "consult_code", arguments: ["brief": "auth flow"])
        XCTAssertEqual(result, "found auth flow")
        XCTAssertEqual(briefs, ["auth flow"])
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

        XCTAssertEqual(ChatGPTProvider.toolsForRound(0, tools: [["name": "list_projects"]]).count, 1)
        XCTAssertEqual(ChatGPTProvider.toolsForRound(ChatGPTProvider.maxToolRounds - 1, tools: [["name": "list_projects"]]).count, 1)
        XCTAssertTrue(ChatGPTProvider.toolsForRound(ChatGPTProvider.maxToolRounds, tools: [["name": "list_projects"]]).isEmpty)

        let forced = ChatGPTProvider.inferenceBody(
            model: "gpt-5.5",
            instructions: "Use Slate tools.",
            input: [["role": "user", "content": ChatGPTProvider.answerNowMessage]],
            tools: []
        )
        XCTAssertNil(forced["tools"])
        XCTAssertNil(forced["tool_choice"])
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

    func testChatGPTTokenExpiryUsesJWTAndRetriesExpiredAuth() {
        let exp = Date().addingTimeInterval(30).timeIntervalSince1970
        let payload = Data("{\"exp\":\(Int(exp))}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJub25lIn0.\(payload).sig"
        var session = ChatGPTSession(
            email: "a@b.c",
            subject: "sub",
            clientID: "client",
            hostID: "host",
            idToken: "id",
            accessToken: token,
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600),
            scopes: ["chatgpt.tokens.use.direct"],
            usingPlan: true
        )
        XCTAssertEqual(ChatGPTSignIn.jwtExpiration(token)?.timeIntervalSince1970 ?? 0, exp, accuracy: 1)
        XCTAssertLessThan(ChatGPTSignIn.remainingLifetime(session), 60)
        XCTAssertTrue(ChatGPTSignIn.needsRefresh(session))

        session.accessToken = "opaque"
        session.expiresAt = Date().addingTimeInterval(3600)
        XCTAssertFalse(ChatGPTSignIn.needsRefresh(session))
        XCTAssertTrue(ChatGPTSignIn.needsRefresh(session, refreshing: "opaque"))
        XCTAssertFalse(ChatGPTSignIn.needsRefresh(session, refreshing: "other"))

        XCTAssertTrue(ChatGPTSignIn.isExpiredTokenError(status: 401, detail: nil))
        XCTAssertTrue(ChatGPTSignIn.isExpiredTokenError(
            status: 403,
            detail: "Provided authentication token is expired. Please try signing in again. token_expired"
        ))
        XCTAssertFalse(ChatGPTSignIn.isExpiredTokenError(status: 400, detail: "Unsupported parameter: store"))
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

    func testStreamPaceSummarySeparatesWaitFromPaint() {
        var pace = StreamPace(startedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(pace.summary(now: Date(timeIntervalSince1970: 101.5)).contains("waiting 1.50s"))

        pace.markPrepared(at: Date(timeIntervalSince1970: 100.4))
        pace.inbound(40, at: Date(timeIntervalSince1970: 101.2))
        pace.inbound(40, at: Date(timeIntervalSince1970: 102.2))
        pace.painted(80, applyMs: 3, at: Date(timeIntervalSince1970: 102.21))

        let summary = pace.summary()
        XCTAssertTrue(summary.contains("first token 1.20s"))
        XCTAssertTrue(summary.contains("prepare 0.40s"))
        XCTAssertTrue(summary.contains("in  80 ch/s"))
        XCTAssertTrue(summary.contains("hold 10ms"))
        XCTAssertTrue(summary.contains("apply 3ms"))
    }

    func testStreamTextCoalescerFlushesOnInterval() {
        var coalescer = StreamTextCoalescer(interval: 0.04)
        XCTAssertEqual(coalescer.push("Hel"), "Hel")
        XCTAssertNil(coalescer.push("lo"))
        XCTAssertEqual(coalescer.take(), "lo")
    }

    func testMarkdownIncompleteStartIsLastLineOrOpenFence() {
        let line = "Hello world"
        XCTAssertEqual(ChatMarkdown.incompleteStart(in: line), line.startIndex)

        let partial = "Hello\nwor"
        XCTAssertEqual(String(partial[ChatMarkdown.incompleteStart(in: partial)...]), "wor")

        let fence = "```swift\nlet x = 1"
        XCTAssertEqual(String(fence[ChatMarkdown.incompleteStart(in: fence)...]), fence)

        let closed = "```swift\nlet x = 1\n```\nNext"
        XCTAssertEqual(String(closed[ChatMarkdown.incompleteStart(in: closed)...]), "Next")
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

    func testChatMarkdownCollapsesBlankLinesToParagraphSpacing() {
        let paragraphs = ChatMarkdown.attributed("One\n\n\nTwo")
        XCTAssertEqual(paragraphs.string, "One\nTwo")
        let breakRange = (paragraphs.string as NSString).range(of: "\n")
        let style = paragraphs.attribute(.paragraphStyle, at: breakRange.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.paragraphSpacing, 8)

        let tight = ChatMarkdown.attributed("- a\n- b")
        let tightBreak = (tight.string as NSString).range(of: "\n")
        let tightStyle = tight.attribute(.paragraphStyle, at: tightBreak.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(tightStyle?.paragraphSpacing, 4)

        let fenced = ChatMarkdown.attributed("```\nline\n\nline\n```")
        XCTAssertTrue(fenced.string.contains("line\n\nline"))
        XCTAssertFalse(fenced.string.contains("```"))
        let fenceStyle = fenced.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertFalse(fenceStyle?.textBlocks.isEmpty ?? true)
        let fenceFont = fenced.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(fenceFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    func testChatMarkdownRendersInlineCode() {
        let rendered = ChatMarkdown.attributed("Use `this` here")
        let inner = (rendered.string as NSString).range(of: "this")
        XCTAssertNotEqual(inner.location, NSNotFound)
        let font = rendered.attribute(.font, at: inner.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertNotNil(rendered.attribute(.backgroundColor, at: inner.location, effectiveRange: nil))
        XCTAssertFalse(rendered.string.contains("`"))
    }
}
