import Foundation

/// Inbound tokens vs UI paints. If `in` is low and hold/apply stay small, the provider is slow.
struct StreamPace: Sendable, Equatable {
    var startedAt = Date()
    var preparedAt: Date?
    var firstInboundAt: Date?
    var lastInboundAt: Date?
    var lastPaintAt: Date?
    var inboundChars = 0
    var inboundEvents = 0
    var paintedChars = 0
    var paintEvents = 0
    var lastApplyMs = 0.0
    var lastHoldMs = 0.0

    mutating func markPrepared(at date: Date = .now) {
        if preparedAt == nil { preparedAt = date }
    }

    mutating func inbound(_ count: Int, at date: Date = .now) {
        guard count > 0 else { return }
        if firstInboundAt == nil { firstInboundAt = date }
        lastInboundAt = date
        inboundChars += count
        inboundEvents += 1
    }

    mutating func painted(_ count: Int, applyMs: Double, at date: Date = .now) {
        guard count > 0 else { return }
        lastPaintAt = date
        paintedChars += count
        paintEvents += 1
        lastApplyMs = applyMs
        if let lastInboundAt {
            lastHoldMs = max(0, date.timeIntervalSince(lastInboundAt) * 1000)
        }
    }

    func summary(now: Date = .now) -> String {
        let firstWait = (firstInboundAt ?? now).timeIntervalSince(startedAt)
        let first = Self.seconds(firstWait)
        guard firstInboundAt != nil else {
            return "waiting \(first) · no tokens yet"
        }
        var firstLine = "first token \(first)"
        if let preparedAt {
            firstLine += " · prepare \(Self.seconds(preparedAt.timeIntervalSince(startedAt)))"
        }
        return [
            firstLine,
            "in  \(Self.rate(inboundChars, from: firstInboundAt, to: lastInboundAt)) · \(inboundChars) chars · \(inboundEvents) events",
            "out \(Self.rate(paintedChars, from: firstInboundAt, to: lastPaintAt)) · hold \(Self.millis(lastHoldMs)) · apply \(Self.millis(lastApplyMs))"
        ].joined(separator: "\n")
    }

    var logLine: String {
        summary().replacingOccurrences(of: "\n", with: " · ")
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }

    private static func millis(_ value: Double) -> String {
        String(format: "%.0fms", value)
    }

    private static func rate(_ chars: Int, from: Date?, to: Date?) -> String {
        guard let from, let to else { return "—" }
        let elapsed = to.timeIntervalSince(from)
        guard elapsed >= 0.05, chars > 0 else { return "burst" }
        return String(format: "%.0f ch/s", Double(chars) / elapsed)
    }
}

struct StreamTextCoalescer: Sendable {
    var interval: TimeInterval
    private var pending = ""
    private var lastFlush = Date.distantPast

    init(interval: TimeInterval = 0.04) {
        self.interval = interval
    }

    mutating func push(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        pending += text
        let now = Date()
        guard now.timeIntervalSince(lastFlush) >= interval else { return nil }
        lastFlush = now
        return take()
    }

    mutating func take() -> String? {
        guard !pending.isEmpty else { return nil }
        let chunk = pending
        pending = ""
        return chunk
    }
}
