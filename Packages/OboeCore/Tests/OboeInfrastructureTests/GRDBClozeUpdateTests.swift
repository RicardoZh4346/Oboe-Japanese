import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// v0.7.0 S13：sentence/Cloze 手动编辑的事务语义
/// （设计 §9.2 + cloze-impact-review §4）。
///
/// 关键断言：
/// - range 重选/句子改写走同一更新路径——`ValidatedClozeContent`
///   构造期完成新句校验，仓储再复核持久化一致性；
/// - 双版本：`cloze_definitions.content_version` 是编辑乐观锁，
///   `notes.content_version` 是复习提交守卫——编辑必须同时抬升；
/// - Card 行/FSRS/`source_context_id` 原样保留（§9.2「编辑保留
///   Card ID 和 FSRS」；原文删除后仍可编辑）；
/// - 任一前置失败零写入（乐观锁/卡链/校验失败都不落半更新）。
final class GRDBClozeUpdateTests: XCTestCase {

    private let duplicateSurfaceSentence = "彼が言ったことは彼が言った通りだ"

    // MARK: - 成功路径

    /// 同句重选范围（同形词第二处）+ 元字段更新：definition 全字段
    /// 生效、双版本 +1、notes.headword 同步、Card 行原样。
    func testUpdateReselectsRangeAndBumpsBothVersions() async throws {
        let location = try ClozeUpdateTestLocation()
        defer { location.remove() }
        let database = try openDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let clozeRepository = GRDBClozeRepository(database: database)
        let cardRepository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let cardID = UUID()
        let first = ClozeValidator.surfaceRanges(
            of: "言った",
            in: duplicateSurfaceSentence
        )[0]
        _ = try await cardRepository.commitSentence(
            sentenceCommit(
                noteID: noteID,
                clozeID: UUID(),
                cardID: cardID,
                deckID: deckID,
                sentence: duplicateSurfaceSentence,
                target: "言った",
                range: first
            ),
            capture: nil
        )
        let cardBefore = try await cardRow(cardID, in: database)

        // 重选到第二处出现，同时更新 lemma/reading/answers/hint/翻译/备注。
        let second = ClozeValidator.surfaceRanges(
            of: "言った",
            in: duplicateSurfaceSentence
        )[1]
        let updated = try await clozeRepository.updateSentence(
            noteID: noteID,
            update: try makeUpdate(
                sentence: duplicateSurfaceSentence,
                target: "言った",
                range: second,
                targetLemma: "云う",
                targetReading: "いった",
                acceptedAnswers: ["言った"],
                hint: "新提示",
                meaningZH: "如他所说",
                notes: "编辑备注",
                expectedContentVersion: 1
            ),
            at: Date(timeIntervalSince1970: 1_769_000_000)
        )

        let sentenceNote = try XCTUnwrap(updated)
        let definition = sentenceNote.definition
        XCTAssertEqual(definition.range.utf16Start, second.utf16Start)
        XCTAssertEqual(definition.targetLemma, "云う")
        XCTAssertEqual(definition.acceptedAnswers, ["言った"])
        XCTAssertEqual(definition.hint, "新提示")
        XCTAssertEqual(definition.contentVersion, 2)
        XCTAssertEqual(sentenceNote.meaningZH, "如他所说")
        XCTAssertEqual(sentenceNote.notes, "编辑备注")
        XCTAssertEqual(sentenceNote.noteContentVersion, 2)
        XCTAssertEqual(
            sentenceNote.updatedAt,
            Date(timeIntervalSince1970: 1_769_000_000)
        )
        // Card 行完全不动（FSRS/enable/due 保留）。
        let cardAfter = try await cardRow(cardID, in: database)
        XCTAssertEqual(cardBefore, cardAfter)
    }

