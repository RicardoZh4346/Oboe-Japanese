import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.0 S12（设计 §9.1–9.3）：sentence Note + `sentence_cloze` Card +
/// `cloze_definitions` 的事务写入、读侧回放与生命周期守卫。
///
/// `v19_cloze` 尚未接线 `OboeDatabase.swift`（主 agent 负责）——
/// `openClozeDatabase` 在 `OboeDatabase(path:)` 之后独立注册 v19，
/// 两种接线状态下行为一致。
/// 共享样例——文件级常量，`pool.write`/`read` 的 @Sendable 闭包内引用
/// 不触发 self 捕获。
private let sentence = "私は昨日映画を見た。"
private let target = "見た"

final class GRDBClozeCommitTests: XCTestCase {

    // MARK: - 成功路径

    /// 一次提交落齐：sentence Note（headword=快照、meaning 可空、
    /// origin=reader）、唯一 cloze 卡、definition、membership、
    /// Reader 定位来源、tags、scheduler profile。
    func testCommitSentencePersistsAllRowsAtomically() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let clozeID = UUID()
        let cardID = UUID()
        let contextID = UUID()
        let documentID = UUID()
        let chapterID = UUID()
        let (start, length) = utf16Range(of: target, in: sentence)
        let commit = try sentenceCommit(
            noteID: noteID, clozeID: clozeID, cardID: cardID,
            deckID: deckID, utf16Start: start, utf16Length: length,
            sourceContext: SourceContext(
                id: contextID,
                noteID: noteID,
                sourceType: .reader,
                originalSentence: sentence,
                surroundingText: nil,
                sourceTitle: "测试文档",
                sourceURL: nil,
                sourceApp: nil,
                imageReference: nil,
                dictionaryEntryID: nil,
                dictionaryVersion: nil,
                dictionarySenseKey: nil,
                selectedGlossLanguage: nil,
                isPrimary: true,
                createdAt: Date(timeIntervalSince1970: 1_768_000_000),
                readerDocumentID: documentID,
                readerChapterID: chapterID,
                readerLocation: ReaderLocation(
                    chapterOrdinal: 2,
                    blockOrdinal: 5,
                    utf16Offset: 6,
                    blockTextHash: "hash",
                    prefix: "私は昨日",
                    suffix: "。"
                ),
                selectedSurface: target
            )
        )

        let result = try await repository.commitSentence(commit, capture: nil)
        XCTAssertEqual(result, ContentCommitResult(noteID: noteID, cardCount: 1))

