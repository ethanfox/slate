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
        CodeReference.self,
        CodeReferenceEntry.self,
        AgentRun.self,
        TitleIndex.self,
        Space.self,
        SpaceType.self,
        SpaceRecord.self,
        SpaceEvent.self,
        PersonalFact.self,
        SpaceScreen.self
    ])

    /// Bump whenever a model or a stored property is added. A build that opens a store written by a
    /// newer schema drops the tables and columns it does not know, so older builds must refuse.
    static let schemaVersion = 3

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
    static let applicationGroupIdentifier = "NUF99UVUKB.com.ethanfox.PersonalContext"

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

    static var configuration: ModelConfiguration {
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
            try migrateAgentRunColumns(at: configuration.url)
            try migrateCodeReferenceOwnership(at: configuration.url)
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
        legacyBackfillIndexingMetadata(in: context)
        try backfillCodeReferenceOwnership(in: context)
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
        let spaceColumns = tableColumns(db, table: "ZSPACE")
        if !spaceColumns.isEmpty, !spaceColumns.contains("ZGRADIENTRAW") {
            try execIgnoringDuplicateColumn(db, "ALTER TABLE ZSPACE ADD COLUMN ZGRADIENTRAW VARCHAR DEFAULT ''")
        }
    }

    static func migrateAgentRunColumns(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw StoreMigrationError("Could not open \(url.lastPathComponent) to migrate AgentRun columns.")
        }
        defer { sqlite3_close(db) }
        let columns = tableColumns(db, table: "ZAGENTRUN")
        guard !columns.isEmpty else { return }
        if !columns.contains("ZPURPOSERAW") {
            try execIgnoringDuplicateColumn(db, "ALTER TABLE ZAGENTRUN ADD COLUMN ZPURPOSERAW VARCHAR DEFAULT 'general'")
        }
        if !columns.contains("ZINDEXEDATTACHMENTIDSTRING") {
            try execIgnoringDuplicateColumn(db, "ALTER TABLE ZAGENTRUN ADD COLUMN ZINDEXEDATTACHMENTIDSTRING VARCHAR DEFAULT ''")
        }
    }

    /// One-time repair for runs saved before the purpose columns existed.
    /// New launches persist purpose and attachment id in `RunStore.enqueue`.
    static func legacyBackfillIndexingMetadata(in context: ModelContext) {
        var changed = false
        for run in RunStore.runs(in: context) where run.purpose == .general && CodeReferenceStore.isIndexingBrief(run.brief) {
            run.purpose = .indexRepository
            if run.indexedAttachmentID == nil,
               let attachment = CodeReferenceStore.attachment(matching: run, in: context) {
                run.indexedAttachmentID = attachment.id
            }
            changed = true
        }
        if changed {
            try? context.save()
        }
    }

    /// Ownership lives on string ID columns, not SwiftData relationships.
    /// Add the columns and copy IDs from leftover relationship foreign keys.
    static func migrateCodeReferenceOwnership(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw StoreMigrationError("Could not open \(url.lastPathComponent) to migrate code-reference ownership.")
        }
        defer { sqlite3_close(db) }

        let referenceColumns = tableColumns(db, table: "ZCODEREFERENCE")
        if !referenceColumns.isEmpty, !referenceColumns.contains("ZATTACHMENTIDSTRING") {
            try execIgnoringDuplicateColumn(db, "ALTER TABLE ZCODEREFERENCE ADD COLUMN ZATTACHMENTIDSTRING VARCHAR DEFAULT ''")
        }
        if !referenceColumns.isEmpty, !referenceColumns.contains("ZSOURCEFRESHNESSRAW") {
            try execIgnoringDuplicateColumn(db, "ALTER TABLE ZCODEREFERENCE ADD COLUMN ZSOURCEFRESHNESSRAW VARCHAR DEFAULT ''")
        }
        let entryColumns = tableColumns(db, table: "ZCODEREFERENCEENTRY")
        if !entryColumns.isEmpty, !entryColumns.contains("ZREFERENCEIDSTRING") {
            try execIgnoringDuplicateColumn(db, "ALTER TABLE ZCODEREFERENCEENTRY ADD COLUMN ZREFERENCEIDSTRING VARCHAR DEFAULT ''")
        }

        if referenceColumns.contains("ZATTACHMENT") {
            try copyRelationshipUUIDs(
                db,
                update: "ZCODEREFERENCE",
                column: "ZATTACHMENTIDSTRING",
                join: "SELECT ref.Z_PK, att.ZID FROM ZCODEREFERENCE ref JOIN ZCODEATTACHMENT att ON ref.ZATTACHMENT = att.Z_PK WHERE ref.ZATTACHMENTIDSTRING IS NULL OR ref.ZATTACHMENTIDSTRING = ''"
            )
        }
        if entryColumns.contains("ZREFERENCE") {
            try copyRelationshipUUIDs(
                db,
                update: "ZCODEREFERENCEENTRY",
                column: "ZREFERENCEIDSTRING",
                join: "SELECT entry.Z_PK, ref.ZID FROM ZCODEREFERENCEENTRY entry JOIN ZCODEREFERENCE ref ON entry.ZREFERENCE = ref.Z_PK WHERE entry.ZREFERENCEIDSTRING IS NULL OR entry.ZREFERENCEIDSTRING = ''"
            )
        }
    }

    static func backfillCodeReferenceOwnership(in context: ModelContext) throws {
        var changed = false
        for reference in ((try? context.fetch(FetchDescriptor<CodeReference>())) ?? []) {
            if reference.attachmentIDString.isEmpty, let id = reference.attachmentID {
                reference.attachmentIDString = id.uuidString.lowercased()
                changed = true
            } else if !reference.attachmentIDString.isEmpty {
                let lowered = reference.attachmentIDString.lowercased()
                if reference.attachmentIDString != lowered {
                    reference.attachmentIDString = lowered
                    changed = true
                }
            }
        }
        for entry in ((try? context.fetch(FetchDescriptor<CodeReferenceEntry>())) ?? []) {
            if entry.referenceIDString.isEmpty, let id = entry.referenceID {
                entry.referenceIDString = id.uuidString.lowercased()
                changed = true
            } else if !entry.referenceIDString.isEmpty {
                let lowered = entry.referenceIDString.lowercased()
                if entry.referenceIDString != lowered {
                    entry.referenceIDString = lowered
                    changed = true
                }
            }
        }
        if changed {
            try context.save()
        }
    }

    private static func copyRelationshipUUIDs(
        _ db: OpaquePointer,
        update table: String,
        column: String,
        join sql: String
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let pk = sqlite3_column_int64(statement, 0)
            guard let uuid = uuidString(from: statement, column: 1) else { continue }
            try exec(db, "UPDATE \(table) SET \(column) = '\(uuid)' WHERE Z_PK = \(pk)")
        }
    }

    private static func uuidString(from statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_bytes(statement, column) == 16, let raw = sqlite3_column_blob(statement, column) else {
            return nil
        }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: 16)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString.lowercased()
    }

    static func persistedAgentRunIdentity(runID: UUID, at url: URL) -> (purpose: String, attachmentID: String)? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZID, ZPURPOSERAW, ZINDEXEDATTACHMENTIDSTRING FROM ZAGENTRUN", -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_bytes(statement, 0) == 16, let raw = sqlite3_column_blob(statement, 0) else { continue }
            let bytes = raw.bindMemory(to: UInt8.self, capacity: 16)
            let stored = UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
            guard stored == runID else { continue }
            let purpose = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let attachment = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            return (purpose, attachment)
        }
        return nil
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
