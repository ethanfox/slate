import SwiftData
import XCTest
@testable import Membrae

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
        let first = bridge.prompt("hi", applyingTo: conversation)
        XCTAssertTrue(first.contains("You are the assistant inside Membrae"))
        XCTAssertTrue(first.contains(ContextBuilder.replyFirst))
        XCTAssertTrue(first.contains(ContextBuilder.responseStyle))
        XCTAssertTrue(first.contains("Do not walk the whole project"))
        XCTAssertTrue(first.contains("Harbor"))
        XCTAssertTrue(first.contains("<project-context>"))
        XCTAssertFalse(first.contains("Active decisions"))
        XCTAssertFalse(first.contains("Ship the Mac app in Swift"))

        let later = bridge.prompt("again", applyingTo: conversation)
        XCTAssertFalse(later.contains("You are the assistant inside Membrae"))
        XCTAssertTrue(later.contains(ContextBuilder.replyFirst))
        XCTAssertTrue(later.contains(ContextBuilder.responseStyle))
        XCTAssertTrue(later.contains("Harbor"))
        XCTAssertFalse(later.contains("Active decisions"))
        XCTAssertFalse(later.contains("Ship the Mac app in Swift"))
        XCTAssertFalse(first.contains("Notes are specs and facts"))
        XCTAssertTrue(first.contains("track bodies"))
    }

    @MainActor
    func testChatWithNoProjectGetsTheMapAndFilingRules() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let context = container.mainContext
        let project = Project(name: "Harbor", symbol: "folder", summary: "A marina app.")
        let finished = Project(name: "Old site", symbol: "folder", summary: "Shipped.")
        finished.status = .done
        context.insert(project)
        context.insert(finished)
        let space = try SpaceStore.create(named: "Kitchen", summary: "Recipes and what got cooked.", in: context)
        context.insert(SpaceType(spaceID: space.id, key: "recipe", name: "Recipe", role: .object, schema: SpaceSchema(), origin: .agent))
        context.insert(SpaceType(spaceID: space.id, key: "cooked", name: "Cooked", role: .event, schema: SpaceSchema(), origin: .agent))
        let loose = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test")
        let inSpace = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test")
        inSpace.spaceIDString = SpaceJSON.key(space.id)
        let inProject = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test", project: project)
        context.insert(loose)
        context.insert(inSpace)
        context.insert(inProject)
        try context.save()

        let prompt = ChatWorkspace(conversation: loose, project: nil, debugLog: ChatDebugLog())
            .prepareTurn(userText: "save this chili recipe").prompt
        XCTAssertTrue(prompt.contains(ContextBuilder.routingRules))
        XCTAssertTrue(prompt.contains("- Harbor (id \(project.id.uuidString)): A marina app."))
        XCTAssertFalse(prompt.contains("Old site"))
        XCTAssertTrue(prompt.contains("- Kitchen (id \(space.id.uuidString)): Recipes and what got cooked. Holds: Recipe (recipe). Logs: Cooked (cooked)."))
        XCTAssertFalse(prompt.contains("The user is looking at the Space"))

        let spacePrompt = ChatWorkspace(conversation: inSpace, project: nil, debugLog: ChatDebugLog())
            .prepareTurn(userText: "made this tonight").prompt
        XCTAssertTrue(spacePrompt.contains("The user is looking at the Space Kitchen (id \(space.id.uuidString))"))

        let projectPrompt = ChatWorkspace(conversation: inProject, project: project, debugLog: ChatDebugLog())
            .prepareTurn(userText: "hi").prompt
        XCTAssertFalse(projectPrompt.contains("<map>"))
        XCTAssertFalse(projectPrompt.contains(ContextBuilder.routingRules))
    }

    func testShortRepliesStayAsBubblesAndLongOnesNeedTheChatView() {
        XCTAssertFalse(QuickReplyRule.needsChatView("Saved the chili recipe to Kitchen."))
        XCTAssertFalse(QuickReplyRule.needsChatView("It is due Friday.\n\n[Ship sign-in](membrae://task/\(UUID().uuidString))"))
        XCTAssertFalse(QuickReplyRule.needsChatView("Two options:\n- Keep it\n- Drop it"))
        XCTAssertTrue(QuickReplyRule.needsChatView("## Plan\n\nFirst do this."))
        XCTAssertTrue(QuickReplyRule.needsChatView("Run this:\n\n```swift\nprint(1)\n```"))
        XCTAssertTrue(QuickReplyRule.needsChatView("| A | B |\n|---|---|\n| 1 | 2 |"))
        XCTAssertTrue(QuickReplyRule.needsChatView(String(repeating: "word ", count: 200)))
        XCTAssertTrue(QuickReplyRule.needsChatView((1...9).map { "Line \($0)" }.joined(separator: "\n")))
    }

    @MainActor
    func testWritesFromAChatAreLoggedAgainstThatChat() async throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let project = Project(name: "Harbor", symbol: "folder", summary: "A marina app.")
        container.mainContext.insert(project)
        try container.mainContext.save()
        let conversationID = UUID()
        let gateway = RunGateway(
            policy: .chat(projectID: nil),
            inner: MembraeToolGateway(
                includeProjectTools: false,
                mcp: MembraeMCPClient(command: nil),
                store: container,
                conversationID: conversationID
            ),
            includeFinishRun: false
        )
        let names = try await gateway.definitions().compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("create_note"))
        XCTAssertTrue(names.contains("create_space_record"))
        _ = try await gateway.execute(name: "create_note", arguments: [
            "project_id": project.id.uuidString,
            "title": "Dock fees",
            "content": "Slip fees went up in March."
        ])
        let action = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<AgentAction>()).first)
        XCTAssertEqual(UUID(uuidString: action.conversationIDString), conversationID)
        XCTAssertEqual(UUID(uuidString: action.projectIDString), project.id)
    }

    @MainActor
    func testPackageKeepsNoteTitlesAndTaskTracks() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let project = Project(name: "Harbor", symbol: "folder", summary: "A marina app.")
        let track = ProjectThread(title: "Auth", kind: .feature, project: project)
        track.summary = "Sign-in work"
        let note = Note(content: "Secret spec text that must not dump", project: project, title: "OAuth notes")
        let task = AgendaItem(kind: .task, eventKitID: "", title: "Ship sign-in")
        container.mainContext.insert(project)
        container.mainContext.insert(track)
        container.mainContext.insert(note)
        container.mainContext.insert(task)
        AssociationService.assignUserProject(project, on: task)
        AssociationService.applyLink(thread: track, onto: task)
        try container.mainContext.save()

        let text = ContextBuilder.package(for: project)
        XCTAssertTrue(text.contains("OAuth notes"))
        XCTAssertFalse(text.contains("Secret spec text that must not dump"))
        XCTAssertTrue(text.contains("Ship sign-in"))
        XCTAssertTrue(text.contains("tracks: Auth"))
    }

    @MainActor
    func testFocusedTrackContextIsCurrentEachTurn() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let project = Project(name: "Harbor", symbol: "folder", summary: "A marina app.")
        let child = ProjectThread(title: "Tokens", kind: .problem, project: project)
        child.summary = "Refresh is flaky"
        let track = ProjectThread(title: "Auth", kind: .feature, project: project)
        track.summary = "Users can sign in"
        track.body = "Use the existing session store.\nDo not invent a second token."
        child.parent = track
        let decision = Decision(
            title: "Keep the Mac session",
            decision: "Reuse ChatGPTSignIn, do not mint Membrae tokens.",
            project: project,
            thread: track
        )
        let task = AgendaItem(kind: .task, eventKitID: "", title: "Wire refresh")
        let conversation = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test", project: project)
        conversation.thread = track
        container.mainContext.insert(project)
        container.mainContext.insert(track)
        container.mainContext.insert(child)
        container.mainContext.insert(decision)
        container.mainContext.insert(task)
        container.mainContext.insert(conversation)
        AssociationService.assignUserProject(project, on: task)
        AssociationService.applyLink(thread: child, onto: task)
        try container.mainContext.save()

        let bridge = CursorConversationBridge(conversation: conversation, project: project)
        let first = bridge.prompt("hi", applyingTo: conversation)
        XCTAssertTrue(first.contains("You are the assistant inside Membrae"))
        XCTAssertTrue(first.contains("<focused-track>"))
        XCTAssertTrue(first.contains("append_to_body"))
        XCTAssertTrue(first.contains("keeping existing requirements"))
        XCTAssertTrue(first.contains("Use the existing session store."))
        XCTAssertTrue(first.contains("Keep the Mac session"))
        XCTAssertTrue(first.contains("Wire refresh"))
        XCTAssertTrue(first.contains("Tokens"))
        XCTAssertFalse(first.contains("Notes are specs and facts"))

        let later = bridge.prompt("again", applyingTo: conversation)
        XCTAssertFalse(later.contains("You are the assistant inside Membrae"))
        XCTAssertTrue(later.contains("<focused-track>"))
        XCTAssertTrue(later.contains("Do not invent a second token."))
        XCTAssertTrue(later.contains("Wire refresh"))
    }

    @MainActor
    func testFocusedTrackBodyChangeAppearsOnNextTurn() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        let conversation = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test", project: seed.project)
        conversation.thread = seed.auth
        container.mainContext.insert(conversation)
        try container.mainContext.save()

        let bridge = CursorConversationBridge(conversation: conversation, project: seed.project)
        let first = bridge.prompt("What are the requirements?")
        XCTAssertTrue(first.contains(HarborEvalFixture.authBody))
        XCTAssertFalse(first.contains("Sign-in must work offline."))

        seed.auth.body = HarborEvalFixture.authBodyWithOffline
        try container.mainContext.save()

        let later = bridge.prompt("What are the requirements now?")
        XCTAssertTrue(later.contains("Sign-in must work offline."))
        XCTAssertTrue(later.contains("local session store"))
    }

    @MainActor
    func testFocusedContextExcludesUnrelatedTracksAndNoteBodies() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        let conversation = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test", project: seed.project)
        conversation.thread = seed.auth
        container.mainContext.insert(conversation)
        try container.mainContext.save()

        let text = CursorConversationBridge(conversation: conversation, project: seed.project)
            .prompt("What's left?")
        XCTAssertTrue(text.contains("<focused-track>"))
        XCTAssertTrue(text.contains("Auth"))
        XCTAssertTrue(text.contains("Tokens"))
        XCTAssertFalse(text.contains("Billing"))
        XCTAssertFalse(text.contains(HarborEvalFixture.vendorTail))
        XCTAssertFalse(text.contains(HarborEvalFixture.billingSentinel))
        XCTAssertFalse(text.contains("Retry invoice webhooks"))
    }

    @MainActor
    func testFocusedContextShowsDescendantTaskStatusOnNextTurn() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        let conversation = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test", project: seed.project)
        conversation.thread = seed.auth
        container.mainContext.insert(conversation)
        try container.mainContext.save()

        let bridge = CursorConversationBridge(conversation: conversation, project: seed.project)
        let refresh = seed.fixRefresh.id.uuidString
        let first = bridge.prompt("What's left?")
        XCTAssertTrue(first.contains("Fix refresh after wake (id \(refresh), blocked)"))

        TaskStore.setStatus(.ready, on: seed.fixRefresh, in: container.mainContext)
        try container.mainContext.save()

        let later = bridge.prompt("And now?")
        XCTAssertTrue(later.contains("Fix refresh after wake (id \(refresh), ready)"))
        XCTAssertFalse(later.contains("Fix refresh after wake (id \(refresh), blocked)"))
    }

    func testOpeningPromptIncludesPriorTurns() {
        let history = [
            TalkMessage(role: .user, text: "What is a Space?"),
            TalkMessage(role: .assistant, text: "A Space is a home for one life area."),
            TalkMessage(role: .user, text: "Lock that.")
        ]
        let transcript = TalkMessage.conversationTranscript(history)
        let opening = ContextBuilder.prompt(
            userText: "Lock that.",
            context: "",
            opening: true,
            transcript: transcript
        )
        XCTAssertTrue(opening.contains("<conversation>"))
        XCTAssertTrue(opening.contains("User: What is a Space?"))
        XCTAssertTrue(opening.contains("Assistant: A Space is a home for one life area."))
        XCTAssertTrue(opening.contains("Lock that."))

        let resumed = ContextBuilder.prompt(
            userText: "Lock that.",
            context: "",
            opening: false,
            transcript: transcript
        )
        XCTAssertFalse(resumed.contains("<conversation>"))
    }

    @MainActor
    func testTrackFirstRulesRemainAfterOpeningTurn() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let seed = HarborEvalFixture.seed(in: container.mainContext)
        let conversation = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test", project: seed.project)
        conversation.thread = seed.auth
        container.mainContext.insert(conversation)
        try container.mainContext.save()

        let bridge = CursorConversationBridge(conversation: conversation, project: seed.project)
        let first = bridge.prompt("hi", applyingTo: conversation)
        XCTAssertTrue(first.contains(ContextBuilder.knowledgeRules))
        XCTAssertTrue(first.contains(ContextBuilder.replyFirst))
        XCTAssertTrue(first.contains(ContextBuilder.responseStyle))
        XCTAssertTrue(first.contains("You are the assistant inside Membrae"))

        let later = bridge.prompt("again", applyingTo: conversation)
        XCTAssertFalse(later.contains("You are the assistant inside Membrae"))
        XCTAssertTrue(later.contains(ContextBuilder.replyFirst))
        XCTAssertTrue(later.contains(ContextBuilder.responseStyle))
        XCTAssertTrue(later.contains(ContextBuilder.knowledgeRules))
        XCTAssertTrue(later.contains("track bodies"))
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
        let attachment = project.codeAttachments[0]
        let text = ContextBuilder.identity(for: project)
        XCTAssertTrue(text.contains("owner/repo"))
        XCTAssertTrue(text.contains(attachment.id.uuidString))
        XCTAssertTrue(text.contains("list_code_references"))
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
        let provider = ChatProviderFactory.make(
            conversation: conversation,
            project: project,
            debugLog: ChatDebugLog()
        )
        XCTAssertTrue(provider is ChatGPTProvider)
        XCTAssertEqual(provider.id, TalkProvider.chatgpt.rawValue)
    }

    @MainActor
    /// Projects no longer choose a worker, so a stored one is ignored.
    func testStoredProjectWorkerIsIgnored() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        project.workerProviderID = TalkProvider.cursor.rawValue
        container.mainContext.insert(project)
        try container.mainContext.save()
        XCTAssertFalse(ContextBuilder.identity(for: project).contains("consult_code"))
        XCTAssertFalse(ProjectWorker.isConfigured(on: project))
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
            includeMembraeTools: true,
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

    func testMembraeMCPClientCachesToolList() async throws {
        let client = MembraeMCPClient(command: nil)
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
    func testGatewayUsesCachedMembraeTools() async throws {
        let client = MembraeMCPClient(command: nil)
        await client.useListProvider {
            [["name": "get_note", "description": "Read a note.", "inputSchema": ["type": "object"]]]
        }
        let gateway = MembraeToolGateway(
            includeMembraeTools: true,
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
        let gateway = MembraeToolGateway(
            includeMembraeTools: false,
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
        XCTAssertTrue(root.matches("/tmp/repo"))
        XCTAssertEqual(ProjectCodeRoot.resolve([root], requested: "Harbor").map(\.title), ["owner/repo"])
        XCTAssertEqual(ProjectCodeRoot.resolve([root], requested: "/tmp/repo").map(\.path), ["/tmp/repo"])
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

        let gateway = MembraeToolGateway(
            roots: [.init(title: "Fixture", path: root.path)],
            includeMembraeTools: false
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
        XCTAssertTrue(read.hasPrefix("content_hash sha256:"), read)
        XCTAssertTrue(read.contains("1: let answer = 42"), read)

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
            instructions: "Use Membrae tools.",
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
            instructions: "Use Membrae tools.",
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
            "This ChatGPT model or account can’t use that attachment. The draft is still here—remove the file or pick another model."
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
        XCTAssertNil(models.first?.endpointImage)
        XCTAssertNil(models.first?.endpointDocument)
    }

    func testChatGPTCatalogReadsEndpointModalitiesWhenPresent() {
        let models = ChatGPTSignIn.catalog(from: [
            "models": [
                [
                    "slug": "research",
                    "display_name": "Research",
                    "visibility": "list",
                    "input_modalities": ["text", "image", "file"],
                ]
            ]
        ])
        XCTAssertEqual(models.first?.endpointImage, .supported)
        XCTAssertEqual(models.first?.endpointDocument, .supported)
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
        try stored.write(to: root.appendingPathComponent(".membrae-commits.json"))
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
        let gateway = MembraeToolGateway(
            includeMembraeTools: false,
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
        XCTAssertEqual(prepared, 2)
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
            title: "membrae",
            locator: "ethanfox/membrae",
            defaultBranch: "main",
            project: project
        )
        let snapshot = RemoteSnapshot(
            attachment: attachment,
            projectID: project.id,
            storeURL: root.appendingPathComponent("default.store")
        )
        let cloned = try await ManagedCloneService.prepare(snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloned.appendingPathComponent(".membrae-snapshot").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloned.appendingPathComponent(".membrae-commits.json").path))
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

    func testToolActivityNamesAReadFile() {
        XCTAssertEqual(ChatToolActivity.title(for: "project_read_file", status: .succeeded), "Read file")
        XCTAssertEqual(
            ChatToolActivity.detail(for: "project_read_file", arguments: [
                "root": "PC-OS",
                "path": "PersonalContext/Services/ContextBuilder.swift",
                "start_line": 48,
                "end_line": 80
            ]),
            "PC-OS · PersonalContext/Services/ContextBuilder.swift · 48–80"
        )
    }

    func testToolActivityNamesACodeSearch() {
        XCTAssertEqual(ChatToolActivity.title(for: "project_search_code", status: .succeeded), "Searched code")
        XCTAssertEqual(
            ChatToolActivity.detail(for: "project_search_code", arguments: ["query": "ChatToolActivity"]),
            "ChatToolActivity"
        )
    }

    func testToolActivitySummarizesListedFiles() {
        XCTAssertEqual(ChatToolActivity.title(for: "project_list_files", status: .succeeded), "Listed files")
        XCTAssertEqual(
            ChatToolActivity.detail(
                for: "project_list_files",
                result: #"[{"root":"PC-OS","path":"A.swift"},{"root":"PC-OS","path":"B.swift"}]"#
            ),
            "PC-OS · 2 files"
        )
        XCTAssertEqual(
            ChatToolActivity.detail(for: "project_list_files", arguments: ["query": "ChatMessages"]),
            "ChatMessages"
        )
    }

    func testToolActivityNamesABrowserPage() {
        XCTAssertEqual(ChatToolActivity.title(for: "browser_navigate", status: .running), "Opening a page")
        XCTAssertEqual(
            ChatToolActivity.detail(for: "browser_navigate", arguments: ["url": "https://docs.example.com/guide"]),
            "https://docs.example.com/guide"
        )
        XCTAssertEqual(
            ChatToolActivity.detail(
                for: "browser_snapshot",
                result: "Page URL: https://wiki.example.com/Home\nPage Title: Home"
            ),
            "https://wiki.example.com/Home"
        )
        let tool = ChatToolActivity(
            id: "1",
            name: "browser_navigate",
            status: .succeeded,
            detail: "https://www.docs.example.com/guide/"
        )
        XCTAssertEqual(tool.displayTitle, "docs.example.com/guide")
        XCTAssertEqual(tool.pageURL?.host(), "www.docs.example.com")
        XCTAssertEqual(tool.destination()?.kind, .url)
    }

    func testToolActivityNamesAWebSearchQuery() {
        XCTAssertEqual(
            ChatToolActivity.detail(for: "browser_search", arguments: ["query": "swift concurrency"]),
            "swift concurrency"
        )
        let tool = ChatToolActivity(
            id: "1",
            name: "browser_search",
            status: .succeeded,
            detail: "swift concurrency"
        )
        XCTAssertNil(tool.pageURL)
        XCTAssertEqual(tool.displayTitle, "Searched the web")
        XCTAssertTrue(tool.showsDetail)
    }

    func testToolActivityNamesALiveList() {
        XCTAssertEqual(ChatToolActivity.title(for: "list_tracks", status: .running), "Listing Tracks")
        XCTAssertEqual(ChatToolActivity.title(for: "list_tracks", status: .succeeded), "Listed Tracks")
    }

    func testToolActivityNamesCreatedAndUpdatedRecords() {
        XCTAssertEqual(ChatToolActivity.title(for: "create_track", status: .succeeded), "Added Track")
        XCTAssertEqual(ChatToolActivity.detail(for: "create_track", arguments: ["title": "Auth"]), "Auth")
        XCTAssertEqual(ChatToolActivity.detail(for: "create_task", arguments: ["title": "Ship sign-in"]), "Ship sign-in")
        XCTAssertEqual(
            ChatToolActivity.detail(for: "create_note", arguments: ["content": "Findings from the Harbor sign-in pass."]),
            "Findings from the Harbor sign-in pass."
        )
        let id = UUID().uuidString
        XCTAssertEqual(ChatToolActivity.detail(for: "update_track", arguments: ["track_id": id]), "")
        XCTAssertEqual(
            ChatToolActivity.detail(
                for: "update_track",
                arguments: ["track_id": id],
                result: #"{"id":"\#(id)","title":"Auth"}"#
            ),
            "Auth"
        )
    }

    func testPackDoesNotStripExistingWork() {
        let work = ChatWork(
            seconds: 4,
            thinking: "",
            tools: [ChatToolActivity(id: "1", name: "list_tracks", status: .succeeded)]
        )
        let packed = ChatTranscript.pack(text: "Hello", sources: [], work: work)
        XCTAssertNotNil(ChatTranscript.unpack(packed).work)
        XCTAssertEqual(ChatTranscript.unpack(packed).work?.tools.map(\.name), ["list_tracks"])

        let again = ChatTranscript.pack(text: packed, sources: [], work: ChatWork(seconds: 0, thinking: "", tools: []))
        XCTAssertEqual(ChatTranscript.unpack(again).work?.tools.map(\.name), ["list_tracks"])
        XCTAssertEqual(ChatTranscript.unpack(again).text, "Hello")
    }

    func testApplyToolKeepsEarlierCalls() {
        var turn = ChatTurnState()
        turn.begin(userID: nil)
        turn.applyTool(name: "list_tracks", status: "running", id: "a")
        turn.applyTool(name: "list_tracks", status: "completed", id: "a")
        turn.applyTool(name: "get_project", status: "running", id: "b")
        turn.applyTool(name: "get_project", status: "completed", id: "b")
        XCTAssertEqual(turn.tools.map(\.name), ["list_tracks", "get_project"])

        turn.applyTool(name: "list_tracks", status: "running", id: "")
        turn.applyTool(name: "list_tracks", status: "completed", id: "")
        turn.applyTool(name: "get_note", status: "running", id: "")
        XCTAssertEqual(turn.tools.map(\.name), ["list_tracks", "get_project", "list_tracks", "get_note"])
    }

    @MainActor
    func testPrepareProviderTurnDoesNotWriteConversation() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Store.schema, configurations: configuration)
        let project = Project(name: "Harbor", symbol: "folder", summary: "A marina app.")
        let conversation = Conversation(providerID: TalkProvider.chatgpt.rawValue, modelID: "gpt-test", project: project)
        container.mainContext.insert(project)
        container.mainContext.insert(conversation)
        try container.mainContext.save()

        let prepared = CursorConversationBridge(conversation: conversation, project: project)
            .prepareProviderTurn(userText: "hello there")
        XCTAssertEqual(conversation.title, "New chat")
        XCTAssertTrue(conversation.contextSnapshot.isEmpty)
        XCTAssertEqual(prepared.metadata.title, conversationTitle(from: "hello there"))
        XCTAssertEqual(prepared.metadata.contextSnapshot, ContextBuilder.identity(for: project))
    }
}

private extension CursorConversationBridge {
    func prompt(_ userText: String, applyingTo conversation: Conversation? = nil) -> String {
        let prepared = prepareProviderTurn(userText: userText)
        if let conversation {
            if let title = prepared.metadata.title { conversation.title = title }
            if let snapshot = prepared.metadata.contextSnapshot { conversation.contextSnapshot = snapshot }
        }
        return prepared.prompt
    }
}
