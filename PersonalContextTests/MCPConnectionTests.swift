import XCTest
@testable import Membrae

@MainActor
final class MCPConnectionTests: XCTestCase {
    private var directory: URL!
    private var store: MCPConnectionStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MCPConnectionStore(url: directory.appendingPathComponent("mcp-connections.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPaperJSONImportIsExactAndIdempotent() throws {
        let json = """
        {
          "mcpServers": {
            "paper": {
              "type": "stdio",
              "command": "/Users/ethanfox/.paper/bin/paper",
              "args": ["mcp"]
            }
          }
        }
        """
        let first = try store.importJSON(json, replace: false)
        XCTAssertEqual(first.added.count, 1)
        XCTAssertEqual(first.unchanged.count, 0)
        let paper = try XCTUnwrap(store.connection(named: "paper"))
        XCTAssertEqual(paper.transport, .stdio)
        XCTAssertEqual(paper.command, "/Users/ethanfox/.paper/bin/paper")
        XCTAssertEqual(paper.arguments, ["mcp"])
        XCTAssertTrue(paper.enabled)
        XCTAssertTrue(store.authorizedConnections(for: UUID()).isEmpty)

        let second = try store.importJSON(json, replace: false)
        XCTAssertTrue(second.added.isEmpty)
        XCTAssertEqual(second.unchanged.count, 1)
        XCTAssertEqual(store.connections.count, 1)
    }

    func testImportConflictRequiresReplace() throws {
        let original = """
        {"mcpServers":{"paper":{"command":"/usr/bin/old","args":["mcp"]}}}
        """
        _ = try store.importJSON(original, replace: false)
        let changed = """
        {"mcpServers":{"paper":{"command":"/usr/bin/new","args":["mcp"]}}}
        """
        let conflict = try store.importJSON(changed, replace: false)
        XCTAssertEqual(conflict.conflicts, ["paper"])
        XCTAssertEqual(store.connection(named: "paper")?.command, "/usr/bin/old")

        let replaced = try store.importJSON(changed, replace: true)
        XCTAssertEqual(replaced.updated.count, 1)
        XCTAssertEqual(store.connection(named: "paper")?.command, "/usr/bin/new")
    }

    func testImportSupportsMultipleServersAndHTTP() throws {
        let json = """
        {
          "mcpServers": {
            "paper": { "command": "/bin/paper", "args": ["mcp"] },
            "docs": { "type": "http", "url": "https://example.com/mcp" }
          }
        }
        """
        let result = try store.importJSON(json, replace: false)
        XCTAssertEqual(result.added.count, 2)
        XCTAssertEqual(store.connection(named: "docs")?.transport, .http)
        XCTAssertEqual(store.connection(named: "docs")?.url, "https://example.com/mcp")
    }

    func testExportRedactsSecrets() throws {
        var record = MCPConnectionRecord(name: "secure", transport: .http, url: "https://example.com/mcp", headerKeys: ["Authorization"])
        record = try store.save(record)
        try MCPSecrets.saveHeaders(connectionID: record.id, values: ["Authorization": "Bearer secret-token"])
        let export = try store.exportJSON()
        XCTAssertFalse(export.contains("secret-token"))
        XCTAssertTrue(export.contains("<redacted>"))
    }

    func testPersistenceSurvivesReload() throws {
        let saved = try store.save(MCPConnectionRecord(
            name: "paper",
            transport: .stdio,
            command: "/Users/ethanfox/.paper/bin/paper",
            arguments: ["mcp"]
        ))
        let projectID = UUID()
        store.setAllowed(saved.id, in: projectID, allowed: true)

        let reloaded = MCPConnectionStore(url: storeURL)
        let paper = try XCTUnwrap(reloaded.connection(id: saved.id))
        XCTAssertEqual(paper.command, "/Users/ethanfox/.paper/bin/paper")
        XCTAssertEqual(paper.arguments, ["mcp"])
        XCTAssertTrue(reloaded.allows(saved.id, in: projectID))
    }

    func testProjectScopeBlocksDiscoveryAndCalls() async throws {
        let paper = try store.save(MCPConnectionRecord(name: "paper", transport: .stdio, command: "/bin/paper"))
        let other = try store.save(MCPConnectionRecord(name: "other", transport: .stdio, command: "/bin/other"))
        let projectID = UUID()
        store.setAllowed(paper.id, in: projectID, allowed: true)

        let session = FakeMCPSession(tools: [
            MCPDiscoveredTool(name: "get_guide", description: "Read a guide", inputSchema: [:], readOnlyHint: true, destructiveHint: false)
        ])
        let runtime = MCPRuntime(store: store, factory: FakeFactory(session: session))
        runtime.useAuthorizer { _, _, _ in true }

        let listed = await runtime.definitions(projectID: projectID)
        XCTAssertEqual(listed.map(\.originalName), ["get_guide"])
        XCTAssertTrue(listed.allSatisfy { $0.connectionID == paper.id })

        let unscoped = await runtime.definitions(projectID: nil)
        XCTAssertTrue(unscoped.isEmpty)

        let outsider = UUID()
        let hidden = await runtime.definitions(projectID: outsider)
        XCTAssertTrue(hidden.isEmpty)

        let namespaced = MCPToolName.namespaced(connectionID: paper.id, original: "get_guide")
        session.result = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": "ok"]]
        ])
        let output = try await runtime.execute(name: namespaced, arguments: [:], projectID: projectID)
        XCTAssertEqual(output, "ok")

