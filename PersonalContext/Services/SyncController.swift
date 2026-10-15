import Foundation
import SwiftData

enum SyncStatus: Equatable {
    /// Nothing to do: no Space is synced, or there is no key to sign in with.
    case idle(String)
    case syncing
    case synced(Date)
    case failed(String)

    var label: String {
        switch self {
        case .idle(let reason): reason
        case .syncing: "Syncing…"
        case .synced(let at): "Synced \(at.formatted(date: .omitted, time: .shortened))"
        case .failed(let message): message
        }
    }
}

/// What the Mac sends up in one push.
struct SyncPushBody: Codable {
    var v = 1
    var device: String
    var changes: [SyncRecord]
}

struct SyncPushReply: Codable {
    var accepted: Int
    var cursor: Int
}

/// What comes down in one pull: changes other devices and services made, and where to pull from next.
struct SyncPullReply: Codable {
    var changes: [SyncRecord]
    var cursor: Int
}

/// Decides what goes up: changes in synced Spaces, and the records outside any Space that belong
/// to the user rather than this device, once any Space is synced.
enum SyncPlanner {
    /// Kinds with no Space that still sync, because they are the user's and not the device's.
    static let spacelessKinds: Set<ChangeKind> = [.tag, .source, .fact]

    static func syncedSpaceIDs(in context: ModelContext) -> Set<String> {
        let spaces = (try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.isSynced }))) ?? []
        return Set(spaces.map { SpaceJSON.key($0.id) })
    }

    /// The records to send for every change after `sequence`, oldest first, with the sequence the
    /// cursor moves to once they are accepted. A change in a local Space is passed over.
    static func outgoing(after sequence: Int, limit: Int = 200, in context: ModelContext) -> (records: [SyncRecord], through: Int) {
        let changes = ChangeLog.changes(after: sequence, in: context)
        guard !changes.isEmpty else { return ([], sequence) }
        let spaces = syncedSpaceIDs(in: context)
        var records: [SyncRecord] = []
        var through = sequence
        for change in changes {
            if records.count >= limit { break }
            through = change.sequence
            guard shouldSync(change, spaces: spaces) else { continue }
            if let record = SyncCodec.record(for: change, in: context) {
                records.append(record)
            }
        }
        return (records, through)
    }

    static func shouldSync(_ change: RecordChange, spaces: Set<String>) -> Bool {
        guard !spaces.isEmpty else { return false }
        if change.spaceIDString.isEmpty {
            return change.kind.map(spacelessKinds.contains) ?? false
        }
        return spaces.contains(change.spaceIDString)
    }

    /// Applies what came down, in order. The losing side of a conflict is written to the action log
    /// so it shows in Lately. Returns how many were applied.
    static func apply(_ records: [SyncRecord], unsentAfter pushed: Int, in context: ModelContext) -> Int {
        var applied = 0
        for record in records {
            let outcome = SyncCodec.apply(record, unsentAfter: pushed, in: context)
            switch outcome {
            case .applied, .deleted:
                applied += 1
            case .keptLocal:
                noteConflict(record, kept: "this Mac", in: context)
            case .skipped(let reason):
                NavTrace.event("sync.skip \(record.kind) \(record.id): \(reason)")
            }
        }
        return applied
    }

    private static func noteConflict(_ record: SyncRecord, kept: String, in context: ModelContext) {
        guard let id = record.targetID else { return }
        let title = TitleIndexStore.row(id, in: context)?.title ?? ""
        context.insert(AgentAction(
            tool: "sync",
            verb: .changed,
            kind: record.kind,
            targetID: record.id,
            title: title,
            detail: "Edited in two places; the edit on \(kept) was later and was kept.",
            spaceID: record.spaceID,
            origin: ActionOrigin(client: record.origin.isEmpty ? "cloud" : record.origin)
        ))
    }
}

/// Keeps the Mac and the user's database in Cloudflare the same: pushes the change record, then
/// pulls what others wrote. Runs on wake, on foreground, every few minutes, and on Sync now.
@MainActor
@Observable
final class SyncController {
    private(set) var status: SyncStatus = .idle("Nothing is synced")
    private(set) var pushedSequence: Int
    private(set) var pulledCursor: Int
    private(set) var lastPushed = 0
    private(set) var lastPulled = 0
    let deviceID: String

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var session = URLSession(configuration: .ephemeral)

    static let interval: Duration = .seconds(180)

    private enum Keys {
        static let pushed = "sync.pushedSequence"
        static let pulled = "sync.pulledCursor"
        static let device = "sync.deviceID"
        /// The account the cursors belong to. A different account is a different database.
        static let account = "sync.accountID"
    }

