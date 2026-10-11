import Darwin
import Foundation

enum BrowserSupport {
    static let applicationGroup = "NUF99UVUKB.com.ethanfox.PersonalContext"
    static let playwrightMCP = "0.0.41"

    static var root: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: applicationGroup) {
            return group.appending(path: "Browser", directoryHint: .isDirectory)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support.appending(path: "Membrae/Browser", directoryHint: .isDirectory)
    }

    static var runtime: URL { root.appending(path: "Runtime", directoryHint: .isDirectory) }
    static var browsers: URL { root.appending(path: "Browsers", directoryHint: .isDirectory) }
    static var profiles: URL { root.appending(path: "Profiles", directoryHint: .isDirectory) }
    static var downloads: URL { root.appending(path: "Downloads", directoryHint: .isDirectory) }
    static var temporary: URL { root.appending(path: "Tmp", directoryHint: .isDirectory) }
    static var logFile: URL { root.appending(path: "browser.log") }

    static var nodeURL: URL? { bundledNode }
    static var mcpCLI: URL? { bundledResource("node_modules/@playwright/mcp/cli.js") }
    static var playwrightCLI: URL? { bundledResource("node_modules/playwright-core/cli.js") }
    static var bundledBrowsers: URL? { bundledResource("browsers") }
    static var helperAppURL: URL? {
        if Bundle.main.bundleIdentifier == "com.ethanfox.PersonalContext.browser" {
            return Bundle.main.bundleURL
        }
        let bundled = helperAppURL(in: Bundle.main.bundleURL)
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
    }

    static var isReady: Bool {
        bundledNode != nil && mcpCLI != nil && hasChromium && (isHelperProcess || helperAppURL != nil)
    }

    static func helperAppURL(in appBundle: URL) -> URL {
        appBundle
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Helpers", directoryHint: .isDirectory)
            .appending(path: "Membrae Browser.app")
    }

    static func mcpURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    static func writeLaunchTicket(arguments: [String]) throws -> URL {
        try ensureDirectories()
        let url = temporary.appending(path: "launch.json")
        let data = try JSONEncoder().encode(LaunchTicket(arguments: arguments))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func readLaunchTicket(at url: URL? = nil) throws -> [String] {
        let data = try Data(contentsOf: url ?? temporary.appending(path: "launch.json"))
        return try JSONDecoder().decode(LaunchTicket.self, from: data).arguments
    }

    static func log(_ message: String) {
        let line = "\(logStamp()) \(message)"
        print("[membrae-browser] \(message)")
        appendLog(line + "\n")
    }

    static func clip(_ arguments: [String: Any], _ limit: Int = 180) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    static func attachStandardStreamsToLog() {
        try? ensureDirectories()
        let fd = open(logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        dup2(fd, STDOUT_FILENO)
        if fd != STDERR_FILENO && fd != STDOUT_FILENO {
            Darwin.close(fd)
        }
    }

    static func ensureDirectories() throws {
        let fm = FileManager.default
        for url in [root, runtime, browsers, profiles, downloads, temporary] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(playwrightEnvironment()) { _, new in new }
        return environment
    }

    static func playwrightEnvironment() -> [String: String] {
        [
            "PLAYWRIGHT_BROWSERS_PATH": browserPayloadPath,
            "PLAYWRIGHT_SKIP_BROWSER_GC": "1",
            "PLAYWRIGHT_MCP_PING_TIMEOUT_MS": "0",
            "TMPDIR": temporary.path
        ]
    }

    static func ensureRuntime(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try ensureDirectories()
        if isReady { return }
        guard bundledNode != nil else {
            throw BrowserSupportError("Membrae is missing its bundled Node binary.")
        }
        guard mcpCLI != nil else {
            throw BrowserSupportError("Membrae is missing the bundled Playwright package.")
        }
        if !hasChromium {
            onProgress?("Installing Chromium")
            try installChromium()
        }
        onProgress?("Ready")
    }

    static func execPlaywright(arguments: [String]) throws -> Never {
        guard let node = bundledNode, let mcp = mcpCLI else {
            throw BrowserSupportError("The browser runtime is missing from the app.")
        }
        log("exec node=\(node.path) mcp=\(mcp.path) args=\(arguments.joined(separator: " ")) browsers=\(browserPayloadPath)")
        let process = Process()
        process.executableURL = node
        process.arguments = [mcp.path] + arguments
        process.environment = processEnvironment()
        process.currentDirectoryURL = temporary
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        log("playwright pid=\(process.processIdentifier)")
        process.waitUntilExit()
        log("playwright exit=\(process.terminationStatus)")
        exit(process.terminationStatus)
    }

    private static func installChromium() throws {
        guard let node = bundledNode, let cli = playwrightCLI else {
            throw BrowserSupportError("The bundled Playwright CLI is missing.")
        }
        try run(node.path, [cli.path, "install", "chromium"])
        guard hasChromium else {
            throw BrowserSupportError("Chromium did not install into \(browserPayloadPath).")
        }
    }

    private static var hasChromium: Bool {
        [bundledBrowsers, browsers].compactMap { $0 }.contains(where: containsChromium)
    }

    private static var browserPayloadPath: String {
        if let bundled = bundledBrowsers, containsChromium(bundled) {
            return bundled.path
        }
        return browsers.path
    }

    private static func containsChromium(_ directory: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { $0.hasPrefix("chromium") }
    }

    private static var bundledNode: URL? {
        if let node = Bundle.main.url(forAuxiliaryExecutable: "membrae-node"),
           FileManager.default.isReadableFile(atPath: node.path) {
            return node
        }
        if let contents = contentsDirectory() {
            let node = contents.appending(path: "MacOS/membrae-node")
            if FileManager.default.isReadableFile(atPath: node.path) { return node }
        }
        return nil
    }

    private static func bundledResource(_ relative: String) -> URL? {
        if let resources = Bundle.main.resourceURL {
            let url = resources.appending(path: "browser/\(relative)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let contents = contentsDirectory() {
            let url = contents.appending(path: "Resources/browser/\(relative)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static var isHelperProcess: Bool {
        Bundle.main.bundleIdentifier == "com.ethanfox.PersonalContext.browser"
    }

    private static func contentsDirectory() -> URL? {
        var candidates: [URL] = []
        if let node = Bundle.main.url(forAuxiliaryExecutable: "membrae-node") {
            candidates.append(node.deletingLastPathComponent())
        }
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent())
        candidates.append(Bundle.main.bundleURL)
        for folder in candidates {
            var cursor = folder
            for _ in 0..<8 {
                if let found = membraeContents(from: cursor) {
                    return found
                }
                cursor = cursor.deletingLastPathComponent()
            }
        }
        return nil
    }

    private static func membraeContents(from cursor: URL) -> URL? {
        let macOS = cursor.appending(path: "MacOS/membrae-node")
        if FileManager.default.isReadableFile(atPath: macOS.path) {
            return cursor
        }
        let node = cursor.appending(path: "membrae-node")
        if FileManager.default.isReadableFile(atPath: node.path) {
            return cursor.deletingLastPathComponent()
        }
        if cursor.lastPathComponent == "Helpers" {
            let parent = cursor.deletingLastPathComponent()
            if FileManager.default.isReadableFile(atPath: parent.appending(path: "MacOS/membrae-node").path) {
                return parent
            }
        }
        if cursor.pathExtension == "app" {
            let nested = cursor.appending(path: "Contents/MacOS/membrae-node")
            if FileManager.default.isReadableFile(atPath: nested.path) {
                return cursor.appending(path: "Contents")
            }
        }
        return nil
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = processEnvironment()
        process.currentDirectoryURL = directory
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw BrowserSupportError("Couldn’t start \(executable): \(error.localizedDescription)")
        }
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let combined = [outData, errData]
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard process.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            let detail = combined.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
            if detail.isEmpty {
                throw BrowserSupportError("\(name) exited \(process.terminationStatus).")
            }
            throw BrowserSupportError("\(name) exited \(process.terminationStatus): \(detail)")
        }
        return combined
    }

    private static let logLock = NSLock()

    private static func logStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func appendLog(_ line: String) {
        try? ensureDirectories()
        logLock.lock()
        defer { logLock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path),
           let handle = try? FileHandle(forWritingTo: logFile) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logFile)
        }
    }
}

private struct LaunchTicket: Codable {
    var arguments: [String]
}

struct BrowserSupportError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
