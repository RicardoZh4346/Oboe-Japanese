import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class OboeInboxSchemaTests: XCTestCase {
    func testFreshDatabaseCreatesInboxTablesAndIndexes() throws {
        try withTemporaryDatabase { database in
            let tableNames = try database.pool.read { db in
                Set(try String.fetchAll(
                    db,
                    sql: """
                        SELECT name FROM sqlite_master
                        WHERE type = 'table' AND name IN (
                            'inbox_items', 'inbox_processing_contexts',
                            'capture_import_receipts', 'inbox_commit_receipts'
                        )
                        """
                ))
            }
            let indexNames = try database.pool.read { db in
                Set(try String.fetchAll(
                    db,
                    sql: """
                        SELECT name FROM sqlite_master
                        WHERE type = 'index'
                          AND (name LIKE 'inbox_%' OR name LIKE 'capture_%')
                        """
                ))
            }

            XCTAssertEqual(tableNames, [
                "inbox_items", "inbox_processing_contexts",
                "capture_import_receipts", "inbox_commit_receipts"
            ])
            XCTAssertEqual(indexNames, [
                "inbox_items_on_status_created_at",
                "inbox_items_on_created_at",
                "inbox_processing_contexts_on_inbox_item_id",
                "inbox_processing_contexts_on_draft_id",
                "capture_import_receipts_on_inbox_item_id",
                "inbox_commit_receipts_on_processing_context_id"
            ])
        }
    }

    func testV6DatabaseUpgradesToV7PreservingExistingData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OboeInboxSchemaTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("oboe.sqlite")
        let deckID = UUID()
        let noteID = UUID()

        do {
            let pool = try OboeDatabase.openPool(path: fileURL.path)
            let migrator = OboeDatabaseSchema.makeMigrator()
            try migrator.migrate(pool, upTo: "v6_builtin_jlpt_source")
            try pool.write { db in
                try insertDeck(id: deckID, name: "升级保留", in: db)
                try insertNote(id: noteID, deckID: deckID, in: db)
            }
            try pool.close()
        }

        let database = try OboeDatabase(path: fileURL.path)
        let result = try database.pool.read { db in
            (
                try String.fetchOne(db, sql: "SELECT name FROM decks")!,
                try String.fetchOne(db, sql: "SELECT headword FROM notes")!,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items")!,
                try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
            )
        }

        XCTAssertEqual(result.0, "升级保留")
        XCTAssertEqual(result.1, "食べる")
        XCTAssertEqual(result.2, 0)
        XCTAssertEqual(result.3, Set(OboeDatabaseSchema.migrationIdentifiers))
    }

    func testInboxItemEnumAndRevisionConstraintsAreEnforced() throws {
        try withTemporaryDatabase { database in
            XCTAssertThrowsError(try database.pool.write { db in
                try insertInboxItem(in: db, sourceType: "clipboard")
            })
            XCTAssertThrowsError(try database.pool.write { db in
                try insertInboxItem(in: db, status: "pending")
            })
            XCTAssertThrowsError(try database.pool.write { db in
                try insertInboxItem(in: db, contentRevision: 0)
            })
            for sourceType in InboxSourceType.allCases {
                try database.pool.write { db in
                    try insertInboxItem(in: db, sourceType: sourceType.rawValue)
                }
            }
            let count = try database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items")!
            }
            XCTAssertEqual(count, InboxSourceType.allCases.count)
        }
    }

    func testInboxItemTextConstraintsAreEnforced() throws {
        try withTemporaryDatabase { database in
            XCTAssertThrowsError(try database.pool.write { db in
                try insertInboxItem(in: db, text: "")
            })
            XCTAssertThrowsError(try database.pool.write { db in
                try insertInboxItem(in: db, text: "   ")
            })
            let oversized = String(
                repeating: "あ",
                count: InboxText.maximumUTF8ByteCount / 3 + 1
            )
            XCTAssertThrowsError(try database.pool.write { db in
                try insertInboxItem(in: db, text: oversized)
            })
            let twentyThousandCharacters = String(repeating: "あ", count: 20_000)
            try database.pool.write { db in
                try insertInboxItem(in: db, text: twentyThousandCharacters)
            }
        }
    }

    func testInboxItemArchiveAndProcessedInvariants() throws {
        try withTemporaryDatabase { database in
            XCTAssertThrowsError(try database.pool.write { db in
                try insertInboxItem(in: db, status: "archived")
            })
            XCTAssertThrowsError(try database.pool.write { db in
                try insertInboxItem(in: db, statusBeforeArchive: "processed")
            })
            XCTAssertThrowsError(try database.pool.write { db in
                try insertInboxItem(
                    in: db,
                    status: "archived",
                    archivedAtMilliseconds: 2,
                    statusBeforeArchive: "archived"
                )
            })
            XCTAssertThrowsError(try database.pool.write { db in
                try insertInboxItem(in: db, status: "processed")
            })

            try database.pool.write { db in
                try insertInboxItem(
                    in: db,
                    status: "archived",
                    processedAtMilliseconds: 1,
                    archivedAtMilliseconds: 2,
                    statusBeforeArchive: "processed"
                )
                try insertInboxItem(
                    in: db,
                    status: "processed",
                    processedAtMilliseconds: 2
                )
            }
        }
    }

    func testProcessingContextRequiresExistingInboxAndCascadesOnDelete() throws {
        try withTemporaryDatabase { database in
            XCTAssertThrowsError(try database.pool.write { db in
                try insertContext(in: db, inboxItemID: DatabaseValueCodec.encode(UUID()))
            })

            let inboxID = DatabaseValueCodec.encode(UUID())
            try database.pool.write { db in
                try insertInboxItem(in: db, id: inboxID)
                try insertContext(in: db, inboxItemID: inboxID)
            }

            try database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM inbox_items WHERE id = ?",
                    arguments: [inboxID]
                )
            }

            let remaining = try database.pool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM inbox_processing_contexts"
                )!
            }
            XCTAssertEqual(remaining, 0)
        }
    }

    func testProcessingContextModeVersionAndPayloadConstraints() throws {
        try withTemporaryDatabase { database in
            let inboxID = DatabaseValueCodec.encode(UUID())
            try database.pool.write { db in
                try insertInboxItem(in: db, id: inboxID)
            }

            XCTAssertThrowsError(try database.pool.write { db in
                try insertContext(in: db, inboxItemID: inboxID, mode: "flashcard")
            })
            XCTAssertThrowsError(try database.pool.write { db in
                try insertContext(in: db, inboxItemID: inboxID, payloadVersion: 0)
            })
            XCTAssertThrowsError(try database.pool.write { db in
                try insertContext(in: db, inboxItemID: inboxID, resumePayload: "{invalid")
            })
            let oversizedPayload = #"{"k":""# + String(
                repeating: "x",
                count: CaptureResumePayloadFormat.maximumUTF8ByteCount
            ) + #""}"#
            XCTAssertThrowsError(try database.pool.write { db in
                try insertContext(
                    in: db,
                    inboxItemID: inboxID,
                    resumePayload: oversizedPayload
                )
            })
            XCTAssertThrowsError(try database.pool.write { db in
                try insertContext(in: db, inboxItemID: inboxID, inputText: "  ")
            })

            try database.pool.write { db in
                try insertContext(
                    in: db,
                    inboxItemID: inboxID,
                    resumePayload: #"{"version":1,"selectedItems":[]}"#
                )
            }
        }
    }

    func testDraftDeletionNullsContextDraftWithoutDeletingContext() throws {
        try withTemporaryDatabase { database in
            let inboxID = DatabaseValueCodec.encode(UUID())
            let contextID = DatabaseValueCodec.encode(UUID())
            let draftID = DatabaseValueCodec.encode(UUID())
            try database.pool.write { db in
                try insertInboxItem(in: db, id: inboxID)
                try insertDraft(in: db, id: draftID)
                try insertContext(
                    in: db,
                    id: contextID,
                    inboxItemID: inboxID,
                    draftID: draftID
                )
            }

            try database.pool.write { db in
                try db.execute(sql: "DELETE FROM drafts WHERE id = ?", arguments: [draftID])
            }

            let row = try database.pool.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT id, draft_id FROM inbox_processing_contexts WHERE id = ?",
                    arguments: [contextID]
                )
            }
            XCTAssertEqual(row?["id"], contextID)
            XCTAssertNil(row?["draft_id"])
        }
    }

    func testImportReceiptSurvivesInboxDeletionWithNullifiedReference() throws {
        try withTemporaryDatabase { database in
            let inboxID = DatabaseValueCodec.encode(UUID())
            let captureID = DatabaseValueCodec.encode(UUID())
            try database.pool.write { db in
                try insertInboxItem(in: db, id: inboxID)
                try db.execute(
                    sql: """
                        INSERT INTO capture_import_receipts(
                            capture_id, payload_hash, inbox_item_id, imported_at_ms
                        ) VALUES (?, ?, ?, 1)
                        """,
                    arguments: [captureID, "hash-1", inboxID]
                )
            }

            try database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM inbox_items WHERE id = ?",
                    arguments: [inboxID]
                )
            }

            let row = try database.pool.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT capture_id, inbox_item_id FROM capture_import_receipts"
                )
            }
            XCTAssertEqual(row?["capture_id"], captureID)
            XCTAssertNil(row?["inbox_item_id"])
        }
    }

    func testCommitReceiptSurvivesContextDeletionAndValidatesResult() throws {
        try withTemporaryDatabase { database in
            let inboxID = DatabaseValueCodec.encode(UUID())
            let contextID = DatabaseValueCodec.encode(UUID())
            let operationID = DatabaseValueCodec.encode(UUID())
            try database.pool.write { db in
                try insertInboxItem(in: db, id: inboxID)
                try insertContext(in: db, id: contextID, inboxItemID: inboxID)
                try db.execute(
                    sql: """
                        INSERT INTO inbox_commit_receipts(
                            operation_id, processing_context_id, payload_hash,
                            result_json, committed_at_ms
                        ) VALUES (?, ?, ?, ?, 1)
                        """,
                    arguments: [
                        operationID,
                        contextID,
                        "hash-1",
                        "{\"version\":1,\"noteIDs\":[\"\(DatabaseValueCodec.encode(UUID()))\"],\"cardCount\":2}"
                    ]
                )
            }

            XCTAssertThrowsError(try database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO inbox_commit_receipts(
                            operation_id, processing_context_id, payload_hash,
                            result_json, committed_at_ms
                        ) VALUES (?, NULL, ?, '{invalid', 1)
                        """,
                    arguments: [DatabaseValueCodec.encode(UUID()), "hash-2"]
                )
            })
            XCTAssertThrowsError(try database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO inbox_commit_receipts(
                            operation_id, processing_context_id, payload_hash,
                            result_json, committed_at_ms
                        ) VALUES (?, ?, '', '{}', 1)
                        """,
                    arguments: [DatabaseValueCodec.encode(UUID()), contextID]
                )
            })

            try database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM inbox_items WHERE id = ?",
                    arguments: [inboxID]
                )
            }

            let row = try database.pool.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT operation_id, processing_context_id FROM inbox_commit_receipts"
                )
            }
            XCTAssertEqual(row?["operation_id"], operationID)
            XCTAssertNil(row?["processing_context_id"])
        }
    }

    func testDeletingInboxDoesNotTouchLearningContent() throws {
        try withTemporaryDatabase { database in
            let deckID = UUID()
            let noteID = UUID()
            let inboxID = DatabaseValueCodec.encode(UUID())
            try database.pool.write { db in
                try insertDeck(id: deckID, name: "学习内容", in: db)
                try insertNote(id: noteID, deckID: deckID, in: db)
                try insertInboxItem(in: db, id: inboxID)
                try insertContext(in: db, inboxItemID: inboxID)
            }

            try database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM inbox_items WHERE id = ?",
                    arguments: [inboxID]
                )
            }

            let counts = try database.pool.read { db in
                (
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decks")!,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes")!,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items")!,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_processing_contexts")!
                )
            }
            XCTAssertEqual(counts.0, 1)
            XCTAssertEqual(counts.1, 1)
            XCTAssertEqual(counts.2, 0)
            XCTAssertEqual(counts.3, 0)
        }
    }
}

