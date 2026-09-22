import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// T00B: the v8/v9/v10 upgrade path — a fully populated v0.3 (v7) database
/// keeps every row, UUID, scheduling snapshot and foreign key while gaining
/// the four settings columns, the valid-review index and the widened CHECKs.
final class OboeSchemaV8V10MigrationTests: XCTestCase {
    func testV7FixtureUpgradesPreservingAllData() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let fixture = Fixture()

        try stageLegacyDatabase(at: location.file, through: "v7_inbox_capture") { db in
            try fixture.seed(into: db)
        }

        let database = try OboeDatabase(path: location.file.path)
        // v12 为词汇笔记补齐缺失方向：夹具的 2 张方向卡升级后为 3 张。
        let expectedCounts: [(table: String, count: Int)] = [
            ("decks", 1), ("notes", 1), ("examples", 1), ("note_tags", 1),
            ("scheduler_profiles", 1), ("cards", 3), ("study_days", 1),
            ("daily_tasks", 1), ("review_logs", 1), ("drafts", 1),
            ("inbox_items", 1), ("inbox_processing_contexts", 1),
            ("capture_import_receipts", 1), ("inbox_commit_receipts", 1),
            ("search_documents", 1), ("note_decks", 1)
        ]
        try database.pool.read { db in
            for (table, expected) in expectedCounts {
                let actual = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(table)"
                ) ?? -1
                XCTAssertEqual(actual, expected, "\(table) 行数迁移后应保持一致")
            }
            let applied = try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
            XCTAssertEqual(applied, Set(OboeDatabaseSchema.migrationIdentifiers))
        }

        try database.pool.read { db in
            let card = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM cards WHERE id = ?",
                arguments: [fixture.encodedCardID]
            ))
            XCTAssertEqual(card["note_id"] as String, fixture.encodedNoteID)
            XCTAssertEqual(card["state_version"] as Int, fixture.cardStateVersion)
            XCTAssertEqual(card["stability"] as Double, fixture.cardStability)
            XCTAssertEqual(card["profile_id"] as String, fixture.encodedProfileID)

            let task = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT card_id, study_day_id FROM daily_tasks"
            ))
            XCTAssertEqual(task["card_id"] as String, fixture.encodedCardID)
            XCTAssertEqual(task["study_day_id"] as String, fixture.encodedStudyDayID)

            let review = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT card_id, card_key, study_day_id FROM review_logs"
            ))
            XCTAssertEqual(review["card_id"] as String, fixture.encodedCardID)
            XCTAssertEqual(review["card_key"] as String, fixture.encodedCardID)
            XCTAssertEqual(review["study_day_id"] as String, fixture.encodedStudyDayID)

            let context = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT draft_id FROM inbox_processing_contexts"
            ))
            XCTAssertEqual(context["draft_id"] as String, fixture.encodedDraftID)

            let settings = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM app_settings WHERE id = 1"
            ))
            // v13 冻结的列 DEFAULT 仍是 v0.4 的 0/1/0/1：老库升级后保持旧
            // 行为不改写；新装默认由 AppSettingsRowDefaults 显式写入。
            XCTAssertEqual(settings["typed_answer_zh_ja"] as Bool, false)
            XCTAssertEqual(settings["auto_play_listening_audio"] as Bool, true)
            XCTAssertEqual(settings["typed_answer_listening"] as Bool, false)
            XCTAssertEqual(settings["leech_reminders_enabled"] as Bool, true)
            XCTAssertEqual(settings["auto_play_word_audio"] as Bool, true)

            let indexExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'index'
                          AND name = 'review_logs_on_card_key_valid_reviewed_at'
                    )
                    """
            ) ?? false
            XCTAssertTrue(indexExists)
        }

        let integrity = try database.pool.read { db in
            (
                try String.fetchAll(db, sql: "PRAGMA integrity_check"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") ?? -1
            )
        }
        XCTAssertEqual(integrity.0, ["ok"])
        XCTAssertEqual(integrity.1, 0)
    }

    /// v12：词汇笔记补齐缺失方向为 New 卡；已停用方向保持停用（暂停语义
    /// 不可被迁移擅自恢复）；语法笔记不受影响。
    func testV12FillsMissingVocabularyDirectionsAndKeepsSuspended() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let noteID = UUID()
        let grammarNoteID = UUID()
        let deckID = UUID()
        let profileID = UUID()
        let disabledCardID = UUID()
        let encode: (UUID) -> String = DatabaseValueCodec.encode

        try stageLegacyDatabase(at: location.file, through: "v11_primary_deck") { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, 'D', 0, 1, 2)",
                arguments: [encode(deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '走る', '跑', 1, 1, 2)
                    """,
                arguments: [encode(noteID), encode(deckID)]
            )
            try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'grammar', '〜ながら', '一边…一边…', 1, 1, 2)
                    """,
                arguments: [encode(grammarNoteID), encode(deckID)]
            )
            try insertHomeMembershipIfSupported(noteID: grammarNoteID, deckID: deckID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, 'fsrs-6.0-default-r90-v1', 'FSRS-6.0', ?, '{}', 0.9, 36500, 1)
                    """,
                arguments: [encode(profileID), SwiftFSRSReviewScheduler.dependencyRevision]
            )
            // 一张启用方向 + 一张被停用的方向（保留暂停语义）。
            for (id, kind, enabled) in [
                (UUID(), "vocabulary_ja_zh", 1),
                (disabledCardID, "vocabulary_zh_ja", 0)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, state_version,
                            algorithm_version, profile_id
                        ) VALUES (?, ?, ?, ?, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 'FSRS-6.0', ?)
                        """,
                    arguments: [encode(id), encode(noteID), kind, enabled, encode(profileID)]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        stability, difficulty, reps, lapses, scheduled_days,
                        elapsed_days, learning_step, state_version,
                        algorithm_version, profile_id
                    ) VALUES (?, ?, 'grammar_form_explanation', 1, 0, 1, 0, 0, 0, 0,
                              0, 0, 0, 0, 'FSRS-6.0', ?)
                    """,
                arguments: [encode(UUID()), encode(grammarNoteID), encode(profileID)]
            )
        }

        let database = try OboeDatabase(path: location.file.path)
        defer { try? database.close() }
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT template_kind, is_enabled, state, profile_id
                    FROM cards WHERE note_id = ? ORDER BY template_kind
                    """,
                arguments: [encode(noteID)]
            )
            XCTAssertEqual(rows.map { $0["template_kind"] as String }, [
                "vocabulary_ja_zh", "vocabulary_listening", "vocabulary_zh_ja"
            ])
            let listening = try XCTUnwrap(
                rows.first { ($0["template_kind"] as String) == "vocabulary_listening" }
            )
            XCTAssertEqual(listening["is_enabled"] as Int, 1)
            XCTAssertEqual(listening["state"] as Int, 0)
            XCTAssertEqual(
                listening["profile_id"] as String, encode(profileID),
                "补齐卡沿用同笔记卡的调度配置"
            )
            let zhJa = try XCTUnwrap(
                rows.first { ($0["template_kind"] as String) == "vocabulary_zh_ja" }
            )
            XCTAssertEqual(zhJa["is_enabled"] as Int, 0, "停用方向不被迁移恢复")

            let grammarCards = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                arguments: [encode(grammarNoteID)]
            )
            XCTAssertEqual(grammarCards, 1, "语法笔记不补方向")
        }
    }

    func testUpgradeIsIdempotentAcrossReopen() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try stageLegacyDatabase(at: location.file, through: "v7_inbox_capture") { _ in }

        var database = try OboeDatabase(path: location.file.path)
        try database.close()
        database = try OboeDatabase(path: location.file.path)
        let applied = try database.pool.read { db in
            try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
        }
        XCTAssertEqual(applied, Set(OboeDatabaseSchema.migrationIdentifiers))
        try database.close()
    }

    func testWidenedChecksAcceptNewValuesAndRejectInvalidOnes() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let fixture = Fixture()
        try stageLegacyDatabase(at: location.file, through: "v7_inbox_capture") { db in
            try fixture.seed(into: db)
        }
        let database = try OboeDatabase(path: location.file.path)

        // The new template value is accepted on a vocabulary note. v12 already
        // filled the listening direction during upgrade — replace it to keep
        // exercising the widened CHECK on a fresh insert.
        try database.pool.write { db in
            try db.execute(
                sql: """
                    DELETE FROM cards
                    WHERE note_id = ? AND template_kind = 'vocabulary_listening'
                    """,
                arguments: [fixture.encodedNoteID]
            )
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        stability, difficulty, reps, lapses, scheduled_days,
                        elapsed_days, learning_step, state_version,
                        algorithm_version, profile_id
                    ) VALUES (?, ?, 'vocabulary_listening', 1, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    fixture.encodedNoteID,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    fixture.encodedProfileID
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO drafts(
                        id, draft_kind, payload_version, payload_json, updated_at_ms
                    ) VALUES (?, 'ai_repair', 1, '{}', 1)
                    """,
                arguments: [DatabaseValueCodec.encode(UUID())]
            )
        }

        // Values outside the widened sets are still rejected.
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        stability, difficulty, reps, lapses, scheduled_days,
                        elapsed_days, learning_step, state_version,
                        algorithm_version, profile_id
                    ) VALUES (?, ?, 'not_a_template', 1, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    fixture.encodedNoteID,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    fixture.encodedProfileID
                ]
            )
        })
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO drafts(
                        id, draft_kind, payload_version, payload_json, updated_at_ms
                    ) VALUES (?, 'not_a_draft', 1, '{}', 1)
                    """,
                arguments: [DatabaseValueCodec.encode(UUID())]
            )
        })
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: "UPDATE app_settings SET typed_answer_zh_ja = 2 WHERE id = 1"
            )
        })
    }

    /// A migration that fails mid-way (here: the deferred foreign-key check
    /// after the v9 rebuild) rolls that migration back — the original rows,
    /// including the violating one, are still there and nothing is erased.
    func testFailedMigrationPreservesOriginalDatabase() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let fixture = Fixture()
        try stageLegacyDatabase(at: location.file, through: "v7_inbox_capture") { db in
            try fixture.seed(into: db)
        }

        // Plant a foreign-key violation with enforcement off.
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let unfenced = try DatabaseQueue(path: location.file.path, configuration: configuration)
        try unfenced.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        stability, difficulty, reps, lapses, scheduled_days,
                        elapsed_days, learning_step, state_version,
                        algorithm_version, profile_id
                    ) VALUES (?, ?, 'vocabulary_ja_zh', 1, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()), // missing note
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    fixture.encodedProfileID
                ]
            )
        }
        try unfenced.close()

        XCTAssertThrowsError(try OboeDatabase(path: location.file.path))

        // The database still opens at its last good state with every row kept.
        var validConfiguration = Configuration()
        validConfiguration.foreignKeysEnabled = false
        let surviving = try DatabaseQueue(
            path: location.file.path,
            configuration: validConfiguration
        )
        let state = try surviving.read { db in
            (
                cardCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1,
                deckCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decks") ?? -1,
                applied: try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db),
                cardsTableExists: try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM sqlite_master
                            WHERE type = 'table' AND name = 'cards'
                        )
                        """
                ) ?? false
            )
        }
        XCTAssertEqual(state.cardCount, 3, "including the planted violation")
        XCTAssertEqual(state.deckCount, 1)
        XCTAssertTrue(state.cardsTableExists)
        XCTAssertTrue(
            state.applied.isSubset(of: Set(OboeDatabaseSchema.migrationIdentifiers)),
            "applied migrations must remain a prefix of the known list"
        )
        try surviving.close()

        // Repairing the violation lets the upgrade complete on retry.
        try stageRepair(at: location.file)
        let database = try OboeDatabase(path: location.file.path)
        let applied = try database.pool.read { db in
            try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
        }
        XCTAssertEqual(applied, Set(OboeDatabaseSchema.migrationIdentifiers))
    }
}

