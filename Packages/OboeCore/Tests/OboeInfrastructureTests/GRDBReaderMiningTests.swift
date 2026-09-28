import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S11 挖词闭环测试：lookup → mine/link → receipt 幂等 → 批量取消 →
/// 世代屏障 → ambiguous 不自动关联。schema 走全量注册迁移（v18 提供
/// `reader_mining_receipts`/`reader_activity_events`/`lexemes`）。
final class GRDBReaderMiningTests: XCTestCase {

    // MARK: - fixture

    private var directory: URL!
    private var pool: DatabasePool!
    private var database: OboeDatabase!
    private var store: GRDBReaderMiningStore!
    private var knowledge: GRDBVocabularyKnowledgeRepository!
    /// 可变世代——测试模拟恢复后 generation++（@unchecked Sendable
    /// 盒让 @Sendable 的 currentGeneration 闭包不捕获测试类 self）。
    private let generationBox = GenerationBox()
    private var generation: Int {
        get { generationBox.value }
        set { generationBox.value = newValue }
    }
    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private let documentID = UUID(
        uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let chapterID = UUID(
        uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let deckID = UUID(
        uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let extraDeckID = UUID(
        uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Mining-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        pool = try DatabasePool(
            path: directory.appendingPathComponent("oboe.sqlite").path,
            configuration: config)
        try OboeDatabaseSchema.makeMigrator().migrate(pool)
        database = OboeDatabase(pool: pool)
        store = GRDBReaderMiningStore(pool: pool)
        knowledge = GRDBVocabularyKnowledgeRepository(pool: pool)
        generation = 7
        try insertDeck(id: deckID)
        try insertDeck(id: extraDeckID)
        try insertReaderDocument()
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeService(
        dictionary: any DictionaryRepository = StubDictionaryRepository()
    ) -> ReaderMiningService {
        // @Sendable 闭包只捕获 Sendable 盒/值——不捕获 XCTestCase self。
        let box = generationBox
        let fixedNow = clock
        return ReaderMiningService(
            dictionary: dictionary,
            knowledge: knowledge,
            linking: knowledge,
            store: store,
            currentGeneration: { box.value },
            now: { fixedNow },
            makeID: { UUID() }
        )
    }

    private func insertDeck(id: UUID) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(id)])
        }
    }

