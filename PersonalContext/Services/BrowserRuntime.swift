import Foundation
import Observation
import os

struct BrowserCallContext: Sendable {
    var runID: UUID?
    var projectID: UUID?
    var persistentProfileID: UUID?
}

@MainActor
@Observable
final class BrowserActionGate {
    struct Request: Identifiable {
        var id = UUID()
        var kind: BrowserActionKind
        var host: String
        var detail: String
    }

    private(set) var request: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    func confirm(kind: BrowserActionKind, host: String, detail: String) async -> Bool {
        if let continuation {
            continuation.resume(returning: false)
            self.continuation = nil
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            request = Request(kind: kind, host: host, detail: detail)
        }
    }

    func respond(_ allowed: Bool) {
        request = nil
        continuation?.resume(returning: allowed)
        continuation = nil
    }

    func cancel() {
        respond(false)
    }
}

@MainActor
@Observable
final class BrowserRuntime {
    static let shared = BrowserRuntime()

    let store: BrowserSessionStore
    let actions = BrowserActionGate()
    private(set) var installLabel = ""
    private(set) var isInstalling = false
    private(set) var lastError: String?
    private(set) var challenge: BrowserChallenge?
    private(set) var activity: [UUID: BrowserActivityState] = [:]
    private(set) var sharedActivity = BrowserActivityState()
    var onActivity: ((UUID?, BrowserActivityEvent) -> Void)?

    private let pool = BrowserProcessPool()
    private var reapTask: Task<Void, Never>?
    private var selectedProfile: [UUID: UUID] = [:]