    init() {
        let defaults = UserDefaults.standard
        pushedSequence = defaults.integer(forKey: Keys.pushed)
        pulledCursor = defaults.integer(forKey: Keys.pulled)
        if let id = defaults.string(forKey: Keys.device), !id.isEmpty {
            deviceID = id
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: Keys.device)
        }
    }

    func attach(_ app: AppModel) {
        self.app = app
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func handleWake() { syncSoon() }
    func handleForeground() { syncSoon() }

    func syncSoon() {
        Task { await sync() }
    }

    /// One cycle: save what is pending, push, pull, apply. Overlapping calls fold into the one running.
    func sync() async {
        guard !running, let app else { return }
        let context = app.container.mainContext
        guard !SyncPlanner.syncedSpaceIDs(in: context).isEmpty else {
            status = .idle("Nothing is synced")
            return
        }
        // Every request carries the key this device holds from the account; the account names
        // the database in Cloudflare.
        guard app.account.isSignedIn, let key = app.account.deviceKey else {
            status = .idle("Sign in to sync")
            return
        }
        running = true
        defer { running = false }
        status = .syncing
        startOverIfAccountChanged(app.account.accountID)
        do {
            if context.hasChanges { try context.persist() }
            try await push(key: key, context: context)
            try await pull(key: key, context: context)
            status = .synced(.now)
            app.flash(lastPushed == 0 && lastPulled == 0 ? "Synced. Nothing new to send." : "Synced: sent \(lastPushed), received \(lastPulled).")
        } catch {
            status = .failed(error.localizedDescription)
            NavTrace.event("sync.failed \(error.localizedDescription)")
            app.flash("Sync failed: \(error.localizedDescription)")
        }
    }

    private var endpoint: String {
        (app?.importRelay.endpoint ?? ImportKeyStore.defaultRelayURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func push(key: String, context: ModelContext) async throws {
        var sent = 0
        while true {
            let (records, through) = SyncPlanner.outgoing(after: pushedSequence, in: context)
            guard through > pushedSequence else { break }
            if !records.isEmpty {
                let body = SyncPushBody(device: deviceID, changes: records)
                let reply: SyncPushReply = try await send("POST", path: "/sync/push", key: key, body: SyncCodec.json.encode(body))
                sent += reply.accepted
            }
            setPushed(through)
        }
        lastPushed = sent
    }

    private func pull(key: String, context: ModelContext) async throws {
        var received = 0
        while true {
            let reply: SyncPullReply = try await send("GET", path: "/sync/pull?since=\(pulledCursor)&device=\(deviceID)", key: key)
            guard !reply.changes.isEmpty || reply.cursor > pulledCursor else { break }
            let before = ChangeLog.latestSequence(in: context)
            ChangeLog.recording(as: "cloud") {
                received += SyncPlanner.apply(reply.changes, unsentAfter: pushedSequence, in: context)
            }
            try context.persist()
            // What was just applied came from Cloudflare, so its rows need no push.
            let after = ChangeLog.latestSequence(in: context)
            if after > before, pushedSequence == before { setPushed(after) }
            pulledCursor = reply.cursor
            UserDefaults.standard.set(pulledCursor, forKey: Keys.pulled)
            if reply.changes.isEmpty { break }
        }
        lastPulled = received
    }

    /// The database in Cloudflare is named after the account, so a different account is a
    /// different database: push everything again from the start and pull from the start.
    private func startOverIfAccountChanged(_ accountID: String) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Keys.account) ?? ""
        if !previous.isEmpty, previous != accountID {
            setPushed(0)
            pulledCursor = 0
            defaults.set(0, forKey: Keys.pulled)
            NavTrace.event("sync.account-changed cursors reset")
        }
        if previous != accountID { defaults.set(accountID, forKey: Keys.account) }
    }

    private func setPushed(_ sequence: Int) {
        pushedSequence = sequence
        UserDefaults.standard.set(sequence, forKey: Keys.pushed)
    }

    private func send<Reply: Decodable>(_ method: String, path: String, key: String, body: Data? = nil) async throws -> Reply {
        guard let url = URL(string: endpoint + path) else { throw SyncError("Bad sync address") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceID, forHTTPHeaderField: "X-Membrae-Device")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError("No reply from sync") }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError("Sync answered \(http.statusCode)")
        }
        return try SyncCodec.jsonDecoder.decode(Reply.self, from: data)
    }
}

struct SyncError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
