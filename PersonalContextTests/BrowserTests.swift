import XCTest
@testable import Membrae

final class BrowserTests: XCTestCase {
    func testBlocksPrivateNetworkHosts() {
        XCTAssertEqual(BrowserPermissions.networkClass(of: "http://localhost/admin"), .privateNetwork)
        XCTAssertEqual(BrowserPermissions.networkClass(of: "http://127.0.0.1:8080"), .privateNetwork)
        XCTAssertEqual(BrowserPermissions.networkClass(of: "http://10.0.0.4/"), .privateNetwork)
        XCTAssertEqual(BrowserPermissions.networkClass(of: "http://192.168.1.1/"), .privateNetwork)
        XCTAssertEqual(BrowserPermissions.networkClass(of: "http://172.16.5.2/"), .privateNetwork)
        XCTAssertEqual(BrowserPermissions.networkClass(of: "http://printer.local/"), .privateNetwork)
        XCTAssertEqual(BrowserPermissions.networkClass(of: "https://example.com/docs"), .publicWeb)
    }

    func testClassifiesSensitiveActions() {
        XCTAssertEqual(
            BrowserPermissions.classify(tool: "browser_search", arguments: ["query": "swift concurrency"]),
            .read
        )
        XCTAssertEqual(
            BrowserPermissions.classify(tool: "browser_navigate", arguments: ["url": "https://example.com/login"]),
            .authenticate
        )
        XCTAssertEqual(
            BrowserPermissions.classify(tool: "browser_navigate", arguments: ["url": "https://shop.example/checkout"]),
            .purchase
        )
        XCTAssertEqual(
            BrowserPermissions.classify(tool: "browser_file_upload", arguments: ["paths": ["/tmp/a.pdf"]]),
            .upload
        )
        XCTAssertEqual(
            BrowserPermissions.classify(tool: "browser_navigate", arguments: ["url": "http://127.0.0.1:3000"]),
            .privateNetwork
        )
    }

    func testPrivateNetworkStaysBlockedUnlessEnabled() {
        XCTAssertEqual(BrowserPermissions.decision(for: .privateNetwork, allowPrivateNetwork: false), .block)
        XCTAssertEqual(BrowserPermissions.decision(for: .privateNetwork, allowPrivateNetwork: true), .confirm)
        XCTAssertEqual(BrowserPermissions.decision(for: .read, allowPrivateNetwork: false), .allow)
        XCTAssertEqual(BrowserPermissions.decision(for: .purchase, allowPrivateNetwork: false), .confirm)
    }

    func testDetectsChallengePages() {
        let challenge = BrowserChallengeDetector.detect(
            text: "Please confirm you are human before continuing",
            url: "https://example.com/path"
        )
        XCTAssertEqual(challenge?.host, "example.com")
        XCTAssertNil(BrowserChallengeDetector.detect(text: "Swift concurrency notes", url: "https://example.com"))
    }

    func testSearchUsesAPublicEngine() {
        let url = BrowserPermissions.searchURL(for: "playwright mcp")
        XCTAssertTrue(url.contains("duckduckgo.com"))
        XCTAssertTrue(url.contains("playwright"))
    }

    func testRedactsSecretsFromLogs() {
        let redacted = BrowserPermissions.redact([
            "text": "hunter2",
            "password": "super-secret",
            "url": "https://example.com/login"
        ])
        XCTAssertEqual(redacted["password"] as? String, "••••")
        XCTAssertEqual(redacted["url"] as? String, "https://example.com/login")
    }

    func testActivitySummarizesSearchAndPages() {
        var state = BrowserActivityState()
        BrowserActivity.apply(
            BrowserActivity.summary(for: "browser_search", arguments: ["query": "site docs"], result: ""),
            to: &state
        )
        BrowserActivity.apply(
            BrowserActivity.summary(for: "browser_navigate", arguments: ["url": "https://docs.example.com"], result: ""),
            to: &state
        )
        BrowserActivity.apply(
            BrowserActivity.summary(for: "browser_navigate", arguments: ["url": "https://wiki.example.com"], result: ""),
            to: &state
        )
        XCTAssertEqual(state.searches, 1)
        XCTAssertEqual(state.pages, 2)
        XCTAssertEqual(state.headline, "Reviewed 2 pages")
    }

    func testRuntimePathsAreRealDirectories() {
        let url = URL(fileURLWithPath: "/tmp/browser").appending(path: "node_modules/@playwright/mcp/cli.js")
        XCTAssertTrue(url.path.hasSuffix("/node_modules/@playwright/mcp/cli.js"), url.path)
        XCTAssertFalse(url.path.contains("%2F"), url.path)
    }

    func testHelperLivesBesideTheAppAndSpeaksMCPOverHTTP() {
        let helper = BrowserSupport.helperAppURL(in: URL(fileURLWithPath: "/tmp/Membrae.app"))
        XCTAssertEqual(helper.path, "/tmp/Membrae.app/Contents/Helpers/Membrae Browser.app")
        XCTAssertFalse(helper.path.contains("%2F"), helper.path)
        XCTAssertEqual(BrowserSupport.mcpURL(port: 8931).absoluteString, "http://127.0.0.1:8931/mcp")
        XCTAssertEqual(BrowserSupport.logFile.lastPathComponent, "browser.log")
    }
}