        try await database.pool.read { db in
            let note = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT kind, headword, meaning_zh, origin, source_text
                    FROM notes WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]))
            XCTAssertEqual(note["kind"], "sentence")
            XCTAssertEqual(note["headword"], sentence)
            XCTAssertNil(note["meaning_zh"] as String?)
            XCTAssertEqual(note["origin"], "reader")

            let card = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT template_kind, is_enabled
                    FROM cards WHERE id = ? AND note_id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(noteID)
                ]))
            XCTAssertEqual(card["template_kind"], "sentence_cloze")
            XCTAssertEqual(card["is_enabled"], 1)

            let definition = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT source_context_id, sentence_snapshot, sentence_sha256,
                           range_version, range_utf16_start, range_utf16_length,
                           target_surface, target_lemma, target_reading,
                           accepted_answers_json, hint, content_version
                    FROM cloze_definitions WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(clozeID)]))
            XCTAssertEqual(
                try DatabaseValueCodec.decodeUUID(
                    definition["source_context_id"]),
                contextID)
            XCTAssertEqual(definition["sentence_snapshot"], sentence)
            XCTAssertEqual(
                definition["sentence_sha256"],
                ClozeValidator.snapshotSHA256(sentence))
            XCTAssertEqual(definition["range_version"], 1)
            XCTAssertEqual(definition["range_utf16_start"], start)
            XCTAssertEqual(definition["range_utf16_length"], length)
            XCTAssertEqual(definition["target_surface"], target)
            XCTAssertEqual(definition["target_lemma"], "見る")
            XCTAssertEqual(definition["target_reading"], "みた")
            XCTAssertEqual(definition["hint"], "提示")
            XCTAssertEqual(definition["content_version"], 1)

            let context = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT source_type, reader_document_id, reader_chapter_id,
                           reader_location, selected_surface
                    FROM source_contexts WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(contextID)]))
            XCTAssertEqual(context["source_type"], "reader")
            XCTAssertEqual(
                try DatabaseValueCodec.decodeUUID(
                    context["reader_document_id"]),
                documentID)
            XCTAssertEqual(
                try DatabaseValueCodec.decodeUUID(
                    context["reader_chapter_id"]),
                chapterID)
            XCTAssertNotNil(context["reader_location"] as String?)
            XCTAssertEqual(context["selected_surface"], target)

            // home membership + tags + profile。
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM note_decks WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]),
                1)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM note_tags WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]),
                1)
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM scheduler_profiles"),
                1)
            // 搜索行由 NULL 安全触发器产生。
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM search_documents WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]),
                1)
        }
    }

    /// `GRDBClozeRepository` 两种入口回放同一定义（读取即快照，
    /// 不回链 Reader）。
    func testClozeRepositoryFetchesDefinitionByNoteAndCard() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let clozeRepository = GRDBClozeRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let clozeID = UUID()
        let cardID = UUID()
        let (start, length) = utf16Range(of: target, in: sentence)
        _ = try await repository.commitSentence(
            try sentenceCommit(
                noteID: noteID, clozeID: clozeID, cardID: cardID,
                deckID: deckID, utf16Start: start, utf16Length: length),
            capture: nil
        )

        let byNote = try await clozeRepository.fetchDefinition(noteID: noteID)
        let byCard = try await clozeRepository.fetchDefinition(cardID: cardID)
        XCTAssertEqual(byNote, byCard)
        let definition = try XCTUnwrap(byNote)
        XCTAssertEqual(definition.id, clozeID)
        XCTAssertEqual(definition.noteID, noteID)
        XCTAssertEqual(definition.cardID, cardID)
        XCTAssertNil(definition.sourceContextID)
        XCTAssertEqual(definition.sentenceSnapshot, sentence)
        XCTAssertEqual(
            definition.sentenceSHA256,
            ClozeValidator.snapshotSHA256(sentence))
        XCTAssertEqual(definition.range.utf16Start, start)
        XCTAssertEqual(definition.range.utf16Length, length)
        XCTAssertEqual(definition.targetSurface, target)
        XCTAssertEqual(definition.targetLemma, "見る")
        XCTAssertEqual(definition.targetReading, "みた")
        XCTAssertEqual(definition.acceptedAnswers, ["見た", "みた"])
        XCTAssertEqual(definition.hint, "提示")
        XCTAssertEqual(definition.contentVersion, 1)

        // 非 sentence Note / 未知 id → nil（合法状态，不抛错）。
        let unknownByNote = try await clozeRepository.fetchDefinition(
            noteID: UUID())
        let unknownByCard = try await clozeRepository.fetchDefinition(
            cardID: UUID())
        XCTAssertNil(unknownByNote)
        XCTAssertNil(unknownByCard)
    }

    /// 复习链路：`fetchReviewCardContent` 返回的 cloze 载荷可渲染出
    /// 不泄题的正面（遮罩句不含答案），meaning NULL → 空串。
    func testReviewContentCarriesClozeWithoutLeakingAnswer() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let reviewRepository = GRDBReviewCardContentRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let cardID = UUID()
        let (start, length) = utf16Range(of: target, in: sentence)
        _ = try await repository.commitSentence(
            try sentenceCommit(
                noteID: noteID, clozeID: UUID(), cardID: cardID,
                deckID: deckID, utf16Start: start, utf16Length: length),
            capture: nil
        )

        let fetched = try await reviewRepository.fetchReviewCardContent(
            cardID: cardID)
        let content = try XCTUnwrap(fetched)
        XCTAssertEqual(content.templateKind, .sentenceCloze)
        XCTAssertEqual(content.headword, sentence)
        XCTAssertEqual(content.meaningZH, "")
        XCTAssertNil(content.reading)
        let cloze = try XCTUnwrap(content.cloze)
        XCTAssertEqual(cloze.cardID, cardID)
        XCTAssertEqual(cloze.targetSurface, target)

        // 正面渲染原语：遮罩句必须含 blank 且不含答案本体。
        let question = ClozeValidator.maskedSentence(
            cloze.sentenceSnapshot,
            range: cloze.range,
            blank: "＿＿"
        )
        XCTAssertFalse(question.contains(target))
        XCTAssertTrue(question.contains("＿＿"))
        XCTAssertTrue(question.contains("私は昨日映画を"))
    }

    // MARK: - 原子性：任一失败零残留

    /// 成员牌组不存在 → deckNotFound，整事务回滚：notes/cards/
    /// cloze_definitions/note_decks/source_contexts/tags 全零。
    func testMissingDeckRollsBackEverything() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)

        let (start, length) = utf16Range(of: target, in: sentence)
        let commit = try sentenceCommit(
            deckID: UUID(),   // 不存在的牌组
            utf16Start: start, utf16Length: length)

        await assertThrowsContentCardError(.deckNotFound) {
            _ = try await repository.commitSentence(commit, capture: nil)
        }
        try await assertAllSentenceTablesEmpty(in: database)
    }

    /// 非 sentence_cloze 模板 → invalidTemplateForKnowledgePoint，零残留。
    func testNonClozeTemplateRollsBack() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let (start, length) = utf16Range(of: target, in: sentence)
        var commit = try sentenceCommit(
            noteID: noteID, deckID: deckID,
            utf16Start: start, utf16Length: length)
        commit = SentenceContentCommit(
            noteID: commit.noteID,
            clozeID: commit.clozeID,
            deckID: commit.deckID,
            cloze: commit.cloze,
            // 故意错配：词汇方向模板。
            card: NewCardSeed(
                id: UUID(), templateKind: .vocabularyJapaneseToChinese),
            schedulerProfileID: commit.schedulerProfileID,
            createdAt: commit.createdAt,
            meaningZH: commit.meaningZH,
            notes: commit.notes,
            tags: commit.tags,
            origin: commit.origin,
            sourceText: commit.sourceText,
            deckIDs: commit.deckIDs
        )

        await assertThrowsContentCardError(.invalidTemplateForKnowledgePoint) {
            _ = try await repository.commitSentence(commit, capture: nil)
        }
        try await assertAllSentenceTablesEmpty(in: database)
    }

    /// 来源记录 noteID 与 commit 不一致 → sourceContextNoteMismatch，
    /// 零残留（错挂来源比失败更糟）。
    func testSourceContextNoteMismatchRollsBack() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let (start, length) = utf16Range(of: target, in: sentence)
        let commit = try sentenceCommit(
            deckID: deckID, utf16Start: start, utf16Length: length,
            sourceContext: SourceContext(
                id: UUID(),
                noteID: UUID(),   // 与 commit.noteID 不一致
                sourceType: .reader,
                originalSentence: sentence,
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
                createdAt: Date(timeIntervalSince1970: 1_768_000_000),
                selectedSurface: target
            )
        )

        await assertThrowsContentCardError(.sourceContextNoteMismatch) {
            _ = try await repository.commitSentence(commit, capture: nil)
        }
        try await assertAllSentenceTablesEmpty(in: database)
    }

    // MARK: - 生命周期守卫

    /// `deleteCard` 拒绝 sentence_cloze——裸删会让 sentence Note 成为
    /// 无卡孤儿并级联丢 definition。删除必须走整 Note。
    func testDeleteCardRejectsSentenceCloze() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let cardID = UUID()
        let (start, length) = utf16Range(of: target, in: sentence)
        _ = try await repository.commitSentence(
            try sentenceCommit(
                noteID: noteID, clozeID: UUID(), cardID: cardID,
                deckID: deckID, utf16Start: start, utf16Length: length),
            capture: nil
        )

        await assertThrowsContentCardError(.clozeDeletionRequiresNoteDelete) {
            try await repository.deleteCard(cardID: cardID)
        }
        // 卡与定义都还在。
        try await database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM cards WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(cardID)]),
                1)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM cloze_definitions"),
                1)
        }
    }

    /// 方向替换对 sentence Note 一律拒绝——恒为恰好一张 cloze 卡，
    /// 不在方向管理面内改写。
    func testDirectionReplacementRejectsSentenceNote() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let cardID = UUID()
        let (start, length) = utf16Range(of: target, in: sentence)
        _ = try await repository.commitSentence(
            try sentenceCommit(
                noteID: noteID, clozeID: UUID(), cardID: cardID,
                deckID: deckID, utf16Start: start, utf16Length: length),
            capture: nil
        )

        await assertThrowsContentCardError(.sentenceCardsNotDirectionManaged) {
            _ = try await repository.replaceEnabledCardDirections(
                CardDirectionReplacement(
                    noteID: noteID,
                    kind: .sentence,
                    enabledCards: [
                        NewCardSeed(id: UUID(), templateKind: .sentenceCloze)
                    ],
                    schedulerProfileID: UUID(),
                    updatedAt: Date()
                )
            )
        }
        // 原卡仍 enabled，未被改写。
        let directions = try await repository.fetchCardDirections(
            noteID: noteID)
        XCTAssertEqual(
            directions,
            [CardDirectionState(
                cardID: cardID, templateKind: .sentenceCloze,
                isEnabled: true)]
        )
    }

    /// 整 Note 删除级联清除 note+card+definition+membership。
    func testDeleteKnowledgePointCascadesCloze() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let knowledgeRepository = GRDBKnowledgePointRepository(
            database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let cardID = UUID()
        let (start, length) = utf16Range(of: target, in: sentence)
        _ = try await repository.commitSentence(
            try sentenceCommit(
                noteID: noteID, clozeID: UUID(), cardID: cardID,
                deckID: deckID, utf16Start: start, utf16Length: length),
            capture: nil
        )

        let result = try await knowledgeRepository.deleteKnowledgePoint(
            noteID: noteID)
        XCTAssertEqual(
            result,
            .deleted(KnowledgePointDeletionImpact(
                cardCount: 1, reviewLogCount: 0)))
        try await database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM cloze_definitions"),
                0)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]),
                0)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM note_decks WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]),
                0)
        }
    }

    /// 来源删除后 definition 仍完整可复习（快照独立存活——§9.3）。
    func testSourceContextDeletionPreservesClozeDefinition() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let clozeRepository = GRDBClozeRepository(database: database)
        let sourceRepository = GRDBSourceContextRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let cardID = UUID()
        let contextID = UUID()
        let (start, length) = utf16Range(of: target, in: sentence)
        _ = try await repository.commitSentence(
            try sentenceCommit(
                noteID: noteID, clozeID: UUID(), cardID: cardID,
                deckID: deckID, utf16Start: start, utf16Length: length,
                sourceContext: SourceContext(
                    id: contextID,
                    noteID: noteID,
                    sourceType: .reader,
                    originalSentence: sentence,
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
                    createdAt: Date(timeIntervalSince1970: 1_768_000_000),
                    readerDocumentID: UUID(),
                    readerLocation: nil,
                    selectedSurface: target
                )),
            capture: nil
        )
        let beforeDelete = try await clozeRepository.fetchDefinition(
            noteID: noteID)
        var definition = try XCTUnwrap(beforeDelete)
        XCTAssertEqual(definition.sourceContextID, contextID)

        // 删除来源行——definition SET NULL 后仍完整。
        let deleted = try await sourceRepository.delete(id: contextID)
        XCTAssertTrue(deleted)
        let afterDelete = try await clozeRepository.fetchDefinition(
            noteID: noteID)
        definition = try XCTUnwrap(afterDelete)
        XCTAssertNil(definition.sourceContextID)
        XCTAssertEqual(definition.sentenceSnapshot, sentence)
        XCTAssertEqual(definition.targetSurface, target)
    }

    // MARK: - 损坏行读侧防护

    /// `sentence_cloze` 卡缺 definition 行是数据损坏信号——复习装载
    /// 抛 inconsistentCardLink，不回落成泄题展示。
    func testReviewContentThrowsWhenDefinitionMissing() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let reviewRepository = GRDBReviewCardContentRepository(
            database: database)
        let deckID = UUID()
        let noteID = UUID()
        let cardID = UUID()
        try await insertDeck(id: deckID, in: database)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(id, deck_id, kind, headword, meaning_zh,
                                      is_favorite, origin, content_version,
                                      created_at_ms, updated_at_ms)
                    VALUES (?, ?, 'sentence', ?, NULL, 0, 'manual', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID), sentence
                ])
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version,
                        library_revision, parameters_json, desired_retention,
                        max_interval_days, created_at_ms
                    ) VALUES (?, 'p', 'fsrs-5', 'r', '{}', 0.9, 36500, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(UUID())])
            let profileID: String = try String.fetchOne(
                db, sql: "SELECT id FROM scheduler_profiles LIMIT 1")!
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state,
                        due_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, 'sentence_cloze', 1, 0, 1, 0, 0, 0, 0,
                              0, 0, 0, 0, 'fsrs-5', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(noteID), profileID
                ])
        }

        do {
            _ = try await reviewRepository.fetchReviewCardContent(
                cardID: cardID)
            XCTFail("expected inconsistentCardLink")
        } catch {
            XCTAssertEqual(error as? ClozeError, .inconsistentCardLink)
        }
    }

    /// 非数组的合法 JSON 不是可解码的答案集 → 按损坏处理抛错。
    func testRepositoryThrowsOnMalformedAnswersJSON() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let clozeRepository = GRDBClozeRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let (start, length) = utf16Range(of: target, in: sentence)
        _ = try await repository.commitSentence(
            try sentenceCommit(
                noteID: noteID, clozeID: UUID(), cardID: UUID(),
                deckID: deckID, utf16Start: start, utf16Length: length),
            capture: nil
        )
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE cloze_definitions
                    SET accepted_answers_json = '{"a":1}'
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)])
        }
        do {
            _ = try await clozeRepository.fetchDefinition(noteID: noteID)
            XCTFail("expected decode failure")
        } catch {
            XCTAssertEqual(error as? ClozeError, .emptyAcceptedAnswers)
        }
    }

    /// 未来 range 编码版本拒绝解码——不按 v1 语义误读。
    func testRepositoryThrowsOnUnsupportedRangeVersion() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let clozeRepository = GRDBClozeRepository(database: database)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let noteID = UUID()
        let (start, length) = utf16Range(of: target, in: sentence)
        _ = try await repository.commitSentence(
            try sentenceCommit(
                noteID: noteID, clozeID: UUID(), cardID: UUID(),
                deckID: deckID, utf16Start: start, utf16Length: length),
            capture: nil
        )
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE cloze_definitions SET range_version = 99
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)])
        }
        do {
            _ = try await clozeRepository.fetchDefinition(noteID: noteID)
            XCTFail("expected unsupportedRangeVersion")
        } catch {
            XCTAssertEqual(error as? ClozeError, .unsupportedRangeVersion)
        }
    }

    // MARK: - 捕获回放（digest + operationID 幂等）

    /// 同 operationID + 同内容重试 → 回放 receipt 不重写；
    /// 不同内容同 operationID → commitPayloadConflict。
    func testCaptureCommitReplayAndConflict() async throws {
        let location = try ClozeTestLocation()
        defer { location.remove() }
        let database = try openClozeDatabase(at: location.databaseURL)
        defer { try? database.close() }
        let repository = GRDBContentCardRepository(database: database)
        let inboxRepository = GRDBInboxRepository(database: database)
        let inboxService = InboxService(repository: inboxRepository)
        let deckID = UUID()
        try await insertDeck(id: deckID, in: database)

        let item = InboxItem(
            id: UUID(),
            text: sentence,
            sourceType: .manual,
            status: .unprocessed,
            contentRevision: 1,
            sourceApp: nil,
            sourceURL: nil,
            imageReference: nil,
            createdAt: Date(timeIntervalSince1970: 1_768_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_768_000_000),
            processedAt: nil,
            archivedAt: nil,
            statusBeforeArchive: nil
        )
        try await inboxRepository.insertItem(item)
        let context = try await inboxService.beginProcessing(
            itemID: item.id, mode: .sentenceAnalysis)
        let capture = CaptureCommitContext(
            operationID: UUID(),
            processingContextID: context.id,
            inboxItemID: item.id,
            expectedContentRevision: context.contentRevision,
            sourceText: context.inputText
        )

        let (start, length) = utf16Range(of: target, in: sentence)
        let commit = try sentenceCommit(
            deckID: deckID, utf16Start: start, utf16Length: length,
            sourceText: context.inputText
        )
        let first = try await repository.commitSentence(
            commit, capture: capture)
        XCTAssertTrue(first.wasCreated)
        // 丢失响应重试：相同 payload 回放 receipt。
        let second = try await repository.commitSentence(
            commit, capture: capture)
        XCTAssertEqual(second.noteID, first.noteID)
        XCTAssertFalse(second.wasCreated)

        try await database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM cloze_definitions"),
                1)
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts"),
                1)
        }

        // 同 operationID 换 payload → 冲突。
        var tampered = commit
        tampered = SentenceContentCommit(
            noteID: commit.noteID,
            clozeID: commit.clozeID,
            deckID: commit.deckID,
            cloze: commit.cloze,
            card: commit.card,
            schedulerProfileID: commit.schedulerProfileID,
            createdAt: commit.createdAt,
            meaningZH: "改了释义",   // digest 输入之一被改
            notes: commit.notes,
            tags: commit.tags,
            origin: commit.origin,
            sourceText: commit.sourceText,
            deckIDs: commit.deckIDs
        )
        do {
            _ = try await repository.commitSentence(
                tampered, capture: capture)
            XCTFail("expected commitPayloadConflict")
        } catch InboxError.commitPayloadConflict(let operationID) {
            XCTAssertEqual(operationID, capture.operationID)
        }
    }

    // MARK: - 工具

    private func utf16Range(
        of needle: String,
        in haystack: String
    ) -> (start: Int, length: Int) {
        let range = haystack.range(of: needle)!
        let ns = NSRange(range, in: haystack)
        return (ns.location, ns.length)
    }

    private func sentenceCommit(
        noteID: UUID = UUID(),
        clozeID: UUID = UUID(),
        cardID: UUID = UUID(),
        deckID: UUID,
        utf16Start: Int,
        utf16Length: Int,
        sourceText: String? = nil,
        sourceContext: SourceContext? = nil
    ) throws -> SentenceContentCommit {
        try SentenceContentCommit(
            noteID: noteID,
            clozeID: clozeID,
            deckID: deckID,
            cloze: ValidatedClozeContent(
                sentenceSnapshot: sentence,
                utf16Start: utf16Start,
                utf16Length: utf16Length,
                targetSurface: target,
                targetLemma: "見る",
                targetReading: "みた",
                acceptedAnswers: ["見た", "みた"],
                hint: "提示"
            ),
            card: NewCardSeed(id: cardID, templateKind: .sentenceCloze),
            schedulerProfileID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_768_000_000),
            meaningZH: nil,
            tags: [KnowledgeTag(id: UUID(), name: "N3", normalizedName: "n3")],
            origin: .reader,
            sourceText: sourceText,
            sourceContext: sourceContext
        )
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

    /// sentence commit 全链路表行数断言：任一失败路径回滚后全零。
    private func assertAllSentenceTablesEmpty(
        in database: OboeDatabase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await database.pool.read { db in
            for table in [
                "notes", "cards", "cloze_definitions", "note_decks",
                "source_contexts", "tags", "note_tags", "search_documents"
            ] {
                XCTAssertEqual(
                    try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM \(table)"),
                    0,
                    "\(table) 必须为 0 行（事务回滚零残留）",
                    file: file, line: line)
            }
        }
    }

    private func assertThrowsContentCardError(
        _ expected: ContentCardError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ContentCardError, expected,
                file: file, line: line)
        }
    }

    /// 建库 + 补跑 v19（未接线时）；已接线则 GRDB 检测到已应用，跳过。
    private func openClozeDatabase(at file: URL) throws -> OboeDatabase {
        let database = try OboeDatabase(path: file.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v19_cloze", migrate: GRDBClozeSchema.migrate)
        try migrator.migrate(database.pool)
        return database
    }
}

private struct ClozeTestLocation {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GRDBClozeTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
