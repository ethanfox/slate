import Foundation

struct BrowserActivityEvent: Identifiable, Equatable, Sendable {
    var id = UUID()
    var at = Date()
    var runID: UUID?
    var summary: String
    var url: String?
    var host: String?
    var pages: Int
}

struct BrowserActivityState: Equatable, Sendable {
    var searches = 0
    var pages = 0
    var lastHost: String?
    var lastSummary = "Starting the browser"
    var events: [BrowserActivityEvent] = []

    var headline: String {
        if searches > 0, pages == 0 { return "Searched for relevant sources" }
        if pages == 1 { return "Reviewed 1 page" }
        if pages > 1 { return "Reviewed \(pages) pages" }
        return lastSummary
    }

    var statusLine: String {
        "Headless Chromium · Running locally"
    }
}

enum BrowserActivity {
    static func summary(for tool: String, arguments: [String: Any], result: String) -> BrowserActivityEvent {
        let url = BrowserPermissions.firstURL(in: arguments)
        let host = url.map(BrowserChallengeDetector.host(from:))
        switch tool {
        case "browser_search":
            let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return BrowserActivityEvent(
                summary: query.isEmpty ? "Searched for relevant sources" : "Searched for \(clip(query, 48))",
                url: url,
                host: host,
                pages: 0
            )
        case "browser_navigate", "browser_open":
            return BrowserActivityEvent(
                summary: host.map { "Opened \($0)" } ?? "Opened a page",
                url: url,
                host: host,
                pages: 1
            )
        case "browser_snapshot", "browser_read":
            return BrowserActivityEvent(summary: "Read page content", url: url, host: host, pages: 0)
        case "browser_take_screenshot", "browser_screenshot":
            return BrowserActivityEvent(summary: "Captured a screenshot", url: url, host: host, pages: 0)
        case "browser_click":
            return BrowserActivityEvent(summary: "Clicked a control", url: url, host: host, pages: 0)
        case "browser_type", "browser_fill", "browser_fill_form":
            return BrowserActivityEvent(summary: "Entered text", url: url, host: host, pages: 0)
        case "browser_tabs":
            return BrowserActivityEvent(summary: "Managed tabs", url: url, host: host, pages: 0)
        case "browser_evaluate":
            return BrowserActivityEvent(summary: "Ran page script", url: url, host: host, pages: 0)
        case "browser_download":
            return BrowserActivityEvent(summary: "Downloaded a file", url: url, host: host, pages: 0)
        default:
            let readable = tool.replacingOccurrences(of: "browser_", with: "").replacingOccurrences(of: "_", with: " ")
            return BrowserActivityEvent(summary: readable.localizedCapitalized, url: url, host: host, pages: pageDelta(in: result))
        }
    }

    static func apply(_ event: BrowserActivityEvent, to state: inout BrowserActivityState) {
        if event.summary.lowercased().contains("search") { state.searches += 1 }
        state.pages += event.pages
        if let host = event.host { state.lastHost = host }
        state.lastSummary = event.summary
        state.events.append(event)
        if state.events.count > 40 {
            state.events.removeFirst(state.events.count - 40)
        }
    }

    static func pageDelta(in result: String) -> Int {
        result.contains("Page URL") || result.contains("- generic") || result.contains("Page Title") ? 1 : 0
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
