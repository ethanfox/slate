import AppKit
import Foundation

/// A coding tool run outside Membrae's sandbox.
///
/// A child of the app inherits its App Sandbox, so Claude Code or Codex started with `Process` cannot write to the
/// user's repository. Launch Services starts the helper app outside the sandbox instead, the same way the browser
/// is started. The app writes a ticket, the helper runs the tool and relays its output into files in the app
/// group, and the app tails them. A stop file asks the helper to end the tool.
enum WorkerRelay {
    struct Ticket: Codable, Equatable {
        var id: String
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var directory: String
        /// Membrae's process at launch. Kept for the record; the helper does not end the tool when Membrae goes,
        /// because a worker building Membrae restarts Membrae, and Membrae picks the turn back up when it opens.
        var parentPID: Int32 = 0
    }

    static var root: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BrowserSupport.applicationGroup) {
            return group.appending(path: "Workers", directoryHint: .isDirectory)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "Workers", directoryHint: .isDirectory)
    }

    static func folder(for id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }
    static func ticketURL(for id: String) -> URL { folder(for: id).appending(path: "ticket.json") }
    static func outputURL(for id: String) -> URL { folder(for: id).appending(path: "out.jsonl") }
    static func errorURL(for id: String) -> URL { folder(for: id).appending(path: "err.log") }
    static func exitURL(for id: String) -> URL { folder(for: id).appending(path: "exit") }
    static func stopURL(for id: String) -> URL { folder(for: id).appending(path: "stop") }
    /// Written by the helper the moment it launches, before it runs anything.
    static func startedURL(for id: String) -> URL { folder(for: id).appending(path: "started") }
    /// How far the app has read the output, so a relaunched Membrae carries on from there.
    static func consumedURL(for id: String) -> URL { folder(for: id).appending(path: "consumed") }

    /// The helper's process id, from its started marker.
    static func helperPID(for id: String) -> pid_t? {
        guard let text = try? String(contentsOf: startedURL(for: id), encoding: .utf8) else { return nil }
        return text.split(separator: " ").first.flatMap { pid_t($0) }
    }

    /// The tool is still running: the helper started, has not written its exit, and its process exists.
    static func isAlive(_ id: String) -> Bool {
        guard !id.isEmpty, !FileManager.default.fileExists(atPath: exitURL(for: id).path), let pid = helperPID(for: id) else { return false }
        return kill(pid, 0) == 0
    }

    /// The output already handed to the app before a relaunch.
    static func consumedOffset(for id: String) -> UInt64 {
        UInt64((try? String(contentsOf: consumedURL(for: id), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// Picks a worker's output back up where the app left off, after a relaunch.
    static func reattach(_ id: String, report: @escaping (String) -> Void) -> Handle {
        let handle = Handle(id: id, report: report)
        handle.beginTailing(from: consumedOffset(for: id))
        return handle
    }
    /// Launch Services drops the arguments and environment a sandboxed app passes, so the app also leaves the
    /// ticket's id here and a helper launched with nothing claims the oldest one.
    static var pendingFolder: URL { root.appending(path: "pending", directoryHint: .isDirectory) }
    static func pendingURL(for id: String) -> URL { pendingFolder.appending(path: id + ".json") }

    static let ticketVariable = "MEMBRAE_WORKER_TICKET"

    /// Helper side: the ticket to run, from the arguments, the environment, or the pending folder.
    static func claimTicket(arguments: [String], environment: [String: String]) -> (url: URL, route: String)? {
        if let index = arguments.firstIndex(of: "--exec"), arguments.indices.contains(index + 1) {
            return (URL(fileURLWithPath: arguments[index + 1]), "arguments")
        }
        if let path = environment[ticketVariable], !path.isEmpty {
            return (URL(fileURLWithPath: path), "environment")
        }
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: pendingFolder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let oldest = files
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
        for file in oldest {
            let id = file.deletingPathExtension().lastPathComponent
            let claimed = folder(for: id).appending(path: "claimed")
            // Rename is atomic: two helpers cannot both take one ticket.
            if (try? manager.moveItem(at: file, to: claimed)) != nil {
                return (ticketURL(for: id), "pending folder")
            }
        }
        return nil
    }

    static func writeTicket(_ ticket: Ticket) throws -> URL {
        let folder = folder(for: ticket.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = ticketURL(for: ticket.id)
        try JSONEncoder().encode(ticket).write(to: url, options: .atomic)
        return url
    }

    static func readTicket(at url: URL) throws -> Ticket {
        try JSONDecoder().decode(Ticket.self, from: Data(contentsOf: url))
    }

    /// The error log's last non-empty line, for a message when the tool stops short.
    static func lastErrorLine(for id: String) -> String {
        guard let data = try? Data(contentsOf: errorURL(for: id)) else { return "" }
        let tail = data.count > 4000 ? data.suffix(4000) : data[...]
        return String(decoding: tail, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty } ?? ""
    }

    /// Drops worker folders older than a day. Called by the helper, which can see them all.
    static func sweep() {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date.now.addingTimeInterval(-86_400)
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? manager.removeItem(at: folder) }
        }
    }

    // MARK: - Helper side

    /// Runs the ticket's tool to the end, relaying its output, and returns the helper's own exit code.
    static func serve(ticketURL: URL, route: String = "arguments") -> Int32 {
        let ticket: Ticket
        do {
            ticket = try readTicket(at: ticketURL)
        } catch {
            FileHandle.standardError.write(Data("membrae-worker: bad ticket \(error.localizedDescription)\n".utf8))
            return 2
        }
        let id = ticket.id
        let manager = FileManager.default
        try? manager.removeItem(at: pendingURL(for: id))
        manager.createFile(atPath: startedURL(for: id).path, contents: Data("\(ProcessInfo.processInfo.processIdentifier) via \(route)".utf8))
        manager.createFile(atPath: outputURL(for: id).path, contents: nil)
        manager.createFile(atPath: errorURL(for: id).path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: outputURL(for: id)),
              let errors = try? FileHandle(forWritingTo: errorURL(for: id)) else {
            writeExit(id, status: 2)
            return 2
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ticket.executable)
        process.arguments = ticket.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(ticket.environment) { _, fromTicket in fromTicket }
        process.currentDirectoryURL = URL(fileURLWithPath: ticket.directory, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            errors.write(Data("membrae-worker: could not start \(ticket.executable): \(error.localizedDescription)\n".utf8))
            try? errors.close()
            try? output.close()
            writeExit(id, status: 127)
            return 127
        }
        // The app cannot signal a process it did not start, so it asks with a file.
        let stop = stopURL(for: id)
        var askedToStop = false
        while process.isRunning {
            if !askedToStop, manager.fileExists(atPath: stop.path) {
                askedToStop = true
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            usleep(150_000)
        }
        process.waitUntilExit()
        try? output.close()
        try? errors.close()
        writeExit(id, status: askedToStop ? 15 : process.terminationStatus)
        sweep()
        return 0
    }

    private static func writeExit(_ id: String, status: Int32) {
        try? String(status).write(to: exitURL(for: id), atomically: true, encoding: .utf8)
    }

    // MARK: - App side

    /// Starts the helper app for the ticket through Launch Services and tails what the tool writes.
    /// Every step is reported through `report`, so the session page shows where a launch stops.
    @MainActor
    static func launch(_ ticket: Ticket, report: @escaping (String) -> Void) async throws -> Handle {
        guard let app = BrowserSupport.helperAppURL else {
            throw BrowserSupportError("The worker helper is missing from the app at Contents/Helpers/Membrae Browser.app.")
        }
        let url = try writeTicket(ticket)
        try FileManager.default.createDirectory(at: pendingFolder, withIntermediateDirectories: true)
        try Data(url.path.utf8).write(to: pendingURL(for: ticket.id), options: .atomic)
        report("Wrote the worker ticket to \(url.path)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--exec", url.path]
        configuration.environment = [ticketVariable: url.path]
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        report("Asking Launch Services to start \(app.lastPathComponent)")
        let started = Date.now
        let launch = Task { try await NSWorkspace.shared.openApplication(at: app, configuration: configuration) }
        enum Outcome { case launched(pid_t), refused(String), slow }
        let outcome = await withTaskGroup(of: Outcome.self) { group -> Outcome in
            group.addTask {
                do { return .launched(try await launch.value.processIdentifier) } catch { return .refused(error.localizedDescription) }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return .slow
            }
            let first = await group.next() ?? .slow
            group.cancelAll()
            return first
        }
        switch outcome {
        case .refused(let message):
            throw BrowserSupportError("Launch Services refused to start the worker helper: \(message)")
        case .launched(let pid):
            report("Helper launched as process \(pid) after \(Int(Date.now.timeIntervalSince(started) * 1000)) ms")
        case .slow:
            report("Launch Services has not answered after 8 s; watching for the helper anyway")
        }
        let handle = Handle(id: ticket.id, report: report)
        handle.beginTailing()
        return handle
    }

    /// The exit status the tail reports when the helper never wrote anything.
    static let neverStarted: Int32 = -2

    /// Everything the app gets back from a relayed tool.
    final class Handle: @unchecked Sendable {
        let id: String
        /// Each line the tool wrote to stdout, as it is written.
        let lines: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation
        private let report: (String) -> Void
        private let lock = NSLock()
        private var status: Int32?
        private var waiters: [CheckedContinuation<Int32, Never>] = []
        private var tail: Task<Void, Never>?

        init(id: String, report: @escaping (String) -> Void = { _ in }) {
            self.id = id
            self.report = report
            var continuation: AsyncStream<String>.Continuation!
            lines = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }

        /// The tool's exit status, once it has ended. 15 means it was stopped on request.
        func exitStatus() async -> Int32 {
            await withCheckedContinuation { waiter in
                lock.lock()
                if let status {
                    lock.unlock()
                    waiter.resume(returning: status)
                    return
                }
                waiters.append(waiter)
                lock.unlock()
            }
        }

        func stop() {
            FileManager.default.createFile(atPath: WorkerRelay.stopURL(for: id).path, contents: nil)
        }

        fileprivate func beginTailing(from start: UInt64 = 0) {
            let id = id
            tail = Task.detached(priority: .userInitiated) { [weak self] in
                var offset: UInt64 = start
                var consumedWhole: UInt64 = start
                var partial = Data()
                var drainedAfterExit = false
                let output = WorkerRelay.outputURL(for: id)
                let exit = WorkerRelay.exitURL(for: id)
                let startedAt = Date.now
                var sawHelper = false
                var sawOutput = false
                let startedMarker = WorkerRelay.startedURL(for: id)
                while !Task.isCancelled {
                    if !sawHelper, let pid = try? String(contentsOf: startedMarker, encoding: .utf8) {
                        sawHelper = true
                        self?.report("Helper is running as process \(pid.trimmingCharacters(in: .whitespacesAndNewlines)); starting the tool")
                    }
                    if !sawOutput, Date.now.timeIntervalSince(startedAt) > 25 {
                        try? FileManager.default.removeItem(at: WorkerRelay.pendingURL(for: id))
                    }
                    if !sawOutput, FileManager.default.fileExists(atPath: output.path) {
                        sawOutput = true
                        self?.report("Tool started; waiting for its first line")
                    }
                    if !sawOutput, Date.now.timeIntervalSince(startedAt) > 25 {
                        let error = WorkerRelay.lastErrorLine(for: id)
                        self?.report(sawHelper
                            ? "The helper ran but the tool wrote nothing in 25 s" + (error.isEmpty ? "" : ": \(error)")
                            : "The helper never launched in 25 s. Launch Services started nothing at \(WorkerRelay.folder(for: id).path)")
                        self?.finish(status: WorkerRelay.neverStarted)
                        return
                    }
                    if let handle = try? FileHandle(forReadingFrom: output) {
                        try? handle.seek(toOffset: offset)
                        let data = (try? handle.readToEnd()) ?? Data()
                        try? handle.close()
                        if !data.isEmpty {
                            offset += UInt64(data.count)
                            partial.append(data)
                            var cut = 0
                            while let newline = partial.firstIndex(of: 0x0A) {
                                let line = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
                                cut += newline - partial.startIndex + 1
                                partial.removeSubrange(partial.startIndex...newline)
                                if !line.isEmpty { self?.continuation.yield(line) }
                            }
                            // Only whole lines count as handed over; a part line is read again after a relaunch.
                            if cut > 0 {
                                consumedWhole += UInt64(cut)
                                try? String(consumedWhole).write(to: WorkerRelay.consumedURL(for: id), atomically: true, encoding: .utf8)
                            }
                        }
                    }
                    if FileManager.default.fileExists(atPath: exit.path) {
                        // The exit file lands after the last write, so one more pass drains what is left.
                        if drainedAfterExit { break }
                        drainedAfterExit = true
                        continue
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                if !partial.isEmpty {
                    self?.continuation.yield(String(decoding: partial, as: UTF8.self))
                }
                let status = Int32((try? String(contentsOf: exit, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
                self?.finish(status: status)
            }
        }

        private func finish(status: Int32) {
            continuation.finish()
            lock.lock()
            self.status = status
            let waiting = waiters
            waiters = []
            lock.unlock()
            for waiter in waiting { waiter.resume(returning: status) }
        }

        deinit { tail?.cancel() }
    }
}