    init(store: BrowserSessionStore? = nil) {
        let store = store ?? BrowserSessionStore()
        self.store = store
        reapTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.pool.reapIdle(olderThan: store.idleSeconds)
            }
        }
    }

    var isReady: Bool { BrowserSupport.isReady }
    var profiles: [BrowserProfile] { store.profiles }
    var rememberedHosts: [String] { store.record.rememberedHosts }

    func warm() {
        guard !BrowserSupport.isReady else { return }
        Task { try? await prepare() }
    }

    func shutdown() {
        actions.cancel()
        resolveChallenge(open: false)
        reapTask?.cancel()
        Task { await pool.closeAll() }
    }

    func prepare() async throws {
        if BrowserSupport.isReady {
            lastError = nil
            return
        }
        if isInstalling {
            while isInstalling {
                try await Task.sleep(for: .milliseconds(200))
            }
            if BrowserSupport.isReady { return }
            throw BrowserSupportError(lastError ?? "The browser is still installing.")
        }
        isInstalling = true
        lastError = nil
        installLabel = "Preparing the browser"
        defer { isInstalling = false }
        do {
            try await bootstrapHelper()
            installLabel = "Ready"
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func bootstrapHelper() async throws {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "membrae-browser") else {
            throw BrowserSupportError("The browser helper is missing from the app.")
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--bootstrap-only"]
        process.environment = BrowserSupport.processEnvironment()
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let log = OSAllocatedUnfairLock(initialState: "")
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            log.withLock { $0 += text }
            if let line = text.split(whereSeparator: \.isNewline).last {
                let label = line.replacingOccurrences(of: "membrae-browser: ", with: "")
                if !label.isEmpty {
                    Task { @MainActor in
                        self?.installLabel = String(label)
                    }
                }
            }
        }
        do {
            try process.run()
        } catch {
            throw BrowserSupportError("Couldn’t start the browser helper: \(error.localizedDescription)")
        }
        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
        }
        errors.fileHandleForReading.readabilityHandler = nil
        let leftover = errors.fileHandleForReading.availableData
        if !leftover.isEmpty {
            log.withLock { $0 += String(decoding: leftover, as: UTF8.self) }
        }
        let lines = log.withLock { $0 }
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "membrae-browser: ", with: "") }
        guard status == 0, BrowserSupport.isReady else {
            let progress = Set(["Installing Chromium", "Ready", "Preparing the browser"])
            let detail = lines.last { !progress.contains($0) }
            throw BrowserSupportError(detail?.isEmpty == false ? detail! : "Couldn’t install the browser (helper exit \(status)).")
        }
    }

    func execute(name: String, arguments: [String: Any], context: BrowserCallContext = BrowserCallContext()) async throws -> String {
        try Task.checkCancellation()
        if name == "browser_sessions" {
            return try await manageSessions(arguments, context: context)
        }
        let started = Date()
        BrowserSupport.log("execute \(name) slot=\(slotKey(context: context)) \(BrowserSupport.clip(arguments))")
        ChatTrace.event("browser \(name) \(BrowserSupport.clip(arguments))")
        try await prepare()
        var arguments = arguments
        if name == "browser_search" {
            let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw BrowserSupportError("query is required.") }
            arguments["url"] = BrowserPermissions.searchURL(for: query)
        }
        let kind = BrowserPermissions.classify(tool: name, arguments: arguments)
        try await authorize(kind, arguments: arguments)
        let options = launchOptions(context: context, headed: false)
        let process = try await pool.process(
            for: slotKey(context: context),
            options: options,
            limit: store.maxConcurrentPages
        )
        let playwrightName = mappedTool(name)
        let data: Data
        do {
            data = try await process.call(name: playwrightName, arguments: arguments, options: options)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            BrowserSupport.log("execute \(name) fail ms=\(Int(Date().timeIntervalSince(started) * 1000)) \(error.localizedDescription)")
            ChatTrace.event("browser \(name) fail \(error.localizedDescription)")
            if isTimeout(error) {
                let host = BrowserPermissions.firstURL(in: arguments).map(BrowserChallengeDetector.host(from:)) ?? "the page"
                throw BrowserSupportError("The page on \(host) timed out. Try another source.")
            }
            throw error
        }
        let formatted = try MCPToolResult.format(data)
        if let url = currentURL(arguments: arguments, result: formatted),
           let detected = BrowserChallengeDetector.detect(text: formatted, url: url) {
            var next = detected
            next.runID = context.runID
            next.profileID = context.persistentProfileID ?? context.runID.flatMap { selectedProfile[$0] }
            challenge = next
            record(BrowserActivityEvent(runID: context.runID, summary: "Verification required on \(next.host)", url: url, host: next.host, pages: 0))
            return """
            Verification required on \(next.host). Do not try to bypass it.
            For research, try another source. If this website is necessary, the user can open a visible browser to verify, then continue.
            """
        }
        if let profileID = context.persistentProfileID ?? selectedProfile[context.runID ?? UUID()] {
            try? store.touch(profileID, host: BrowserPermissions.firstURL(in: arguments).map(BrowserChallengeDetector.host(from:)))
        }
        let event = BrowserActivity.summary(for: name, arguments: BrowserPermissions.redact(arguments), result: formatted)
        var tagged = event
        tagged.runID = context.runID
        record(tagged)
        BrowserSupport.log("execute \(name) ok ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return formatted
    }

    func cancel(runID: UUID) {
        selectedProfile[runID] = nil
        activity[runID] = nil
        if challenge?.runID == runID {
            challenge = nil
        }
        Task { await pool.close("run:\(runID.uuidString)") }
    }

    func openVerification() async throws {
        guard let challenge else { throw BrowserSupportError("There is no verification waiting.") }
        try await prepare()
        let context = BrowserCallContext(runID: challenge.runID, persistentProfileID: challenge.profileID)
        let options = launchOptions(context: context, headed: true)
        let process = try await pool.process(
            for: slotKey(context: context) + ":headed",
            options: options,
            limit: store.maxConcurrentPages
        )
        _ = try await process.call(
            name: "browser_navigate",
            arguments: ["url": challenge.url],
            options: options
        )
        record(BrowserActivityEvent(runID: challenge.runID, summary: "Opened verification on \(challenge.host)", url: challenge.url, host: challenge.host, pages: 0))
    }

    func finishVerification() {
        let runID = challenge?.runID
        challenge = nil
        if let runID {
            Task { await pool.close("run:\(runID.uuidString):headed") }
        }
    }

    func skipChallenge() {
        let runID = challenge?.runID
        challenge = nil
        record(BrowserActivityEvent(runID: runID, summary: "Skipped a blocked website", pages: 0))
    }

    func resolveChallenge(open: Bool) {
        if open {
            Task { try? await openVerification() }
        } else {
            skipChallenge()
        }
    }

    func headline(for runID: UUID?) -> String? {
        if let runID, let state = activity[runID] { return state.headline }
        if sharedActivity.events.isEmpty { return nil }
        return sharedActivity.headline
    }

    private func authorize(_ kind: BrowserActionKind, arguments: [String: Any]) async throws {
        let decision = BrowserPermissions.decision(for: kind, allowPrivateNetwork: store.allowPrivateNetwork)
        let host = BrowserPermissions.firstURL(in: arguments).map(BrowserChallengeDetector.host(from:)) ?? "this website"
        switch decision {
        case .allow:
            return
        case .block:
            throw BrowserPermissionDenied("Private-network addresses are blocked unless you allow them in Settings → Browser.")
        case .confirm:
            let allowed = await actions.confirm(
                kind: kind,
                host: host,
                detail: argumentSummary(BrowserPermissions.redact(arguments))
            )
            guard allowed else {
                throw BrowserPermissionDenied("The user declined \(kind.confirmationTitle.lowercased())")
            }
        }
    }

    private func manageSessions(_ arguments: [String: Any], context: BrowserCallContext) async throws -> String {
        let action = (arguments["action"] as? String ?? "list").lowercased()
        switch action {
        case "list":
            let rows = store.profiles.map { "\($0.name) · \($0.host.isEmpty ? "no remembered site" : $0.host)" }
            return rows.isEmpty ? "No stored browser sessions." : rows.joined(separator: "\n")
        case "use":
            let name = (arguments["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw BrowserSupportError("name is required.") }
            let profile = try store.upsertProfile(named: name)
            if let runID = context.runID {
                selectedProfile[runID] = profile.id
            }
            return "Using stored session “\(profile.name)”."
        case "reset":
            let name = (arguments["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let profile = store.profiles.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else {
                throw BrowserSupportError("No stored session named \(name).")
            }
            await pool.close("profile:\(profile.id.uuidString)")
            try store.reset(profile.id)
            return "Reset stored session “\(profile.name)”."
        default:
            throw BrowserSupportError("action must be list, use, or reset.")
        }
    }

    private func launchOptions(context: BrowserCallContext, headed: Bool) -> BrowserLaunchOptions {
        let profileID = context.persistentProfileID ?? context.runID.flatMap { selectedProfile[$0] }
        if let profileID, let profile = store.profiles.first(where: { $0.id == profileID }) {
            return BrowserLaunchOptions(
                headed: headed,
                isolated: false,
                userDataDir: store.profileDirectory(profile),
                outputDir: BrowserSupport.downloads
            )
        }
        return BrowserLaunchOptions(headed: headed, isolated: true, userDataDir: nil, outputDir: BrowserSupport.downloads)
    }

    private func slotKey(context: BrowserCallContext) -> String {
        if let profileID = context.persistentProfileID ?? context.runID.flatMap({ selectedProfile[$0] }) {
            return "profile:\(profileID.uuidString)"
        }
        if let runID = context.runID {
            return "run:\(runID.uuidString)"
        }
        return "chat"
    }

    private func mappedTool(_ name: String) -> String {
        switch name {
        case "browser_search", "browser_open": return "browser_navigate"
        case "browser_read": return "browser_snapshot"
        case "browser_screenshot": return "browser_take_screenshot"
        case "browser_fill": return "browser_type"
        case "browser_scroll": return "browser_press_key"
        default: return name
        }
    }

    private func record(_ event: BrowserActivityEvent) {
        if let runID = event.runID {
            var state = activity[runID] ?? BrowserActivityState()
            BrowserActivity.apply(event, to: &state)
            activity[runID] = state
        } else {
            BrowserActivity.apply(event, to: &sharedActivity)
        }
        onActivity?(event.runID, event)
    }

    private func currentURL(arguments: [String: Any], result: String) -> String? {
        if let url = BrowserPermissions.firstURL(in: arguments) { return url }
        for line in result.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.contains("http://") || text.contains("https://") {
                return text
            }
        }
        return nil
    }

    private func isTimeout(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("timeout") || text.contains("timed out")
    }

    private func argumentSummary(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return BrowserActivity.clip(text, 400)
    }
}
