import Foundation
import SwiftData

enum CodeReferenceError: LocalizedError, Equatable {
    case notIndexingRun
    case runNotActive
    case attachmentMismatch
    case noStagedReference
    case invalidKey(String)
    case missingTitle
    case missingBody
    case coverageUnset
    case noEntries
    case missingSourceLocation
    case missingPath
    case pathMissing(String)
    case pathExcluded(String)
    case declarationMissing(String, String)
    case unknownRelatedKey(String)
    case sourceEditDenied
    case unrelatedWriteDenied
    case attachmentNotFound
    case entryNotFound
    case unpublished
    case publicationNotCommitted

    var errorDescription: String? {
        switch self {
        case .notIndexingRun:
            "Only an active indexing run can write this attachment’s code reference."
        case .runNotActive:
            "That indexing run is no longer active."
        case .attachmentMismatch:
            "This run can only write the staged reference for its own attachment."
        case .noStagedReference:
            "There is no staged code reference for this attachment."
        case .invalidKey(let key):
            "Entry key “\(key)” must be lowercase letters, numbers, and hyphens."
        case .missingTitle:
            "Each reference entry needs a title."
        case .missingBody:
            "Each reference entry needs a markdown explanation."
        case .coverageUnset:
            "Record coverage before the reference can be published."
        case .noEntries:
            "A published reference needs at least one entry."
        case .missingSourceLocation:
            "Each implementation reference entry needs at least one supporting source location."
        case .missingPath:
            "Each source location needs a path."
        case .pathMissing(let path):
            "Referenced path does not exist in the attachment: \(path)"
        case .pathExcluded(let path):
            "Referenced path is excluded from the architecture reference: \(path)"
        case .declarationMissing(let name, let path):
            "Declaration “\(name)” was not found in \(path)."
        case .unknownRelatedKey(let key):
            "Related entry “\(key)” does not exist in this reference."
        case .sourceEditDenied:
            "This run cannot edit source."
        case .unrelatedWriteDenied:
            "This run cannot change unrelated Slate records."
        case .attachmentNotFound:
            "No code attachment matches that id."
        case .entryNotFound:
            "No published reference entry matches that key."
        case .unpublished:
            "That code reference is not published."
        case .publicationNotCommitted:
            "The reference was not retrievable after save. It was not published."
        }
    }
}

enum CodeReferenceStore {
    static let excludedPathParts = [
        "/.git/", "/.build/", "/build/", "/DerivedData/", "/node_modules/",
        "/.swiftpm/", "/xcuserdata/", "/.env"
    ]

    static let keyPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

    static func references(on attachment: CodeAttachment, in context: ModelContext) -> [CodeReference] {
        references(attachmentID: attachment.id, in: context)
    }

    static func references(attachmentID: UUID, in context: ModelContext) -> [CodeReference] {
        let needle = attachmentID.uuidString.lowercased()
        let found = ((try? context.fetch(FetchDescriptor<CodeReference>())) ?? []).filter {
            $0.attachmentIDString.lowercased() == needle
        }
        return found.sorted { $0.createdAt < $1.createdAt }
    }