    /// §9.2「编辑句子后必须重新选择并验证范围」：新快照 + 新 range
    /// 同事务落库；notes.headword 与搜索索引随行。
    func testUpdateSentenceChangeRewritesSnapshotHeadwordAndSearch() async throws {
        let location = try ClozeUpdateTestLocation()
        defer { location.remove() }
        let database = try openDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let clozeRepository = GRDBClozeRepository(database: database)
        let cardRepository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        _ = try await cardRepository.commitSentence(
            sentenceCommit(
                noteID: noteID,
                clozeID: UUID(),
                cardID: UUID(),
                deckID: deckID,
                sentence: "私は昨日映画を見た。",
                target: "見た",
                range: ClozeValidator.surfaceRanges(
                    of: "見た", in: "私は昨日映画を見た。"
                )[0]
            ),
            capture: nil
        )

        let newSentence = "彼は静かに言った。"
        let newRange = ClozeValidator.surfaceRanges(
            of: "言った", in: newSentence
        )[0]
        let updated = try await clozeRepository.updateSentence(
            noteID: noteID,
            update: try makeUpdate(
                sentence: newSentence,
                target: "言った",
                range: newRange,
                acceptedAnswers: ["言った", "いった"],
                expectedContentVersion: 1
            ),
            at: Date()
        )

        let definition = try XCTUnwrap(updated?.definition)
        XCTAssertEqual(definition.sentenceSnapshot, newSentence)
        XCTAssertEqual(
            definition.sentenceSHA256,
            ClozeValidator.snapshotSHA256(newSentence)
        )
        XCTAssertEqual(definition.targetSurface, "言った")
        // notes.headword = 新快照；search_documents 由 trigger 重填。
        let (headword, normalized) = try await database.pool.read { db in
            (
                try String.fetchOne(
                    db,
                    sql: "SELECT headword FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]
                ),
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT normalized_headword FROM search_documents
                        WHERE note_id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(noteID)]
                )
            )
        }
        XCTAssertEqual(headword, newSentence)
        XCTAssertTrue(
            try XCTUnwrap(normalized).contains("言った")
        )
    }

    /// 原文删除后仍可编辑（§9.3/S13 验收）：`source_context_id`
    /// SET NULL 的 definition 照常更新，链接保持 NULL。
    func testUpdateSurvivesSourceContextDeletion() async throws {
        let location = try ClozeUpdateTestLocation()
        defer { location.remove() }
        let database = try openDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let clozeRepository = GRDBClozeRepository(database: database)
        let cardRepository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_768_000_000)
        let context = SourceContext(
            id: UUID(),
            noteID: noteID,
            sourceType: .reader,
            originalSentence: "私は昨日映画を見た。",
            surroundingText: nil,
            sourceTitle: nil,
            sourceURL: nil,
            sourceApp: nil,
            imageReference: nil,
            dictionaryEntryID: nil,
            dictionaryVersion: nil,
            dictionarySenseKey: nil,
            selectedGlossLanguage: nil,
            isPrimary: true,
            createdAt: createdAt,
            readerDocumentID: UUID(),
            readerChapterID: UUID(),
            selectedSurface: "見た"
        )
        _ = try await cardRepository.commitSentence(
            sentenceCommit(
                noteID: noteID,
                clozeID: UUID(),
                cardID: UUID(),
                deckID: deckID,
                sentence: "私は昨日映画を見た。",
                target: "見た",
                range: ClozeValidator.surfaceRanges(
                    of: "見た", in: "私は昨日映画を見た。"
                )[0],
                createdAt: createdAt,
                sourceContext: context
            ),
            capture: nil
        )
        // 删掉 source 行（原文删除的等价物）：FK SET NULL。
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM source_contexts WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
        let detached = try await clozeRepository.fetchSentence(noteID: noteID)
        XCTAssertNil(detached?.definition.sourceContextID)

        let newRange = ClozeValidator.surfaceRanges(
            of: "言った", in: "彼は静かに言った。"
        )[0]
        let updated = try await clozeRepository.updateSentence(
            noteID: noteID,
            update: try makeUpdate(
                sentence: "彼は静かに言った。",
                target: "言った",
                range: newRange,
                acceptedAnswers: ["言った"],
                expectedContentVersion: 1
            ),
            at: Date()
        )
        XCTAssertEqual(
            updated?.definition.sentenceSnapshot, "彼は静かに言った。"
        )
        XCTAssertNil(updated?.definition.sourceContextID)
    }

    // MARK: - 拒绝矩阵（失败零写入）

    /// 乐观锁：版本失配抛 `staleContentVersion`，definition/notes 两个
    /// 版本与全部内容列原样（半更新不存在——事务内 guard 先拒再写）。
    func testStaleContentVersionRejectedAndLeavesRowsUnchanged() async throws {
        let location = try ClozeUpdateTestLocation()
        defer { location.remove() }
        let database = try openDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let clozeRepository = GRDBClozeRepository(database: database)
        let cardRepository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        _ = try await cardRepository.commitSentence(
            sentenceCommit(
                noteID: noteID,
                clozeID: UUID(),
                cardID: UUID(),
                deckID: deckID,
                sentence: "私は昨日映画を見た。",
                target: "見た",
                range: ClozeValidator.surfaceRanges(
                    of: "見た", in: "私は昨日映画を見た。"
                )[0],
                meaningZH: "原翻译"
            ),
            capture: nil
        )
        let before = try await clozeRepository.fetchSentence(noteID: noteID)

        let range = ClozeValidator.surfaceRanges(
            of: "言った", in: "彼は静かに言った。"
        )[0]
        do {
            _ = try await clozeRepository.updateSentence(
                noteID: noteID,
                update: try makeUpdate(
                    sentence: "彼は静かに言った。",
                    target: "言った",
                    range: range,
                    acceptedAnswers: ["言った"],
                    meaningZH: "新翻译",
                    expectedContentVersion: 99
                ),
                at: Date()
            )
            XCTFail("expected staleContentVersion")
        } catch {
            XCTAssertEqual(error as? ClozeError, .staleContentVersion)
        }

        let after = try await clozeRepository.fetchSentence(noteID: noteID)
        XCTAssertEqual(before, after)
    }

    /// 读路径对非 sentence/不存在的 note 返回 nil——编辑面不会
    /// 「升级」一个 vocabulary Note 也不会误建行。
    func testUpdateReturnsNilForMissingAndNonSentenceNote() async throws {
        let location = try ClozeUpdateTestLocation()
        defer { location.remove() }
        let database = try openDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let clozeRepository = GRDBClozeRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        // 手工插一条 vocabulary note 作非 sentence 对象。
        let vocabularyID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh, origin,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', '吃',
                              'manual', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(vocabularyID),
                    DatabaseValueCodec.encode(deckID)
                ]
            )
        }
        let range = try ClozeRange(utf16Start: 7, utf16Length: 2)
        let update = SentenceContentUpdate(
            cloze: try ValidatedClozeContent(
                sentenceSnapshot: "私は昨日映画を見た。",
                utf16Start: 7,
                utf16Length: 2,
                targetSurface: "見た",
                acceptedAnswers: ["見た"]
            ),
            meaningZH: nil,
            notes: nil,
            expectedContentVersion: 1
        )
        _ = range
        let missingFetch = try await clozeRepository.fetchSentence(
            noteID: UUID()
        )
        let vocabularyFetch = try await clozeRepository.fetchSentence(
            noteID: vocabularyID
        )
        let missingUpdate = try await clozeRepository.updateSentence(
            noteID: UUID(), update: update, at: Date()
        )
        let vocabularyUpdate = try await clozeRepository.updateSentence(
            noteID: vocabularyID, update: update, at: Date()
        )
        XCTAssertNil(missingFetch)
        XCTAssertNil(vocabularyFetch)
        XCTAssertNil(missingUpdate)
        XCTAssertNil(vocabularyUpdate)
        // vocabulary 行内容未被 sentence 更新触碰。
        let headword = try await database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT headword FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(vocabularyID)]
            )
        }
        XCTAssertEqual(headword, "食べる")
    }

    /// §9.1 不变量：definition.card_id 必须仍指向本 note 的
    /// sentence_cloze 卡——指向他处按数据损坏拒（不借编辑写回）。
    func testUpdateRejectsBrokenCardLink() async throws {
        let location = try ClozeUpdateTestLocation()
        defer { location.remove() }
        let database = try openDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let clozeRepository = GRDBClozeRepository(database: database)
        let cardRepository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        _ = try await cardRepository.commitSentence(
            sentenceCommit(
                noteID: noteID,
                clozeID: UUID(),
                cardID: UUID(),
                deckID: deckID,
                sentence: "私は昨日映画を見た。",
                target: "見た",
                range: ClozeValidator.surfaceRanges(
                    of: "見た", in: "私は昨日映画を見た。"
                )[0]
            ),
            capture: nil
        )
        // 手工造另一条 vocabulary note + 词汇卡，把 definition.card_id
        // 指过去（FK 仍成立，语义链接已坏）。
        let otherNoteID = UUID()
        let otherCardID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh, origin,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', '吃',
                              'manual', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(otherNoteID),
                    DatabaseValueCodec.encode(deckID)
                ]
            )
            guard let profileID = try String.fetchOne(
                db, sql: "SELECT profile_id FROM cards LIMIT 1"
            ) as String? else {
                throw ClozeError.inconsistentCardLink
            }
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state,
                        due_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, 'vocabulary_ja_zh', 1, 0, 1,
                              0, 0, 0, 0, 0, 0, 0, 0, 'fsrs', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(otherCardID),
                    DatabaseValueCodec.encode(otherNoteID),
                    profileID
                ]
            )
            try db.execute(
                sql: """
                    UPDATE cloze_definitions SET card_id = ?
                    WHERE note_id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(otherCardID),
                    DatabaseValueCodec.encode(noteID)
                ]
            )
        }

        let range = ClozeValidator.surfaceRanges(
            of: "見た", in: "私は昨日映画を見た。"
        )[0]
        do {
            _ = try await clozeRepository.updateSentence(
                noteID: noteID,
                update: try makeUpdate(
                    sentence: "私は昨日映画を見た。",
                    target: "見た",
                    range: range,
                    acceptedAnswers: ["見た"],
                    expectedContentVersion: 1
                ),
                at: Date()
            )
            XCTFail("expected inconsistentCardLink")
        } catch {
            XCTAssertEqual(error as? ClozeError, .inconsistentCardLink)
        }
        // 链接与版本都未被写动。
        let definition = try await clozeRepository.fetchDefinition(
            noteID: noteID
        )
        XCTAssertEqual(definition?.cardID, otherCardID)
        XCTAssertEqual(definition?.contentVersion, 1)
    }

    /// sentence Note 缺 definition = 损坏，不是「可更新」——抛
    /// inconsistentCardLink 而不是 nil（与读路径区分）。
    func testUpdateThrowsWhenDefinitionMissing() async throws {
        let location = try ClozeUpdateTestLocation()
        defer { location.remove() }
        let database = try openDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let clozeRepository = GRDBClozeRepository(database: database)
        let cardRepository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        _ = try await cardRepository.commitSentence(
            sentenceCommit(
                noteID: noteID,
                clozeID: UUID(),
                cardID: UUID(),
                deckID: deckID,
                sentence: "私は昨日映画を見た。",
                target: "見た",
                range: ClozeValidator.surfaceRanges(
                    of: "見た", in: "私は昨日映画を見た。"
                )[0]
            ),
            capture: nil
        )
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM cloze_definitions WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
        let range = ClozeValidator.surfaceRanges(
            of: "見た", in: "私は昨日映画を見た。"
        )[0]
        do {
            _ = try await clozeRepository.updateSentence(
                noteID: noteID,
                update: try makeUpdate(
                    sentence: "私は昨日映画を見た。",
                    target: "見た",
                    range: range,
                    acceptedAnswers: ["見た"],
                    expectedContentVersion: 1
                ),
                at: Date()
            )
            XCTFail("expected inconsistentCardLink")
        } catch {
            XCTAssertEqual(error as? ClozeError, .inconsistentCardLink)
        }
    }

    /// meaning/notes 往返：set → clear → 再 set；sentence 的
    /// `meaning_zh` 可空但禁止空串（v19 CHECK）由域层 nilIfEmpty 兜底。
    func testUpdateMeaningAndNotesRoundTrip() async throws {
        let location = try ClozeUpdateTestLocation()
        defer { location.remove() }
        let database = try openDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let clozeRepository = GRDBClozeRepository(database: database)
        let cardRepository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        _ = try await cardRepository.commitSentence(
            sentenceCommit(
                noteID: noteID,
                clozeID: UUID(),
                cardID: UUID(),
                deckID: deckID,
                sentence: "私は昨日映画を見た。",
                target: "見た",
                range: ClozeValidator.surfaceRanges(
                    of: "見た", in: "私は昨日映画を見た。"
                )[0]
            ),
            capture: nil
        )

        let range = ClozeValidator.surfaceRanges(
            of: "見た", in: "私は昨日映画を見た。"
        )[0]
        let withMeaning = try await clozeRepository.updateSentence(
            noteID: noteID,
            update: try makeUpdate(
                sentence: "私は昨日映画を見た。",
                target: "見た",
                range: range,
                acceptedAnswers: ["見た"],
                meaningZH: "我昨天看了电影。",
                notes: "n1",
                expectedContentVersion: 1
            ),
            at: Date()
        )
        XCTAssertEqual(withMeaning?.meaningZH, "我昨天看了电影。")
        XCTAssertEqual(withMeaning?.notes, "n1")

        let cleared = try await clozeRepository.updateSentence(
            noteID: noteID,
            update: try makeUpdate(
                sentence: "私は昨日映画を見た。",
                target: "見た",
                range: range,
                acceptedAnswers: ["見た"],
                meaningZH: nil,
                notes: nil,
                expectedContentVersion: 2
            ),
            at: Date()
        )
        XCTAssertNil(cleared?.meaningZH)
        XCTAssertNil(cleared?.notes)
        XCTAssertEqual(cleared?.definition.contentVersion, 3)
        XCTAssertEqual(cleared?.noteContentVersion, 3)
    }

    // MARK: - 工具

    private func makeUpdate(
        sentence: String,
        target: String,
        range: ClozeRange,
        targetLemma: String? = nil,
        targetReading: String? = nil,
        acceptedAnswers: [String],
        hint: String? = nil,
        meaningZH: String? = nil,
        notes: String? = nil,
        expectedContentVersion: Int
    ) throws -> SentenceContentUpdate {
        try SentenceContentUpdate(
            cloze: ValidatedClozeContent(
                sentenceSnapshot: sentence,
                utf16Start: range.utf16Start,
                utf16Length: range.utf16Length,
                targetSurface: target,
                targetLemma: targetLemma,
                targetReading: targetReading,
                acceptedAnswers: acceptedAnswers,
                hint: hint
            ),
            meaningZH: meaningZH,
            notes: notes,
            expectedContentVersion: expectedContentVersion
        )
    }

    private func sentenceCommit(
        noteID: UUID,
        clozeID: UUID,
        cardID: UUID,
        deckID: UUID,
        sentence: String,
        target: String,
        range: ClozeRange,
        createdAt: Date = Date(timeIntervalSince1970: 1_768_000_000),
        meaningZH: String? = nil,
        sourceContext: SourceContext? = nil
    ) throws -> SentenceContentCommit {
        try SentenceContentCommit(
            noteID: noteID,
            clozeID: clozeID,
            deckID: deckID,
            cloze: ValidatedClozeContent(
                sentenceSnapshot: sentence,
                utf16Start: range.utf16Start,
                utf16Length: range.utf16Length,
                targetSurface: target,
                targetLemma: "見る",
                targetReading: "みた",
                acceptedAnswers: [target],
                hint: nil
            ),
            card: NewCardSeed(id: cardID, templateKind: .sentenceCloze),
            schedulerProfileID: UUID(),
            createdAt: createdAt,
            meaningZH: meaningZH,
            origin: .reader,
            sourceContext: sourceContext
        )
    }

    /// 整行比对用的 Card 快照（FSRS/enable/due 全列）。
    private func cardRow(
        _ cardID: UUID,
        in database: OboeDatabase
    ) async throws -> [String: DatabaseValue] {
        try await database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) else {
                throw ClozeError.inconsistentCardLink
            }
            var values: [String: DatabaseValue] = [:]
            for (name, value) in [
                ("note_id", row["note_id"] as DatabaseValue),
                ("template_kind", row["template_kind"] as DatabaseValue),
                ("is_enabled", row["is_enabled"] as DatabaseValue),
                ("state", row["state"] as DatabaseValue),
                ("due_at_ms", row["due_at_ms"] as DatabaseValue),
                ("stability", row["stability"] as DatabaseValue),
                ("difficulty", row["difficulty"] as DatabaseValue),
                ("reps", row["reps"] as DatabaseValue),
                ("lapses", row["lapses"] as DatabaseValue),
                ("profile_id", row["profile_id"] as DatabaseValue)
            ] {
                values[name] = value
            }
            return values
        }
    }

    private func insertDeck(id: UUID, in database: OboeDatabase) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, 'P08', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(id)]
            )
        }
    }

    private func openDatabase(at file: URL) throws -> OboeDatabase {
        let database = try OboeDatabase(path: file.path)
        // v19 已注册时 GRDB 跳过；未接线时独立补跑（与 commit 测试同策略）。
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v19_cloze", migrate: GRDBClozeSchema.migrate)
        try migrator.migrate(database.pool)
        return database
    }
}

private struct ClozeUpdateTestLocation {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GRDBClozeUpdateTests-\(UUID().uuidString)",
                isDirectory: true
            )
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