        store.setAllowed(paper.id, in: projectID, allowed: false)
        do {
            _ = try await runtime.execute(name: namespaced, arguments: [:], projectID: projectID)
            XCTFail("revoked access should fail")
        } catch {}

        let otherName = MCPToolName.namespaced(connectionID: other.id, original: "get_guide")
        do {
            _ = try await runtime.execute(name: otherName, arguments: [:], projectID: projectID)
            XCTFail("other server should fail")
        } catch {}
    }

    func testTwoServersWithSameToolNameRouteSeparately() async throws {
        let paper = try store.save(MCPConnectionRecord(name: "paper", transport: .stdio, command: "/bin/paper"))
        let docs = try store.save(MCPConnectionRecord(name: "docs", transport: .stdio, command: "/bin/docs"))
        let projectID = UUID()
        store.setAllowed(paper.id, in: projectID, allowed: true)
        store.setAllowed(docs.id, in: projectID, allowed: true)

        let paperSession = FakeMCPSession(tools: [
            MCPDiscoveredTool(name: "search", description: "Paper search", inputSchema: [:], readOnlyHint: true, destructiveHint: false)
        ], result: try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "paper"]]]))
        let docsSession = FakeMCPSession(tools: [
            MCPDiscoveredTool(name: "search", description: "Docs search", inputSchema: [:], readOnlyHint: true, destructiveHint: false)
        ], result: try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "docs"]]]))
        let runtime = MCPRuntime(store: store, factory: RoutingFactory(sessions: [
            paper.command: paperSession,
            docs.command: docsSession
        ]))
        runtime.useAuthorizer { _, _, _ in true }

        let listed = await runtime.definitions(projectID: projectID)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(Set(listed.map(\.namespacedName)).count, 2)

        let paperOut = try await runtime.execute(
            name: MCPToolName.namespaced(connectionID: paper.id, original: "search"),
            arguments: [:],
            projectID: projectID
        )
        let docsOut = try await runtime.execute(
            name: MCPToolName.namespaced(connectionID: docs.id, original: "search"),
            arguments: [:],
            projectID: projectID
        )
        XCTAssertEqual(paperOut, "paper")
        XCTAssertEqual(docsOut, "docs")
        XCTAssertEqual(paperSession.calls.count, 1)
        XCTAssertEqual(docsSession.calls.count, 1)
    }

    func testReadOnlySkipsConfirmationAndMutatingAsks() async throws {
        let record = try store.save(MCPConnectionRecord(name: "paper", transport: .stdio, command: "/bin/paper"))
        let projectID = UUID()
        store.setAllowed(record.id, in: projectID, allowed: true)
        let session = FakeMCPSession(tools: [
            MCPDiscoveredTool(name: "look", description: "", inputSchema: [:], readOnlyHint: true, destructiveHint: false),
            MCPDiscoveredTool(name: "write_html", description: "", inputSchema: [:], readOnlyHint: false, destructiveHint: false),
            MCPDiscoveredTool(name: "mystery", description: "", inputSchema: [:], readOnlyHint: nil, destructiveHint: nil)
        ], result: try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "ok"]]]))
        let runtime = MCPRuntime(store: store, factory: FakeFactory(session: session))
        var asked: [String] = []
        runtime.useAuthorizer { _, tool, _ in
            asked.append(tool)
            return tool != "mystery"
        }

        _ = try await runtime.execute(
            name: MCPToolName.namespaced(connectionID: record.id, original: "look"),
            arguments: [:],
            projectID: projectID
        )
        _ = try await runtime.execute(
            name: MCPToolName.namespaced(connectionID: record.id, original: "write_html"),
            arguments: [:],
            projectID: projectID
        )
        do {
            _ = try await runtime.execute(
                name: MCPToolName.namespaced(connectionID: record.id, original: "mystery"),
                arguments: [:],
                projectID: projectID
            )
            XCTFail("unclassified decline should fail")
        } catch {}
        XCTAssertEqual(asked, ["write_html", "mystery"])
    }

    func testSchemaValidationAndResultFormats() throws {
        XCTAssertEqual(MCPSchema.compact(["pageId": "", "fileId": "x"]).keys.sorted(), ["fileId"])
        try MCPSchema.validate(arguments: ["topic": "paper-mcp-instructions"], schema: [
            "type": "object",
            "properties": ["topic": ["type": "string"]],
            "required": ["topic"],
            "additionalProperties": false
        ])
        try MCPSchema.validate(arguments: ["pageId": ""], schema: [
            "properties": [
                "pageId": ["type": "string", "description": "Optional page id"]
            ],
            "required": ["pageId"]
        ])
        XCTAssertThrowsError(try MCPSchema.validate(arguments: [:], schema: [
            "required": ["topic"]
        ]))
        XCTAssertThrowsError(try MCPSchema.validate(arguments: ["topic": "x", "extra": "y"], schema: [
            "properties": ["topic": ["type": "string"]],
            "additionalProperties": false
        ]))

        let text = try MCPToolResult.format(JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": "hello"]]
        ]))
        XCTAssertEqual(text, "hello")

        let image = try MCPToolResult.format(JSONSerialization.data(withJSONObject: [
            "content": [["type": "image", "mimeType": "image/png"]]
        ]))
        XCTAssertTrue(image.contains("image"))

        let unsupported = try MCPToolResult.format(JSONSerialization.data(withJSONObject: [
            "content": [["type": "resource"]]
        ]))
        XCTAssertTrue(unsupported.contains("cannot display"))

        XCTAssertThrowsError(try MCPToolResult.format(JSONSerialization.data(withJSONObject: [
            "isError": true,
            "content": [["type": "text", "text": "nope"]]
        ])))
    }

    func testImportDoesNotConnect() throws {
        let factory = CountingFactory()
        let runtime = MCPRuntime(store: store, factory: factory)
        let summary = try runtime.importServers(json: """
        {"mcpServers":{"paper":{"command":"/bin/paper","args":["mcp"]}}}
        """, replace: false)
        XCTAssertTrue(summary.contains("paper"))
        XCTAssertEqual(factory.opens, 0)
        XCTAssertEqual(runtime.clients.status(for: try XCTUnwrap(store.connection(named: "paper")).id), .disconnected)
    }

    func testRunPolicyDeniesExternalMCP() {
        let run = RunToolPolicy(runID: UUID(), projectID: UUID(), assignedTaskID: nil, allowCode: true)
        XCTAssertFalse(run.allows(MCPToolName.importServers))
        XCTAssertFalse(run.allows(MCPToolName.namespaced(connectionID: UUID(), original: "get_guide")))
        XCTAssertTrue(RunToolPolicy.chat(projectID: UUID()).allows(MCPToolName.importServers))
    }

    func testNamespacedNamesMatchProviderPattern() throws {
        let id = UUID(uuidString: "A1B2C3D4-E5F6-7890-1234-5678ABCDEF01")!
        MCPDisplay.refresh([MCPConnectionRecord(id: id, name: "Paper", transport: .stdio, command: "/bin/paper")])
        let name = MCPToolName.namespaced(connectionID: id, original: "get.guide")
        XCTAssertEqual(name, "mcp_A1B2C3D4_get_guide")
        XCTAssertTrue(name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        XCTAssertLessThanOrEqual(name.count, 64)
        let parsed = try XCTUnwrap(MCPToolName.parse(name))
        XCTAssertEqual(parsed.connectionID, id)
        XCTAssertEqual(parsed.original, "get_guide")
        XCTAssertTrue(MCPToolName.matches("get.guide", encoded: parsed.original))
        let long = MCPToolName.namespaced(connectionID: id, original: "list_comment_thread_authors")
        XCTAssertLessThanOrEqual(long.count, 64)
        XCTAssertTrue(long.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    }

    func testBlankOptionalArgumentsAreOmitted() async throws {
        let paper = try store.save(MCPConnectionRecord(name: "paper", transport: .stdio, command: "/bin/paper"))
        let projectID = UUID()
        store.setAllowed(paper.id, in: projectID, allowed: true)
        let schema = JSONHash.make([
            "type": "object",
            "properties": [
                "pageId": [
                    "type": "string",
                    "description": "Page id. Optional — omit to list pages."
                ],
                "fileId": ["type": "string"]
            ],
            "required": ["pageId"]
        ])
        let session = FakeMCPSession(tools: [
            MCPDiscoveredTool(
                name: "get_basic_info",
                description: "File info",
                inputSchema: schema,
                readOnlyHint: true,
                destructiveHint: false
            )
        ])
        let runtime = MCPRuntime(store: store, factory: FakeFactory(session: session))
        runtime.useAuthorizer { _, _, _ in true }
        session.result = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": "pages"]]
        ])
        let name = MCPToolName.namespaced(connectionID: paper.id, original: "get_basic_info")
        let output = try await runtime.execute(
            name: name,
            arguments: ["pageId": "  ", "fileId": "membrae"],
            projectID: projectID
        )
        XCTAssertEqual(output, "pages")
        XCTAssertEqual(session.calls.count, 1)
        XCTAssertNil(session.calls[0].1["pageId"])
        XCTAssertEqual(session.calls[0].1["fileId"] as? String, "membrae")

        let listed = await runtime.definitions(projectID: projectID)
        let first = try XCTUnwrap(listed.first)
        let parameters = first.providerDefinition["parameters"] as? [String: Any]
        let required = parameters?["required"] as? [String] ?? []
        XCTAssertFalse(required.contains("pageId"))
    }

    func testToolActivityTitleAndTranscriptRestore() throws {
        let id = UUID()
        MCPDisplay.refresh([MCPConnectionRecord(id: id, name: "Paper", transport: .stdio, command: "/bin/paper")])
        let name = MCPToolName.namespaced(connectionID: id, original: "get_guide")
        XCTAssertEqual(ChatToolActivity.title(for: name, status: .running), "Paper · get guide")
        let work = ChatWork(
            seconds: 2,
            thinking: "",
            tools: [ChatToolActivity(id: "1", name: name, status: .succeeded, detail: "read")]
        )
        let packed = ChatTranscript.pack(text: "Done in Paper.", sources: [], work: work)
        let message = ChatMessage(id: UUID(), role: .assistant, content: packed)
        let decoded = try XCTUnwrap(ConversationStore.decode(message, attachments: []))
        guard case .aiMessage(let assistant) = decoded.entry else {
            return XCTFail("expected assistant")
        }
        XCTAssertEqual(assistant.displayText, "Done in Paper.")
        XCTAssertEqual(assistant.tools.map(\.name), [name])
        XCTAssertEqual(assistant.tools.first?.title, "Paper · get guide")
    }

    func testSSERejectedAndMissingFields() {
        XCTAssertThrowsError(try MCPJSONImport.parse("""
        {"mcpServers":{"old":{"type":"sse","url":"https://example.com"}}}
        """))
        XCTAssertThrowsError(try MCPJSONImport.parse("""
        {"mcpServers":{"blank":{}}}
        """))
    }

    private var storeURL: URL {
        directory.appendingPathComponent("mcp-connections.json")
    }
}

