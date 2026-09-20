import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T17: the v3 contract restores learning and Inbox data together — rows round-trip
/// verbatim, semantic payloads (resume JSON, receipt digests, controlled resource
/// IDs) are validated, unresolvable image references degrade to NULL keeping the
/// text, and restored commit receipts keep capture commits idempotent.
final class PortableBackupV3RestorationTests: XCTestCase {
    func testV3BackupRestoresInboxRowsVerbatimAndSummarizes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try InboxSeed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await seedInboxSource(source, seed: seed)
        let backup = try await exportV3Backup(from: source, fixture: fixture)

        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL,
            inboxImageResourceExists: { _ in true }
        )
        let prepared = try await preparer.prepare(fileURL: backup.url)

        XCTAssertEqual(prepared.sourceFormatVersion, 3)
        XCTAssertEqual(prepared.preparedFormatVersion, PortableBackupFormat.currentVersion)
        XCTAssertTrue(prepared.restoresInboxData)
        XCTAssertEqual(prepared.backup.inboxItemCount, 4)
        XCTAssertEqual(prepared.backup.processingContextCount, 2)
        XCTAssertEqual(prepared.backup.captureImportReceiptCount, 1)
        XCTAssertEqual(prepared.backup.inboxCommitReceiptCount, 1)
        XCTAssertEqual(prepared.backup.processingInboxItemCount, 1)
        XCTAssertEqual(
            prepared.excludedScopes,
            PortableBackupFormat.excludedScopes
        )

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        let snapshot = try await queue.read { db in
            (
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, text, source_type, status, source_app,
                               source_url, image_reference
                        FROM inbox_items ORDER BY created_at_ms, id
                        """
                ).map { row in
                    (
                        row["id"] as String,
                        row["text"] as String,
                        row["source_type"] as String,
                        row["status"] as String,
                        row["source_app"] as String?,
                        row["source_url"] as String?,
                        row["image_reference"] as String?
                    )
                },
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, payload_version, resume_payload_json, draft_id
                        FROM inbox_processing_contexts ORDER BY id
                        """
                ).map { row in
                    (
                        row["id"] as String,
                        row["payload_version"] as Int,
                        row["resume_payload_json"] as String?,
                        row["draft_id"] as String?
                    )
                },
                try Row.fetchAll(
                    db,
                    sql: "SELECT capture_id, payload_hash FROM capture_import_receipts"
                ).map { row in (row["capture_id"] as String, row["payload_hash"] as String) },
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT operation_id, payload_hash, result_json
                        FROM inbox_commit_receipts
                        """
                ).map { row in
                    (
                        row["operation_id"] as String,
                        row["payload_hash"] as String,
                        row["result_json"] as String
                    )
                }
            )
        }
        XCTAssertEqual(snapshot.0.count, 4)
        let processingRow = try XCTUnwrap(
            snapshot.0.first { $0.0 == DatabaseValueCodec.encode(seed.processingItemID) }
        )
        XCTAssertEqual(processingRow.1, "日本に行ったことがありますか。")
        XCTAssertEqual(processingRow.3, "processing")
        XCTAssertEqual(processingRow.2, "share")
        XCTAssertEqual(processingRow.4, "com.example.share")
        XCTAssertEqual(processingRow.5, "https://example.com/x")
        let imageRow = try XCTUnwrap(
            snapshot.0.first { $0.0 == DatabaseValueCodec.encode(seed.imageItemID) }
        )
        XCTAssertEqual(imageRow.6, "img_alpha1")

        XCTAssertEqual(snapshot.1.count, 2)
        let contextRow = try XCTUnwrap(
            snapshot.1.first { $0.0 == DatabaseValueCodec.encode(seed.analysisContextID) }
        )
        XCTAssertEqual(contextRow.1, 1)
        XCTAssertEqual(contextRow.2, seed.resumeJSON)
        XCTAssertEqual(contextRow.3, DatabaseValueCodec.encode(seed.draftID))

        let importReceipt = try XCTUnwrap(snapshot.2.first)
        XCTAssertEqual(importReceipt.0, DatabaseValueCodec.encode(seed.captureID))
        XCTAssertEqual(importReceipt.1, "share-import-hash")

        let commitReceipt = try XCTUnwrap(snapshot.3.first)
        XCTAssertEqual(commitReceipt.0, DatabaseValueCodec.encode(seed.operationID))
        XCTAssertEqual(commitReceipt.1, seed.commitPayloadHash)
        XCTAssertEqual(commitReceipt.2, seed.resultJSON)

        try await preparer.discard(prepared)
    }

    func testV3RoundTripRestoresInboxAndKeepsCommitReceiptIdempotent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try InboxSeed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await seedInboxSource(source, seed: seed)
        let backup = try await exportV3Backup(from: source, fixture: fixture)
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL,
            inboxImageResourceExists: { _ in true }
        )
        let prepared = try await preparer.prepare(fileURL: backup.url)
        try current.close()

        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: fixture.currentDatabaseURL,
            snapshotDirectoryURL: fixture.rootURL.appendingPathComponent("snapshots", isDirectory: true)
        )
        _ = try await lifecycle.open()
        let restored = try await lifecycle.replaceDatabase(with: prepared.temporaryDatabaseURL)

        let inboxCounts = try await restored.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_processing_contexts") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts") ?? 0
            )
        }
        XCTAssertEqual(inboxCounts.0, 4)
        XCTAssertEqual(inboxCounts.1, 2)
        XCTAssertEqual(inboxCounts.2, 1)

        // The restored commit receipt replays the same operation without
        // writing duplicates — post-restore capture commits stay idempotent.
        let repository = GRDBContentCardRepository(database: restored)
        let result = try await repository.commitVocabulary(
            seed.vocabularyCommit,
            capture: seed.captureContext
        )
        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.noteID, seed.committedNoteID)
        XCTAssertEqual(result.cardCount, 2)

        let postCounts = try await restored.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts") ?? 0,
                try String.fetchOne(
                    db,
                    sql: "SELECT status FROM inbox_items WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(seed.processedItemID)]
                )
            )
        }
        XCTAssertEqual(postCounts.0, 0, "Replay must not create notes")
        XCTAssertEqual(postCounts.1, 1, "Replay must not insert another receipt")
        XCTAssertEqual(postCounts.2, "processed")
    }

    func testV3ValidationRejectsMalformedInboxSemanticsWithoutTouchingCurrent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try InboxSeed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await seedInboxSource(source, seed: seed)
        try await seedCurrentDatabase(current)
        let backup = try await exportV3Backup(from: source, fixture: fixture)
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL,
            inboxImageResourceExists: { _ in true }
        )

        let cases: [(String, (inout [[String: Any]]) -> Void)] = [
            ("unknown payload_version", { objects in
                self.mutateRecord(&objects, type: "inboxProcessingContext") { record in
                    record["payload_version"] = 99
                }
            }),
            ("undecodable resume payload", { objects in
                self.mutateRecord(&objects, type: "inboxProcessingContext") { record in
                    guard record["resume_payload_json"] != nil else { return }
                    record["resume_payload_json"] = #"{"version":99}"#
                }
            }),
            ("non-hex commit digest", { objects in
                self.mutateRecord(&objects, type: "inboxCommitReceipt") { record in
                    record["payload_hash"] = "not-a-sha256"
                }
            }),
            ("path-like image reference", { objects in
                self.mutateRecord(&objects, type: "inboxItem") { record in
                    guard (record["image_reference"] as? String) != nil else { return }
                    record["image_reference"] = "/tmp/secret.png"
                }
            }),
            ("dangling context parent", { objects in
                self.mutateRecord(&objects, type: "inboxProcessingContext") { record in
                    record["inbox_item_id"] = UUID().uuidString.lowercased()
                }
            })
        ]

        for (index, entry) in cases.enumerated() {
            let (name, mutate) = entry
            let mutatedURL = fixture.rootURL.appendingPathComponent(
                "mutated-\(index).oboe-backup"
            )
            try rewriteBackup(backup.url, to: mutatedURL, transform: mutate)
            do {
                _ = try await preparer.prepare(fileURL: mutatedURL)
                XCTFail("\(name) must be rejected")
            } catch is PortableBackupPreparationError {
                // Expected — every malformed v3 record fails preparation.
            }
        }
        try await assertCurrentUntouched(current: current, fixture: fixture)
    }

    func testUnresolvableImageReferenceIsClearedWhileTextIsPreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try InboxSeed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await seedInboxSource(source, seed: seed)
        let backup = try await exportV3Backup(from: source, fixture: fixture)

        // No attachment store registered → every well-formed reference clears.
        let clearingPreparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )
        let cleared = try await clearingPreparer.prepare(fileURL: backup.url)
        let clearedQueue = try DatabaseQueue(path: cleared.temporaryDatabaseURL.path)
        let clearedRow = try await clearedQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT text, image_reference FROM inbox_items WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(seed.imageItemID)]
            ).map { ($0["text"] as String, $0["image_reference"] as String?) }
        }
        let clearedReference: String? = try XCTUnwrap(clearedRow).1
        XCTAssertNil(clearedReference)
        XCTAssertEqual(try XCTUnwrap(clearedRow).0, "添付付きメモ")
        try await clearingPreparer.discard(cleared)

        // A registered store resolving the ID keeps the reference intact.
        let resolvingPreparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL,
            inboxImageResourceExists: { $0 == "img_alpha1" }
        )
        let kept = try await resolvingPreparer.prepare(fileURL: backup.url)
        let keptQueue = try DatabaseQueue(path: kept.temporaryDatabaseURL.path)
        let keptReference: String? = try await keptQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT image_reference FROM inbox_items WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(seed.imageItemID)]
            )
        }
        XCTAssertEqual(keptReference, "img_alpha1")
        try await resolvingPreparer.discard(kept)
    }

    func testLegacyRestoreReportsNoInboxDataAndLeavesInboxEmpty() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try InboxSeed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await seedInboxSource(source, seed: seed)
        try await seedCurrentDatabase(current)
        let backup = try await exportV3Backup(from: source, fixture: fixture)

        let legacyURL = fixture.rootURL.appendingPathComponent("legacy-v2.oboe-backup")
        try rewriteBackup(backup.url, to: legacyURL) { objects in
            downgradeBackupToLegacyFormat(&objects, version: 2)
        }
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )
        let prepared = try await preparer.prepare(fileURL: legacyURL)

        XCTAssertEqual(prepared.sourceFormatVersion, 2)
        XCTAssertFalse(prepared.restoresInboxData)
        XCTAssertEqual(prepared.backup.inboxItemCount, 0)
        XCTAssertEqual(prepared.backup.processingInboxItemCount, 0)
        XCTAssertTrue(prepared.excludedScopes.isEmpty)
        // The preview can still warn how much local Inbox data would be lost.
        XCTAssertEqual(prepared.current.inboxItemCount, 1)
        XCTAssertEqual(prepared.current.processingInboxItemCount, 1)

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        let inboxCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items") ?? -1
        }
        XCTAssertEqual(inboxCount, 0)
        try await preparer.discard(prepared)
    }
}

private extension PortableBackupV3RestorationTests {
    /// Produces a genuine v3-format file: exports with the current (v4)
    /// exporter, then strips the fields a real v0.3 export never had. Restore
    /// coverage for the v3 source contract stays honest as the format evolves.
    func exportV3Backup(
        from database: OboeDatabase,
        fixture: Fixture
    ) async throws -> PortableBackupExport {
        let backup = try await PortableBackupExporter(
            database: database,
            workingDirectoryURL: fixture.exportsURL
        ).export(appVersion: "test", at: fixture.exportedAt)
        let legacyURL = fixture.rootURL.appendingPathComponent(
            "v3-\(backup.url.lastPathComponent)"
        )
        try rewriteBackup(backup.url, to: legacyURL) { objects in
            downgradeBackupToLegacyFormat(&objects, version: 3)
        }
        return PortableBackupExport(
            url: legacyURL,
            exportedAt: backup.exportedAt,
            recordCounts: backup.recordCounts
        )
    }

    struct Fixture {
        let rootURL: URL
        let sourceDatabaseURL: URL
        let currentDatabaseURL: URL
        let exportsURL: URL
        let preparationsURL: URL
        let exportedAt = Date(timeIntervalSince1970: 1_789_056_000.123)

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PortableBackupV3RestorationTests-\(UUID().uuidString)",
                isDirectory: true
            )
            sourceDatabaseURL = rootURL.appendingPathComponent("source.sqlite")
            currentDatabaseURL = rootURL.appendingPathComponent("current.sqlite")
            exportsURL = rootURL.appendingPathComponent("exports", isDirectory: true)
            preparationsURL = rootURL.appendingPathComponent("preparations", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    struct InboxSeed {
        let deckID = UUID()
        let draftID = UUID()
        let imageItemID = UUID()
        let processingItemID = UUID()
        let processedItemID = UUID()
        let archivedItemID = UUID()
        let analysisContextID = UUID()
        let manualContextID = UUID()
        let captureID = UUID()
        let operationID = UUID()
        let commitContextID = UUID()
        let committedNoteID = UUID()
        let resumeJSON: String
        let commitPayloadHash: String
        let resultJSON: String
        let vocabularyCommit: VocabularyContentCommit
        let captureContext: CaptureCommitContext

        init() throws {
            resumeJSON = try CaptureResumePayloadCodec.encode(
                CaptureResumePayload(
                    selection: CaptureTextSelection(utf16Offset: 0, utf16Length: 3),
                    targetDeckID: deckID,
                    selectedAnalysisItemIDs: [UUID()],
                    analysisContentRevision: 1,
                    pendingOperationID: operationID
                )
            )
            let commit = try VocabularyContentCommit(
                noteID: committedNoteID,
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: VocabularyFormData(
                    headword: "食べる",
                    meaningZH: "吃"
                ).validatedContent(),
                tags: [],
                cards: [
                    NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese),
                    NewCardSeed(id: UUID(), templateKind: .vocabularyChineseToJapanese)
                ],
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_789_060_000),
                origin: .ai,
                sourceText: "食べる"
            )
            vocabularyCommit = commit
            commitPayloadHash = CaptureCommitDigest.vocabulary(commit)
            resultJSON = #"{"note_id":""# + committedNoteID.uuidString
                + #"","card_count":2}"#
            captureContext = CaptureCommitContext(
                operationID: operationID,
                processingContextID: commitContextID,
                inboxItemID: processedItemID,
                expectedContentRevision: 1,
                sourceText: "食べる"
            )
        }
    }

    func seedInboxSource(_ database: OboeDatabase, seed: InboxSeed) async throws {
        let encode: @Sendable (UUID) -> String = DatabaseValueCodec.encode
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '收集箱源', 0, 1, 2)",
                arguments: [encode(seed.deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO drafts VALUES(
                        ?, 'vocabulary', 1, '{"headword":"食べる"}',
                        'provider', 'model', 'prompt-v1', 1789056000000
                    )
                    """,
                arguments: [encode(seed.draftID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        source_app, source_url, image_reference,
                        created_at_ms, updated_at_ms, processed_at_ms,
                        archived_at_ms, status_before_archive
                    ) VALUES (?, '添付付きメモ', 'manual', 'unprocessed', 1,
                        NULL, NULL, 'img_alpha1', 1789056000000, 1789056000000,
                        NULL, NULL, NULL)
                    """,
                arguments: [encode(seed.imageItemID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        source_app, source_url, image_reference,
                        created_at_ms, updated_at_ms, processed_at_ms,
                        archived_at_ms, status_before_archive
                    ) VALUES (?, '日本に行ったことがありますか。', 'share', 'processing', 2,
                        'com.example.share', 'https://example.com/x', NULL,
                        1789056001000, 1789056001000, NULL, NULL, NULL)
                    """,
                arguments: [encode(seed.processingItemID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        source_app, source_url, image_reference,
                        created_at_ms, updated_at_ms, processed_at_ms,
                        archived_at_ms, status_before_archive
                    ) VALUES (?, '食べる', 'paste', 'processed', 1,
                        NULL, NULL, NULL, 1789056002000, 1789056002000,
                        1789056100000, NULL, NULL)
                    """,
                arguments: [encode(seed.processedItemID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        source_app, source_url, image_reference,
                        created_at_ms, updated_at_ms, processed_at_ms,
                        archived_at_ms, status_before_archive
                    ) VALUES (?, '古いメモ', 'manual', 'archived', 1,
                        NULL, NULL, NULL, 1789056003000, 1789056003000,
                        NULL, 1789056200000, 'unprocessed')
                    """,
                arguments: [encode(seed.archivedItemID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_processing_contexts(
                        id, inbox_item_id, content_revision, input_text, mode,
                        draft_id, payload_version, resume_payload_json, updated_at_ms
                    ) VALUES (?, ?, 2, '日本に行ったことがありますか。',
                        'sentence_analysis', ?, 1, ?, 1789056001500)
                    """,
                arguments: [
                    encode(seed.analysisContextID), encode(seed.processingItemID),
                    encode(seed.draftID), seed.resumeJSON
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_processing_contexts(
                        id, inbox_item_id, content_revision, input_text, mode,
                        draft_id, payload_version, resume_payload_json, updated_at_ms
                    ) VALUES (?, ?, 1, '食べる', 'vocabulary_generation',
                        NULL, 1, NULL, 1789056002500)
                    """,
                arguments: [encode(seed.commitContextID), encode(seed.processedItemID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO capture_import_receipts(
                        capture_id, payload_hash, inbox_item_id, imported_at_ms
                    ) VALUES (?, 'share-import-hash', ?, 1789056001000)
                    """,
                arguments: [encode(seed.captureID), encode(seed.processingItemID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_commit_receipts(
                        operation_id, processing_context_id, payload_hash,
                        result_json, committed_at_ms
                    ) VALUES (?, ?, ?, ?, 1789056100000)
                    """,
                arguments: [
                    encode(seed.operationID), encode(seed.commitContextID),
                    seed.commitPayloadHash, seed.resultJSON
                ]
            )
        }
    }

    func seedCurrentDatabase(_ database: OboeDatabase) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '当前资料', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(UUID())]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        source_app, source_url, image_reference,
                        created_at_ms, updated_at_ms, processed_at_ms,
                        archived_at_ms, status_before_archive
                    ) VALUES (?, '本地处理中', 'manual', 'processing', 1,
                        NULL, NULL, NULL, 1789056000000, 1789056000000,
                        NULL, NULL, NULL)
                    """,
                arguments: [DatabaseValueCodec.encode(UUID())]
            )
        }
    }

    func mutateRecord(
        _ objects: inout [[String: Any]],
        type: String,
        mutate: (inout [String: Any]) -> Void
    ) {
        for index in objects.indices where objects[index]["recordType"] as? String == type {
            mutate(&objects[index])
        }
    }

    func assertCurrentUntouched(
        current: OboeDatabase,
        fixture: Fixture
    ) async throws {
        let names = try await current.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(names, ["当前资料"])
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: fixture.preparationsURL,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Failed preparation left files: \(leftovers)")
    }
}