    static func reference(_ id: UUID, in context: ModelContext) -> CodeReference? {
        let descriptor = FetchDescriptor<CodeReference>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    static func entries(on reference: CodeReference, in context: ModelContext) -> [CodeReferenceEntry] {
        entries(referenceID: reference.id, in: context)
    }

    static func entries(referenceID: UUID, in context: ModelContext) -> [CodeReferenceEntry] {
        let needle = referenceID.uuidString.lowercased()
        return ((try? context.fetch(FetchDescriptor<CodeReferenceEntry>())) ?? []).filter {
            $0.referenceIDString.lowercased() == needle
        }
    }

    static func sortedEntries(on reference: CodeReference, in context: ModelContext) -> [CodeReferenceEntry] {
        entries(on: reference, in: context).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func published(on attachment: CodeAttachment, in context: ModelContext) -> CodeReference? {
        references(on: attachment, in: context).first { $0.publication == .published }
    }

    static func staged(on attachment: CodeAttachment, in context: ModelContext) -> CodeReference? {
        references(on: attachment, in: context).first { $0.publication == .staged }
    }

    static func locator(for attachment: CodeAttachment) -> String {
        attachment.locator.isEmpty ? attachment.title : attachment.locator
    }

    static func isIndexingBrief(_ brief: String) -> Bool {
        let text = brief.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.contains("produce an architecture reference")
            || text.hasPrefix("index repository ")
    }

    static func attachmentsOn(_ project: Project, in context: ModelContext) -> [CodeAttachment] {
        let id = project.id
        let found = ((try? context.fetch(FetchDescriptor<CodeAttachment>())) ?? []).filter { $0.project?.id == id }
        if !found.isEmpty { return found }
        return project.codeAttachments
    }

    static func attachment(_ id: UUID, in context: ModelContext) -> CodeAttachment? {
        let descriptor = FetchDescriptor<CodeAttachment>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    static func attachment(matching run: AgentRun, in context: ModelContext) -> CodeAttachment? {
        if let id = run.indexedAttachmentID, let found = attachment(id, in: context) {
            return found
        }
        let locators = Set(run.repositoryLocators)
        guard !locators.isEmpty else { return nil }
        let pool = run.project.map { attachmentsOn($0, in: context) }
            ?? ((try? context.fetch(FetchDescriptor<CodeAttachment>())) ?? [])
        return pool.first { attachment in
            locators.contains(locator(for: attachment))
                || locators.contains(attachment.title)
                || locators.contains(attachment.locator)
        }
    }

    static func activeIndexingRun(for attachment: CodeAttachment, in context: ModelContext) -> AgentRun? {
        RunStore.activeRuns(in: context).first {
            $0.purpose == .indexRepository && $0.indexedAttachmentID == attachment.id
        }
    }

    static func authorizeWrite(attachment: CodeAttachment, in context: ModelContext) throws -> (AgentRun, CodeReference) {
        guard let run = activeIndexingRun(for: attachment, in: context) else {
            throw CodeReferenceError.notIndexingRun
        }
        guard run.status.isActive else { throw CodeReferenceError.runNotActive }
        guard run.indexedAttachmentID == attachment.id else { throw CodeReferenceError.attachmentMismatch }
        guard let staged = staged(on: attachment, in: context), staged.originatingRunID == run.id else {
            throw CodeReferenceError.noStagedReference
        }
        return (run, staged)
    }

    static func beginStaging(
        for attachment: CodeAttachment,
        run: AgentRun,
        fingerprint: CodeSourceFingerprint,
        in context: ModelContext
    ) throws -> CodeReference {
        for existing in references(on: attachment, in: context) where existing.publication == .staged {
            existing.publication = .discarded
            existing.touch(runID: run.id)
        }
        let nextRevision = (published(on: attachment, in: context)?.revision ?? 0) + 1
        let reference = CodeReference(
            attachmentID: attachment.id,
            originatingRunID: run.id,
            fingerprint: fingerprint,
            revision: nextRevision
        )
        context.insert(reference)
        try save(context)
        return reference
    }

    static func upsertEntry(
        attachment: CodeAttachment,
        key: String,
        title: String,
        body: String,
        sourceLocations: [CodeSourceLocation],
        relatedKeys: [String],
        rootPath: String?,
        in context: ModelContext
    ) throws -> CodeReferenceEntry {
        let (run, reference) = try authorizeWrite(attachment: attachment, in: context)
        let key = try normalizedKey(key)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CodeReferenceError.missingTitle }
        guard !body.isEmpty else { throw CodeReferenceError.missingBody }
        let owned = entries(on: reference, in: context)
        let existing = owned.first(where: { $0.key == key })
        let cleaned = try cleanedLocations(sourceLocations)
        guard !cleaned.isEmpty else { throw CodeReferenceError.missingSourceLocation }
        let locations = attachProvenance(
            cleaned,
            existing: existing?.sourceLocations ?? [],
            runID: run.id,
            storeURL: context.container.configurations.first?.url
        )
        if let rootPath {
            try validateLocations(locations, rootPath: rootPath, requireDeclarations: true)
        }

        let entry: CodeReferenceEntry
        if let existing {
            existing.title = title
            existing.body = body
            existing.sourceLocations = locations
            existing.relatedKeys = cleanedKeys(relatedKeys)
            existing.sourceRevision = reference.sourceRevision
            existing.touch()
            entry = existing
        } else {
            entry = CodeReferenceEntry(
                key: key,
                title: title,
                body: body,
                sourceLocations: locations,
                relatedKeys: cleanedKeys(relatedKeys),
                sourceRevision: reference.sourceRevision,
                referenceID: reference.id
            )
            context.insert(entry)
        }
        reference.touch(runID: run.id)
        try save(context)
        return entry
    }

    static func updateMeta(
        attachment: CodeAttachment,
        coverage: CodeReferenceCoverage?,
        coverageNotes: String?,
        sourceRevision: String?,
        localChangesExamined: String?,
        in context: ModelContext
    ) throws -> CodeReference {
        let (run, reference) = try authorizeWrite(attachment: attachment, in: context)
        if let coverage { reference.coverage = coverage }
        if let coverageNotes { reference.coverageNotes = coverageNotes }
        if let sourceRevision, !sourceRevision.isEmpty { reference.sourceRevision = sourceRevision }
        if let localChangesExamined { reference.localChangesExamined = localChangesExamined }
        reference.touch(runID: run.id)
        try save(context)
        return reference
    }

    static func validate(_ reference: CodeReference, rootPath: String, in context: ModelContext) throws {
        guard reference.coverage != .unknown else { throw CodeReferenceError.coverageUnset }
        let entries = entries(on: reference, in: context)
        guard !entries.isEmpty else { throw CodeReferenceError.noEntries }
        let keys = Set(entries.map(\.key))
        for entry in entries {
            _ = try normalizedKey(entry.key)
            guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodeReferenceError.missingTitle
            }
            guard !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodeReferenceError.missingBody
            }
            try validateLocations(entry.sourceLocations, rootPath: rootPath, requireDeclarations: true)
            for related in entry.relatedKeys where !keys.contains(related) {
                throw CodeReferenceError.unknownRelatedKey(related)
            }
        }
    }

