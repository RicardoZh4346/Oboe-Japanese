import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// T02: v12 → v13 upgrade — `note_decks` backfills exactly one membership per
/// note (= its home deck), `notes.pitch_accent` gains the non-negative CHECK,
/// and every later notes write path keeps the "home deck ∈ membership"
/// invariant inside the same transaction.
final class OboeSchemaV13MigrationTests: XCTestCase {
    func testV12UpgradeBackfillsMembershipsAndPitchColumn() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let fixture = Fixture()

        try stageLegacyDatabase(at: location.file, through: "v12_fill_vocabulary_directions") { db in
            try fixture.seed(into: db)
        }

        let database = try OboeDatabase(path: location.file.path)
        defer { try? database.close() }
        try database.pool.read { db in
            // 每个既有 Note 恰好生成一个 membership，且等于当时的 deck_id。
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT note_id, deck_id, added_at_ms FROM note_decks ORDER BY note_id"
            )
            XCTAssertEqual(rows.count, 2)
            let membership: [String: String] = rows.reduce(into: [:]) { partial, row in
                partial[row["note_id"]] = row["deck_id"]
            }
            XCTAssertEqual(
                membership[fixture.encodedVocabNoteID], fixture.encodedDeckAID
            )
            XCTAssertEqual(
                membership[fixture.encodedGrammarNoteID], fixture.encodedDeckBID
            )
            let addedAt: Int64 = rows.first!["added_at_ms"]
            XCTAssertEqual(addedAt, fixture.createdAtMilliseconds)

            // pitch_accent 默认 NULL；CHECK 拒绝负值（非负底线在 SQLite 层）。
            XCTAssertTrue(try db.tableExists("note_decks"))
            let columns = try db.columns(in: "notes").map(\.name)
            XCTAssertTrue(columns.contains("pitch_accent"))
            let pitch: Int? = try Row.fetchOne(
                db,
                sql: "SELECT pitch_accent FROM notes WHERE id = ?",
                arguments: [fixture.encodedVocabNoteID]
            )?["pitch_accent"]
            XCTAssertNil(pitch)

