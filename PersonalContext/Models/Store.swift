import Foundation
import SQLite3
import SwiftData

/// The app and the MCP server open the same store. Both carry the same App Group
/// entitlement, so SwiftData places it in that group's container for either process.
enum StoreOpenMode: Sendable {
    /// First launch: schema columns, backfills, product-name rewrite, asset cleanup.
    case prepare
    /// After an external writer saved. Skip full-table work.
    case reopen
}

enum Store {
    /// Darwin notification posted by the MCP server after it saves, so a running app can refetch.
    static let changedNotification = "com.ethanfox.PersonalContext.storeChanged"

    /// Wait for a burst of MCP writes to finish before remounting the UI.
    static let reloadDebounce: Duration = .milliseconds(800)
    /// Keep the previous container only long enough for in-flight SwiftData faults.
    static let retireDelay: Duration = .milliseconds(400)

    static func announceChange() {
        // A test run writes to its own store. Telling the real app to reload would remount its
        // window and lose whatever the user was typing.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(changedNotification as CFString),
            nil, nil, true
        )
    }

    static let schema = Schema([
        Project.self,
        ProjectThread.self,
        Note.self,
        Decision.self,
        Conversation.self,
        ChatMessage.self,
        StoredAsset.self,
        AssetReference.self,
        Tag.self,
        AgendaItem.self,
        AgendaTrackLink.self,
        AgendaNoteLink.self,
        TaskCompletion.self,
        TaskDependency.self,
        DeletionMark.self,
        CodeAttachment.self,
        AgentRun.self,
        TitleIndex.self,
        Space.self,
        SpaceType.self,
        SpaceRecord.self,
        SpaceEvent.self,
        PersonalFact.self,
        AgentAction.self,
        SavedSource.self,
        Pin.self,
        AreaWidget.self,
        TrackStop.self,
        TrackTheme.self
    ])

    /// Bump whenever a model or a stored property is added. A build that opens a store written by a
    /// newer schema drops the tables and columns it does not know, so older builds must refuse.
    static let schemaVersion = 18

    /// Sits beside the store and holds the highest schema version that has opened it.
    static func schemaMarkerURL(for store: URL) -> URL {
        store.appendingPathExtension("schema")
    }

    static func recordedSchemaVersion(for store: URL) -> Int {
        guard let raw = try? String(contentsOf: schemaMarkerURL(for: store), encoding: .utf8) else { return 0 }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Throws when a newer build has already opened this store.
    static func refuseIfOutdated(at store: URL, running version: Int = schemaVersion) throws {
        let recorded = recordedSchemaVersion(for: store)
        guard recorded <= version else {
            throw StoreMigrationError(
                "This copy of Membrae is older than its data (schema \(version), data \(recorded)). "
                    + "It will not open the store, because doing so would delete newer records. "
                    + "Quit it and start the current build."
            )
        }
    }

    private static func recordSchemaVersion(at store: URL, running version: Int) {
        guard recordedSchemaVersion(for: store) < version else { return }
        try? String(version).write(to: schemaMarkerURL(for: store), atomically: true, encoding: .utf8)
    }

    /// Same identifier the app and membrae-mcp declare in their entitlements.
    static let applicationGroupIdentifier = "Z85NB2ZYMN.com.ethanfox.PersonalContext"

    static var applicationGroupStoreURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: applicationGroupIdentifier)?
            .appendingPathComponent("Library/Application Support/default.store")
    }

    static func productSupportDirectory(
        in root: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL {
        let directory = root ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let current = directory.appendingPathComponent("Membrae", isDirectory: true)
        let legacy = directory.appendingPathComponent("Slate", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        return current
    }

    static func marker(_ name: String, in directory: URL) -> URL {
        let current = directory.appendingPathComponent(name)
        let legacy = directory.appendingPathComponent(name.replacingOccurrences(of: ".membrae-", with: ".slate-"))
        let fm = FileManager.default
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        return current
    }

    static func commitsFile(in directory: URL) -> URL {
        marker(".membrae-commits.json", in: directory)
    }

    static func snapshotFile(in directory: URL) -> URL {
        marker(".membrae-snapshot", in: directory)
    }

    static func rewriteProductNames(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "slate://", with: "membrae://")
            .replacingOccurrences(of: "<!--slate:", with: "<!--membrae:")
    }

    static func migrateProductNames(in context: ModelContext) {
        var changed = false
        let messages = (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? []
        for message in messages {
            let updated = rewriteProductNames(message.content)
            if updated != message.content {
                message.content = updated
                changed = true
            }
        }
        for run in RunStore.runs(in: context) {
            let updated = rewriteProductNames(run.resultLinksJSON)
            if updated != run.resultLinksJSON {
                run.resultLinksJSON = updated
                changed = true
            }
        }
        if changed {
            try? context.save()
        }
    }

    /// True inside the app when it is only hosting the unit tests.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var configuration: ModelConfiguration {
        // The tests run inside the app. It must not open, migrate, or write the user's store for them.
        if isHostingTests {
            return ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        if let url = applicationGroupStoreURL {
            return ModelConfiguration(schema: schema, url: url)
        }
        return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    }

    static func open(mode: StoreOpenMode = .prepare) throws -> ModelContainer {
        try open(configuration: configuration, mode: mode)
    }

    static func open(
        url: URL,
        mode: StoreOpenMode = .prepare,
        schemaVersion: Int = Store.schemaVersion
    ) throws -> ModelContainer {
        try open(configuration: ModelConfiguration(schema: schema, url: url), mode: mode, schemaVersion: schemaVersion)
    }

    private static func open(
        configuration: ModelConfiguration,
        mode: StoreOpenMode,
        schemaVersion: Int = Store.schemaVersion
    ) throws -> ModelContainer {
        if !configuration.isStoredInMemoryOnly {
            // Before the container exists: creating it is what migrates the file.
            try refuseIfOutdated(at: configuration.url, running: schemaVersion)
            try migrateTagColumns(at: configuration.url)
            try migrateSpaceOwnerColumns(at: configuration.url)
        }
        let start = ContinuousClock.now
        let container = try ModelContainer(for: schema, configurations: configuration)
        if !configuration.isStoredInMemoryOnly {
            recordSchemaVersion(at: configuration.url, running: schemaVersion)
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard mode == .prepare else {
            // A helper built before the title index existed drops its table when it saves.
            TitleIndexStore.backfillIfNeeded(in: context)
            NavTrace.event("store.open mode=reopen \(NavTrace.elapsed(start))")
            return container
        }
        migrateProductNames(in: context)
        TagStore.mergeDuplicates(in: context)
        TitleIndexStore.backfillIfNeeded(in: context)
        try? FileStore.default(context: context).cleanup()
        NavTrace.event("store.open mode=prepare \(NavTrace.elapsed(start))")
        return container
    }

    @MainActor
    static func disableAutosave(_ container: ModelContainer) {
        container.mainContext.autosaveEnabled = false
    }

    /// Existing stores created before indexing may lack these columns. Safe to
    /// call on every open: ADD COLUMN runs only when the name is missing, and a
    /// duplicate-column error is ignored.
    static func migrateTagColumns(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var peek: OpaquePointer?
        guard sqlite3_open_v2(url.path, &peek, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let peek else {
            return
        }
        let columns = tableColumns(peek, table: "ZTAG")
        sqlite3_close(peek)
        guard !columns.isEmpty, !columns.contains("ZCOLORRAW") else { return }

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        try execIgnoringDuplicateColumn(db, "ALTER TABLE ZTAG ADD COLUMN ZCOLORRAW VARCHAR DEFAULT ''")
    }

    /// Built-in records gained a Space owner column. Add it to stores created before Spaces.
    static func migrateSpaceOwnerColumns(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw StoreMigrationError("Could not open \(url.lastPathComponent) to migrate Space owner columns.")
        }
        defer { sqlite3_close(db) }
        for table in ["ZPROJECTTHREAD", "ZNOTE", "ZDECISION", "ZCONVERSATION", "ZAGENDAITEM", "ZAGENTRUN"] {
            let columns = tableColumns(db, table: table)
            guard !columns.isEmpty, !columns.contains("ZSPACEIDSTRING") else { continue }
            try execIgnoringDuplicateColumn(db, "ALTER TABLE \(table) ADD COLUMN ZSPACEIDSTRING VARCHAR DEFAULT ''")
        }
        let recordColumns = tableColumns(db, table: "ZSPACERECORD")
        if !recordColumns.isEmpty, !recordColumns.contains("ZISARCHIVED") {
            try execIgnoringDuplicateColumn(db, "ALTER TABLE ZSPACERECORD ADD COLUMN ZISARCHIVED INTEGER DEFAULT 0")
        }
        let spaceColumns = tableColumns(db, table: "ZSPACE")
        if !spaceColumns.isEmpty, !spaceColumns.contains("ZGRADIENTRAW") {
            try execIgnoringDuplicateColumn(db, "ALTER TABLE ZSPACE ADD COLUMN ZGRADIENTRAW VARCHAR DEFAULT ''")
        }
        let factColumns = tableColumns(db, table: "ZPERSONALFACT")
        if !factColumns.isEmpty, !factColumns.contains("ZORIGIN") {
            try execIgnoringDuplicateColumn(db, "ALTER TABLE ZPERSONALFACT ADD COLUMN ZORIGIN VARCHAR DEFAULT ''")
        }
    }

    private static func tableColumns(_ db: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: raw).uppercased())
            }
        }
        return names
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let detail = sqlite3_errmsg(db).map { String(cString: $0) } ?? sql
            throw StoreMigrationError(detail)
        }
    }

    private static func execIgnoringDuplicateColumn(_ db: OpaquePointer, _ sql: String) throws {
        do {
            try exec(db, sql)
        } catch {
            let detail = error.localizedDescription.lowercased()
            if detail.contains("duplicate column") { return }
            throw error
        }
    }
}

