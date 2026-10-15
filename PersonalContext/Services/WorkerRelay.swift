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
    static func serve(ticketURL: URL) -> Int32 {
        let ticket: Ticket
        do {
            ticket = try readTicket(at: ticketURL)
        } catch {
            FileHandle.standardError.write(Data("membrae-worker: bad ticket \(error.localizedDescription)\n".utf8))
            return 2
        }
        let id = ticket.id
        let manager = FileManager.default
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
    @MainActor
    static func launch(_ ticket: Ticket) async throws -> Handle {
        guard let app = BrowserSupport.helperAppURL else {
            throw BrowserSupportError("The worker helper is missing from the app.")
        }
        let url = try writeTicket(ticket)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--exec", url.path]
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } catch {
            throw BrowserSupportError("Couldn’t start the worker helper: \(error.localizedDescription)")
        }
        let handle = Handle(id: ticket.id)
        handle.beginTailing()
        return handle
    }

    /// Everything the app gets back from a relayed tool.
    final class Handle: @unchecked Sendable {
        let id: String
        /// Each line the tool wrote to stdout, as it is written.
        let lines: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation
        private let lock = NSLock()
        private var status: Int32?
        private var waiters: [CheckedContinuation<Int32, Never>] = []
        private var tail: Task<Void, Never>?

        init(id: String) {
            self.id = id
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

        fileprivate func beginTailing() {
            let id = id
            tail = Task.detached(priority: .userInitiated) { [weak self] in
                var offset: UInt64 = 0
                var partial = Data()
                var drainedAfterExit = false
                let output = WorkerRelay.outputURL(for: id)
                let exit = WorkerRelay.exitURL(for: id)
                while !Task.isCancelled {
                    if let handle = try? FileHandle(forReadingFrom: output) {
                        try? handle.seek(toOffset: offset)
                        let data = (try? handle.readToEnd()) ?? Data()
                        try? handle.close()
                        if !data.isEmpty {
                            offset += UInt64(data.count)
                            partial.append(data)
                            while let newline = partial.firstIndex(of: 0x0A) {
                                let line = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
                                partial.removeSubrange(partial.startIndex...newline)
                                if !line.isEmpty { self?.continuation.yield(line) }
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