    static func publishIfValid(
        run: AgentRun,
        rootPath: String,
        currentFingerprint: CodeSourceFingerprint,
        in context: ModelContext
    ) throws -> CodeReference {
        guard run.purpose == .indexRepository else { throw CodeReferenceError.notIndexingRun }
        guard let attachmentID = run.indexedAttachmentID,
              let attachment = attachment(attachmentID, in: context)
        else { throw CodeReferenceError.attachmentNotFound }
        guard let staged = staged(on: attachment, in: context), staged.originatingRunID == run.id else {
            throw CodeReferenceError.noStagedReference
        }
        if let start = staged.startFingerprint,
           start.commitSHA != currentFingerprint.commitSHA || start.localChanges != currentFingerprint.localChanges {
            staged.sourceChangedDuringIndex = true
            if !staged.coverageNotes.contains("Source changed during indexing") {
                let note = "Source changed during indexing. This reference may not match the current tree."
                staged.coverageNotes = staged.coverageNotes.isEmpty
                    ? note
                    : staged.coverageNotes + "\n\n" + note
            }
        }
        staged.sourceRevision = currentFingerprint.commitSHA
        staged.localChangesExamined = currentFingerprint.localChanges
        try validate(staged, rootPath: rootPath, in: context)
        let freshness = evaluateFreshness(staged, rootPath: rootPath, in: context)
        staged.sourceFreshness = freshness
        if freshness == .changed || freshness == .missing || freshness == .mixed {
            staged.sourceChangedDuringIndex = true
            if !staged.coverageNotes.contains("Source changed") {
                let note = "Source changed during indexing. This reference may not match the current tree."
                staged.coverageNotes = staged.coverageNotes.isEmpty
                    ? note
                    : staged.coverageNotes + "\n\n" + note
            }
        }
        if let previous = published(on: attachment, in: context), previous.id != staged.id {
            previous.publication = .discarded
            previous.touch(runID: run.id)
        }
        staged.publication = .published
        staged.touch(runID: run.id)
        try save(context)
        return try committedPublished(id: staged.id, attachmentID: attachmentID, in: context)
    }

    static func committedPublished(id: UUID, attachmentID: UUID, in context: ModelContext) throws -> CodeReference {
        guard let found = reference(id, in: context),
              found.publication == .published,
              found.attachmentID == attachmentID,
              !entries(on: found, in: context).isEmpty
        else {
            throw CodeReferenceError.publicationNotCommitted
        }
        return found
    }

