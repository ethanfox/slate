import Foundation
import os

enum NavTrace {
    static let logger = Logger(subsystem: "com.ethanfox.PersonalContext", category: "nav")

    private static let lock = NSLock()
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Membrae", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nav.log")
    }()
    private static var spanStart: ContinuousClock.Instant?
    private static var keepSpan = false

    static func begin(_ name: String) {
        lock.lock()
        let fresh = !keepSpan || spanStart == nil
        keepSpan = false
        if fresh { spanStart = .now }
        lock.unlock()
        event(fresh ? "begin \(name)" : "cont \(name)")
    }

    static func keep() {
        lock.lock()
        keepSpan = true
        lock.unlock()
    }

    static func event(_ message: String) {
        let prefix: String
        lock.lock()
        if let spanStart {
            prefix = "+\(elapsed(spanStart)) "
        } else {
            prefix = ""
        }
        lock.unlock()
        write("\(prefix)\(message)")
    }

    @discardableResult
    static func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        let result = try work()
        event("\(label) \(elapsed(start))")
        return result
    }

    static func afterTurn(_ label: String = "runloop") {
        DispatchQueue.main.async {
            event(label)
        }
    }

    static func elapsed(_ start: ContinuousClock.Instant) -> String {
        let ms = start.duration(to: .now) / .milliseconds(1)
        return String(format: "%.1fms", ms)
    }

    private static func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[PC-OS nav] \(message)")
        let line = "\(iso.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