    private func insertReaderDocument() throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version, availability
                    ) VALUES (?, '测试书', 'txt', 1, ?, 'h', 'v1', 'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    String(repeating: "a", count: 64)
                ])
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, title, canonical_hash,
                        text_utf16_length
                    ) VALUES (?, ?, 0, '序章', 'ch', 100)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(chapterID),
                    DatabaseValueCodec.encode(documentID)
                ])
        }
    }

    /// 标准挖词请求：候选显式选定 jmdict 42。
    private func makeRequest(
        operationID: UUID = UUID(),
        existingNoteID: UUID? = nil,
        additionalDeckIDs: Set<UUID> = [],
        surface: String = "食べる",
        meaningZH: String = "吃",
        directions: Set<VocabularyCardDirection> = [.japaneseToChinese]
    ) -> ReaderMiningRequest {
        ReaderMiningRequest(
            operationID: operationID,
            expectedGeneration: generation,
            deckID: deckID,
            additionalDeckIDs: additionalDeckIDs,
            selection: ReaderMiningSelection(
                lexicalKey: LexicalIdentityKey.jmdict(
                    entryID: 42,
                    normalizedForm: "食べる",
                    reading: "たべる"
                ),
                writtenForm: "食べる",
                normalizedLemma: "食べる",
                reading: "たべる",
                posFamily: "动词",
                posCodes: ["v1"],
                entryID: 42,
                senseID: 7,
                senseKey: "42:7",
                selectedGlossLanguage: "zho",
                meaningZH: meaningZH,
                dictionaryVersion: "ds-1"
            ),
            existingNoteID: existingNoteID,
            context: ReaderMiningContext(
                documentID: documentID,
                chapterID: chapterID,
                location: ReaderLocation(
                    chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 3,
                    blockTextHash: "bh", prefix: "前", suffix: "后"
                ),
                sentence: "毎日パンを食べる。",
                surroundingText: "上下文",
                selectedSurface: surface,
                sourceTitle: "测试书"
            ),
            cardDirections: directions
        )
    }

    // MARK: - 新建挖词

    func testMineCreatesNoteCardsMembershipSourceLexemeEventReceipt()
        async throws
    {
        let service = makeService()
        let opID = UUID()
        let outcome = try await service.mine(
            makeRequest(
                operationID: opID,
                additionalDeckIDs: [extraDeckID],
                directions: [.japaneseToChinese, .listening]
            )
        )
        XCTAssertFalse(outcome.wasReplayed)
        XCTAssertFalse(outcome.wasExistingNote)
        XCTAssertEqual(outcome.cardCount, 2)

        // @Sendable 闭包不捕获 self——先把夹具 ID 降为局部常量。
        let documentID = self.documentID
        let chapterID = self.chapterID
        let deckID = self.deckID
        let extraDeckID = self.extraDeckID
        try await pool.read { db in
            let noteID = DatabaseValueCodec.encode(outcome.noteID)
            // Note：vocabulary + reader origin + 例句=挖词句。
            let note = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM notes WHERE id = ?",
                arguments: [noteID]
            ))
            XCTAssertEqual(note["kind"], "vocabulary")
            XCTAssertEqual(note["origin"], "reader")
            XCTAssertEqual(note["headword"], "食べる")
            XCTAssertEqual(note["reading"], "たべる")
            XCTAssertEqual(note["meaning_zh"], "吃")
            // Cards：恰两张指定方向。
            let kinds = try String.fetchAll(
                db,
                sql: """
                    SELECT template_kind FROM cards
                    WHERE note_id = ? ORDER BY template_kind
                    """,
                arguments: [noteID]
            )
            XCTAssertEqual(
                kinds, ["vocabulary_ja_zh", "vocabulary_listening"]
            )
            // Membership：home + 追加牌组。
            let memberDecks = Set(try String.fetchAll(
                db,
                sql: "SELECT deck_id FROM note_decks WHERE note_id = ?",
                arguments: [noteID]
            ))
            XCTAssertEqual(memberDecks, [
                DatabaseValueCodec.encode(deckID),
                DatabaseValueCodec.encode(extraDeckID),
            ])
            // Source：reader 定位 + 词典快照 + selectedSurface。
            let source = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM source_contexts WHERE note_id = ?
                    """,
                arguments: [noteID]
            ))
            XCTAssertEqual(source["source_type"], "reader")
            XCTAssertEqual(
                source["reader_document_id"],
                DatabaseValueCodec.encode(documentID)
            )
            XCTAssertEqual(
                source["reader_chapter_id"],
                DatabaseValueCodec.encode(chapterID)
            )
            XCTAssertEqual(source["selected_surface"], "食べる")
            XCTAssertEqual(source["original_sentence"], "毎日パンを食べる。")
            XCTAssertEqual(source["dictionary_entry_id"], 42)
            XCTAssertEqual(source["dictionary_sense_key"], "42:7")
            XCTAssertEqual(source["selected_gloss_language"], "zho")
            XCTAssertNotNil(source["reader_location"])
            // Lexeme + link + event + receipt。
            let lexemeID = DatabaseValueCodec.encode(outcome.lexemeID)
            XCTAssertNotNil(try Row.fetchOne(
                db, sql: "SELECT id FROM lexemes WHERE id = ?",
                arguments: [lexemeID]
            ))
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM lexeme_note_links
                    WHERE lexeme_id = ? AND note_id = ?
                          AND association_origin = 'userConfirmed'
                    """,
                arguments: [lexemeID, noteID]
            ))
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_activity_events
                    WHERE operation_id = ? AND kind = 'minedNewNote'
                          AND note_id = ? AND document_id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(opID),
                    noteID,
                    DatabaseValueCodec.encode(documentID)
                ]
            ))
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_mining_receipts
                    WHERE operation_id = ? AND kind = 'mine_vocabulary'
                    """,
                arguments: [DatabaseValueCodec.encode(opID)]
            ))
        }
    }

    /// 重试同 operationID：receipt 回放——不复制卡、不新增事件。
    func testRetrySameOperationIDDoesNotDuplicate() async throws {
        let service = makeService()
        let opID = UUID()
        let first = try await service.mine(makeRequest(operationID: opID))
        let second = try await service.mine(makeRequest(operationID: opID))
        XCTAssertTrue(second.wasReplayed)
        XCTAssertEqual(first.noteID, second.noteID)
        XCTAssertEqual(first.lexemeID, second.lexemeID)
        try await pool.read { db in
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notes WHERE kind = 'vocabulary'"
            ))
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_activity_events
                    WHERE operation_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(opID)]
            ))
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_mining_receipts
                    WHERE operation_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(opID)]
            ))
        }
    }

    /// 同 opID 不同负载：payload 冲突，不复用 receipt。
    func testSameOperationIDDifferentPayloadConflicts() async throws {
        let service = makeService()
        let opID = UUID()
        _ = try await service.mine(makeRequest(operationID: opID))
        do {
            _ = try await service.mine(
                makeRequest(operationID: opID, meaningZH: "别的释义")
            )
            XCTFail("expected conflict")
        } catch ReaderMiningError.operationPayloadConflict(let id) {
            XCTAssertEqual(id, opID)
        }
    }

    // MARK: - 既有 Note

    /// 命中既有 Note：不建新卡，只加 membership + 来源 + 关联 + 事件。
    func testExistingNoteOnlyAddsSourceMembershipAndLink() async throws {
        // 先建一张既有词汇 Note（走 executor 正常路径）。
        let service = makeService()
        let first = try await service.mine(makeRequest())
        let existingNoteID = first.noteID
        let cardsBefore = try await pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(existingNoteID)]
            )
        }

        let linkOpID = UUID()
        let outcome = try await service.mine(
            makeRequest(
                operationID: linkOpID,
                existingNoteID: existingNoteID,
                additionalDeckIDs: [extraDeckID],
                surface: "食べた"
            )
        )
        XCTAssertTrue(outcome.wasExistingNote)
        XCTAssertEqual(outcome.cardCount, 0)
        XCTAssertEqual(outcome.noteID, existingNoteID)

        let extraDeckID = self.extraDeckID
        try await pool.read { db in
            // 卡数不变——不重复制卡。
            let cardsAfter = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(existingNoteID)]
            )
            XCTAssertEqual(cardsBefore, cardsAfter)
            // 追加 membership。
            let memberDecks = Set(try String.fetchAll(
                db,
                sql: "SELECT deck_id FROM note_decks WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(existingNoteID)]
            ))
            XCTAssertTrue(memberDecks.contains(
                DatabaseValueCodec.encode(extraDeckID)
            ))
            // 新增一条来源（非 primary——已有首条 primary）。
            let sources = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM source_contexts WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(existingNoteID)]
            )
            XCTAssertEqual(2, sources)
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM source_contexts
                    WHERE note_id = ? AND is_primary = 1
                    """,
                arguments: [DatabaseValueCodec.encode(existingNoteID)]
            ))
            // 事件 + receipt。
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_activity_events
                    WHERE operation_id = ? AND kind = 'linkedExistingNote'
                    """,
                arguments: [DatabaseValueCodec.encode(linkOpID)]
            ))
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_mining_receipts
                    WHERE operation_id = ? AND kind = 'link_existing_note'
                    """,
                arguments: [DatabaseValueCodec.encode(linkOpID)]
            ))
        }
    }

    /// link 目标不存在 / 非词汇 Note → noteNotFound，不写任何行。
    func testLinkMissingNoteRejected() async throws {
        let service = makeService()
        let opID = UUID()
        do {
            _ = try await service.mine(
                makeRequest(operationID: opID, existingNoteID: UUID())
            )
            XCTFail("expected noteNotFound")
        } catch ReaderMiningError.noteNotFound {}
        let receiptCount = try await pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_mining_receipts
                    WHERE operation_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(opID)]
            )
        }
        XCTAssertEqual(0, receiptCount)
    }

    // MARK: - 批量

    /// 未勾选项不产生任何写入；勾选项正常提交。
    func testBatchUnselectedItemsCreateNothing() async throws {
        let service = makeService()
        let selectedOp = UUID()
        let skippedOp = UUID()
        let summary = await service.mineBatch([
            ReaderMiningBatchItem(
                request: makeRequest(operationID: selectedOp),
                isSelected: true, label: "a"
            ),
            ReaderMiningBatchItem(
                request: makeRequest(
                    operationID: skippedOp, meaningZH: "未勾选"
                ),
                isSelected: false, label: "b"
            ),
        ])
        XCTAssertEqual(2, summary.totalCount)
        XCTAssertEqual(1, summary.committedCount)
        XCTAssertEqual(1, summary.skippedCount)
        XCTAssertEqual(0, summary.cancelledCount)
        XCTAssertTrue(summary.failures.isEmpty)
        try await pool.read { db in
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notes WHERE kind = 'vocabulary'"
            ))
            XCTAssertNil(try Row.fetchOne(
                db,
                sql: """
                    SELECT operation_id FROM reader_mining_receipts
                    WHERE operation_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(skippedOp)]
            ))
        }
    }

    /// 批取消：已提交保留、剩余丢弃、摘要计数正确。
    func testBatchCancelKeepsCommittedAndDropsRest() async throws {
        let service = makeService()
        let counter = BatchCounter()
        let summary = await service.mineBatch(
            (0..<4).map { index in
                ReaderMiningBatchItem(
                    request: makeRequest(
                        operationID: UUID(),
                        surface: "词\(index)",
                        meaningZH: "义\(index)"
                    ),
                    isSelected: true, label: "\(index)"
                )
            },
            isCancelled: { counter.value >= 2 },
            progress: { counter.value = $0.committedCount }
        )
        // isCancelled 在每项开始前检查：前两项提交后取消，
        // 第 3/4 项被丢弃。
        XCTAssertEqual(2, summary.committedCount)
        XCTAssertEqual(2, summary.cancelledCount)
        XCTAssertTrue(summary.wasCancelled)
        let noteCount = try await pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notes WHERE kind = 'vocabulary'"
            )
        }
        XCTAssertEqual(2, noteCount)
    }

    /// ambiguous/未选候选项不自动关联——批量里计 requiresSelection。
    func testBatchAmbiguousItemWithoutSelectionSkipped() async throws {
        let service = makeService()
        var request = makeRequest(operationID: UUID())
        request = ReaderMiningRequest(
            operationID: request.operationID,
            expectedGeneration: request.expectedGeneration,
            deckID: request.deckID,
            selection: nil,  // ambiguous：用户未选——不得自动取首候选
            context: request.context
        )
        let summary = await service.mineBatch([
            ReaderMiningBatchItem(
                request: request, isSelected: true, label: "amb"
            )
        ])
        XCTAssertEqual(0, summary.committedCount)
        XCTAssertEqual(1, summary.requiresSelectionCount)
        let counts = try await pool.read { db in
            (
                links: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM lexeme_note_links"
                ) ?? 0,
                notes: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM notes"
                ) ?? 0
            )
        }
        XCTAssertEqual(0, counts.links)
        XCTAssertEqual(0, counts.notes)
    }

    // MARK: - 世代屏障

    /// 恢复模拟：generation++ 后旧请求在写事务内被拒，零写入。
    func testStaleGenerationRefusesWriteAfterRestore() async throws {
        let service = makeService()
        // 请求在 generation=7 时构造。
        let request = makeRequest()
        // 模拟恢复：世代递增（请求仍持旧世代）。
        generation += 1
        do {
            _ = try await service.mine(request)
            XCTFail("expected staleGeneration")
        } catch ReaderMiningError.staleGeneration(let expected, let current) {
            XCTAssertEqual(expected, 7)
            XCTAssertEqual(current, 8)
        }
        // 零写入：无 Note/receipt/event/lexeme/link。
        try await pool.read { db in
            XCTAssertEqual(0, try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM notes"
            ) ?? 0)
            XCTAssertEqual(0, try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM reader_mining_receipts"
            ) ?? 0)
            XCTAssertEqual(0, try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM reader_activity_events"
            ) ?? 0)
            XCTAssertEqual(0, try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lexemes"
            ) ?? 0)
        }
        // 新世代请求正常写回。
        let fresh = try await service.mine(makeRequest())
        XCTAssertFalse(fresh.wasReplayed)
    }

    /// mine() 前置校验：generation 不等时构造计划前就拒绝。
    func testMineRejectsNilSelection() async throws {
        let service = makeService()
        let request = ReaderMiningRequest(
            operationID: UUID(),
            expectedGeneration: generation,
            deckID: deckID,
            selection: nil,
            context: ReaderMiningContext(
                documentID: documentID, chapterID: chapterID,
                location: ReaderLocation(
                    chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 0,
                    blockTextHash: "h", prefix: "", suffix: ""
                ),
                sentence: "s", surroundingText: nil,
                selectedSurface: "x", sourceTitle: nil
            )
        )
        do {
            _ = try await service.mine(request)
            XCTFail("expected selectionRequired")
        } catch ReaderMiningError.selectionRequired {}
    }

    // MARK: - lookup

    /// lookup：morphology 候选 → 词条详情 → lexeme 状态 + 重名探测。
    func testLookupResolvesCandidatesAndDuplicates() async throws {
        let dictionary = StubDictionaryRepository()
        dictionary.stubbedEntries[42] = DictionaryEntry(
            id: 42, primaryForm: "食べる", commonRank: 1,
            forms: [DictionaryForm(id: 1, text: "食べる", formType: "standard", priority: 1)],
            readings: [DictionaryReading(
                id: 1, reading: "たべる", noKanji: false,
                restrictedFormIDs: [], restrictedForms: []
            )],
            senses: [DictionarySense(
                id: 7, order: 1, posCodes: ["v1"], tags: [],
                glosses: [DictionaryGloss(
                    language: "zho", text: "吃", order: 1,
                    sourceID: "test", isMachineGenerated: false
                )]
            )]
        )
        let service = makeService(dictionary: dictionary)
        let result = try await service.lookup(
            surface: "食べた",
            morphologyCandidates: [
                MorphologyCandidate(
                    lemma: "食べる", normalizedForm: "食べる",
                    reading: "たべる", posCodes: ["v1"], entryID: 42,
                    reasons: ["deinflect:た→る"], cost: 1
                )
            ]
        )
        XCTAssertEqual(result.candidates.count, 1)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.entryID, 42)
        XCTAssertEqual(candidate.writtenForm, "食べる")
        XCTAssertEqual(candidate.senses.first?.id, 7)
        XCTAssertEqual(candidate.senses.first?.senseKey, "42:7")
        XCTAssertEqual(candidate.knowledgeState, .unknown)
        XCTAssertFalse(result.requiresSelection)
        // 挖词后再 lookup：lexeme 命中 → learning + 重名 Note。
        _ = try await service.mine(makeRequest())
        let second = try await service.lookup(
            surface: "食べる",
            morphologyCandidates: [
                MorphologyCandidate(
                    lemma: "食べる", normalizedForm: "食べる",
                    reading: "たべる", posCodes: ["v1"], entryID: 42,
                    reasons: [], cost: 0
                )
            ]
        )
        let resolved = try XCTUnwrap(second.candidates.first)
        XCTAssertNotNil(resolved.lexemeID)
        XCTAssertEqual(resolved.knowledgeState, .learning)
        XCTAssertEqual(resolved.linkedNotes.count, 1)
        XCTAssertFalse(second.duplicateNotes.isEmpty)
    }

    /// OOV：无词典候选时补 local 候选，挖词也能落库。
    func testOOVLocalCandidateCanBeMined() async throws {
        let service = makeService()  // 空词典
        let result = try await service.lookup(
            surface: "未知語", reading: "みちご"
        )
        XCTAssertEqual(result.candidates.count, 1)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertNil(candidate.entryID)
        XCTAssertEqual(candidate.lexicalKey.provider, .local)
        let outcome = try await service.mine(
            ReaderMiningRequest(
                operationID: UUID(),
                expectedGeneration: generation,
                deckID: deckID,
                selection: ReaderMiningSelection(
                    lexicalKey: candidate.lexicalKey,
                    writtenForm: "未知語",
                    normalizedLemma: "未知語",
                    reading: "みちご",
                    posFamily: nil,
                    posCodes: [],
                    entryID: nil,
                    senseID: nil,
                    senseKey: nil,
                    selectedGlossLanguage: nil,
                    meaningZH: "未知",
                    dictionaryVersion: nil
                ),
                context: makeRequest().context
            )
        )
        // 默认制卡方向 = 全部三个方向（与词汇编辑器/JLPT 导入一致）。
        XCTAssertEqual(outcome.cardCount, 3)
        try await pool.read { db in
            XCTAssertEqual(1, try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM lexemes WHERE provider = 'local'
                    """
            ) ?? 0)
            let kinds = try String.fetchAll(
                db,
                sql: """
                    SELECT template_kind FROM cards
                    WHERE note_id = ? ORDER BY template_kind
                    """,
                arguments: [DatabaseValueCodec.encode(outcome.noteID)]
            )
            XCTAssertEqual(kinds, [
                "vocabulary_ja_zh", "vocabulary_listening",
                "vocabulary_zh_ja"
            ])
        }
    }
}