    static func discardStaged(for run: AgentRun, in context: ModelContext) {
        guard run.purpose == .indexRepository, let attachmentID = run.indexedAttachmentID else { return }
        guard let attachment = attachment(attachmentID, in: context) else { return }
        for staged in references(on: attachment, in: context)
        where staged.publication == .staged && staged.originatingRunID == run.id {
            staged.publication = .discarded
            staged.touch(runID: run.id)
        }
        try? save(context)
    }

    static func deleteOwnedReferences(for attachment: CodeAttachment, in context: ModelContext) {
        deleteReferences(attachmentID: attachment.id, in: context)
    }

    static func deleteReferences(attachmentID: UUID, in context: ModelContext) {
        for reference in references(attachmentID: attachmentID, in: context) {
            deleteReference(reference, in: context)
        }
    }

    static func deleteReference(_ reference: CodeReference, in context: ModelContext) {
        for entry in entries(on: reference, in: context) {
            context.delete(entry)
        }
        context.delete(reference)
    }

    static func deleteOwnedReferences(in project: Project, context: ModelContext) {
        for attachment in attachmentsOn(project, in: context) {
            deleteOwnedReferences(for: attachment, in: context)
        }
    }

    static func summaries(
        project: Project?,
        attachmentID: UUID?,
        in context: ModelContext
    ) -> [[String: Any]] {
        let attachments: [CodeAttachment]
        if let attachmentID {
            attachments = attachment(attachmentID, in: context).map { [$0] } ?? []
        } else if let project {
            attachments = attachmentsOn(project, in: context)
        } else {
            attachments = (try? context.fetch(FetchDescriptor<CodeAttachment>())) ?? []
        }
        return attachments
            .sorted { $0.createdAt < $1.createdAt }
            .map { summary(for: $0, in: context) }
    }

    static func summary(for attachment: CodeAttachment, in context: ModelContext) -> [String: Any] {
        let shown = inspectable(on: attachment, in: context)
        let published = shown?.publication == .published ? shown : published(on: attachment, in: context)
        let indexing = activeIndexingRun(for: attachment, in: context)
        let lastRun = latestIndexingRun(for: attachment, in: context)
        var shape: [String: Any] = [
            "attachment_id": attachment.id.uuidString,
            "project_id": attachment.project?.id.uuidString ?? "",
            "attachment_title": attachment.title.isEmpty ? attachment.locator : attachment.title,
            "kind": attachment.kind.rawValue,
            "locator": attachment.locator,
            "available": published != nil,
            "publication": shown?.publication.rawValue ?? "",
            "coverage": shown?.coverage.rawValue ?? "",
            "coverage_label": shown.map { coverageLabel($0) } ?? "No published reference",
            "revision": shown?.revision ?? 0,
            "source_revision": shown?.sourceRevision ?? "",
            "local_changes_examined": shown?.localChangesExamined ?? "",
            "source_changed_during_index": shown?.sourceChangedDuringIndex ?? false,
            "source_freshness": liveFreshness(shown, attachment: attachment, in: context).rawValue,
            "last_updated_at": shown.map { ISO8601DateFormatter().string(from: $0.lastUpdatedAt) } ?? "",
            "originating_run_id": shown?.originatingRunID.uuidString ?? "",
            "entry_count": shown.map { entries(on: $0, in: context).count } ?? 0,
            "entries": (shown.map { sortedEntries(on: $0, in: context) } ?? []).map { entry in
                [
                    "key": entry.key,
                    "title": entry.title,
                    "source_locations": entry.sourceLocations.map {
                        locationShape($0, rootPath: rootPath(for: attachment, storeURL: context.container.configurations.first?.url))
                    },
                    "related_keys": entry.relatedKeys
                ] as [String: Any]
            },
            "unpublished_reason": unpublishedReason(
                published: published,
                shown: shown,
                indexing: indexing,
                lastRun: lastRun,
                in: context
            )
        ]
        if let indexing {
            shape["indexing_run_id"] = indexing.id.uuidString
            shape["indexing_status"] = indexing.status.rawValue
        }
        if let lastRun {
            shape["last_indexing_run"] = [
                "id": lastRun.id.uuidString,
                "status": lastRun.status.rawValue,
                "status_detail": lastRun.statusDetail,
                "updated_at": ISO8601DateFormatter().string(from: lastRun.updatedAt)
            ]
        }
        return shape
    }