struct StoreMigrationError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// WAL-aware mtimes so the MCP helper can tell app writes from its own.
struct StoreFileStamp: Equatable {
    let values: [String: TimeInterval]

    init(url: URL?) {
        guard let url else {
            values = [:]
            return
        }
        let fm = FileManager.default
        values = [url.path, url.path + "-wal", url.path + "-shm"].reduce(into: [:]) { result, path in
            if let date = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) {
                result[path] = date.timeIntervalSinceReferenceDate
            }
        }
    }
}

/// Cursor keeps membrae-mcp for hours. Reuse one container and reopen only when the app wrote.
enum MCPStoreSession {
    private static var held: ModelContainer?
    private static var stamp: StoreFileStamp?
    private static var url: URL?

    static func container(at url: URL? = Store.applicationGroupStoreURL) throws -> ModelContainer {
        // A helper can outlive several app builds. Check on every call, not only on open.
        if let url {
            do {
                try Store.refuseIfOutdated(at: url)
            } catch {
                held = nil
                throw error
            }
        }
        let current = StoreFileStamp(url: url)
        if let held, self.url == url, stamp == current {
            return held
        }
        let mode: StoreOpenMode = held == nil ? .prepare : .reopen
        let opened = if let url {
            try Store.open(url: url, mode: mode)
        } else {
            try Store.open(mode: mode)
        }
        held = opened
        self.url = url
        stamp = StoreFileStamp(url: url)
        return opened
    }

    static func noteLocalWrite(at url: URL? = Store.applicationGroupStoreURL) {
        stamp = StoreFileStamp(url: url)
        self.url = url
    }

    static func reset() {
        held = nil
        stamp = nil
        url = nil
    }
}
