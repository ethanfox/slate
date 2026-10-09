import Foundation
import SQLite3
import SwiftData

/// The app and the MCP server open the same store. Both carry the same App Group
/// entitlement, so SwiftData places it in that group's container for either process.
enum Store {
    /// Darwin notification posted by the MCP server after it saves, so a running app can refetch.
    static let changedNotification = "com.ethanfox.PersonalContext.storeChanged"

    static let schema = Schema([
        Project.self,
        ProjectThread.self,
        Note.self,
        Decision.self,
        Conversation.self,
        ChatMessage.self,
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
        AgentRun.self
    ])

    /// Same identifier the app and slate-mcp declare in their entitlements.
    static let applicationGroupIdentifier = "NUF99UVUKB.com.ethanfox.PersonalContext"

    static var applicationGroupStoreURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: applicationGroupIdentifier)?
            .appendingPathComponent("Library/Application Support/default.store")
    }

    static var configuration: ModelConfiguration {
        if let url = applicationGroupStoreURL {
            return ModelConfiguration(schema: schema, url: url)
        }
        return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    }

    static func open() throws -> ModelContainer {
        try open(configuration: configuration)
    }

    static func open(url: URL) throws -> ModelContainer {
        try open(configuration: ModelConfiguration(schema: schema, url: url))
    }

    private static func open(configuration: ModelConfiguration) throws -> ModelContainer {
        if !configuration.isStoredInMemoryOnly {
            try migrateAgentRunColumns(at: configuration.url)
            try migrateCodeReferenceOwnership(at: configuration.url)
        }
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        legacyBackfillIndexingMetadata(in: context)
        try backfillCodeReferenceOwnership(in: context)
        return container
    }

    @MainActor
    static func disableAutosave(_ container: ModelContainer) {
        container.mainContext.autosaveEnabled = false
    }

    /// Existing stores created before indexing may lack these columns. Safe to
    /// call on every open: ADD COLUMN runs only when the name is missing, and a
    /// duplicate-column error is ignored.
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
