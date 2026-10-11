import AppKit
import Darwin
import Foundation

struct BrowserLaunchOptions: Equatable, Sendable {
    var headed = false
    var isolated = true
    var userDataDir: URL?
    var outputDir: URL = BrowserSupport.downloads
}

actor BrowserProcess {
    private var session: (any MCPSessioning)?
    private var options: BrowserLaunchOptions?
    private var lastUsed = Date()
    private var opening = false
    private var helperPID: pid_t?
    private var port: UInt16?

    var isOpen: Bool { session != nil }

    func touch() {
        lastUsed = Date()
    }

    func idleDuration(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(lastUsed)
    }

    func ensure(options: BrowserLaunchOptions) async throws -> any MCPSessioning {
        if let session, self.options == options {
            lastUsed = Date()
            BrowserSupport.log("reuse pid=\(helperPID.map(String.init) ?? "-") port=\(port.map(String.init) ?? "-")")
            return session
        }
        if opening {
            throw BrowserSupportError("The browser is still starting.")
        }
        opening = true
        defer { opening = false }
        await close()
        let opened = try await Self.start(options)
        session = opened.session
        helperPID = opened.pid
        port = opened.port
        self.options = options
        lastUsed = Date()
        return opened.session
    }

    func recover(options: BrowserLaunchOptions) async throws -> any MCPSessioning {
        await close()
        return try await ensure(options: options)
    }

    func call(name: String, arguments: [String: Any], options: BrowserLaunchOptions) async throws -> Data {
        let started = Date()
        BrowserSupport.log("call \(name) \(BrowserSupport.clip(arguments))")
        do {
            let session = try await ensure(options: options)
            lastUsed = Date()
            let data = try await session.call(name: name, arguments: arguments)
            BrowserSupport.log("call \(name) ok ms=\(Self.ms(since: started)) bytes=\(data.count)")
            return data
        } catch is CancellationError {
            BrowserSupport.log("call \(name) cancelled ms=\(Self.ms(since: started))")
            throw CancellationError()
        } catch {
            guard MCPTransportLoss.isLost(error) else {
                BrowserSupport.log("call \(name) fail ms=\(Self.ms(since: started)) \(error.localizedDescription)")
                throw error
            }
            BrowserSupport.log("call \(name) recover ms=\(Self.ms(since: started)) \(error.localizedDescription)")
            let session = try await recover(options: options)
            lastUsed = Date()
            let data = try await session.call(name: name, arguments: arguments)
            BrowserSupport.log("call \(name) recovered ms=\(Self.ms(since: started)) bytes=\(data.count)")
            return data
        }
    }

    func close() async {
        let pid = helperPID
        let port = port
        if session != nil || pid != nil {
            BrowserSupport.log("close pid=\(pid.map(String.init) ?? "-") port=\(port.map(String.init) ?? "-")")
        }
        if let session {
            await session.close()
        }
        if let pid {
            await MainActor.run {
                NSRunningApplication(processIdentifier: pid)?.terminate()
            }
        }
        session = nil
        options = nil
        helperPID = nil
        self.port = nil
    }

    private static func start(_ options: BrowserLaunchOptions) async throws -> (session: any MCPSessioning, pid: pid_t, port: UInt16) {
        let started = Date()
        try BrowserSupport.ensureDirectories()
        let port = try reservedLocalPort()
        BrowserSupport.log("start port=\(port) headed=\(options.headed) isolated=\(options.isolated)")
        var arguments: [String] = [
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--browser", "chromium",
            "--image-responses", "omit",
            "--viewport-size", "1280x800",
            "--timeout-navigation", "30000",
            "--timeout-action", "8000",
            "--output-dir", options.outputDir.path
        ]
        if !options.headed {
            arguments.append("--headless")
        }
        if options.isolated {
            arguments.append("--isolated")
        }
        if let userDataDir = options.userDataDir {
            try FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)
            arguments += ["--user-data-dir", userDataDir.path]
        }
        let ticket = try BrowserSupport.writeLaunchTicket(arguments: arguments)
        let pid = try await launchHelperApp(arguments: ["--ticket", ticket.path])
        BrowserSupport.log("helper pid=\(pid) launch ms=\(ms(since: started))")
        try await waitUntilListening(port: port)
        BrowserSupport.log("listening port=\(port) ms=\(ms(since: started))")
        let record = MCPConnectionRecord(
            name: "Browser",
            transport: .http,
            url: BrowserSupport.mcpURL(port: port).absoluteString
        )
        do {
            let session = try await MCPLiveSessionFactory.shared.open(
                MCPResolvedConnection(record: record, environment: [:], headers: [:])
            )
            BrowserSupport.log("mcp ready port=\(port) ms=\(ms(since: started))")
            return (session, pid, port)
        } catch {
            BrowserSupport.log("mcp open fail ms=\(ms(since: started)) \(error.localizedDescription)")
            throw error
        }
    }

    @MainActor
    private static func launchHelperApp(arguments: [String]) async throws -> pid_t {
        guard let app = BrowserSupport.helperAppURL else {
            throw BrowserSupportError("The browser helper is missing from the app.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = BrowserSupport.playwrightEnvironment()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        do {
            let running = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            return running.processIdentifier
        } catch {
            BrowserSupport.log("open helper fail \(error.localizedDescription)")
            throw BrowserSupportError("Couldn’t start the browser: \(error.localizedDescription)")
        }
    }

    private static func reservedLocalPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw BrowserSupportError("Couldn’t reserve a local port.") }
        defer { Darwin.close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw BrowserSupportError("Couldn’t reserve a local port.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { throw BrowserSupportError("Couldn’t reserve a local port.") }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func waitUntilListening(port: UInt16) async throws {
        let started = Date()
        for step in 0..<80 {
            if isOpen(port: port) { return }
            if step == 20 || step == 40 || step == 60 {
                BrowserSupport.log("listen wait port=\(port) ms=\(ms(since: started))")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        BrowserSupport.log("listen timeout port=\(port) ms=\(ms(since: started))")
        throw BrowserSupportError("The browser helper did not start listening on port \(port).")
    }

    private static func isOpen(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

}

@MainActor
final class BrowserProcessPool {
    private struct Slot {
        var key: String
        var process: BrowserProcess
        var options: BrowserLaunchOptions
    }

    private var slots: [Slot] = []

    func process(for key: String, options: BrowserLaunchOptions, limit: Int) async throws -> BrowserProcess {
        if let existing = slots.first(where: { $0.key == key }) {
            return existing.process
        }
        while slots.count >= max(1, limit) {
            await evictIdle()
            if slots.count >= max(1, limit) {
                if let last = slots.popLast() {
                    await last.process.close()
                } else {
                    break
                }
            }
        }
        let process = BrowserProcess()
        slots.append(Slot(key: key, process: process, options: options))
        return process
    }

    func close(_ key: String) async {
        if let index = slots.firstIndex(where: { $0.key == key }) {
            await slots[index].process.close()
            slots.remove(at: index)
        }
    }

    func closeAll() async {
        for slot in slots {
            await slot.process.close()
        }
        slots = []
    }

    private func evictIdle() async {
        var best: (index: Int, idle: TimeInterval)?
        for (index, slot) in slots.enumerated() {
            let idle = await slot.process.idleDuration()
            if best == nil || idle > best!.idle {
                best = (index, idle)
            }
        }
        if let best {
            await slots[best.index].process.close()
            slots.remove(at: best.index)
        }
    }

    func reapIdle(olderThan interval: TimeInterval) async {
        var kept: [Slot] = []
        for slot in slots {
            let idle = await slot.process.idleDuration()
            if idle >= interval, slot.options.isolated {
                await slot.process.close()
            } else {
                kept.append(slot)
            }
        }
        slots = kept
    }
}
