import CryptoKit
import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class PortableBackupExporterTests: XCTestCase {
    func testExportIsIndependentlyParseableCompleteAndExcludesConnectionSettings() async throws {
        let location = try BackupTestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        try await seedEveryExportedRecord(in: database)
        let exportedAt = Date(timeIntervalSince1970: 1_789_056_000.123)
        let exporter = PortableBackupExporter(
            database: database,
            workingDirectoryURL: location.exportsURL
        )

        let result = try await exporter.export(
            appVersion: "0.1.0-test",
            at: exportedAt
        )

        XCTAssertEqual(result.url.pathExtension, "oboe-backup")
        XCTAssertEqual(result.exportedAt, exportedAt)
        XCTAssertEqual(Set(result.recordCounts.keys), Set(Self.recordTypes))
        XCTAssertTrue(result.recordCounts.values.allSatisfy { $0 == 1 })

        let parsed = try parseIndependently(result.url)
        XCTAssertEqual(parsed.records.first?["recordType"] as? String, "manifest")
        XCTAssertEqual(parsed.records.last?["recordType"] as? String, "footer")
        let manifest = try XCTUnwrap(parsed.records.first)
        XCTAssertEqual(manifest["format"] as? String, "oboe-portable-backup")
        XCTAssertEqual(manifest["formatVersion"] as? Int, PortableBackupFormat.currentVersion)
        XCTAssertEqual(manifest["appVersion"] as? String, "0.1.0-test")
        XCTAssertEqual(manifest["encoding"] as? String, "utf-8")
        XCTAssertEqual(manifest["lineEnding"] as? String, "lf")
        XCTAssertEqual(manifest["checksumAlgorithm"] as? String, "sha256")
        XCTAssertEqual(manifest["recordOrder"] as? [String], Self.recordTypes)
        XCTAssertEqual(
            manifest["excludedScopes"] as? [String],
            [
                "credentials", "aiConnectionConfiguration", "sharedTransferFiles",
                "imageAttachments", "derivedSearchIndex"
            ]
        )

        let bodyRecords = parsed.records.dropFirst().dropLast()
        XCTAssertEqual(bodyRecords.count, Self.recordTypes.count)
        XCTAssertEqual(
            bodyRecords.compactMap { $0["recordType"] as? String },
            Self.recordTypes
        )
        XCTAssertEqual(
            bodyRecords.first(where: { $0["recordType"] as? String == "note" })?["headword"] as? String,
            "食べる"
        )
        XCTAssertEqual(
            bodyRecords.first(where: { $0["recordType"] as? String == "note" })?["source_ref"] as? String,
            "openjlpt:N5:000001"
        )
        XCTAssertEqual(
            bodyRecords.first(where: { $0["recordType"] as? String == "review" })?["undone_at_ms"] as? Int,
            1_789_056_100_000
        )
        XCTAssertEqual(
            bodyRecords.first(where: { $0["recordType"] as? String == "draft" })?["payload_json"] as? String,
            #"{"headword":"秘密草稿"}"#
        )

        let inboxItem = try XCTUnwrap(
            bodyRecords.first(where: { $0["recordType"] as? String == "inboxItem" })
        )
        XCTAssertEqual(inboxItem["text"] as? String, "パンを食べる")
        XCTAssertEqual(inboxItem["source_type"] as? String, "share")
        XCTAssertEqual(inboxItem["status"] as? String, "processing")
        XCTAssertEqual(inboxItem["content_revision"] as? Int, 2)
        XCTAssertEqual(inboxItem["source_app"] as? String, "com.apple.mobilesafari")
        XCTAssertEqual(inboxItem["source_url"] as? String, "https://example.com/article")
        XCTAssertEqual(
            inboxItem["image_reference"] as? String,
            "inbox-image-resource-01",
            "image_reference must stay an opaque resource ID, never a file path"
        )
        XCTAssertEqual(inboxItem["processed_at_ms"] as? NSNull, NSNull())
        XCTAssertEqual(inboxItem["archived_at_ms"] as? NSNull, NSNull())

        let context = try XCTUnwrap(
            bodyRecords.first(where: { $0["recordType"] as? String == "inboxProcessingContext" })
        )
        XCTAssertEqual(context["inbox_item_id"] as? String, inboxItem["id"] as? String)
        XCTAssertEqual(context["input_text"] as? String, "パンを食べる")
        XCTAssertEqual(context["mode"] as? String, "sentence_analysis")
        XCTAssertEqual(context["content_revision"] as? Int, 2)
        XCTAssertEqual(context["payload_version"] as? Int, 1)
        XCTAssertEqual(
            context["resume_payload_json"] as? String,
            #"{"version":1,"mode":"sentence_analysis"}"#
        )

        let importReceipt = try XCTUnwrap(
            bodyRecords.first(where: { $0["recordType"] as? String == "captureImportReceipt" })
        )
        XCTAssertEqual(importReceipt["inbox_item_id"] as? String, inboxItem["id"] as? String)
        XCTAssertEqual((importReceipt["payload_hash"] as? String)?.count, 64)

        let commitReceipt = try XCTUnwrap(
            bodyRecords.first(where: { $0["recordType"] as? String == "inboxCommitReceipt" })
        )
        XCTAssertEqual(commitReceipt["processing_context_id"] as? String, context["id"] as? String)
        XCTAssertEqual((commitReceipt["payload_hash"] as? String)?.count, 64)
        XCTAssertEqual(
            commitReceipt["result_json"] as? String,
            #"{"noteID":"9B361C4E-7A77-4E46-9B25-4BD90B96CCE1"}"#
        )

        let settings = try XCTUnwrap(
            bodyRecords.first(where: { $0["recordType"] as? String == "settings" })
        )
        XCTAssertNil(settings["ai_provider_id"])
        XCTAssertNil(settings["ai_enabled"])
        XCTAssertNil(settings["ai_service_name"])
        XCTAssertNil(settings["ai_base_url"])
        XCTAssertNil(settings["ai_model_id"])
        XCTAssertNil(settings["ai_credential_id"])
        XCTAssertNil(settings["ai_response_format_mode"])
        let rawText = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertFalse(rawText.contains("secret.example"))
        XCTAssertFalse(rawText.contains("secret-model"))
        XCTAssertFalse(rawText.contains("search-index-only-secret"))
        XCTAssertFalse(rawText.contains("file://"))
        XCTAssertFalse(rawText.contains("/var/"))

        let footer = try XCTUnwrap(parsed.records.last)
        XCTAssertEqual(footer["checksumAlgorithm"] as? String, "sha256")
        XCTAssertEqual(footer["checksum"] as? String, parsed.bodyChecksum)
        XCTAssertEqual(parsed.bodyChecksum.count, 64)
    }

    func testExportReadsOnlyTheConsistentSnapshotWhenLiveDatabaseChanges() async throws {
        let location = try BackupTestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let deckID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, '快照前', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        let exporter = PortableBackupExporter(
            database: database,
            workingDirectoryURL: location.exportsURL,
            snapshotCreatedHook: {
                try await database.pool.write { db in
                    try db.execute(
                        sql: "UPDATE decks SET name = '快照后', updated_at_ms = 2 WHERE id = ?",
                        arguments: [DatabaseValueCodec.encode(deckID)]
                    )
                }
            }
        )

        let result = try await exporter.export(appVersion: "test", at: Date(timeIntervalSince1970: 2))
        let parsed = try parseIndependently(result.url)
        let exportedDeck = try XCTUnwrap(
            parsed.records.first(where: { $0["recordType"] as? String == "deck" })
        )
        let liveName = try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM decks WHERE id = ?", arguments: [DatabaseValueCodec.encode(deckID)])
        }

        XCTAssertEqual(exportedDeck["name"] as? String, "快照前")
        XCTAssertEqual(liveName, "快照后")
        XCTAssertEqual(result.recordCounts["deck"], 1)
        XCTAssertEqual(Set(result.recordCounts.keys), Set(Self.recordTypes))
        XCTAssertEqual(result.recordCounts["inboxItem"], 0)
        XCTAssertEqual(result.recordCounts["inboxProcessingContext"], 0)
        XCTAssertEqual(result.recordCounts["captureImportReceipt"], 0)
        XCTAssertEqual(result.recordCounts["inboxCommitReceipt"], 0)
    }
}

