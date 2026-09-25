import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T03: the v6 contract — `note.pitch_accent` and the `noteDeck` record
/// type. Export always emits at least the home membership per note (UNION
/// fallback); restoring v1–v5 synthesizes the single home membership;
/// a v6 file with missing/dangling/duplicate memberships or an
/// out-of-range pitch is rejected.
final class PortableBackupV6RestorationTests: XCTestCase {

    /// v6 往返：pitch、双 membership、home 归属全部保留。
    func testV6RoundTripPreservesPitchAndMemberships() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await seedSource(source, seed: seed)
        let backup = try await export(source, fixture: fixture)

        let objects = try backupObjects(backup.url)
        let noteRecord = try XCTUnwrap(
            objects.first {
                $0["recordType"] as? String == "note"
                    && $0["id"] as? String
                        == DatabaseValueCodec.encode(seed.vocabularyNoteID)
            }
        )
        XCTAssertEqual(noteRecord["pitch_accent"] as? Int, 2)
        let noteDecks = objects.filter {
            $0["recordType"] as? String == "noteDeck"
                && $0["note_id"] as? String
                    == DatabaseValueCodec.encode(seed.vocabularyNoteID)
        }
        XCTAssertEqual(noteDecks.count, 2)

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        let prepared = try await preparer(current: current, fixture: fixture).prepare(fileURL: backup.url)
        XCTAssertEqual(prepared.sourceFormatVersion, PortableBackupFormat.currentVersion)
        XCTAssertEqual(prepared.preparedFormatVersion, PortableBackupFormat.currentVersion)

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            let pitch: Int? = try Row.fetchOne(
                db,
                sql: "SELECT pitch_accent FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(seed.vocabularyNoteID)]
            )?["pitch_accent"]
            XCTAssertEqual(pitch, 2)
            let memberships = try String.fetchAll(
                db,
                sql: "SELECT deck_id FROM note_decks WHERE note_id = ? ORDER BY deck_id",
                arguments: [DatabaseValueCodec.encode(seed.vocabularyNoteID)]
            )
            XCTAssertEqual(
                memberships.sorted(),
                [seed.deckID, seed.deckBID]
                    .map { DatabaseValueCodec.encode($0) }.sorted()
            )
            let home: String = try XCTUnwrap(try String.fetchOne(
                db,
                sql: "SELECT deck_id FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(seed.vocabularyNoteID)]
            ))
            XCTAssertEqual(home, DatabaseValueCodec.encode(seed.deckID))
        }
    }

    /// v1–v5：每条 Note 恢复后自动获得 home membership，pitch 为 NULL。
    func testLegacyBackupsSynthesizeHomeMembership() async throws {
        for version in [5, 4, 3, 2, 1] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let seed = Seed()
            let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
            try await seedSource(source, seed: seed)
            let backup = try await export(source, fixture: fixture)

            let legacyURL = fixture.rootURL.appendingPathComponent(
                "legacy-v\(version).oboe-backup"
            )
            try rewriteBackup(backup.url, to: legacyURL) { objects in
                downgradeBackupToLegacyFormat(&objects, version: version)
            }
            let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
            let prepared = try await preparer(current: current, fixture: fixture).prepare(fileURL: legacyURL)
            XCTAssertEqual(prepared.sourceFormatVersion, version)

            let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
            try await queue.read { db in
                // 每个 Note 恰好一个 membership = home deck。
                let orphanNotes = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM notes n
                        WHERE (SELECT COUNT(*) FROM note_decks nd
                               WHERE nd.note_id = n.id) != 1
                        """
                )
                XCTAssertEqual(orphanNotes, 0, "v\(version) restore must synthesize exactly one membership")
                let homeMismatch = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM notes n
                        WHERE NOT EXISTS (
                            SELECT 1 FROM note_decks nd
                            WHERE nd.note_id = n.id AND nd.deck_id = n.deck_id
                        )
                        """
                )
                XCTAssertEqual(homeMismatch, 0)
                let pitchSet = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM notes WHERE pitch_accent IS NOT NULL"
                )
                XCTAssertEqual(pitchSet, 0)
            }
            try queue.close()
            try current.close()
            try source.close()
        }
    }

    /// v6 文件声称某 Note 无 membership（手工删记录后重算计数/校验和）→ 拒绝。
    func testV6RejectsNoteWithoutMembership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await seedSource(source, seed: seed)
        let backup = try await export(source, fixture: fixture)

        let tamperedURL = fixture.rootURL.appendingPathComponent("no-membership.oboe-backup")
        try rewriteBackup(backup.url, to: tamperedURL) { objects in
            objects.removeAll {
                $0["recordType"] as? String == "noteDeck"
                    && $0["note_id"] as? String
                        == DatabaseValueCodec.encode(seed.vocabularyNoteID)
            }
            var counts = objects[0]["counts"] as? [String: Any] ?? [:]
            counts["noteDeck"] = 1
            objects[0]["counts"] = counts
        }
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        await XCTAssertThrowsPreparationError {
            _ = try await preparer(current: current, fixture: fixture).prepare(fileURL: tamperedURL)
        }
    }

    /// v6 悬空 membership（指向不存在的 deck）与重复 membership 都拒绝。
    func testV6RejectsDanglingAndDuplicateMembership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await seedSource(source, seed: seed)
        let backup = try await export(source, fixture: fixture)

        // 悬空：noteDeck 指向文件中不存在的 deck。
        let danglingURL = fixture.rootURL.appendingPathComponent("dangling.oboe-backup")
        try rewriteBackup(backup.url, to: danglingURL) { objects in
            let ghost = [
                "recordType": "noteDeck",
                "note_id": DatabaseValueCodec.encode(seed.vocabularyNoteID),
                "deck_id": UUID().uuidString.lowercased(),
                "added_at_ms": 1
            ] as [String: Any]
            let insertAt = objects.firstIndex {
                $0["recordType"] as? String == "example"
            } ?? objects.count
            objects.insert(ghost, at: insertAt)
            var counts = objects[0]["counts"] as? [String: Any] ?? [:]
            counts["noteDeck"] = 3
            objects[0]["counts"] = counts
        }
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        await XCTAssertThrowsPreparationError {
            _ = try await preparer(current: current, fixture: fixture).prepare(fileURL: danglingURL)
        }

        // 重复：同一 (note_id, deck_id) 出现两次。
        let duplicateURL = fixture.rootURL.appendingPathComponent("duplicate.oboe-backup")
        try rewriteBackup(backup.url, to: duplicateURL) { objects in
            guard let existing = objects.first(where: {
                $0["recordType"] as? String == "noteDeck"
            }) else { return }
            let insertAt = objects.firstIndex {
                $0["recordType"] as? String == "example"
            } ?? objects.count
            objects.insert(existing, at: insertAt)
            var counts = objects[0]["counts"] as? [String: Any] ?? [:]
            counts["noteDeck"] = 3
            objects[0]["counts"] = counts
        }
        let current2 = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        await XCTAssertThrowsPreparationError {
            _ = try await preparer(current: current2, fixture: fixture).prepare(fileURL: duplicateURL)
        }
    }

    /// v6 pitch 超出读音 mora 数 → 拒绝；负数 pitch → CHECK 拒绝。
    func testV6RejectsOutOfRangePitch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await seedSource(source, seed: seed)
        let backup = try await export(source, fixture: fixture)

        let tooLargeURL = fixture.rootURL.appendingPathComponent("pitch-big.oboe-backup")
        try rewriteBackup(backup.url, to: tooLargeURL) { objects in
            for index in objects.indices
            where objects[index]["recordType"] as? String == "note"
                && objects[index]["id"] as? String
                    == DatabaseValueCodec.encode(seed.vocabularyNoteID) {
                objects[index]["pitch_accent"] = 9 // たべる 只有 3 mora
            }
        }
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        await XCTAssertThrowsPreparationError {
            _ = try await preparer(current: current, fixture: fixture).prepare(fileURL: tooLargeURL)
        }

        let negativeURL = fixture.rootURL.appendingPathComponent("pitch-neg.oboe-backup")
        try rewriteBackup(backup.url, to: negativeURL) { objects in
            for index in objects.indices
            where objects[index]["recordType"] as? String == "note"
                && objects[index]["id"] as? String
                    == DatabaseValueCodec.encode(seed.vocabularyNoteID) {
                objects[index]["pitch_accent"] = -1
            }
        }
        let current2 = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        await XCTAssertThrowsPreparationError {
            _ = try await preparer(current: current2, fixture: fixture).prepare(fileURL: negativeURL)
        }
    }

    /// 更高版本仍按 futureFormatVersion 拒绝。
    func testFutureVersionStillRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await seedSource(source, seed: seed)
        let backup = try await export(source, fixture: fixture)

        let futureURL = fixture.rootURL.appendingPathComponent("future.oboe-backup")
        try rewriteBackup(backup.url, to: futureURL) { objects in
            objects[0]["formatVersion"] = PortableBackupFormat.currentVersion + 1
        }
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        do {
            _ = try await preparer(current: current, fixture: fixture).prepare(fileURL: futureURL)
            XCTFail("future format version must be rejected")
        } catch let error as PortableBackupPreparationError {
            let expectedVersion = PortableBackupFormat.currentVersion + 1
            guard case .futureFormatVersion(expectedVersion) = error else {
                return XCTFail(
                    "expected futureFormatVersion(\(expectedVersion)), got \(error)"
                )
            }
        }
    }

    /// 词汇草稿：旧 payload（只有 deckID）解码为 home + 单元素 deckIDs；
    /// 新字段往返保留多牌组集合。
    func testVocabularyDraftPayloadMigratesLegacySingleDeck() async throws {
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let database = try OboeDatabase(
            path: location.appendingPathComponent("db.sqlite").path
        )
        defer {
            try? database.close()
            try? FileManager.default.removeItem(at: location)
        }
        let repository = GRDBVocabularyRepository(database: database)
        let deckA = UUID(), deckB = UUID()

        // 新格式：deckIDs 往返。
        let draft = try await VocabularyService(repository: repository)
            .saveDraft(
                id: nil,
                deckID: deckA,
                deckIDs: [deckA, deckB],
                formData: VocabularyFormData(headword: "新", meaningZH: "新")
            )
        let fetched = try await repository.fetchVocabularyDraft(id: draft.id)
        XCTAssertEqual(fetched?.deckID, deckA)
        XCTAssertEqual(fetched?.deckIDs, [deckA, deckB])

        // 旧格式 payload（仅 deckID）自动升级。
        let legacyID = UUID()
        let legacyPayload = """
            {"deckID":"\(deckA.uuidString)","formData":{"headword":"旧",\
            "reading":"","meaningZH":"旧","partOfSpeech":"","jlpt":null,\
            "exampleJapanese":"","exampleTranslationZH":"","notes":""}}
            """
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO drafts(
                        id, draft_kind, payload_version, payload_json, updated_at_ms
                    ) VALUES (?, 'vocabulary', 1, ?, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(legacyID), legacyPayload]
            )
        }
        let migrated = try await repository.fetchVocabularyDraft(id: legacyID)
        XCTAssertEqual(migrated?.deckID, deckA)
        XCTAssertEqual(migrated?.deckIDs, [deckA])
    }

    /// capture resume payload：旧格式只有 targetDeckID 时解码为单元素
    /// targetDeckIDs；新格式保留集合。
    func testCaptureResumePayloadMigratesLegacyTargetDeck() throws {
        let deckA = UUID(), deckB = UUID()
        let legacy = """
            {"version":1,"targetDeckID":"\(deckA.uuidString)"}
            """
        let decoded = try CaptureResumePayloadCodec.decode(legacy)
        XCTAssertEqual(decoded.targetDeckID, deckA)
        XCTAssertEqual(decoded.targetDeckIDs, [deckA])

        let payload = CaptureResumePayload(
            targetDeckID: deckA,
            targetDeckIDs: [deckA, deckB]
        )
        let roundTripped = try CaptureResumePayloadCodec.decode(
            CaptureResumePayloadCodec.encode(payload)
        )
        XCTAssertEqual(roundTripped.targetDeckID, deckA)
        XCTAssertEqual(roundTripped.targetDeckIDs, [deckA, deckB])
    }

    /// 句子分析卡片草稿：pitchAccent 可选解码——旧 JSON 无该键时为 nil，
    /// 且经 vocabularyForm 透传到表单数据。
    func testSentenceAnalysisCardDraftPitchDecoding() throws {
        let id = UUID()
        let legacyJSON = """
            {"id":"\(id.uuidString)","kind":"vocabulary","headword":"食べる",\
            "reading":"たべる","meaningZH":"吃","partOfSpeech":"",\
            "usage":"","connection":"","exampleJapanese":"",\
            "exampleTranslationZH":"","notes":"",\
            "vocabularyDirections":["japaneseToChinese"],\
            "createDespiteDuplicate":false}
            """
        let legacy = try JSONDecoder().decode(
            SentenceAnalysisCardDraft.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(legacy.pitchAccent)

        let draft = SentenceAnalysisCardDraft(
            id: id,
            kind: .vocabulary,
            headword: "食べる",
            reading: "たべる",
            pitchAccent: PitchAccent(rawValue: 2),
            meaningZH: "吃"
        )
        XCTAssertEqual(draft.vocabularyForm.pitchAccent, PitchAccent(rawValue: 2))
        let reDecoded = try JSONDecoder().decode(
            SentenceAnalysisCardDraft.self,
            from: JSONEncoder().encode(draft)
        )
        XCTAssertEqual(reDecoded.pitchAccent, PitchAccent(rawValue: 2))
    }
}