            // 数据量在迁移前后不变（v13 不动内容表；词汇 2 卡 + 语法 1 卡）。
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes"), 2
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards"), 3
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs"), 1
            )

            let applied = try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
            XCTAssertEqual(applied, Set(OboeDatabaseSchema.migrationIdentifiers))
        }

        let integrity = try database.pool.read { db in
            (
                try String.fetchAll(db, sql: "PRAGMA integrity_check"),
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            )
        }
        XCTAssertEqual(integrity.0, ["ok"])
        XCTAssertTrue(integrity.1.isEmpty)
    }

    func testV13RejectsNegativePitchAndOrphanMembership() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let fixture = Fixture()
        try stageLegacyDatabase(at: location.file, through: "v12_fill_vocabulary_directions") { db in
            try fixture.seed(into: db)
        }
        let database = try OboeDatabase(path: location.file.path)
        defer { try? database.close() }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: "UPDATE notes SET pitch_accent = -1 WHERE id = ?",
                arguments: [fixture.encodedVocabNoteID]
            )
        })
        // 合法大值（5、6 等）不受上限约束。
        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE notes SET pitch_accent = 6 WHERE id = ?",
                arguments: [fixture.encodedVocabNoteID]
            )
        }
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                    VALUES (?, ?, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()), // 不存在的 note
                    fixture.encodedDeckAID
                ]
            )
        })
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                    VALUES (?, ?, 1)
                    """,
                arguments: [
                    fixture.encodedVocabNoteID,
                    DatabaseValueCodec.encode(UUID()) // 不存在的 deck
                ]
            )
        })
    }

    func testV13ReopenIsIdempotent() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let fixture = Fixture()
        try stageLegacyDatabase(at: location.file, through: "v12_fill_vocabulary_directions") { db in
            try fixture.seed(into: db)
        }

        var database = try OboeDatabase(path: location.file.path)
        try database.close()
        database = try OboeDatabase(path: location.file.path)
        let state = try database.pool.read { db in
            (
                applied: try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db),
                memberships: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_decks") ?? -1
            )
        }
        XCTAssertEqual(state.applied, Set(OboeDatabaseSchema.migrationIdentifiers))
        XCTAssertEqual(state.memberships, 2, "重复打开不得重复回填")
        try database.close()
    }

    /// 删除牌组的 moveContents 策略：home 改指目标牌组后，目标必须补入
    /// membership（home ∈ membership 不变量），源牌组成员行由 CASCADE 清理。
    func testMoveContentsKeepsHomeInMembership() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try OboeDatabase(path: location.file.path)
        let decks = GRDBDeckRepository(database: database)
        let repository = GRDBContentCardRepository(database: database)

        let deckA = UUID()
        let deckB = UUID()
        let noteID = UUID()
        try await database.pool.write { db in
            for deckID in [deckA, deckB] {
                try db.execute(
                    sql: """
                        INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                        VALUES (?, 'D', 0, 1, 2)
                        """,
                    arguments: [DatabaseValueCodec.encode(deckID)]
                )
            }
        }
        _ = try await repository.commitVocabulary(
            VocabularyContentCommit(
                noteID: noteID,
                exampleID: UUID(),
                draftID: nil,
                deckID: deckA,
                content: try VocabularyFormData(
                    headword: "共有",
                    reading: "きょうゆう",
                    meaningZH: "共享",
                    pitchAccent: PitchAccent(rawValue: 4)
                ).validatedContent(),
                tags: [],
                cards: [
                    NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese)
                ],
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            capture: nil
        )

        // 提交即写入 home membership；pitch 随 notes 行持久化。
        try await database.pool.read { db in
            let membership: String? = try String.fetchOne(
                db,
                sql: "SELECT deck_id FROM note_decks WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            XCTAssertEqual(membership, DatabaseValueCodec.encode(deckA))
            let pitch: Int? = try Row.fetchOne(
                db,
                sql: "SELECT pitch_accent FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )?["pitch_accent"]
            XCTAssertEqual(pitch, 4)
        }

        let result = try await decks.deleteDeck(
            id: deckA,
            strategy: .moveContents(to: deckB),
            at: Date(timeIntervalSince1970: 200)
        )
        guard case .deleted = result else {
            XCTFail("expected .deleted, got \(result)")
            return
        }
        try await database.pool.read { db in
            let home: String? = try String.fetchOne(
                db,
                sql: "SELECT deck_id FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            XCTAssertEqual(home, DatabaseValueCodec.encode(deckB))
            let memberships = try String.fetchAll(
                db,
                sql: "SELECT deck_id FROM note_decks WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            XCTAssertEqual(memberships, [DatabaseValueCodec.encode(deckB)])
        }
    }

    /// 词汇编辑链路：pitch 随 updateVocabulary 写回并可清空；
    /// 复习卡面内容读出同一值。
    func testPitchAccentRoundTripThroughRepositories() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try OboeDatabase(path: location.file.path)
        let commits = GRDBContentCardRepository(database: database)
        let vocabulary = GRDBVocabularyRepository(database: database)
        let reviewContent = GRDBReviewCardContentRepository(database: database)

        let deckID = UUID()
        let noteID = UUID()
        let cardID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, 'D', 0, 1, 2)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        _ = try await commits.commitVocabulary(
            VocabularyContentCommit(
                noteID: noteID,
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try VocabularyFormData(
                    headword: "一生懸命",
                    reading: "いっしょうけんめい",
                    meaningZH: "拼命",
                    pitchAccent: PitchAccent(rawValue: 5)
                ).validatedContent(),
                tags: [],
                cards: [NewCardSeed(id: cardID, templateKind: .vocabularyJapaneseToChinese)],
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            capture: nil
        )

        let fetched = try await vocabulary.fetchVocabulary(id: noteID)
        XCTAssertEqual(fetched?.pitchAccent, PitchAccent(rawValue: 5))
        let card = try await reviewContent.fetchReviewCardContent(cardID: cardID)
        XCTAssertEqual(card?.pitchAccent, PitchAccent(rawValue: 5))

        // 编辑清空 pitch：显式置 nil 必须覆盖旧值（不留残值）。
        _ = try await vocabulary.updateVocabulary(
            id: noteID,
            content: try VocabularyFormData(
                headword: "一生懸命",
                reading: "いっしょうけんめい",
                meaningZH: "拼命"
            ).validatedContent(),
            newExampleID: UUID(),
            at: Date(timeIntervalSince1970: 200)
        )
        let clearedNote = try await vocabulary.fetchVocabulary(id: noteID)
        let clearedCard = try await reviewContent.fetchReviewCardContent(cardID: cardID)
        XCTAssertNil(clearedNote?.pitchAccent)
        XCTAssertNil(clearedCard?.pitchAccent)
    }

    /// 表单校验：pitch 需要 reading；pitch 不得超过读音 mora 数；
    /// 0（平板）合法；5/6 等大值按真实值接受。
    func testPitchAccentFormValidation() throws {
        XCTAssertThrowsError(
            try VocabularyFormData(
                headword: "学校",
                meaningZH: "学校",
                pitchAccent: PitchAccent(rawValue: 0)
            ).validatedContent()
        ) { error in
            XCTAssertEqual(error as? VocabularyValidationError, .pitchAccentRequiresReading)
        }
        XCTAssertThrowsError(
            try VocabularyFormData(
                headword: "学校",
                reading: "がっこう",
                meaningZH: "学校",
                pitchAccent: PitchAccent(rawValue: 5)
            ).validatedContent()
        ) { error in
            XCTAssertEqual(error as? VocabularyValidationError, .pitchAccentExceedsMora)
        }
        let content = try VocabularyFormData(
            headword: "交通機関",
            reading: "こうつうきかん",
            meaningZH: "交通工具",
            pitchAccent: PitchAccent(rawValue: 6)
        ).validatedContent()
        XCTAssertEqual(content.pitchAccent, PitchAccent(rawValue: 6))
        XCTAssertNil(PitchAccent(rawValue: -1))
    }
}

private extension OboeSchemaV13MigrationTests {
    struct TemporaryDatabaseLocation {
        let directory: URL
        let file: URL
    }

    struct Fixture {
        let deckAID = UUID()
        let deckBID = UUID()
        let vocabNoteID = UUID()
        let grammarNoteID = UUID()
        let profileID = UUID()
        let cardID = UUID()
        let reviewID = UUID()
        let studyDayID = UUID()
        let createdAtMilliseconds: Int64 = 1_700_000_000_000

        var encodedDeckAID: String { DatabaseValueCodec.encode(deckAID) }
        var encodedDeckBID: String { DatabaseValueCodec.encode(deckBID) }
        var encodedVocabNoteID: String { DatabaseValueCodec.encode(vocabNoteID) }
        var encodedGrammarNoteID: String { DatabaseValueCodec.encode(grammarNoteID) }

        /// v12 形态的种子数据：2 decks、vocabulary+grammar 各一条、各方向卡、
        /// 一条评分日志。v12 迁移会把词汇笔记补齐到三方向（+listening）。
        func seed(into db: Database) throws {
            let encode: (UUID) -> String = DatabaseValueCodec.encode
            for (deckID, name) in [(deckAID, "A"), (deckBID, "B")] {
                try db.execute(
                    sql: """
                        INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                        VALUES (?, ?, 0, 1, 2)
                        """,
                    arguments: [encode(deckID), name]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        part_of_speech, origin, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃',
                              '一段动词', 'manual', 1, ?, ?)
                    """,
                arguments: [encode(vocabNoteID), encode(deckAID),
                            createdAtMilliseconds, createdAtMilliseconds]
            )
            try insertHomeMembershipIfSupported(noteID: vocabNoteID, deckID: deckAID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh, usage,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'grammar', '〜ながら', '一边…一边…', '用法',
                              'manual', 1, ?, ?)
                    """,
                arguments: [encode(grammarNoteID), encode(deckBID),
                            createdAtMilliseconds, createdAtMilliseconds]
            )
            try insertHomeMembershipIfSupported(noteID: grammarNoteID, deckID: deckBID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, 'fsrs-6.0-default-r90-v1', 'FSRS-6.0', ?, '{}', 0.9, 36500, 1)
                    """,
                arguments: [encode(profileID), SwiftFSRSReviewScheduler.dependencyRevision]
            )
            // 词汇笔记两张方向卡（v12 会补第三张 listening），语法一张。
            for (cardID, noteID, template) in [
                (cardID, vocabNoteID, "vocabulary_ja_zh"),
                (UUID(), vocabNoteID, "vocabulary_zh_ja"),
                (UUID(), grammarNoteID, "grammar_form_explanation")
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, state_version,
                            algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
                                  'FSRS-6.0', ?)
                        """,
                    arguments: [encode(cardID), encode(noteID), template, encode(profileID)]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2026-09-01', 'Asia/Shanghai', 1, 2, 10)
                    """,
                arguments: [encode(studyDayID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO review_logs(
                        id, event_id, card_id, card_key, note_id, deck_id_at_review,
                        reviewed_at_ms, study_day_id, was_first_study, rating,
                        previous_state_json, next_state_json, duration_ms,
                        content_version, profile_id, algorithm_version
                    ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, 0, 2, '{}', '{}', 1000, 1, ?, 'FSRS-6.0')
                    """,
                arguments: [
                    encode(reviewID), encode(UUID()), encode(cardID), encode(cardID),
                    encode(vocabNoteID), encode(deckAID), encode(studyDayID),
                    encode(profileID)
                ]
            )
        }
    }

    func temporaryDatabaseLocation() -> TemporaryDatabaseLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OboeSchemaV13MigrationTests-\(UUID().uuidString)",
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
}