    static func publishedEntry(
        attachmentID: UUID,
        key: String,
        in context: ModelContext
    ) throws -> [String: Any] {
        guard let attachment = attachment(attachmentID, in: context) else {
            throw CodeReferenceError.attachmentNotFound
        }
        let needle = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let reference = inspectable(on: attachment, in: context) else {
            throw CodeReferenceError.unpublished
        }
        guard let entry = entries(on: reference, in: context).first(where: { $0.key == needle || $0.id.uuidString.lowercased() == needle }) else {
            throw CodeReferenceError.entryNotFound
        }
        let root = rootPath(for: attachment, storeURL: context.container.configurations.first?.url)
        return [
            "id": entry.id.uuidString,
            "key": entry.key,
            "title": entry.title,
            "body": entry.body,
            "source_locations": entry.sourceLocations.map { locationShape($0, rootPath: root) },
            "related_keys": entry.relatedKeys,
            "source_revision": entry.sourceRevision,
            "source_freshness": liveFreshness(reference, attachment: attachment, in: context).rawValue,
            "attachment_id": reference.attachmentID?.uuidString ?? attachment.id.uuidString,
            "reference_id": reference.id.uuidString,
            "revision": reference.revision,
            "publication": reference.publication.rawValue,
            "coverage": reference.coverage.rawValue,
            "coverage_label": coverageLabel(reference),
            "originating_run_id": reference.originatingRunID.uuidString
        ]
    }

    /// Published first, otherwise the newest staged or discarded reference that still has entries.
    static func inspectable(on attachment: CodeAttachment, in context: ModelContext) -> CodeReference? {
        let all = references(on: attachment, in: context)
        if let published = all.first(where: { $0.publication == .published }) { return published }
        return all
            .filter { $0.publication != .published }
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .first { !entries(on: $0, in: context).isEmpty }
    }

    static func latestIndexingRun(for attachment: CodeAttachment, in context: ModelContext) -> AgentRun? {
        RunStore.runs(in: context)
            .filter { matchesIndexing($0, attachment: attachment) }
            .max { $0.updatedAt < $1.updatedAt }
    }

    static func matchesIndexing(_ run: AgentRun, attachment: CodeAttachment) -> Bool {
        if run.indexedAttachmentID == attachment.id { return true }
        guard isIndexingBrief(run.brief) || run.purpose == .indexRepository else { return false }
        let locators = Set(run.repositoryLocators)
        return locators.contains(locator(for: attachment))
            || locators.contains(attachment.title)
            || locators.contains(attachment.locator)
    }

    private static func unpublishedReason(
        published: CodeReference?,
        shown: CodeReference?,
        indexing: AgentRun?,
        lastRun: AgentRun?,
        in context: ModelContext
    ) -> String {
        if published != nil { return "" }
        if let indexing {
            return "Indexing is \(indexing.status.rawValue)."
        }
        if let lastRun {
            let detail = lastRun.statusDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            switch lastRun.status {
            case .failed:
                return detail.isEmpty ? "The last indexing run failed." : "The last indexing run failed: \(detail)"
            case .cancelled:
                return "The last indexing run was cancelled."
            case .succeeded:
                if shown == nil || entries(on: shown!, in: context).isEmpty {
                    return "The last indexing run succeeded with no published output. Entries were never persisted."
                }
                return "The last indexing run succeeded, but no published reference is attached to this repository."
            case .queued, .running, .waiting:
                return "The last indexing run is \(lastRun.status.rawValue)."
            }
        }
        if let shown, shown.publication == .staged {
            return "A staged reference with \(entries(on: shown, in: context).count) entries has not been published yet."
        }
        if let shown, shown.publication == .discarded {
            return "The last reference was discarded (\(entries(on: shown, in: context).count) entries). It is still readable."
        }
        return "No published reference."
    }

    static func coverageLabel(_ reference: CodeReference) -> String {
        var parts = [reference.coverage.label]
        if reference.sourceChangedDuringIndex {
            parts.append("source changed during indexing")
        }
        switch reference.sourceFreshness {
        case .unknown, .current:
            break
        case .changed, .missing, .mixed:
            parts.append(reference.sourceFreshness.label)
        }
        if reference.coverage == .partial || reference.coverage == .inventory {
            parts.append("not comprehensive")
        }
        return parts.joined(separator: " · ")
    }

