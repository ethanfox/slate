import Foundation

enum BrowserActionKind: String, Sendable {
    case read
    case interact
    case authenticate
    case purchase
    case publish
    case download
    case upload
    case privateNetwork

    var defaultPolicy: BrowserPermissionDecision {
        switch self {
        case .read, .interact, .download: return .allow
        case .authenticate, .purchase, .publish, .upload: return .confirm
        case .privateNetwork: return .block
        }
    }

    var confirmationTitle: String {
        switch self {
        case .read: "Read this page?"
        case .interact: "Interact with this page?"
        case .authenticate: "Sign in on this website?"
        case .purchase: "Submit a purchase or payment?"
        case .publish: "Send or publish this content?"
        case .download: "Download this file?"
        case .upload: "Upload a local file?"
        case .privateNetwork: "Open a private-network address?"
        }
    }
}

enum BrowserPermissionDecision: String, Sendable {
    case allow
    case confirm
    case block
}

enum BrowserNetworkClass: String, Sendable {
    case publicWeb
    case privateNetwork
}

enum BrowserPermissions {
    static let hiddenTools: Set<String> = [
        "browser_install",
        "browser_close"
    ]

    static func networkClass(of raw: String) -> BrowserNetworkClass {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else {
            if looksLikePrivateHost(raw.lowercased()) { return .privateNetwork }
            return .publicWeb
        }
        if looksLikePrivateHost(host) { return .privateNetwork }
        if let address = IPv4(host), address.isPrivate { return .privateNetwork }
        return .publicWeb
    }

    static func classify(tool: String, arguments: [String: Any]) -> BrowserActionKind {
        if let url = firstURL(in: arguments), networkClass(of: url) == .privateNetwork {
            return .privateNetwork
        }
        switch tool {
        case "browser_file_upload":
            return .upload
        case "browser_download":
            return .download
        case "browser_search", "browser_navigate", "browser_navigate_back",
             "browser_snapshot", "browser_read", "browser_take_screenshot",
             "browser_console_messages", "browser_network_requests",
             "browser_tabs", "browser_sessions", "browser_wait_for", "browser_resize":
            return kind(forURL: firstURL(in: arguments)) ?? .read
        case "browser_evaluate":
            return .interact
        default:
            if let url = firstURL(in: arguments) {
                return kind(forURL: url) ?? .interact
            }
            if containsPassword(arguments) { return .authenticate }
            return .interact
        }
    }

    static func decision(for kind: BrowserActionKind, allowPrivateNetwork: Bool) -> BrowserPermissionDecision {
        if kind == .privateNetwork {
            return allowPrivateNetwork ? .confirm : .block
        }
        return kind.defaultPolicy
    }

    static func firstURL(in arguments: [String: Any]) -> String? {
        for key in ["url", "href", "start_url"] {
            if let value = arguments[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    static func searchURL(for query: String) -> String {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.string ?? "https://duckduckgo.com/"
    }

    static func isBrowserTool(_ name: String) -> Bool {
        name == "browser_search" || name == "browser_sessions" || name.hasPrefix("browser_")
    }

    static func redact(_ arguments: [String: Any]) -> [String: Any] {
        arguments.reduce(into: [:]) { result, item in
            let key = item.key.lowercased()
            if key.contains("password") || key.contains("cookie") || key.contains("secret") || key.contains("token") {
                result[item.key] = "••••"
            } else if let text = item.value as? String, looksLikeSecret(text) {
                result[item.key] = "••••"
            } else {
                result[item.key] = item.value
            }
        }
    }

    private static func kind(forURL raw: String?) -> BrowserActionKind? {
        guard let raw else { return nil }
        if networkClass(of: raw) == .privateNetwork { return .privateNetwork }
        let lowered = raw.lowercased()
        if matches(lowered, ["checkout", "payment", "paypal", "stripe.com", "/pay", "billing"]) {
            return .purchase
        }
        if matches(lowered, ["login", "signin", "sign-in", "auth", "oauth", "sso"]) {
            return .authenticate
        }
        if matches(lowered, ["/tweet", "/compose", "/post", "/publish", "mailto:"]) {
            return .publish
        }
        return nil
    }

    private static func containsPassword(_ arguments: [String: Any]) -> Bool {
        let blob = arguments.values.compactMap { $0 as? String }.joined(separator: " ").lowercased()
        return blob.contains("password") || blob.contains("passwd")
    }

    private static func looksLikeSecret(_ text: String) -> Bool {
        text.count >= 20 && text.range(of: #"^[A-Za-z0-9+/=_-]{20,}$"#, options: .regularExpression) != nil
    }

    private static func matches(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private static func looksLikePrivateHost(_ host: String) -> Bool {
        host == "localhost"
            || host == "127.0.0.1"
            || host == "0.0.0.0"
            || host == "::1"
            || host == "[::1]"
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".localhost")
            || host == "metadata.google.internal"
    }
}

private struct IPv4 {
    var octets: [UInt8]

    init?(_ host: String) {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { UInt8($0) }
        guard values.count == 4 else { return nil }
        octets = values
    }

    var isPrivate: Bool {
        switch octets[0] {
        case 10, 127: return true
        case 169: return octets[1] == 254
        case 172: return (16...31).contains(octets[1])
        case 192: return octets[1] == 168
        default: return false
        }
    }
}

struct BrowserPermissionDenied: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
