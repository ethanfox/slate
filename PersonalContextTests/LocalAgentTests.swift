import XCTest
@testable import Membrae

final class LocalAgentTests: XCTestCase {
    private func request(allowEdits: Bool, tools: [String] = []) -> LocalAgentRequest {
        LocalAgentRequest(
            prompt: "Fix the bug",
            directory: "/tmp/repo",
            allowEdits: allowEdits,
            mcpCommand: "/Apps/Membrae.app/Contents/MacOS/membrae-mcp",
            membraeTools: tools
        )
    }

    func testClaudeCodeReadOnlyAllowsNothingExtra() {
        let arguments = LocalAgent.claudeCode.arguments(for: request(allowEdits: false))
        XCTAssertEqual(Array(arguments.prefix(2)), ["-p", "Fix the bug"])
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertFalse(arguments.contains("--permission-mode"))
        XCTAssertFalse(arguments.contains("--allowedTools"))
        XCTAssertFalse(arguments.contains("--mcp-config"))
    }

    func testClaudeCodeWithEditsAndMembraeTools() throws {
        let arguments = LocalAgent.claudeCode.arguments(for: request(allowEdits: true, tools: ["get_track", "update_task"]))
        let mode = try XCTUnwrap(arguments.firstIndex(of: "--permission-mode"))
        XCTAssertEqual(arguments[mode + 1], "acceptEdits")
        let allowed = try XCTUnwrap(arguments.firstIndex(of: "--allowedTools"))
        XCTAssertEqual(arguments[allowed + 1], "Bash,mcp__membrae")
        let config = try XCTUnwrap(arguments.firstIndex(of: "--mcp-config"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[config + 1].utf8)) as? [String: Any])
        let server = try XCTUnwrap((object["mcpServers"] as? [String: Any])?["membrae"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, "/Apps/Membrae.app/Contents/MacOS/membrae-mcp")
        XCTAssertEqual((server["env"] as? [String: String])?[LocalAgent.allowedToolsVariable], "get_track,update_task")
    }

    func testCodexSandboxFollowsTheEditSwitch() throws {
        let readOnly = LocalAgent.codex.arguments(for: request(allowEdits: false))
        XCTAssertEqual(readOnly[try XCTUnwrap(readOnly.firstIndex(of: "-s")) + 1], "read-only")
        XCTAssertEqual(readOnly.last, "Fix the bug")

        let editing = LocalAgent.codex.arguments(for: request(allowEdits: true, tools: ["get_track"]))
        XCTAssertEqual(editing[try XCTUnwrap(editing.firstIndex(of: "-s")) + 1], "danger-full-access")
        XCTAssertEqual(editing[try XCTUnwrap(editing.firstIndex(of: "-C")) + 1], "/tmp/repo")
        XCTAssertTrue(editing.contains("mcp_servers.membrae.command=\"/Apps/Membrae.app/Contents/MacOS/membrae-mcp\""))
        XCTAssertTrue(editing.contains("mcp_servers.membrae.env={MEMBRAE_ALLOWED_TOOLS=\"get_track\"}"))
    }

    func testClaudeCodeStream() {
        let agent = LocalAgent.claudeCode
        let assistant = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#
        XCTAssertEqual(agent.events(fromLine: assistant), [.text("Looking."), .activity("Running a command")])

        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","permission_denials":[{"tool_name":"Write"},{"tool_name":"Write"},{"tool_name":"Bash"}]}"#
        XCTAssertEqual(agent.events(fromLine: result), [.finished(summary: "Done.", refused: ["Write", "Bash"])])

        let failed = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":""}"#
        XCTAssertEqual(agent.events(fromLine: failed), [.failed("Claude Code stopped with error_during_execution.")])

        XCTAssertEqual(agent.events(fromLine: "not json"), [])
    }

    func testCodexStream() {
        let agent = LocalAgent.codex
        let command = #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'echo hi'","status":"in_progress"}}"#
        XCTAssertEqual(agent.events(fromLine: command), [.activity("Running a command")])

        let message = #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"OK"}}"#
        XCTAssertEqual(agent.events(fromLine: message), [.text("OK")])

        XCTAssertEqual(agent.events(fromLine: #"{"type":"turn.completed","usage":{}}"#), [.finished(summary: "", refused: [])])
        XCTAssertEqual(
            agent.events(fromLine: #"{"type":"turn.failed","error":{"message":"Not signed in"}}"#),
            [.failed("Not signed in")]
        )
    }

    func testRefusalNoteSaysWhoseLimitItIs() {
        XCTAssertEqual(LocalAgent.claudeCode.refusalNote([], allowEdits: false), "")
        XCTAssertTrue(LocalAgent.claudeCode.refusalNote(["Write"], allowEdits: false).contains("turned on"))
        XCTAssertTrue(LocalAgent.claudeCode.refusalNote(["Bash"], allowEdits: true).contains("Claude Code’s own settings"))
    }

    func testLocalAgentPrompt() {
        let editing = RunPrompt.localAgent(brief: "Fix it", project: nil, directory: "/tmp/repo", allowEdits: true, hasMembrae: false)
        XCTAssertTrue(editing.contains("/tmp/repo"))
        XCTAssertTrue(editing.contains("Do not push."))
        XCTAssertTrue(editing.hasSuffix("Fix it"))

        let reading = RunPrompt.localAgent(brief: "Look", project: nil, directory: "/tmp/repo", allowEdits: false, hasMembrae: true)
        XCTAssertTrue(reading.contains("Do not change files."))
        XCTAssertTrue(reading.contains("membrae tools"))
    }
}