private extension PortableBackupExporterTests {
    static let recordTypes = [
        "deck", "note", "noteDeck", "sourceContext", "example", "tag",
        "noteTag", "profile", "card", "studyDay", "dailyTask", "review",
        "draft", "inboxItem", "inboxProcessingContext", "captureImportReceipt",
        "inboxCommitReceipt", "customStudySession", "practiceAttempt",
        "scheduledReviewOrigin", "settings"
    ]

    struct ParsedBackup {
        let records: [[String: Any]]
        let bodyChecksum: String
    }

    struct BackupTestLocation {
        let rootURL: URL
        let databaseURL: URL
        let exportsURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PortableBackupExporterTests-\(UUID().uuidString)",
                isDirectory: true
            )
            databaseURL = rootURL.appendingPathComponent("oboe.sqlite")
            exportsURL = rootURL.appendingPathComponent("exports", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func parseIndependently(_ url: URL) throws -> ParsedBackup {
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.last, 0x0A, "NDJSON must use a final LF")
        let lineBytes = data.split(separator: 0x0A)
        var records: [[String: Any]] = []
        for line in lineBytes {
            let object = try JSONSerialization.jsonObject(with: Data(line))
            records.append(try XCTUnwrap(object as? [String: Any]))
        }
        XCTAssertGreaterThanOrEqual(records.count, 2)

        let bodyLength = lineBytes.dropLast().reduce(0) { $0 + $1.count + 1 }
        let body = data.prefix(bodyLength)
        let digest = SHA256.hash(data: body)
        let checksum = digest.map { String(format: "%02x", $0) }.joined()
        return ParsedBackup(records: records, bodyChecksum: checksum)
    }

