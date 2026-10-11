import Foundation

struct BrowserChallenge: Identifiable, Equatable, Sendable {
    var id = UUID()
    var host: String
    var url: String
    var runID: UUID?
    var profileID: UUID?
    var detectedAt = Date()
}

enum BrowserChallengeDetector {
    private static let signals = [
        "captcha",
        "hcaptcha",
        "recaptcha",
        "are you a robot",
        "i'm not a robot",
        "verify you are human",
        "verify you are not a robot",
        "unusual traffic",
        "attention required",
        "enable javascript and cookies",
        "checking your browser",
        "just a moment",
        "cf-browser-verification",
        "please complete the security check",
        "access denied",
        "sorry, you have been blocked",
        "additional verification required",
        "confirm you are human"
    ]

    static func host(from url: String) -> String {
        URL(string: url)?.host ?? url
    }

    static func detect(text: String, url: String) -> BrowserChallenge? {
        let lowered = text.lowercased()
        guard signals.contains(where: { lowered.contains($0) }) else { return nil }
        return BrowserChallenge(host: host(from: url), url: url)
    }
}