private extension PortableBackupV6RestorationTests {
    struct Fixture {
        let rootURL: URL
        let sourceDatabaseURL: URL
        let currentDatabaseURL: URL
        let exportsURL: URL
        let preparationsURL: URL
        let exportedAt = Date(timeIntervalSince1970: 1_789_056_000.123)

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PortableBackupV6RestorationTests-\(UUID().uuidString)",
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

    struct Seed {
        let deckID = UUID()
        let deckBID = UUID()
        let vocabularyNoteID = UUID()
        let grammarNoteID = UUID()
        let cardID = UUID()
        let grammarCardID = UUID()
        let profileID = UUID()
    }

    func preparer(current: OboeDatabase, fixture: Fixture) -> PortableBackupRestorationPreparer {
        PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )
    }

    func export(
        _ database: OboeDatabase,
        fixture: Fixture
    ) async throws -> PortableBackupExport {
        try await PortableBackupExporter(
            database: database,
            workingDirectoryURL: fixture.exportsURL
        ).export(appVersion: "test", at: fixture.exportedAt)
    }

    func backupObjects(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
    }

    func seedSource(_ database: OboeDatabase, seed: Seed) async throws {
        let encode: @Sendable (UUID) -> String = DatabaseValueCodec.encode
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, 'A', 0, 1, 2)",
                arguments: [encode(seed.deckID)]
            )
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, 'B', 1, 1, 2)",
                arguments: [encode(seed.deckBID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        pitch_accent, origin, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃',
                              2, 'manual', 1, 1, 2)
                    """,
                arguments: [encode(seed.vocabularyNoteID), encode(seed.deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'grammar', '〜たことがある', '曾经～过',
                              'manual', 1, 1, 2)
                    """,
                arguments: [encode(seed.grammarNoteID), encode(seed.deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                    VALUES (?, ?, 1), (?, ?, 3), (?, ?, 1)
                    """,
                arguments: [
                    encode(seed.vocabularyNoteID), encode(seed.deckID),
                    encode(seed.vocabularyNoteID), encode(seed.deckBID),
                    encode(seed.grammarNoteID), encode(seed.deckID)
                ]
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
                    encode(seed.profileID),
                    SwiftFSRSReviewScheduler.dependencyRevision,
                    parameters
                ]
            )
            for (cardID, noteID, template) in [
                (seed.cardID, seed.vocabularyNoteID, "vocabulary_ja_zh"),
                (seed.grammarCardID, seed.grammarNoteID, "grammar_form_explanation")
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, state_version,
                            algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 0, 1789056000000, 0, 0, 0, 0,
                                  0, 0, 0, 0, 'FSRS-6.0', ?)
                        """,
                    arguments: [
                        encode(cardID), encode(noteID), template, encode(seed.profileID)
                    ]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id,
                        daily_new_card_limit, retention_preset,
                        auto_play_word_audio, auto_play_example_audio, appearance
                    ) VALUES (1, 1, 'Asia/Shanghai', 10, 90, 1, 0, 'system')
                    """
            )
        }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsPreparationError(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected preparation error", file: file, line: line)
        } catch is PortableBackupPreparationError {
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