    func seedEveryExportedRecord(in database: OboeDatabase) async throws {
        let deckID = UUID()
        let noteID = UUID()
        let exampleID = UUID()
        let tagID = UUID()
        let profileID = UUID()
        let cardID = UUID()
        let studyDayID = UUID()
        let reviewID = UUID()
        let eventID = UUID()
        let draftID = UUID()
        let inboxItemID = UUID()
        let inboxContextID = UUID()
        let captureID = UUID()
        let operationID = UUID()
        let encode: @Sendable (UUID) -> String = DatabaseValueCodec.encode

        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '完整备份', 0, 1, 2)",
                arguments: [encode(deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh, part_of_speech,
                        jlpt, usage, connection, notes, is_favorite, source_text, origin,
                        source_ref, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃', '动词',
                        'N5', '用法', NULL, '说明', 1, '原句', 'builtin_jlpt',
                        'openjlpt:N5:000001', 2, 3, 4)
                    """,
                arguments: [encode(noteID), encode(deckID)]
            )
            try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
            try db.execute(
                sql: "INSERT INTO examples VALUES (?, ?, '魚を食べる。', '吃鱼。', 0)",
                arguments: [encode(exampleID), encode(noteID)]
            )
            try db.execute(
                sql: "INSERT INTO tags VALUES (?, '动词', '动词')",
                arguments: [encode(tagID)]
            )
            try db.execute(
                sql: "INSERT INTO note_tags VALUES (?, ?)",
                arguments: [encode(noteID), encode(tagID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles VALUES(
                        ?, 'test-r90-v1', 'FSRS-6.0', 'test-revision', '{}', 0.9, 36500, 5
                    )
                    """,
                arguments: [encode(profileID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO cards VALUES(
                        ?, ?, 'vocabulary_ja_zh', 1, 2, 1789057000000, 1789056000000,
                        3.5, 4.5, 2, 1, 1, 0, 0, 1789056000000, 2, 'FSRS-6.0', ?
                    )
                    """,
                arguments: [encode(cardID), encode(noteID), encode(profileID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO study_days VALUES(
                        ?, '2026-09-11', 'Asia/Shanghai', 1789056000000, 1789142400000, 10
                    )
                    """,
                arguments: [encode(studyDayID)]
            )
            try db.execute(
                sql: "INSERT INTO daily_tasks VALUES (?, ?, 'new', 1789056000000, NULL)",
                arguments: [encode(studyDayID), encode(cardID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO review_logs VALUES(
                        ?, ?, ?, ?, ?, ?, 1789056000123, ?, 1, 3,
                        '{"state":0}', '{"state":2}', 800, 2, ?, 'FSRS-6.0', 1789056100000
                    )
                    """,
                arguments: [
                    encode(reviewID), encode(eventID), encode(cardID), encode(cardID),
                    encode(noteID), encode(deckID), encode(studyDayID), encode(profileID)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO drafts VALUES(
                        ?, 'vocabulary', 1, '{"headword":"秘密草稿"}',
                        'draft-provider', 'draft-model', 'prompt-v1', 1789056000000
                    )
                    """,
                arguments: [encode(draftID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        source_app, source_url, image_reference,
                        created_at_ms, updated_at_ms, processed_at_ms,
                        archived_at_ms, status_before_archive
                    ) VALUES (
                        ?, 'パンを食べる', 'share', 'processing', 2,
                        'com.apple.mobilesafari', 'https://example.com/article',
                        'inbox-image-resource-01',
                        1789056000001, 1789056000002, NULL, NULL, NULL
                    )
                    """,
                arguments: [encode(inboxItemID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_processing_contexts(
                        id, inbox_item_id, content_revision, input_text, mode,
                        draft_id, payload_version, resume_payload_json, updated_at_ms
                    ) VALUES (
                        ?, ?, 2, 'パンを食べる', 'sentence_analysis',
                        ?, 1, '{"version":1,"mode":"sentence_analysis"}',
                        1789056000003
                    )
                    """,
                arguments: [encode(inboxContextID), encode(inboxItemID), encode(draftID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO capture_import_receipts(
                        capture_id, payload_hash, inbox_item_id, imported_at_ms
                    ) VALUES (?, ?, ?, 1789056000000)
                    """,
                arguments: [
                    encode(captureID), String(repeating: "ab", count: 32),
                    encode(inboxItemID)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_commit_receipts(
                        operation_id, processing_context_id, payload_hash,
                        result_json, committed_at_ms
                    ) VALUES (?, ?, ?, ?, 1789056000004)
                    """,
                arguments: [
                    encode(operationID), encode(inboxContextID),
                    String(repeating: "cd", count: 32),
                    #"{"noteID":"9B361C4E-7A77-4E46-9B25-4BD90B96CCE1"}"#
                ]
            )
            // v7 新表：sourceContext 紧随 note（FK note_id）；
            // Custom Study 三表按 session → attempt → origin。
            let sessionID = UUID()
            let filterJSON = String(
                decoding: try JSONEncoder().encode(CustomStudyFilter()),
                as: UTF8.self
            )
            let queueJSON = String(
                decoding: try JSONEncoder().encode(
                    CustomStudyQueue.ordered(
                        cardIDs: [cardID],
                        order: .due,
                        randomSeed: nil,
                        generatedAt: Date(timeIntervalSince1970: 1_789_056_000)
                    )
                ),
                as: UTF8.self
            )
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, original_sentence,
                        surrounding_text, source_title, source_url, source_app,
                        image_reference, dictionary_entry_id, dictionary_version,
                        dictionary_sense_key, selected_gloss_language,
                        is_primary, created_at_ms
                    ) VALUES (
                        ?, ?, 'ocr', 'パンを食べたい。', NULL, NULL, NULL,
                        'com.apple.mobilesafari', 'inbox-image-resource-01',
                        1358280, '2026.09.24-1', '1358280-1', 'zho', 1, 3
                    )
                    """,
                arguments: [UUID().uuidString.lowercased(), encode(noteID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO custom_study_sessions(
                        id, filter_json, mode, status,
                        started_at_ms, finished_at_ms, queue_json
                    ) VALUES (?, ?, 'practiceOnly', 'finished', 1789056000100, 1789056000200, ?)
                    """,
                arguments: [encode(sessionID), filterJSON, queueJSON]
            )
            try db.execute(
                sql: """
                    INSERT INTO practice_attempts(
                        id, event_id, session_id, card_key, note_id, rating,
                        answered_at_ms, duration_ms, content_version, undone_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 2, 1789056000150, 400, 2, NULL)
                    """,
                arguments: [
                    encode(UUID()), encode(UUID()), encode(sessionID),
                    encode(cardID), encode(noteID)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO scheduled_review_origins(
                        event_id, session_id, submission_kind
                    ) VALUES (?, ?, 'customScheduled')
                    """,
                arguments: [encode(eventID), encode(sessionID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id, daily_new_card_limit,
                        retention_preset, auto_play_word_audio, auto_play_example_audio,
                        appearance, ai_provider_id, ai_base_url, ai_model_id,
                        ai_enabled, ai_service_name, ai_credential_id,
                        ai_response_format_mode
                    ) VALUES(
                        1, 1, 'Asia/Shanghai', 10, 90, 1, 0, 'dark',
                        'secret-provider', 'https://secret.example/token', 'secret-model',
                        1, 'secret-service', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
                        'json_schema'
                    )
                    """
            )
            try db.execute(
                sql: "INSERT OR REPLACE INTO search_documents VALUES (?, 'search-index-only-secret', '', '')",
                arguments: [encode(noteID)]
            )
        }
    }
}