private extension OboeInboxSchemaTests {
    func withTemporaryDatabase(_ body: (OboeDatabase) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OboeInboxSchemaTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try OboeDatabase(
            path: directory.appendingPathComponent("oboe.sqlite").path
        )
        try body(database)
    }

    func insertDeck(id: UUID, name: String, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, ?, 0, 1, 1)",
            arguments: [DatabaseValueCodec.encode(id), name]
        )
    }

    func insertNote(id: UUID, deckID: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, reading, meaning_zh,
                    origin, content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃', 'manual', 1, 1, 1)
                """,
            arguments: [DatabaseValueCodec.encode(id), DatabaseValueCodec.encode(deckID)]
        )
        try insertHomeMembershipIfSupported(noteID: id, deckID: deckID, in: db)
    }

    func insertDraft(in db: Database, id: String) throws {
        try db.execute(
            sql: """
                INSERT INTO drafts(
                    id, draft_kind, payload_version, payload_json, updated_at_ms
                ) VALUES (?, 'vocabulary', 1, '{}', 1)
                """,
            arguments: [id]
        )
    }

    func insertInboxItem(
        in db: Database,
        id: String = DatabaseValueCodec.encode(UUID()),
        text: String = "そんなわけないでしょう。",
        sourceType: String = "manual",
        status: String = "unprocessed",
        contentRevision: Int = 1,
        processedAtMilliseconds: Int64? = nil,
        archivedAtMilliseconds: Int64? = nil,
        statusBeforeArchive: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO inbox_items(
                    id, text, source_type, status, content_revision,
                    created_at_ms, updated_at_ms, processed_at_ms,
                    archived_at_ms, status_before_archive
                ) VALUES (?, ?, ?, ?, ?, 1, 1, ?, ?, ?)
                """,
            arguments: [
                id, text, sourceType, status, contentRevision,
                processedAtMilliseconds, archivedAtMilliseconds, statusBeforeArchive
            ]
        )
    }

    func insertContext(
        in db: Database,
        id: String = DatabaseValueCodec.encode(UUID()),
        inboxItemID: String,
        inputText: String = "そんなわけないでしょう。",
        mode: String = "sentence_analysis",
        draftID: String? = nil,
        payloadVersion: Int = 1,
        resumePayload: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO inbox_processing_contexts(
                    id, inbox_item_id, content_revision, input_text, mode,
                    draft_id, payload_version, resume_payload_json, updated_at_ms
                ) VALUES (?, ?, 1, ?, ?, ?, ?, ?, 1)
                """,
            arguments: [
                id, inboxItemID, inputText, mode,
                draftID, payloadVersion, resumePayload
            ]
        )
    }
}
