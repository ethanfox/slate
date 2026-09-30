import Foundation
import SQLite3

struct CursorUsage: Equatable, Sendable {
    var cursorModels: Double
    var otherModels: Double
    var resetsAt: Date?
    var isUnlimited: Bool

    static func percent(_ value: Double) -> String {
        "\(Int(max(0, value).rounded()))%"
    }
}

/// Cursor has no public usage API. This reads the Cursor app's own sign-in from its local
/// state database and calls the endpoint behind cursor.com/dashboard, so it can change without notice.
enum CursorUsageClient {
    private static let endpoint = URL(string: "https://cursor.com/api/usage-summary")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Returns nil when the Cursor app isn't installed or signed in on this Mac.
    static func fetch() async throws -> CursorUsage? {
        guard let token = localAccessToken(), let cookie = sessionCookie(for: token) else { return nil }
        var request = URLRequest(url: endpoint)
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let message = status == 401 || status == 403
                ? "Sign in to the Cursor app again to see usage."
                : "Couldn’t load Cursor usage (\(status))."
            throw CursorAPIError(status: status, message: message)
        }
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data), let usage = summary.usage else {
            throw CursorAPIError(status: status, message: "Cursor returned usage this app couldn’t read.")
        }
        return usage
    }

    private struct Summary: Decodable {
        struct Individual: Decodable { var plan: Plan? }
        struct Plan: Decodable {
            var autoPercentUsed: Double
            var apiPercentUsed: Double
        }

        var billingCycleEnd: String?
        var isUnlimited: Bool?
        var individualUsage: Individual?
        var autoModelSelectedDisplayMessage: String?
        var namedModelSelectedDisplayMessage: String?

        var usage: CursorUsage? {
            let resetsAt = billingCycleEnd.flatMap(Self.date)
            if isUnlimited == true {
                return CursorUsage(cursorModels: 0, otherModels: 0, resetsAt: resetsAt, isUnlimited: true)
            }
            if let plan = individualUsage?.plan {
                return CursorUsage(cursorModels: plan.autoPercentUsed, otherModels: plan.apiPercentUsed, resetsAt: resetsAt, isUnlimited: false)
            }
            // Team accounts carry no plan numbers, only prose like "You've used 42% of your included total usage".
            guard let auto = autoModelSelectedDisplayMessage.flatMap(Self.percent(in:)),
                  let named = namedModelSelectedDisplayMessage.flatMap(Self.percent(in:)) else { return nil }
            return CursorUsage(cursorModels: auto, otherModels: named, resetsAt: resetsAt, isUnlimited: false)
        }

        private static func date(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }

        private static func percent(in message: String) -> Double? {
            guard let sign = message.firstIndex(of: "%") else { return nil }
            let digits = message[..<sign].reversed().prefix { $0.isNumber || $0 == "." }
            return Double(String(digits.reversed()))
        }
    }

    private static func localAccessToken() -> String? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        let path = String(cString: home) + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        let uri = URL(fileURLWithPath: path).absoluteString
        return readToken(uri: uri + "?mode=ro") ?? readToken(uri: uri + "?immutable=1")
    }

    private static func readToken(uri: String) -> String? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        let token = String(cString: text).trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
        return token.isEmpty ? nil : token
    }

    private static func sessionCookie(for token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String,
              let user = subject.split(separator: "|").last, !user.isEmpty else { return nil }
        return "\(user)%3A%3A\(token)"
    }
}