/// 可变世代盒——测试模拟恢复后 generation++，供 @Sendable 闭包读取。
private final class GenerationBox: @unchecked Sendable {
    var value = 7
}

/// 批取消测试用的 Sendable 计数盒（isCancelled/progress 闭包共用）。
private final class BatchCounter: @unchecked Sendable {
    var value = 0
}

/// 测试用词典仓储桩：search 返回空页，entries/entry 按表返回。
private final class StubDictionaryRepository: DictionaryRepository,
    @unchecked Sendable {
    var stubbedEntries: [Int64: DictionaryEntry] = [:]

    func metadata() async throws -> DictionaryMetadata {
        DictionaryMetadata(
            schemaVersion: "1", datasetVersion: "ds-1",
            dictionaryVersion: "dv-1"
        )
    }

    func search(
        _ request: DictionarySearchRequest
    ) async throws -> DictionarySearchPage {
        DictionarySearchPage(
            items: [], nextCursor: nil, hasMore: false,
            normalizedQuery: request.normalizedQuery
        )
    }

    func entries(ids: [Int64]) async throws -> [DictionaryEntry] {
        ids.compactMap { stubbedEntries[$0] }
    }

    func entry(id: Int64) async throws -> DictionaryEntry? {
        stubbedEntries[id]
    }

    func sources() async throws -> [DictionarySourceInfo] { [] }
}