private extension OboeSchemaV8V10MigrationTests {
    struct TemporaryDatabaseLocation {
        let directory: URL
        let file: URL
    }

    /// Deterministic identities for cross-migration comparison.
    struct Fixture {
        let deckID = UUID()
        let noteID = UUID()
        let exampleID = UUID()
        let tagID = UUID()
        let profileID = UUID()
        let cardID = UUID()
        let secondCardID = UUID()
        let studyDayID = UUID()
        let reviewID = UUID()
        let draftID = UUID()
        let inboxItemID = UUID()
        let contextID = UUID()
        let captureID = UUID()
        let operationID = UUID()
        let cardStateVersion = 7
        let cardStability = 42.5

        var encodedCardID: String { DatabaseValueCodec.encode(cardID) }
        var encodedNoteID: String { DatabaseValueCodec.encode(noteID) }
        var encodedProfileID: String { DatabaseValueCodec.encode(profileID) }
        var encodedStudyDayID: String { DatabaseValueCodec.encode(studyDayID) }
        var encodedDraftID: String { DatabaseValueCodec.encode(draftID) }

        func seed(into db: Database) throws {
            let encode: (UUID) -> String = DatabaseValueCodec.encode
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '迁移夹具', 0, 1, 2)",
                arguments: [encode(deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        part_of_speech, origin, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃',
                              '动词', 'manual', 3, 1, 2)
                    """,
                arguments: [encode(noteID), encode(deckID)]
            )
            try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                    VALUES (?, ?, '毎朝パンを食べます。', '每天早上吃面包。', 0)
                    """,
                arguments: [encode(exampleID), encode(noteID)]
            )
            try db.execute(
                sql: "INSERT INTO tags(id, name, normalized_name) VALUES (?, '动词', '动词')",
                arguments: [encode(tagID)]
            )
            try db.execute(
                sql: "INSERT INTO note_tags(note_id, tag_id) VALUES (?, ?)",
                arguments: [encode(noteID), encode(tagID)]
            )
            let parameters = String(
                decoding: try JSONEncoder().encode(SchedulerProfile.fsrs6DefaultParameters),
                as: UTF8.self
            )
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, 'fsrs-6.0-default-r90-v1', 'FSRS-6.0', ?, ?, 0.9, 36500, 1)
                    """,
                arguments: [
                    encode(profileID),
                    SwiftFSRSReviewScheduler.dependencyRevision,
                    parameters
                ]
            )
            for (cardID, template) in [
                (cardID, "vocabulary_ja_zh"),
                (secondCardID, "vocabulary_zh_ja")
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            last_review_at_ms, stability, difficulty, reps, lapses,
                            scheduled_days, elapsed_days, learning_step,
                            first_studied_at_ms, state_version,
                            algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 2, 1789056000000, 1789000000000,
                                  ?, 4.2, 11, 1, 72.0, 30.0, 0,
                                  1760000000000, ?, 'FSRS-6.0', ?)
                        """,
                    arguments: [
                        encode(cardID), encode(noteID), template,
                        cardStability, cardStateVersion, encode(profileID)
                    ]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2026-07-01', 'Asia/Shanghai', 1789084800000,
                              1789171200000, 10)
                    """,
                arguments: [encode(studyDayID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO daily_tasks(
                        study_day_id, card_id, category_at_admission,
                        admitted_at_ms, cancelled_at_ms
                    ) VALUES (?, ?, 'review', 1789084801000, NULL)
                    """,
                arguments: [encode(studyDayID), encode(cardID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO review_logs(
                        id, event_id, card_id, card_key, note_id, deck_id_at_review,
                        reviewed_at_ms, study_day_id, was_first_study, rating,
                        previous_state_json, next_state_json, duration_ms,
                        content_version, profile_id, algorithm_version, undone_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, 1789000000000, ?, 0, 2,
                              '{}', '{}', 3500, 3, ?, 'FSRS-6.0', NULL)
                    """,
                arguments: [
                    encode(reviewID), encode(UUID()), encode(cardID), encode(cardID),
                    encode(noteID), encode(deckID), encode(studyDayID), encode(profileID)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO drafts(
                        id, draft_kind, payload_version, payload_json,
                        provider_id, model_id, prompt_version, updated_at_ms
                    ) VALUES (?, 'sentence_analysis', 1, '{"items":[]}',
                              'provider', 'model', 'prompt-v1', 1789056000000)
                    """,
                arguments: [encode(draftID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id,
                        daily_new_card_limit, retention_preset,
                        auto_play_word_audio, auto_play_example_audio, appearance
                    ) VALUES (1, 1, 'Asia/Shanghai', 10, 90, 1, 0, 'system')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        created_at_ms, updated_at_ms, processed_at_ms
                    ) VALUES (?, '食べる', 'manual', 'processed', 1,
                              1789056000000, 1789056000000, 1789056100000)
                    """,
                arguments: [encode(inboxItemID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_processing_contexts(
                        id, inbox_item_id, content_revision, input_text, mode,
                        draft_id, payload_version, updated_at_ms
                    ) VALUES (?, ?, 1, '食べる', 'vocabulary_generation',
                              ?, 1, 1789056000500)
                    """,
                arguments: [encode(contextID), encode(inboxItemID), encode(draftID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO capture_import_receipts(
                        capture_id, payload_hash, inbox_item_id, imported_at_ms
                    ) VALUES (?, 'fixture-hash', ?, 1789056000100)
                    """,
                arguments: [encode(captureID), encode(inboxItemID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_commit_receipts(
                        operation_id, processing_context_id, payload_hash,
                        result_json, committed_at_ms
                    ) VALUES (?, ?, 'fixture-commit-hash', '{}', 1789056100000)
                    """,
                arguments: [encode(operationID), encode(contextID)]
            )
        }
    }

    func temporaryDatabaseLocation() -> TemporaryDatabaseLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OboeSchemaV8V10MigrationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return TemporaryDatabaseLocation(
            directory: directory,
            file: directory.appendingPathComponent("oboe.sqlite")
        )
    }

    /// Builds a database at exactly the requested schema version using the
    /// real migration functions — the fixture then seeds data the same way a
    /// v0.3 build would have.
    func stageLegacyDatabase(
        at file: URL,
        through lastIdentifier: String,
        seed: (Database) throws -> Void
    ) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search",
                argumentCount: 1,
                pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0]) else {
                    return nil
                }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let prefix = Array(
            OboeDatabaseSchema.migrationIdentifiers.prefix(
                through: OboeDatabaseSchema.migrationIdentifiers.firstIndex(
                    of: lastIdentifier
                )!
            )
        )
        let pool = try DatabasePool(path: file.path, configuration: configuration)
        try OboeDatabaseSchema.makeMigrator(applying: prefix).migrate(pool)
        try pool.write { db in try seed(db) }
        try pool.close()
    }

    /// Removes the planted dangling card so the migration can succeed.
    func stageRepair(at file: URL) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: file.path, configuration: configuration)
        try queue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM cards
                    WHERE note_id NOT IN (SELECT id FROM notes)
                    """
            )
        }
        try queue.close()
    }
}
