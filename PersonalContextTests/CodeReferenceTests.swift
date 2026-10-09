import SwiftData
import XCTest
@testable import Slate

@MainActor
final class CodeReferenceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
        fixtureRoot = try makeFixture()
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    func testTasklessIndexingRunIsScopedToAttachment() throws {
        let (project, attachment) = seedProject()
        let draft = RepositoryIndex.draft(
            for: attachment,
            project: project,
            providerID: "cursor",
            modelID: "auto"
        )
        XCTAssertNil(draft.taskID)
        XCTAssertEqual(draft.purpose, .indexRepository)
        XCTAssertEqual(draft.indexedAttachmentID, attachment.id)
        XCTAssertEqual(draft.repositoryLocators, [attachment.locator])
        XCTAssertEqual(draft.origin, .project)

        let run = try RunStore.enqueue(draft, in: context)
        XCTAssertNil(run.task)
        XCTAssertEqual(run.purpose, .indexRepository)
        XCTAssertEqual(run.indexedAttachmentID, attachment.id)
        XCTAssertEqual(run.project?.id, project.id)
        XCTAssertEqual(run.repositoryLocators, [attachment.locator])
        XCTAssertEqual(run.status, .queued)
        let tools = RunToolPolicy.catalogNames(for: run)
        XCTAssertTrue(tools.contains("upsert_code_reference_entry"))
        XCTAssertTrue(tools.contains("set_code_reference_meta"))
    }

    func testIndexingPolicyDeniesSourceEditsAndUnrelatedWrites() {
        let attachmentID = UUID()
        let policy = RunToolPolicy.indexing(runID: UUID(), projectID: UUID(), attachmentID: attachmentID)
        XCTAssertTrue(policy.allows("project_read_file"))
        XCTAssertTrue(policy.allows("upsert_code_reference_entry"))
        XCTAssertTrue(policy.allows("set_code_reference_meta"))
        XCTAssertTrue(policy.allows("list_code_references"))
        XCTAssertTrue(policy.allows("finish_run"))
        XCTAssertFalse(policy.allows("create_note"))
        XCTAssertFalse(policy.allows("list_notes"))
        XCTAssertFalse(policy.allows("create_task"))
        XCTAssertFalse(policy.allows("update_thread"))
        XCTAssertFalse(policy.allows("project_write_file"))
        XCTAssertFalse(policy.allows("complete_task"))

        XCTAssertThrowsError(try policy.permitsCall("create_note", arguments: [
            "project_id": UUID().uuidString,
            "content": "nope"
        ]).get())
        XCTAssertThrowsError(try policy.permitsCall("project_write_file", arguments: [
            "path": "Main.swift"
        ]).get())
        XCTAssertThrowsError(try policy.permitsCall("upsert_code_reference_entry", arguments: [
            "attachment_id": UUID().uuidString,
            "key": "runtime",
            "title": "Runtime",
            "body": "Nope"
        ]).get())
        XCTAssertNoThrow(try policy.permitsCall("upsert_code_reference_entry", arguments: [
            "attachment_id": attachmentID.uuidString,
            "key": "runtime",
            "title": "Runtime",
            "body": "Yes"
        ]).get())
    }

    func testChatCannotWriteReference() {
        let policy = RunToolPolicy.chat(projectID: UUID())
        XCTAssertTrue(policy.allows("list_code_references"))
        XCTAssertTrue(policy.allows("create_note"))
        XCTAssertFalse(policy.allows("upsert_code_reference_entry"))
    }

    func testReferenceBelongsToAttachment() throws {
        let (_, attachment) = seedProject()
        let run = try enqueueIndex(attachment)
        try RunStore.transition(run, to: .running, in: context)
        let staged = try CodeReferenceStore.beginStaging(
            for: attachment,
            run: run,
            fingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        )
        XCTAssertEqual(staged.attachmentID, attachment.id)
        XCTAssertEqual(staged.publication, .staged)
        XCTAssertEqual(staged.originatingRunID, run.id)
        XCTAssertEqual(CodeReferenceStore.staged(on: attachment, in: context)?.id, staged.id)
    }

    func testValidOutputPublishesAndInvalidRelationshipsDoNot() throws {
        let (_, attachment) = seedProject()
        let run = try startIndex(attachment)
        try writeRuntimeEntry(attachment)
        try writeStoreEntry(attachment, related: ["agent-runtime"])
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .complete,
            coverageNotes: "Core path covered.",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        let published = try CodeReferenceStore.publishIfValid(
            run: run,
            rootPath: fixtureRoot.path,
            currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        )
        XCTAssertEqual(published.publication, .published)
        XCTAssertEqual(CodeReferenceStore.entries(on: published, in: context).count, 2)

        let second = try startIndex(attachment)
        try writeRuntimeEntry(attachment, related: ["missing-component"])
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .complete,
            coverageNotes: "",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        XCTAssertThrowsError(
            try CodeReferenceStore.publishIfValid(
                run: second,
                rootPath: fixtureRoot.path,
                currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? CodeReferenceError, .unknownRelatedKey("missing-component"))
        }
        XCTAssertEqual(CodeReferenceStore.published(on: attachment, in: context)?.id, published.id)
    }

    func testSourceLocationValidation() throws {
        let (_, attachment) = seedProject()
        _ = try startIndex(attachment)
        XCTAssertThrowsError(
            try CodeReferenceStore.upsertEntry(
                attachment: attachment,
                key: "ghost",
                title: "Ghost",
                body: "Points at a missing file.",
                sourceLocations: [CodeSourceLocation(path: "Sources/Missing.swift", declaration: nil)],
                relatedKeys: [],
                rootPath: fixtureRoot.path,
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? CodeReferenceError, .pathMissing("Sources/Missing.swift"))
        }

        XCTAssertThrowsError(
            try CodeReferenceStore.upsertEntry(
                attachment: attachment,
                key: "runtime",
                title: "Runtime",
                body: "Bad declaration.",
                sourceLocations: [CodeSourceLocation(path: "Sources/Runtime.swift", declaration: "doesNotExist")],
                relatedKeys: [],
                rootPath: fixtureRoot.path,
                in: context
            )
        )

        XCTAssertNoThrow(
            try CodeReferenceStore.upsertEntry(
                attachment: attachment,
                key: "runtime",
                title: "Runtime",
                body: "Coordinates model responses.",
                sourceLocations: [CodeSourceLocation(path: "Sources/Runtime.swift", declaration: "func start")],
                relatedKeys: [],
                rootPath: fixtureRoot.path,
                in: context
            )
        )
    }

    func testPartialDoesNotLookComplete() throws {
        let (_, attachment) = seedProject()
        let run = try startIndex(attachment)
        try writeRuntimeEntry(attachment)
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .partial,
            coverageNotes: "Persistence was not investigated.",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        let published = try CodeReferenceStore.publishIfValid(
            run: run,
            rootPath: fixtureRoot.path,
            currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        )
        XCTAssertEqual(published.coverage, .partial)
        XCTAssertFalse(published.coverage.appearsComprehensive)
        XCTAssertTrue(CodeReferenceStore.coverageLabel(published).contains("not comprehensive"))
    }

    func testCancelAndFailurePreventPublication() throws {
        let (_, attachment) = seedProject()
        let cancelled = try startIndex(attachment)
        try writeRuntimeEntry(attachment)
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .complete,
            coverageNotes: "",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        try RunStore.cancel(cancelled, in: context)
        XCTAssertNil(CodeReferenceStore.published(on: attachment, in: context))
        XCTAssertNil(CodeReferenceStore.staged(on: attachment, in: context))

        let failed = try startIndex(attachment)
        try writeRuntimeEntry(attachment)
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .complete,
            coverageNotes: "",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        try RunStore.fail(failed, detail: "Worker stopped.", in: context)
        XCTAssertNil(CodeReferenceStore.published(on: attachment, in: context))
        XCTAssertEqual(CodeReferenceStore.references(on: attachment, in: context).filter { $0.publication == .staged }.count, 0)

        let listed = CodeReferenceStore.summaries(project: failed.project, attachmentID: attachment.id, in: context)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0]["available"] as? Bool, false)
        XCTAssertEqual(listed[0]["publication"] as? String, "discarded")
        XCTAssertEqual(listed[0]["entry_count"] as? Int, 1)
        XCTAssertEqual((listed[0]["last_indexing_run"] as? [String: Any])?["status"] as? String, "failed")
        XCTAssertTrue(((listed[0]["unpublished_reason"] as? String) ?? "").contains("Worker stopped."))

        let entry = try object(Tools.call(
            "get_code_reference_entry",
            arguments: ["attachment_id": attachment.id.uuidString, "key": "agent-runtime"],
            container: container
        ))
        XCTAssertEqual(entry["publication"] as? String, "discarded")
        XCTAssertTrue((entry["body"] as? String)?.contains("Coordinates") == true)
    }

    func testFailedReplacementPreservesPreviousReference() throws {
        let (_, attachment) = seedProject()
        let first = try startIndex(attachment)
        try writeRuntimeEntry(attachment)
        try writeStoreEntry(attachment, related: ["agent-runtime"])
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .complete,
            coverageNotes: "",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        let published = try CodeReferenceStore.publishIfValid(
            run: first,
            rootPath: fixtureRoot.path,
            currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        )
        try RunStore.succeed(first, summary: "Indexed.", links: [], in: context)

        let replacement = try startIndex(attachment)
        try writeRuntimeEntry(attachment, related: ["does-not-exist"])
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .complete,
            coverageNotes: "",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        XCTAssertThrowsError(
            try CodeReferenceStore.publishIfValid(
                run: replacement,
                rootPath: fixtureRoot.path,
                currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
                in: context
            )
        )
        try RunStore.fail(replacement, detail: "Invalid reference.", in: context)
        XCTAssertEqual(CodeReferenceStore.published(on: attachment, in: context)?.id, published.id)
        XCTAssertEqual(
            CodeReferenceStore.published(on: attachment, in: context).map { CodeReferenceStore.entries(on: $0, in: context).count },
            2
        )
    }

    func testAgentDiscoveryAndSelectiveRetrieval() throws {
        let (project, attachment) = seedProject()
        let run = try startIndex(attachment)
        try writeRuntimeEntry(attachment)
        try writeStoreEntry(attachment, related: ["agent-runtime"])
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .complete,
            coverageNotes: "",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        _ = try CodeReferenceStore.publishIfValid(
            run: run,
            rootPath: fixtureRoot.path,
            currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        )

        let listed = try object(Tools.call(
            "list_code_references",
            arguments: ["project_id": project.id.uuidString],
            container: container
        ), as: [[String: Any]].self)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0]["attachment_id"] as? String, attachment.id.uuidString)
        XCTAssertEqual(listed[0]["project_id"] as? String, project.id.uuidString)
        XCTAssertEqual(listed[0]["available"] as? Bool, true)
        XCTAssertEqual(listed[0]["coverage"] as? String, "complete")
        let summaries = try XCTUnwrap(listed[0]["entries"] as? [[String: Any]])
        XCTAssertEqual(summaries.count, 2)
        XCTAssertTrue(summaries.allSatisfy { $0["body"] == nil })

        let listedWithEmptyAttachment = try object(Tools.call(
            "list_code_references",
            arguments: ["project_id": project.id.uuidString, "attachment_id": ""],
            container: container
        ), as: [[String: Any]].self)
        XCTAssertEqual(listedWithEmptyAttachment.count, 1)
        XCTAssertEqual(listedWithEmptyAttachment[0]["attachment_id"] as? String, attachment.id.uuidString)

        let projectRecord = try object(Tools.call(
            "get_project",
            arguments: ["project_id": project.id.uuidString],
            container: container
        ))
        let attachments = try XCTUnwrap(projectRecord["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0]["id"] as? String, attachment.id.uuidString)
        XCTAssertEqual(attachments[0]["has_published_reference"] as? Bool, true)
        XCTAssertEqual(attachments[0]["entry_count"] as? Int, 2)

        let entry = try object(Tools.call(
            "get_code_reference_entry",
            arguments: ["attachment_id": attachment.id.uuidString, "key": "agent-runtime"],
            container: container
        ))
        XCTAssertEqual(entry["title"] as? String, "Agent runtime")
        XCTAssertTrue((entry["body"] as? String)?.contains("Coordinates") == true)

        let denied = Tools.call(
            "upsert_code_reference_entry",
            arguments: [
                "attachment_id": attachment.id.uuidString,
                "key": "new-thing",
                "title": "New",
                "body": "Should fail because the indexing run is not active."
            ],
            container: container
        )
        XCTAssertEqual(denied["isError"] as? Bool, true)
    }

    func testWriteToolsRequireActiveIndexingRun() throws {
        let (_, attachment) = seedProject()
        let denied = Tools.call(
            "set_code_reference_meta",
            arguments: [
                "attachment_id": attachment.id.uuidString,
                "coverage": "complete"
            ],
            container: container
        )
        XCTAssertEqual(denied["isError"] as? Bool, true)
    }

    @MainActor
    func testSourceToolsResolveCurrentProjectAttachmentsNotFrozenSessionRoots() async throws {
        let (project, attachment) = seedProject()
        try writeFixtureCommits()
        let run = try startIndex(attachment)
        try writeRuntimeEntry(attachment)
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .partial,
            coverageNotes: "Source-access fixture.",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        _ = try CodeReferenceStore.publishIfValid(
            run: run,
            rootPath: fixtureRoot.path,
            currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        )

        let discovered = CodeReferenceStore.summaries(project: project, attachmentID: nil, in: context)
        XCTAssertEqual(discovered.first?["available"] as? Bool, true, String(describing: discovered))
        XCTAssertEqual(
            ProjectCodeWorkspace.attachments(on: project).map(\.id),
            CodeReferenceStore.attachmentsOn(project, in: context).map(\.id)
        )

        let frozen = SlateToolGateway(roots: [], includeSlateTools: false)
        do {
            _ = try await frozen.execute(
                name: "project_read_file",
                arguments: ["path": "Sources/Runtime.swift", "root": attachment.locator]
            )
            XCTFail("Frozen empty session roots must not invent filesystem access")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("No code is attached"),
                error.localizedDescription
            )
        }
        let frozenList = try await frozen.execute(name: "project_list_files", arguments: [:])
        XCTAssertEqual(frozenList, "[]")

        var lateRoots: [ProjectCodeRoot] = []
        let live = SlateToolGateway(
            roots: [],
            includeSlateTools: false,
            prepareRoots: { lateRoots }
        )
        let emptyLive = try await live.execute(name: "project_list_files", arguments: [:])
        XCTAssertEqual(emptyLive, "[]")

        lateRoots = ProjectCodeWorkspace.localRoots(for: project)
        XCTAssertFalse(lateRoots.isEmpty)

        let files = try await live.execute(name: "project_list_files", arguments: [:])
        XCTAssertTrue(files.contains("Runtime.swift"), files)

        let entry = try object(Tools.call(
            "get_code_reference_entry",
            arguments: ["attachment_id": attachment.id.uuidString, "key": "agent-runtime"],
            container: container
        ))
        let path = try XCTUnwrap((entry["source_locations"] as? [[String: Any]])?.first?["path"] as? String)
        let read = try await live.execute(
            name: "project_read_file",
            arguments: ["path": path, "root": attachment.locator]
        )
        XCTAssertTrue(read.contains("func start"), read)

        let byExactRoot = try await live.execute(
            name: "project_read_file",
            arguments: ["path": path, "root": fixtureRoot.path]
        )
        XCTAssertTrue(byExactRoot.contains("func start"), byExactRoot)

        let log = try await live.execute(name: "project_git_log", arguments: [:])
        XCTAssertTrue(log.contains("sha"), log)
        XCTAssertTrue(log.contains("fixture"), log)
    }

    func testNeverIndexedAttachmentIsDiagnosable() throws {
        let (project, attachment) = seedProject()
        let listed = CodeReferenceStore.summaries(project: project, attachmentID: nil, in: context)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0]["attachment_id"] as? String, attachment.id.uuidString)
        XCTAssertEqual(listed[0]["available"] as? Bool, false)
        XCTAssertEqual(listed[0]["entry_count"] as? Int, 0)
        XCTAssertEqual(listed[0]["unpublished_reason"] as? String, "No published reference.")
        XCTAssertNil(listed[0]["last_indexing_run"])
    }

    func testSucceededIndexWithoutEntriesIsDiagnosable() throws {
        let (project, attachment) = seedProject()
        let run = try enqueueIndex(attachment)
        try RunStore.transition(run, to: .running, in: context)
        try RunStore.succeed(run, summary: "Finished with no summary.", links: [], in: context)
        let listed = CodeReferenceStore.summaries(project: project, attachmentID: nil, in: context)
        XCTAssertEqual(listed[0]["available"] as? Bool, false)
        XCTAssertEqual(listed[0]["attachment_id"] as? String, attachment.id.uuidString)
        XCTAssertEqual((listed[0]["last_indexing_run"] as? [String: Any])?["id"] as? String, run.id.uuidString)
        XCTAssertEqual((listed[0]["last_indexing_run"] as? [String: Any])?["status"] as? String, "succeeded")
        XCTAssertTrue(
            ((listed[0]["unpublished_reason"] as? String) ?? "").contains("no published output"),
            String(describing: listed[0]["unpublished_reason"])
        )
    }

    func testUnpublishedIndexIsFailedNotSucceeded() throws {
        let (project, attachment) = seedProject()
        let run = try enqueueIndex(attachment)
        try RunStore.transition(run, to: .running, in: context)
        try RunStore.failUnpublishedIndex(
            run,
            workerSummary: "Mapped components but could not persist entries.",
            detail: CodeReferenceError.noEntries.localizedDescription ?? "no entries",
            in: context
        )
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.statusDetail.contains("Indexing did not publish"))
        XCTAssertTrue(run.resultSummary.contains("Mapped components"))
        XCTAssertNil(CodeReferenceStore.published(on: attachment, in: context))
        let listed = CodeReferenceStore.summaries(project: project, attachmentID: nil, in: context)
        XCTAssertEqual(listed[0]["available"] as? Bool, false)
        XCTAssertEqual((listed[0]["last_indexing_run"] as? [String: Any])?["status"] as? String, "failed")
        XCTAssertTrue(
            ((listed[0]["unpublished_reason"] as? String) ?? "").contains("Indexing did not publish"),
            String(describing: listed[0]["unpublished_reason"])
        )
    }

    func testRunningIndexIsDiagnosable() throws {
        let (project, attachment) = seedProject()
        let run = try startIndex(attachment)
        let listed = CodeReferenceStore.summaries(project: project, attachmentID: nil, in: context)
        XCTAssertEqual(listed[0]["available"] as? Bool, false)
        XCTAssertEqual(listed[0]["indexing_run_id"] as? String, run.id.uuidString)
        XCTAssertEqual(listed[0]["indexing_status"] as? String, "running")
        XCTAssertEqual(listed[0]["unpublished_reason"] as? String, "Indexing is running.")
    }

    func testEntryWithoutSupportingLocationsFailsValidation() throws {
        let (_, attachment) = seedProject()
        _ = try startIndex(attachment)
        XCTAssertThrowsError(try CodeReferenceStore.upsertEntry(
            attachment: attachment,
            key: "agent-runtime",
            title: "Agent runtime",
            body: "Coordinates model responses and tool execution.",
            sourceLocations: [],
            relatedKeys: [],
            rootPath: fixtureRoot.path,
            in: context
        )) { error in
            XCTAssertEqual(error as? CodeReferenceError, .missingSourceLocation)
        }
        XCTAssertThrowsError(try CodeReferenceStore.validateLocations([], rootPath: fixtureRoot.path, requireDeclarations: true)) { error in
            XCTAssertEqual(error as? CodeReferenceError, .missingSourceLocation)
        }
    }

    func testValidSourceLocationsRemainAccepted() throws {
        let (_, attachment) = seedProject()
        _ = try startIndex(attachment)
        try writeRuntimeEntry(attachment)
        let staged = try XCTUnwrap(CodeReferenceStore.staged(on: attachment, in: context))
        let entry = try XCTUnwrap(CodeReferenceStore.entries(on: staged, in: context).first)
        XCTAssertEqual(entry.sourceLocations.first?.path, "Sources/Runtime.swift")
        try CodeReferenceStore.validateLocations(entry.sourceLocations, rootPath: fixtureRoot.path, requireDeclarations: true)
    }

    func testModelSuppliedHashIsIgnoredAndMissingProvenanceIsUnknown() throws {
        let (project, attachment) = seedProject()
        _ = try startIndex(attachment)
        _ = try CodeReferenceStore.upsertEntry(
            attachment: attachment,
            key: "agent-runtime",
            title: "Agent runtime",
            body: "Coordinates model responses and tool execution.",
            sourceLocations: [
                CodeSourceLocation(
                    path: "Sources/Runtime.swift",
                    declaration: "func start",
                    contentHash: "sha256:deadbeef"
                )
            ],
            relatedKeys: [],
            rootPath: fixtureRoot.path,
            in: context
        )
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .partial,
            coverageNotes: "No trusted reads.",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        let published = try CodeReferenceStore.publishIfValid(
            run: try XCTUnwrap(CodeReferenceStore.activeIndexingRun(for: attachment, in: context)),
            rootPath: fixtureRoot.path,
            currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        )
        let entry = try XCTUnwrap(CodeReferenceStore.entries(on: published, in: context).first)
        XCTAssertNil(entry.sourceLocations.first?.contentHash)
        XCTAssertEqual(published.sourceFreshness, .unknown)
        let listed = CodeReferenceStore.summaries(project: project, attachmentID: nil, in: context)
        XCTAssertEqual(listed[0]["source_freshness"] as? String, "unknown")
        let locations = try XCTUnwrap((listed[0]["entries"] as? [[String: Any]])?.first?["source_locations"] as? [[String: Any]])
        XCTAssertNil(locations.first?["content_hash"])
        XCTAssertEqual(locations.first?["freshness"] as? String, "unknown")
    }

    func testUnchangedContentMatchesRecordedHash() throws {
        let (project, attachment) = seedProject()
        let run = try startIndex(attachment)
        let file = fixtureRoot.appendingPathComponent("Sources/Runtime.swift")
        let hash = try CodeContentHash.sha256(ofFile: file)
        CodeReadProvenance.record(
            runID: run.id,
            path: "Sources/Runtime.swift",
            hash: hash,
            storeURL: container.configurations.first?.url
        )
        try writeRuntimeEntry(attachment)
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .partial,
            coverageNotes: "Hashed.",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        let published = try CodeReferenceStore.publishIfValid(
            run: run,
            rootPath: fixtureRoot.path,
            currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        )
        let entry = try XCTUnwrap(CodeReferenceStore.entries(on: published, in: context).first)
        XCTAssertEqual(entry.sourceLocations.first?.contentHash, hash)
        XCTAssertEqual(published.sourceFreshness, .current)
        let listed = CodeReferenceStore.summaries(project: project, attachmentID: nil, in: context)
        XCTAssertEqual(listed[0]["source_freshness"] as? String, "current")
    }

    func testEditingAlreadyModifiedFileIsDetectedWhenGitFingerprintStaysTheSame() throws {
        let (project, attachment) = seedProject()
        let run = try startIndex(attachment)
        let file = fixtureRoot.appendingPathComponent("Sources/Runtime.swift")
        try "func start() { /* dirty */ }\n".write(to: file, atomically: true, encoding: .utf8)
        let startFingerprint = RepositoryIndex.fingerprint(at: fixtureRoot.path)
        let hash = try CodeContentHash.sha256(ofFile: file)
        CodeReadProvenance.record(
            runID: run.id,
            path: "Sources/Runtime.swift",
            hash: hash,
            storeURL: container.configurations.first?.url
        )
        try writeRuntimeEntry(attachment)
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .partial,
            coverageNotes: "Examined a dirty tree.",
            sourceRevision: nil,
            localChangesExamined: startFingerprint.localChanges,
            in: context
        )
        _ = try CodeReferenceStore.publishIfValid(
            run: run,
            rootPath: fixtureRoot.path,
            currentFingerprint: startFingerprint,
            in: context
        )

        try "func start() { /* dirtier */ }\n".write(to: file, atomically: true, encoding: .utf8)
        let laterFingerprint = RepositoryIndex.fingerprint(at: fixtureRoot.path)
        XCTAssertEqual(laterFingerprint.commitSHA, startFingerprint.commitSHA)
        XCTAssertEqual(laterFingerprint.localChanges, startFingerprint.localChanges)

        let published = try XCTUnwrap(CodeReferenceStore.published(on: attachment, in: context))
        XCTAssertEqual(
            CodeReferenceStore.evaluateFreshness(published, rootPath: fixtureRoot.path, in: context),
            .changed
        )
        let listed = CodeReferenceStore.summaries(project: project, attachmentID: nil, in: context)
        XCTAssertEqual(listed[0]["source_freshness"] as? String, "changed")
    }

    func testDeletedSourceFileIsDetectedAndFailedValidationPreservesPublishedReference() throws {
        let (_, attachment) = seedProject()
        let first = try startIndex(attachment)
        let file = fixtureRoot.appendingPathComponent("Sources/Runtime.swift")
        CodeReadProvenance.record(
            runID: first.id,
            path: "Sources/Runtime.swift",
            hash: try CodeContentHash.sha256(ofFile: file),
            storeURL: container.configurations.first?.url
        )
        try writeRuntimeEntry(attachment)
        _ = try CodeReferenceStore.updateMeta(
            attachment: attachment,
            coverage: .partial,
            coverageNotes: "First publish.",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: context
        )
        let published = try CodeReferenceStore.publishIfValid(
            run: first,
            rootPath: fixtureRoot.path,
            currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        )
        try RunStore.succeed(first, summary: "Indexed.", links: [], in: context)

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(
            CodeReferenceStore.evaluateFreshness(published, rootPath: fixtureRoot.path, in: context),
            .missing
        )

        let second = try startIndex(attachment)
        XCTAssertThrowsError(try CodeReferenceStore.upsertEntry(
            attachment: attachment,
            key: "agent-runtime",
            title: "Agent runtime",
            body: "Coordinates model responses and tool execution.",
            sourceLocations: [CodeSourceLocation(path: "Sources/Runtime.swift", declaration: "func start")],
            relatedKeys: [],
            rootPath: fixtureRoot.path,
            in: context
        )) { error in
            XCTAssertEqual(error as? CodeReferenceError, .pathMissing("Sources/Runtime.swift"))
        }
        XCTAssertThrowsError(try CodeReferenceStore.publishIfValid(
            run: second,
            rootPath: fixtureRoot.path,
            currentFingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        ))
        let still = try XCTUnwrap(CodeReferenceStore.published(on: attachment, in: context))
        XCTAssertEqual(still.id, published.id)
        XCTAssertEqual(still.publication, .published)
    }

    func testChatGPTSourceReadHashIsTheVersionReturnedToTheAgent() async throws {
        let (_, attachment) = seedProject()
        let run = try startIndex(attachment)
        let file = fixtureRoot.appendingPathComponent("Sources/Runtime.swift")
        let expected = try CodeContentHash.sha256(ofFile: file)
        let gateway = SlateToolGateway(
            roots: [.init(title: attachment.title, locator: attachment.locator, path: fixtureRoot.path)],
            includeSlateTools: false,
            indexingRunID: run.id,
            storeURL: container.configurations.first?.url
        )
        let read = try await gateway.execute(
            name: "project_read_file",
            arguments: ["path": "Sources/Runtime.swift", "start_line": 1, "end_line": 2]
        )
        let hash = try contentHash(from: read)
        XCTAssertEqual(hash, expected)
        XCTAssertTrue(read.contains("func start"), read)
        try writeRuntimeEntry(attachment)
        let staged = try XCTUnwrap(CodeReferenceStore.staged(on: attachment, in: context))
        let entry = try XCTUnwrap(CodeReferenceStore.entries(on: staged, in: context).first)
        XCTAssertEqual(entry.sourceLocations.first?.contentHash, expected)
        XCTAssertEqual(CodeReadProvenance.hash(runID: run.id, path: "Sources/Runtime.swift", storeURL: container.configurations.first?.url), expected)
    }

    func testCursorSourceReadHashIsTheVersionReturnedToTheAgent() throws {
        let (_, attachment) = seedProject()
        let run = try startIndex(attachment)
        let file = fixtureRoot.appendingPathComponent("Sources/Runtime.swift")
        let expected = try CodeContentHash.sha256(ofFile: file)
        let dest = CodeReadProvenance.fileURL(runID: run.id, storeURL: container.configurations.first?.url)
        let read = try invokeCursorSourceRead(
            file: file,
            relative: "Sources/Runtime.swift",
            provenance: dest,
            start: 1,
            end: 2
        )
        let hash = try contentHash(from: read)
        XCTAssertEqual(hash, expected)
        XCTAssertTrue(read.contains("func start"), read)
        try writeRuntimeEntry(attachment)
        let staged = try XCTUnwrap(CodeReferenceStore.staged(on: attachment, in: context))
        let entry = try XCTUnwrap(CodeReferenceStore.entries(on: staged, in: context).first)
        XCTAssertEqual(entry.sourceLocations.first?.contentHash, expected)
        XCTAssertEqual(CodeReadProvenance.hash(runID: run.id, path: "Sources/Runtime.swift", storeURL: container.configurations.first?.url), expected)
    }

    func testPriorHashIsPreservedWhenALaterReadSeesADifferentVersion() throws {
        let (_, attachment) = seedProject()
        let run = try startIndex(attachment)
        let file = fixtureRoot.appendingPathComponent("Sources/Runtime.swift")
        let firstHash = try CodeContentHash.sha256(ofFile: file)
        CodeReadProvenance.record(
            runID: run.id,
            path: "Sources/Runtime.swift",
            hash: firstHash,
            storeURL: container.configurations.first?.url
        )
        try writeRuntimeEntry(attachment)
        try "func start() { /* later */ }\n".write(to: file, atomically: true, encoding: .utf8)
        let laterHash = try CodeContentHash.sha256(ofFile: file)
        XCTAssertNotEqual(firstHash, laterHash)
        let staged = try XCTUnwrap(CodeReferenceStore.staged(on: attachment, in: context))
        let entry = try XCTUnwrap(CodeReferenceStore.entries(on: staged, in: context).first)
        XCTAssertEqual(entry.sourceLocations.first?.contentHash, firstHash)
        XCTAssertNotEqual(entry.sourceLocations.first?.contentHash, laterHash)
    }

    private func seedProject() -> (Project, CodeAttachment) {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let attachment = CodeAttachment(
            kind: .folder,
            title: "harbor-src",
            locator: fixtureRoot.path,
            project: project
        )
        context.insert(attachment)
        return (project, attachment)
    }

    private func enqueueIndex(_ attachment: CodeAttachment) throws -> AgentRun {
        try RunStore.enqueue(
            RepositoryIndex.draft(
                for: attachment,
                project: try XCTUnwrap(attachment.project),
                providerID: "cursor",
                modelID: "auto"
            ),
            in: context
        )
    }

    private func startIndex(_ attachment: CodeAttachment) throws -> AgentRun {
        let run = try enqueueIndex(attachment)
        try RunStore.transition(run, to: .running, in: context)
        _ = try CodeReferenceStore.beginStaging(
            for: attachment,
            run: run,
            fingerprint: RepositoryIndex.fingerprint(at: fixtureRoot.path),
            in: context
        )
        return run
    }

    private func writeRuntimeEntry(_ attachment: CodeAttachment, related: [String] = []) throws {
        _ = try CodeReferenceStore.upsertEntry(
            attachment: attachment,
            key: "agent-runtime",
            title: "Agent runtime",
            body: "Coordinates model responses and tool execution.",
            sourceLocations: [CodeSourceLocation(path: "Sources/Runtime.swift", declaration: "func start")],
            relatedKeys: related,
            rootPath: fixtureRoot.path,
            in: context
        )
    }

    private func writeStoreEntry(_ attachment: CodeAttachment, related: [String]) throws {
        _ = try CodeReferenceStore.upsertEntry(
            attachment: attachment,
            key: "run-store",
            title: "Run store",
            body: "Persists run lifecycle and receipts.",
            sourceLocations: [CodeSourceLocation(path: "Sources/Store.swift", declaration: "func save")],
            relatedKeys: related,
            rootPath: fixtureRoot.path,
            in: context
        )
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try """
        // Runtime
        func start() {}
        """.write(to: root.appendingPathComponent("Sources/Runtime.swift"), atomically: true, encoding: .utf8)
        try """
        // Store
        func save() {}
        """.write(to: root.appendingPathComponent("Sources/Store.swift"), atomically: true, encoding: .utf8)
        try """
        // Tests
        func testStart() {}
        """.write(to: root.appendingPathComponent("Tests/RuntimeTests.swift"), atomically: true, encoding: .utf8)
        return root
    }

    private func contentHash(from read: String) throws -> String {
        let line = try XCTUnwrap(read.split(separator: "\n", maxSplits: 1).first)
        XCTAssertTrue(line.hasPrefix("content_hash sha256:"), String(line))
        return String(line.dropFirst("content_hash ".count))
    }

    private func invokeCursorSourceRead(
        file: URL,
        relative: String,
        provenance: URL,
        start: Int,
        end: Int
    ) throws -> String {
        let node = try XCTUnwrap(
            Bundle.main.url(forAuxiliaryExecutable: "slate-node"),
            "slate-node should be embedded in Slate.app"
        )
        let script = try XCTUnwrap(
            Bundle.main.url(forResource: "source-read", withExtension: "mjs", subdirectory: "runner"),
            "Cursor source-read helper should ship next to runner.mjs"
        )
        let process = Process()
        process.executableURL = node
        process.arguments = [
            script.path,
            "--read-file-once", file.path,
            "--provenance", provenance.path,
            "--path", relative,
            "--start", String(start),
            "--end", String(end)
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, err)
        return output
    }

    private func writeFixtureCommits() throws {
        let commits: [[String: String]] = [[
            "sha": "abc123def456",
            "author": "Slate",
            "date": "2026-10-09T00:00:00Z",
            "message": "fixture"
        ]]
        try JSONSerialization.data(withJSONObject: commits).write(
            to: fixtureRoot.appendingPathComponent(".slate-commits.json")
        )
    }

    private func object(_ payload: [String: Any]) throws -> [String: Any] {
        try object(payload, as: [String: Any].self)
    }

    private func object<T>(_ payload: [String: Any], as type: T.Type) throws -> T {
        if payload["isError"] as? Bool == true {
            let text = ((payload["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "error"
            throw NSError(domain: "CodeReferenceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        let text = try XCTUnwrap((payload["content"] as? [[String: Any]])?.first?["text"] as? String)
        let data = Data(text.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(json as? T)
    }
}

@MainActor
final class CodeReferencePersistenceTests: XCTestCase {
    func testFileStoreMigratesPurposeAndIsReadableFromANewContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-ref-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        let fixture = try makeSourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let writer = try Store.open(url: url)
        let writerContext = writer.mainContext
        let project = Project(name: "Slate", symbol: "folder", summary: "")
        writerContext.insert(project)
        let attachment = CodeAttachment(kind: .folder, title: "PC-OS", locator: fixture.path, project: project)
        writerContext.insert(attachment)
        let other = CodeAttachment(kind: .folder, title: "Other", locator: "/tmp/other", project: project)
        writerContext.insert(other)
        try writerContext.save()

        dropIndexingColumns(at: url)

        let migrated = try Store.open(url: url)
        let migratedContext = migrated.mainContext
        let migratedProject = try XCTUnwrap(
            try migratedContext.fetch(FetchDescriptor<Project>()).first { $0.name == "Slate" }
        )
        let migratedAttachment = try XCTUnwrap(
            CodeReferenceStore.attachmentsOn(migratedProject, in: migratedContext)
                .first { $0.title == "PC-OS" }
        )
        let draft = RepositoryIndex.draft(
            for: migratedAttachment,
            project: migratedProject,
            providerID: "cursor",
            modelID: "auto"
        )
        let run = try RunStore.enqueue(draft, in: migratedContext)
        try RunStore.transition(run, to: .running, in: migratedContext)
        XCTAssertEqual(run.purpose, .indexRepository)
        XCTAssertEqual(run.indexedAttachmentID, migratedAttachment.id)
        _ = try CodeReferenceStore.beginStaging(
            for: migratedAttachment,
            run: run,
            fingerprint: RepositoryIndex.fingerprint(at: fixture.path),
            in: migratedContext
        )
        let sourceHash = try CodeContentHash.sha256(ofFile: fixture.appendingPathComponent("Sources/Runtime.swift"))
        CodeReadProvenance.record(
            runID: run.id,
            path: "Sources/Runtime.swift",
            hash: sourceHash,
            storeURL: url
        )
        _ = try CodeReferenceStore.upsertEntry(
            attachment: migratedAttachment,
            key: "agent-runtime",
            title: "Agent runtime",
            body: "Coordinates model responses and tool execution.",
            sourceLocations: [CodeSourceLocation(path: "Sources/Runtime.swift", declaration: "func start")],
            relatedKeys: [],
            rootPath: fixture.path,
            in: migratedContext
        )
        _ = try CodeReferenceStore.updateMeta(
            attachment: migratedAttachment,
            coverage: .partial,
            coverageNotes: "Persistence was not investigated.",
            sourceRevision: nil,
            localChangesExamined: "Clean working tree.",
            in: migratedContext
        )
        _ = try CodeReferenceStore.publishIfValid(
            run: run,
            rootPath: fixture.path,
            currentFingerprint: RepositoryIndex.fingerprint(at: fixture.path),
            in: migratedContext
        )
        try RunStore.succeed(run, summary: "Indexed.", links: [], in: migratedContext)
        let attachmentID = migratedAttachment.id
        let projectID = migratedProject.id

        let reader = try Store.open(url: url)
        let listed = try object(Tools.call(
            "list_code_references",
            arguments: ["project_id": projectID.uuidString],
            container: reader
        ), as: [[String: Any]].self)
        XCTAssertEqual(listed.count, 2)
        let pcOS = try XCTUnwrap(listed.first { $0["attachment_id"] as? String == attachmentID.uuidString })
        XCTAssertEqual(pcOS["available"] as? Bool, true)
        XCTAssertEqual(pcOS["entry_count"] as? Int, 1)
        XCTAssertEqual(pcOS["source_freshness"] as? String, "current")
        XCTAssertEqual((pcOS["entries"] as? [[String: Any]])?.first?["key"] as? String, "agent-runtime")
        XCTAssertEqual(
            ((pcOS["entries"] as? [[String: Any]])?.first?["source_locations"] as? [[String: Any]])?.first?["content_hash"] as? String,
            sourceHash
        )
        let otherListed = try XCTUnwrap(listed.first { $0["attachment_title"] as? String == "Other" })
        XCTAssertEqual(otherListed["available"] as? Bool, false)
        XCTAssertEqual(otherListed["entry_count"] as? Int, 0)
        XCTAssertNotEqual(otherListed["attachment_id"] as? String, attachmentID.uuidString)

        let entry = try object(Tools.call(
            "get_code_reference_entry",
            arguments: ["attachment_id": attachmentID.uuidString, "key": "agent-runtime"],
            container: reader
        ))
        XCTAssertEqual(entry["title"] as? String, "Agent runtime")
        XCTAssertTrue((entry["body"] as? String)?.contains("Coordinates") == true)
        XCTAssertEqual(entry["source_freshness"] as? String, "current")
        XCTAssertEqual((entry["source_locations"] as? [[String: Any]])?.first?["content_hash"] as? String, sourceHash)

        let leaked = Tools.call(
            "get_code_reference_entry",
            arguments: [
                "attachment_id": otherListed["attachment_id"] as? String ?? "",
                "key": "agent-runtime"
            ],
            container: reader
        )
        XCTAssertEqual(leaked["isError"] as? Bool, true)
    }

    func testUnpublishedAttemptIsDiagnosableFromASeparateContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-ref-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        let fixture = try makeSourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let writer = try Store.open(url: url)
        let context = writer.mainContext
        let project = Project(name: "Slate", symbol: "folder", summary: "")
        context.insert(project)
        let attachment = CodeAttachment(kind: .folder, title: "PC-OS", locator: fixture.path, project: project)
        context.insert(attachment)
        let run = try RunStore.enqueue(
            RepositoryIndex.draft(for: attachment, project: project, providerID: "cursor", modelID: "auto"),
            in: context
        )
        try RunStore.transition(run, to: .running, in: context)
        _ = try CodeReferenceStore.beginStaging(
            for: attachment,
            run: run,
            fingerprint: RepositoryIndex.fingerprint(at: fixture.path),
            in: context
        )
        _ = try CodeReferenceStore.upsertEntry(
            attachment: attachment,
            key: "agent-runtime",
            title: "Agent runtime",
            body: "Coordinates model responses and tool execution.",
            sourceLocations: [CodeSourceLocation(path: "Sources/Runtime.swift", declaration: "func start")],
            relatedKeys: [],
            rootPath: fixture.path,
            in: context
        )
        try RunStore.fail(run, detail: "Worker stopped.", in: context)
        let projectID = project.id
        let attachmentID = attachment.id

        let reader = try Store.open(url: url)
        let listed = try object(Tools.call(
            "list_code_references",
            arguments: ["project_id": projectID.uuidString],
            container: reader
        ), as: [[String: Any]].self)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0]["available"] as? Bool, false)
        XCTAssertEqual(listed[0]["attachment_id"] as? String, attachmentID.uuidString)
        XCTAssertEqual(listed[0]["publication"] as? String, "discarded")
        XCTAssertEqual(listed[0]["entry_count"] as? Int, 1)
        XCTAssertEqual((listed[0]["last_indexing_run"] as? [String: Any])?["id"] as? String, run.id.uuidString)
        XCTAssertTrue(((listed[0]["unpublished_reason"] as? String) ?? "").contains("Worker stopped."))
    }

    func testExistingIndexingRunIsBackfilledAndDiagnosableFromASeparateContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-ref-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        let fixture = try makeSourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let projectID: UUID
        let attachmentID: UUID
        let runID: UUID
        do {
            let writer = try Store.open(url: url)
            let context = writer.mainContext
            let project = Project(name: "Slate", symbol: "folder", summary: "")
            context.insert(project)
            let attachment = CodeAttachment(kind: .folder, title: "PC-OS", locator: fixture.path, project: project)
            context.insert(attachment)
            let run = try RunStore.enqueue(
                RepositoryIndex.draft(for: attachment, project: project, providerID: "cursor", modelID: "auto"),
                in: context
            )
            try RunStore.transition(run, to: .running, in: context)
            try RunStore.succeed(run, summary: "Finished with no summary.", links: [], in: context)
            projectID = project.id
            attachmentID = attachment.id
            runID = run.id
        }
        dropIndexingColumns(at: url)

        let migrated = try Store.open(url: url)
        let migratedRun = try XCTUnwrap(RunStore.run(runID, in: migrated.mainContext))
        XCTAssertEqual(migratedRun.purpose, .indexRepository)
        XCTAssertEqual(migratedRun.indexedAttachmentID, attachmentID)

        let reader = try Store.open(url: url)
        let listed = try object(Tools.call(
            "list_code_references",
            arguments: ["project_id": projectID.uuidString],
            container: reader
        ), as: [[String: Any]].self)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0]["available"] as? Bool, false)
        XCTAssertEqual(listed[0]["attachment_id"] as? String, attachmentID.uuidString)
        XCTAssertEqual((listed[0]["last_indexing_run"] as? [String: Any])?["id"] as? String, runID.uuidString)
        XCTAssertEqual((listed[0]["last_indexing_run"] as? [String: Any])?["status"] as? String, "succeeded")
        XCTAssertTrue(
            ((listed[0]["unpublished_reason"] as? String) ?? "").contains("no published output"),
            String(describing: listed[0]["unpublished_reason"])
        )
    }

    func testEnqueuePersistsPurposeOnDiskWithoutBackfill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-ref-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        let fixture = try makeSourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let writer = try Store.open(url: url)
        let context = writer.mainContext
        let project = Project(name: "Slate", symbol: "folder", summary: "")
        context.insert(project)
        let attachment = CodeAttachment(kind: .folder, title: "PC-OS", locator: fixture.path, project: project)
        context.insert(attachment)
        let run = try RunStore.enqueue(
            RepositoryIndex.draft(for: attachment, project: project, providerID: "cursor", modelID: "composer-2.5"),
            in: context
        )
        let disk = try XCTUnwrap(Store.persistedAgentRunIdentity(runID: run.id, at: url))
        XCTAssertEqual(disk.purpose, RunPurpose.indexRepository.rawValue)
        XCTAssertEqual(disk.attachmentID.lowercased(), attachment.id.uuidString.lowercased())

        try Store.migrateAgentRunColumns(at: url)
        try Store.migrateAgentRunColumns(at: url)
        let again = try XCTUnwrap(Store.persistedAgentRunIdentity(runID: run.id, at: url))
        XCTAssertEqual(again.purpose, RunPurpose.indexRepository.rawValue)
    }

    func testIndependentOwnershipSurvivesStaleAttachmentSaveAndReopen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-ref-owned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")

        let seed = try Store.open(url: url)
        let seedContext = seed.mainContext
        let project = Project(name: "Slate", symbol: "folder", summary: "")
        seedContext.insert(project)
        let attachment = CodeAttachment(kind: .folder, title: "PC-OS", locator: "/tmp/pc-os", project: project)
        seedContext.insert(attachment)
        try seedContext.save()
        let projectID = project.id
        let attachmentID = attachment.id

        let stale = try Store.open(url: url)
        let staleAttachment = try XCTUnwrap(CodeReferenceStore.attachment(attachmentID, in: stale.mainContext))

        let writer = try Store.open(url: url)
        let writerContext = writer.mainContext
        let fingerprint = CodeSourceFingerprint(commitSHA: "abc123", localChanges: "none", capturedAt: .now)
        let reference = CodeReference(
            attachmentID: attachmentID,
            originatingRunID: UUID(),
            fingerprint: fingerprint
        )
        reference.publication = .published
        reference.coverage = .partial
        reference.coverageNotes = "Synthetic ownership probe."
        writerContext.insert(reference)
        let body = "Coordinates model responses and tool execution."
        let entry = CodeReferenceEntry(
            key: "agent-runtime",
            title: "Agent runtime",
            body: body,
            sourceLocations: [CodeSourceLocation(path: "Sources/Runtime.swift", declaration: "func start")],
            relatedKeys: [],
            sourceRevision: "abc123",
            referenceID: reference.id
        )
        writerContext.insert(entry)
        try writerContext.save()
        let committed = try CodeReferenceStore.committedPublished(
            id: reference.id,
            attachmentID: attachmentID,
            in: writerContext
        )
        XCTAssertEqual(committed.attachmentIDString.lowercased(), attachmentID.uuidString.lowercased())
        XCTAssertEqual(CodeReferenceStore.entries(on: committed, in: writerContext).first?.referenceIDString.lowercased(), reference.id.uuidString.lowercased())

        func assertDiscoverable(_ container: ModelContainer) throws {
            let listed = try object(Tools.call(
                "list_code_references",
                arguments: ["project_id": projectID.uuidString],
                container: container
            ), as: [[String: Any]].self)
            let row = try XCTUnwrap(listed.first { $0["attachment_id"] as? String == attachmentID.uuidString })
            XCTAssertEqual(row["available"] as? Bool, true, String(describing: row))
            XCTAssertEqual(row["publication"] as? String, "published")
            XCTAssertEqual(row["entry_count"] as? Int, 1)
            XCTAssertEqual((row["entries"] as? [[String: Any]])?.first?["key"] as? String, "agent-runtime")

            let retrieved = try object(Tools.call(
                "get_code_reference_entry",
                arguments: ["attachment_id": attachmentID.uuidString, "key": "agent-runtime"],
                container: container
            ))
            XCTAssertEqual(retrieved["publication"] as? String, "published")
            XCTAssertEqual(retrieved["reference_id"] as? String, reference.id.uuidString)
            XCTAssertEqual(retrieved["attachment_id"] as? String, attachmentID.uuidString)
            XCTAssertEqual(retrieved["id"] as? String, entry.id.uuidString)
            XCTAssertEqual(retrieved["title"] as? String, "Agent runtime")
            XCTAssertEqual(retrieved["body"] as? String, body)

            let owned = try XCTUnwrap(CodeReferenceStore.reference(reference.id, in: container.mainContext))
            XCTAssertEqual(owned.attachmentID, attachmentID)
            XCTAssertEqual(owned.publication, .published)
            let ownedEntries = CodeReferenceStore.entries(on: owned, in: container.mainContext)
            XCTAssertEqual(ownedEntries.count, 1)
            XCTAssertEqual(ownedEntries.first?.id, entry.id)
            XCTAssertEqual(ownedEntries.first?.referenceID, reference.id)
        }

        try assertDiscoverable(try Store.open(url: url))

        staleAttachment.defaultBranch = "main"
        staleAttachment.title = "PC-OS"
        try stale.mainContext.save()

        try assertDiscoverable(try Store.open(url: url))
        try assertDiscoverable(try Store.open(url: url))
    }

    func testLiveGroupStoreSyntheticOwnership() throws {
        guard ProcessInfo.processInfo.environment["SLATE_LIVE_OWNERSHIP_PROBE"] == "1" else {
            throw XCTSkip("Set SLATE_LIVE_OWNERSHIP_PROBE=1 to write a synthetic reference into the group store.")
        }
        let url = try XCTUnwrap(Store.applicationGroupStoreURL)
        XCTAssertTrue(url.path.contains("NUF99UVUKB.com.ethanfox.PersonalContext"))
        XCTAssertEqual(url.lastPathComponent, "default.store")

        let projectID = try XCTUnwrap(UUID(uuidString: "0E35C9C4-ABE8-4CCE-ADB6-BC7964A75D51"))
        let writer = try Store.open(url: url)
        let writerContext = writer.mainContext
        let project = try XCTUnwrap(
            (try writerContext.fetch(FetchDescriptor<Project>())).first { $0.id == projectID }
        )
        let attachment = CodeAttachment(
            kind: .folder,
            title: "Persistence probe",
            locator: "/tmp/slate-persistence-probe",
            project: project
        )
        writerContext.insert(attachment)
        try writerContext.save()
        let attachmentID = attachment.id

        let stale = try Store.open(url: url)
        let staleAttachment = try XCTUnwrap(CodeReferenceStore.attachment(attachmentID, in: stale.mainContext))

        let fingerprint = CodeSourceFingerprint(commitSHA: "probe", localChanges: "none", capturedAt: .now)
        let reference = CodeReference(
            attachmentID: attachmentID,
            originatingRunID: UUID(),
            fingerprint: fingerprint
        )
        reference.publication = .published
        reference.coverage = .inventory
        reference.coverageNotes = "Live group-store ownership probe."
        writerContext.insert(reference)
        let body = "This synthetic entry proves independent ownership."
        let entry = CodeReferenceEntry(
            key: "ownership-probe",
            title: "Ownership probe",
            body: body,
            sourceLocations: [],
            relatedKeys: [],
            sourceRevision: "probe",
            referenceID: reference.id
        )
        writerContext.insert(entry)
        try writerContext.save()
        _ = try CodeReferenceStore.committedPublished(
            id: reference.id,
            attachmentID: attachmentID,
            in: writerContext
        )

        func assertMCP(_ container: ModelContainer) throws {
            let listed = try object(Tools.call(
                "list_code_references",
                arguments: ["project_id": projectID.uuidString],
                container: container
            ), as: [[String: Any]].self)
            let row = try XCTUnwrap(listed.first { $0["attachment_id"] as? String == attachmentID.uuidString })
            XCTAssertEqual(row["available"] as? Bool, true, String(describing: row))
            XCTAssertEqual(row["publication"] as? String, "published")
            XCTAssertEqual(row["entry_count"] as? Int, 1)
            let retrieved = try object(Tools.call(
                "get_code_reference_entry",
                arguments: ["attachment_id": attachmentID.uuidString, "key": "ownership-probe"],
                container: container
            ))
            XCTAssertEqual(retrieved["reference_id"] as? String, reference.id.uuidString)
            XCTAssertEqual(retrieved["attachment_id"] as? String, attachmentID.uuidString)
            XCTAssertEqual(retrieved["id"] as? String, entry.id.uuidString)
            XCTAssertEqual(retrieved["body"] as? String, body)
            XCTAssertEqual(retrieved["publication"] as? String, "published")
        }

        try assertMCP(try Store.open(url: url))
        staleAttachment.defaultBranch = "probe-branch"
        try stale.mainContext.save()
        try assertMCP(try Store.open(url: url))
        try assertMCP(try Store.open(url: url))

        print("LIVE_STORE_URL=\(url.path)")
        print("LIVE_PROBE_ATTACHMENT=\(attachmentID.uuidString)")
        print("LIVE_PROBE_REFERENCE=\(reference.id.uuidString)")
        print("LIVE_PROBE_ENTRY=\(entry.id.uuidString)")
    }

    private func dropIndexingColumns(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            url.path,
            "ALTER TABLE ZAGENTRUN DROP COLUMN ZPURPOSERAW;",
            "ALTER TABLE ZAGENTRUN DROP COLUMN ZINDEXEDATTACHMENTIDSTRING;"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func makeSourceFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "func start() {}\n".write(to: root.appendingPathComponent("Sources/Runtime.swift"), atomically: true, encoding: .utf8)
        return root
    }

    private func object(_ payload: [String: Any]) throws -> [String: Any] {
        try object(payload, as: [String: Any].self)
    }

    private func object<T>(_ payload: [String: Any], as type: T.Type) throws -> T {
        if payload["isError"] as? Bool == true {
            let text = ((payload["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "error"
            throw NSError(domain: "CodeReferencePersistenceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        let text = try XCTUnwrap((payload["content"] as? [[String: Any]])?.first?["text"] as? String)
        let data = Data(text.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(json as? T)
    }
}


@MainActor
final class LiveSourceAccessTests: XCTestCase {
    func testLiveSlateProjectSourceToolsResolveAttachedRepository() async throws {
        guard ProcessInfo.processInfo.environment["SLATE_LIVE_SOURCE_VERIFY"] == "1"
            || ProcessInfo.processInfo.environment["TEST_RUNNER_SLATE_LIVE_SOURCE_VERIFY"] == "1"
        else {
            throw XCTSkip("Set TEST_RUNNER_SLATE_LIVE_SOURCE_VERIFY=1 to verify live Slate source access.")
        }
        let container = try Store.open()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let project = try XCTUnwrap(
            (try context.fetch(FetchDescriptor<Project>())).first { $0.name == "Slate" }
        )
        let listed = try object(Tools.call(
            "list_code_references",
            arguments: ["project_id": project.id.uuidString],
            container: container
        ), as: [[String: Any]].self)
        let row = try XCTUnwrap(listed.first { $0["available"] as? Bool == true })
        let attachmentID = try XCTUnwrap(row["attachment_id"] as? String)
        let key = try XCTUnwrap((row["entries"] as? [[String: Any]])?.first?["key"] as? String)

        let entry = try object(Tools.call(
            "get_code_reference_entry",
            arguments: ["attachment_id": attachmentID, "key": key],
            container: container
        ))
        let path = try XCTUnwrap((entry["source_locations"] as? [[String: Any]])?.first?["path"] as? String)
        let roots = ProjectCodeWorkspace.localRoots(for: project)
        XCTAssertFalse(roots.isEmpty, "Live Slate project should resolve authorized folder attachments")
        print("LIVE_REF_KEY=\(key)")
        print("LIVE_REF_PATH=\(path)")
        print("LIVE_ROOTS=\(roots.map(\.locator))")

        let frozen = SlateToolGateway(roots: [], includeSlateTools: false)
        do {
            _ = try await frozen.execute(
                name: "project_read_file",
                arguments: ["path": path, "root": roots[0].locator]
            )
            XCTFail("Empty session roots must not read source")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No code is attached"), error.localizedDescription)
        }

        let live = SlateToolGateway(
            roots: [],
            includeSlateTools: false,
            prepareRoots: { ProjectCodeWorkspace.localRoots(for: project) }
        )
        let files = try await live.execute(name: "project_list_files", arguments: ["query": path])
        XCTAssertTrue(files.contains(URL(fileURLWithPath: path).lastPathComponent), files)
        let read = try await live.execute(
            name: "project_read_file",
            arguments: ["path": path, "root": roots[0].locator, "start_line": 1, "end_line": 40]
        )
        XCTAssertFalse(read.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, read)
        print("LIVE_LIST=\(files.prefix(300))")
        print("LIVE_READ=\(read.prefix(400))")
        do {
            let log = try await live.execute(name: "project_git_log", arguments: [:])
            XCTAssertTrue(log.contains("sha"), log)
            print("LIVE_GIT=\(log.prefix(400))")
        } catch {
            print("LIVE_GIT_UNAVAILABLE=\(error.localizedDescription)")
        }
    }

    private func object(_ payload: [String: Any]) throws -> [String: Any] {
        try object(payload, as: [String: Any].self)
    }

    private func object<T>(_ payload: [String: Any], as type: T.Type) throws -> T {
        if payload["isError"] as? Bool == true {
            let text = ((payload["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "error"
            throw NSError(domain: "LiveSourceAccessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        let text = try XCTUnwrap((payload["content"] as? [[String: Any]])?.first?["text"] as? String)
        let data = Data(text.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(json as? T)
    }
}

@MainActor
final class LiveIndexEnqueueTests: XCTestCase {
    func testEnqueuePCOSIndexWithoutStarting() throws {
        let marker = Store.applicationGroupStoreURL?
            .deletingLastPathComponent()
            .appendingPathComponent("enqueue-live-index")
        let marked = marker.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard marked || ProcessInfo.processInfo.environment["SLATE_LIVE_ENQUEUE_INDEX"] == "1" else {
            throw XCTSkip("Set SLATE_LIVE_ENQUEUE_INDEX=1 to enqueue the live PC-OS index.")
        }
        let attachmentID = try XCTUnwrap(UUID(uuidString: "B4349BC5-1BEF-4E95-8C0C-E40A31067C33"))
        let container = try Store.open()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let attachment = try XCTUnwrap(CodeReferenceStore.attachment(attachmentID, in: context))
        let project = try XCTUnwrap(attachment.project)
        if let active = CodeReferenceStore.activeIndexingRun(for: attachment, in: context) {
            XCTFail("Already indexing \(active.id.uuidString)")
            return
        }
        let provider = project.workerProviderID.isEmpty ? "cursor" : project.workerProviderID
        let model = project.workerModelID.isEmpty ? "composer-2.5" : project.workerModelID
        let run = try RunStore.enqueue(
            RepositoryIndex.draft(for: attachment, project: project, providerID: provider, modelID: model),
            in: context
        )
        XCTAssertEqual(run.purpose, .indexRepository)
        XCTAssertEqual(run.indexedAttachmentID, attachmentID)
        let tools = RunToolPolicy.catalogNames(for: run)
        XCTAssertTrue(tools.contains("upsert_code_reference_entry"), String(describing: tools))
        XCTAssertTrue(tools.contains("set_code_reference_meta"), String(describing: tools))
        let url = try XCTUnwrap(Store.applicationGroupStoreURL)
        let disk = try XCTUnwrap(Store.persistedAgentRunIdentity(runID: run.id, at: url))
        XCTAssertEqual(disk.purpose, RunPurpose.indexRepository.rawValue)
        XCTAssertEqual(disk.attachmentID.lowercased(), attachmentID.uuidString.lowercased())
        print("LIVE_INDEX_RUN_ID=\(run.id.uuidString)")
        print("LIVE_INDEX_TOOLS=\(tools.joined(separator: ","))")
        if let marker {
            try? FileManager.default.removeItem(at: marker)
        }
    }
}