    static func rootPath(for attachment: CodeAttachment, storeURL: URL?) -> String? {
        switch attachment.kind {
        case .folder:
            if FileManager.default.fileExists(atPath: attachment.locator) {
                return attachment.locator
            }
            return nil
        case .github, .gitlab:
            guard let storeURL, let projectID = attachment.project?.id else { return nil }
            let url = storeURL.deletingLastPathComponent()
                .appendingPathComponent("Repositories", isDirectory: true)
                .appendingPathComponent(projectID.uuidString, isDirectory: true)
                .appendingPathComponent(attachment.id.uuidString, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }
    }

    static func normalizedKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard key.wholeMatch(of: keyPattern) != nil else { throw CodeReferenceError.invalidKey(raw) }
        return key
    }

    private static func cleanedKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for key in keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            output.append(trimmed)
        }
        return output
    }

    private static func cleanedLocations(_ locations: [CodeSourceLocation]) throws -> [CodeSourceLocation] {
        try locations.map { location in
            let path = location.path.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { throw CodeReferenceError.missingPath }
            let declaration = location.declaration?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CodeSourceLocation(
                path: path,
                declaration: (declaration?.isEmpty == false) ? declaration : nil,
                contentHash: nil
            )
        }
    }

    static func attachProvenance(
        _ locations: [CodeSourceLocation],
        existing: [CodeSourceLocation],
        runID: UUID,
        storeURL: URL?
    ) -> [CodeSourceLocation] {
        let previous = Dictionary(
            existing.compactMap { location -> (String, String)? in
                guard let hash = location.contentHash, !hash.isEmpty else { return nil }
                return (CodeReadProvenance.normalize(location.path), hash)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        return locations.map { location in
            let trusted = CodeReadProvenance.hash(runID: runID, path: location.path, storeURL: storeURL)
                ?? previous[CodeReadProvenance.normalize(location.path)]
            return CodeSourceLocation(
                path: location.path,
                declaration: location.declaration,
                contentHash: trusted
            )
        }
    }

    static func evaluateFreshness(
        _ reference: CodeReference,
        rootPath: String,
        in context: ModelContext
    ) -> CodeSourceFreshness {
        let states = entries(on: reference, in: context).flatMap(\.sourceLocations).map {
            CodeContentHash.freshness(of: $0, rootPath: rootPath)
        }
        return CodeContentHash.rollup(states)
    }

    static func liveFreshness(
        _ reference: CodeReference?,
        attachment: CodeAttachment,
        in context: ModelContext
    ) -> CodeSourceFreshness {
        guard let reference else { return .unknown }
        guard let root = rootPath(for: attachment, storeURL: context.container.configurations.first?.url) else {
            return reference.sourceFreshness
        }
        return evaluateFreshness(reference, rootPath: root, in: context)
    }

    static func validateLocations(
        _ locations: [CodeSourceLocation],
        rootPath: String,
        requireDeclarations: Bool
    ) throws {
        guard !locations.isEmpty else { throw CodeReferenceError.missingSourceLocation }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        for location in locations {
            if isExcluded(location.path) { throw CodeReferenceError.pathExcluded(location.path) }
            let file = root.appendingPathComponent(location.path).standardizedFileURL
            guard file.path == root.path || file.path.hasPrefix(root.path + "/") else {
                throw CodeReferenceError.pathMissing(location.path)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw CodeReferenceError.pathMissing(location.path)
            }
            if requireDeclarations, let declaration = location.declaration, !declaration.isEmpty {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                guard text.contains(declaration) else {
                    throw CodeReferenceError.declarationMissing(declaration, location.path)
                }
            }
        }
    }

    static func isExcluded(_ path: String) -> Bool {
        let needle = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return excludedPathParts.contains { needle.contains($0) } || path.hasPrefix(".env")
    }

    static func locationShape(_ location: CodeSourceLocation, rootPath: String? = nil) -> [String: Any] {
        var shape: [String: Any] = ["path": location.path]
        if let declaration = location.declaration, !declaration.isEmpty {
            shape["declaration"] = declaration
        }
        if let hash = location.contentHash, !hash.isEmpty {
            shape["content_hash"] = hash
        }
        if let rootPath {
            shape["freshness"] = CodeContentHash.freshness(of: location, rootPath: rootPath).rawValue
        } else {
            shape["freshness"] = CodeSourceFreshness.unknown.rawValue
        }
        return shape
    }

    private static func save(_ context: ModelContext) throws {
        context.autosaveEnabled = false
        try context.save()
    }
}