private final class FakeMCPSession: MCPSessioning, @unchecked Sendable {
    var tools: [MCPDiscoveredTool]
    var result: Data
    var calls: [(String, [String: Any])] = []
    var closed = false

    init(tools: [MCPDiscoveredTool], result: Data = Data("{}".utf8)) {
        self.tools = tools
        self.result = result
    }

    func listTools() async throws -> [MCPDiscoveredTool] { tools }

    func call(name: String, arguments: [String: Any]) async throws -> Data {
        calls.append((name, arguments))
        return result
    }

    func close() async { closed = true }
}

private struct FakeFactory: MCPSessionFactory {
    var session: FakeMCPSession
    func open(_ connection: MCPResolvedConnection) async throws -> any MCPSessioning { session }
}

private struct RoutingFactory: MCPSessionFactory {
    var sessions: [String: FakeMCPSession]
    func open(_ connection: MCPResolvedConnection) async throws -> any MCPSessioning {
        sessions[connection.record.command] ?? FakeMCPSession(tools: [])
    }
}

private final class CountingFactory: MCPSessionFactory, @unchecked Sendable {
    var opens = 0
    func open(_ connection: MCPResolvedConnection) async throws -> any MCPSessioning {
        opens += 1
        return FakeMCPSession(tools: [])
    }
}
