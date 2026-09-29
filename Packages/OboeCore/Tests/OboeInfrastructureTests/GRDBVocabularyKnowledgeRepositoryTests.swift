import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S08 知识状态仓储测试（unit 聚合真值表 + 幂等 receipt/事件 +
/// 关联语义 + 批量解析）。D19（v0.7.5）：词级状态唯一真值 =
/// learning-unit flags/links，`vocabulary_knowledge_overrides`
/// 仅供 v8 导入/审计——运行态不得受其影响（本文件含专门回归）。
/// fixture 跑 `migrationIdentifiers` 全量（v1–v27）。
final class GRDBVocabularyKnowledgeRepositoryTests: XCTestCase {

    // MARK: - fixture

    private var directory: URL!
    private var pool: DatabasePool!
    private var repository: GRDBVocabularyKnowledgeRepository!
    private var service: VocabularyKnowledgeService!
    private var invalidation: KnowledgeInvalidationCenter!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KnowledgeRepo-\(UUID().uuidString)", isDirectory: true)
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
        // 最小依赖集：notes/decks/lexemes/learning_units 等全部由
        // `migrationIdentifiers`（v1–v27）提供——与生产注册路径一致。
        try OboeDatabaseSchema.makeMigrator(applying:
            OboeDatabaseSchema.migrationIdentifiers).migrate(pool)
        repository = GRDBVocabularyKnowledgeRepository(pool: pool)
        invalidation = KnowledgeInvalidationCenter()
        service = VocabularyKnowledgeService(
            repository: repository,
            linking: repository,
            invalidation: invalidation,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - helpers

    private func insertDeck(id: UUID = UUID()) throws -> UUID {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(id)])
        }
        return id
    }

    private func insertNote(
        headword: String,
        reading: String? = nil,
        kind: String = "vocabulary",
        deckID: UUID
    ) throws -> UUID {
        let noteID = UUID()
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        is_favorite, origin, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 'm', 0, 'manual', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    kind, headword, reading
                ])
        }
        return noteID
    }

    /// 词汇 Note + 一张暂停卡（is_enabled=0）——暂停不移除关联语义。
    private func insertPausedCard(noteID: UUID) throws {
        let profileID = DatabaseValueCodec.encode(UUID())
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version,
                        library_revision, parameters_json, desired_retention,
                        max_interval_days, created_at_ms)
                    VALUES (?, 'cfg', 'fsrs-5', 'rev', '{}', 0.9, 365, 1)
                    """,
                arguments: [profileID])
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state,
                        due_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, 'vocabulary_ja_zh', 0, 0, 1,
                              0, 0, 0, 0, 0, 0, 0, 0, 'fsrs-5', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(noteID),
                    profileID
                ])
        }
    }

    private func jmdictLexeme(
        entryID: Int64,
        form: String,
        reading: String? = nil,
        status: TokenResolutionStatus = .resolved
    ) async throws -> Lexeme {
        let key = LexicalIdentityKey.jmdict(
            entryID: entryID,
            normalizedForm: SearchTextNormalizer.normalize(form),
            reading: reading)
        let seed = Lexeme(
            id: UUID(), key: key,
            writtenForm: form, reading: reading,
            normalizedLemma: SearchTextNormalizer.normalize(form),
            posFamily: "v1", dictionaryVersionAtResolution: "test-dict",
            resolutionStatus: status,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        return try await repository.resolveLexeme(key: key, seed: seed)
    }

    /// dictionarySense unit fixture（D19 运行态真值载体）。
    /// `senseIndex` 区分同 entry 的多个义项。
    private func insertUnit(
        entryID: Int64,
        senseIndex: Int = 1,
        bindingStatus: String = "current",
        lemma: String = "語"
    ) throws -> UUID {
        let id = UUID()
        let fingerprint = String(
            format: "%064x", entryID * 1_000 + Int64(senseIndex))
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexical_learning_units(
                        id, identity_kind, identity_key, provider,
                        dictionary_entry_id, semantic_fingerprint,
                        fingerprint_version, lemma, reading,
                        sense_snapshot_json, binding_status,
                        revision, created_at_ms, updated_at_ms
                    ) VALUES (?, 'dictionarySense', ?, 'jmdict', ?, ?,
                              'fp-v1', ?, NULL, NULL, ?, 0, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    "jmdict:sense-v1:\(entryID):\(fingerprint)",
                    entryID, fingerprint, lemma, bindingStatus
                ])
        }
        return id
    }

    /// unit flag 直写 fixture（绕过 CAS——测试构造存储态）。
    private func insertUnitFlag(unitID: UUID, tooEasy: Bool) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_flags(
                        unit_id, too_easy, revision, updated_at_ms
                    ) VALUES (?, ?, 1, 1)
                    ON CONFLICT(unit_id) DO UPDATE SET
                        too_easy = excluded.too_easy,
                        revision = learning_unit_flags.revision + 1
                    """,
                arguments: [
                    DatabaseValueCodec.encode(unitID),
                    tooEasy ? 1 : 0])
        }
    }

    /// unit↔vocabulary Note 关联（learning 信号的载体）。
    private func linkUnit(unitID: UUID, noteID: UUID) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_note_links(
                        unit_id, note_id, role, origin, created_at_ms
                    ) VALUES (?, ?, 'primary', 'manual', 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(unitID),
                    DatabaseValueCodec.encode(noteID)])
        }
    }

    /// 旧 override 行直写 fixture（D19：运行态不得读取——
    /// 仅用于「遗留行不构成真值」的回归构造）。
    private func insertLegacyOverride(
        lexemeID: UUID, state: String
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO vocabulary_knowledge_overrides(
                        lexeme_id, state, updated_at_ms
                    ) VALUES (?, ?, 1)
                    ON CONFLICT(lexeme_id) DO UPDATE SET
                        state = excluded.state
                    """,
                arguments: [DatabaseValueCodec.encode(lexemeID), state])
        }
    }

    private func eventCount(
        kind: ReaderActivityKind? = nil,
        lexemeID: UUID? = nil
    ) throws -> Int {
        try pool.read { db in
            var sql = "SELECT COUNT(*) FROM reader_activity_events WHERE 1=1"
            var args: [any DatabaseValueConvertible] = []
            if let kind { sql += " AND kind = ?"; args.append(kind.rawValue) }
            if let lexemeID {
                sql += " AND lexeme_id = ?"
                args.append(DatabaseValueCodec.encode(lexemeID))
            }
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }

    private func receiptCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM reader_mining_receipts") ?? 0
        }
    }

    // MARK: - 真值表（D19：unit 三态聚合）

    /// unit 聚合全组合：无 unit → unknown；unit 存在但无 flag/无
    /// vocabulary link → unknown；有 link → learning；flag tooEasy →
    /// known（mastered）；flag+link → 仍 known（flag 优先）。
    func testTruthTableAllCombinations() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "食べる", deckID: deckID)
        let lexeme = try await jmdictLexeme(entryID: 1, form: "食べる")

        // 无 unit → unknown
        let k01 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k01, .unknown)

        // entry 绑定 current unit（无 flag/无 link）→ unknown
        let unitID = try insertUnit(entryID: 1, lemma: "食べる")
        let k02 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k02, .unknown)

        // unit 关联 vocabulary Note → learning
        try linkUnit(unitID: unitID, noteID: noteID)
        let k03 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k03, .learning)

        // flag tooEasy → known（mastered 压过 learning）
        try insertUnitFlag(unitID: unitID, tooEasy: true)
        let k04 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k04, .known)

        // 清 flag 回 learning（link 仍在）。
        try insertUnitFlag(unitID: unitID, tooEasy: false)
        let k05 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k05, .learning)
    }

    /// 最小值聚合（多义项词级态）：{mastered, unknown} → unknown——
    /// 全部义项都掌握才算词级已知；{mastered, learning} → learning。
    /// 与 D03「歧义不自动已知」同向：多义不静默算掌握。
    func testMultiUnitMinAggregation() async throws {
        let lexeme = try await jmdictLexeme(entryID: 10, form: "掛ける")
        let u1 = try insertUnit(entryID: 10, senseIndex: 1, lemma: "掛ける")
        let u2 = try insertUnit(entryID: 10, senseIndex: 2, lemma: "掛ける")
        try insertUnitFlag(unitID: u1, tooEasy: true)
        // {mastered, unknown} → unknown（还有未学义项）
        let s1 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s1, .unknown)

        // {mastered, learning} → learning
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "掛ける", deckID: deckID)
        try linkUnit(unitID: u2, noteID: noteID)
        let s2 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s2, .learning)

        // 全部 mastered → known
        try insertUnitFlag(unitID: u2, tooEasy: true)
        let s3 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s3, .known)
    }

    /// D19 回归：遗留 override 行不构成运行态真值——
    /// 直写 known/ignored 对 `state`/`states` 零影响。
    func testLegacyOverrideRowsAreAuditOnly() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "高い", deckID: deckID)
        let lexeme = try await jmdictLexeme(entryID: 6, form: "高い")
        let unitID = try insertUnit(entryID: 6, lemma: "高い")
        try linkUnit(unitID: unitID, noteID: noteID)

        // override=known 不该把 learning 拔成 known
        try insertLegacyOverride(lexemeID: lexeme.id, state: "known")
        let s1 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s1, .learning)

        // override=ignored 也不产生 ignored（D04：已退出运行态）
        try insertLegacyOverride(lexemeID: lexeme.id, state: "ignored")
        let s2 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s2, .learning)

        // flag 真值仍生效——override 行在旁不影响。
        try insertUnitFlag(unitID: unitID, tooEasy: true)
        let s3 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s3, .known)
    }

    /// D19 回归：`lexeme_note_links` 单独存在不再驱动 learning——
    /// 学习信号唯一载体是 `learning_unit_note_links`。
    func testLexemeLinkAloneDoesNotDriveLearning() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "泳ぐ", deckID: deckID)
        let lexeme = try await jmdictLexeme(entryID: 8, form: "泳ぐ")
        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteID, origin: .backfill)
        // lexeme→note 关联在（兼容镜像），但 note 无 unit → unknown。
        let s = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s, .unknown)

        // 该 note 一旦挂上 unit → 经 note 链路聚合为 learning。
        let unitID = try insertUnit(
            entryID: nilEntry, senseIndex: 1, bindingStatus: "legacy",
            lemma: "泳ぐ")
        try linkUnit(unitID: unitID, noteID: noteID)
        let s2 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s2, .learning)
    }

    /// needsConfirmation / stale / legacy 绑定态的义项 unit 不计入
    /// 词级聚合（歧义不猜、陈旧不算当前）；note 链路除外。
    func testNonCurrentBindingUnitsExcluded() async throws {
        let lexeme = try await jmdictLexeme(entryID: 11, form: "行く")
        // needsConfirmation 义项 unit → 不算 live
        _ = try insertUnit(
            entryID: 11, senseIndex: 1,
            bindingStatus: "needsConfirmation", lemma: "行く")
        let s1 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s1, .unknown)
        // stale 义项 unit 同样不计
        _ = try insertUnit(
            entryID: 11, senseIndex: 2,
            bindingStatus: "stale", lemma: "行く")
        let s2 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s2, .unknown)
        // current 义项出现 → 正常参与
        let live = try insertUnit(
            entryID: 11, senseIndex: 3, bindingStatus: "current",
            lemma: "行く")
        try insertUnitFlag(unitID: live, tooEasy: true)
        let s3 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s3, .known)
    }

    private var nilEntry: Int64 { -1 }   // 不占真实 entry 的占位

    /// 暂停卡（is_enabled=0）不移除 learning——unit↔vocabulary
    /// Note 关联存在即学习中，卡可用性属调度层（D05/D13）。
    func testPausedCardNoteStillLearning() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "走る", deckID: deckID)
        try insertPausedCard(noteID: noteID)
        let lexeme = try await jmdictLexeme(entryID: 2, form: "走る")
        let unitID = try insertUnit(entryID: 2, lemma: "走る")
        try linkUnit(unitID: unitID, noteID: noteID)
        let k08 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k08, .learning)
    }

    /// grammar Note 经 unit 链路触达时不驱动 learning
    /// （linkedVocabularyUnitIDs 只认 `notes.kind='vocabulary'`）。
    func testGrammarNoteLinkDoesNotCount() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(
            headword: "〜によって", kind: "grammar", deckID: deckID)
        let lexeme = try await jmdictLexeme(entryID: 3, form: "によって")
        let unitID = try insertUnit(entryID: 3, lemma: "によって")
        // grammar note 也能被 unit 关联（FK 不查 kind）——
        // 状态推导按 vocabulary 过滤 → unknown。
        try linkUnit(unitID: unitID, noteID: noteID)
        let k09 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k09, .unknown)
    }

    /// 多 unit 关联 + Note 删除级联：两个 unit 各自挂 vocabulary
    /// Note；删一个仍 learning（另一 unit 活着），全删 → unknown。
    func testMultipleNotesAndDeletionFallback() async throws {
        let deckA = try insertDeck()
        let deckB = try insertDeck()
        let noteA = try insertNote(headword: "見る", deckID: deckA)
        let noteB = try insertNote(headword: "見る", deckID: deckB)
        let lexeme = try await jmdictLexeme(entryID: 4, form: "見る")
        let uA = try insertUnit(entryID: 4, senseIndex: 1, lemma: "見る")
        let uB = try insertUnit(entryID: 4, senseIndex: 2, lemma: "見る")
        try linkUnit(unitID: uA, noteID: noteA)
        try linkUnit(unitID: uB, noteID: noteB)
        // {learning, learning} → learning
        let k10 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k10, .learning)

        // 删除第一个 Note——FK 级联清 uA 的 unit link；uA 是活
        // unit（entry 绑定仍在）退到 unknown → {unknown, learning}
        // 聚合取最小 → 词级 unknown（义项粒度保守：一词级态不因为
        // 尚存一个学习义项就整词算 learning）。
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteA)])
        }
        let k11 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k11, .unknown)
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteB)])
        }
        let k12 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k12, .unknown)
        // lexeme 行仍在（身份保留）。
        let kept = try await repository.fetchLexeme(key: lexeme.key)
        XCTAssertNotNil(kept)
    }

    // MARK: - 词级标记（D19 写路径）/ 幂等 / 事件 / receipt

    /// `setWordTooEasy` 词级标记：该词全部活 unit 一次置位；重试
    /// （同 base opID 或新 opID）对已相符 unit 幂等短路——零重复
    /// 事件；每 unit 恰好一条 `tooEasySet` 事件。
    func testSetWordTooEasyMarksAllLiveUnits() async throws {
        let lexeme = try await jmdictLexeme(entryID: 5, form: "読む")
        let u1 = try insertUnit(entryID: 5, senseIndex: 1, lemma: "読む")
        let u2 = try insertUnit(entryID: 5, senseIndex: 2, lemma: "読む")
        let units = GRDBLearningUnitRepository(pool: pool)

        let changed = try await units.setWordTooEasy(
            lexemeID: lexeme.id, value: true,
            operationID: UUID(), at: Date())
        XCTAssertEqual(changed, 2)
        let kSet = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(kSet, .known)

        // 重试：全部已相符 → 0 写、零新事件。
        let again = try await units.setWordTooEasy(
            lexemeID: lexeme.id, value: true,
            operationID: UUID(), at: Date())
        XCTAssertEqual(again, 0)

        // 重置 → 两 unit 同时清。
        let cleared = try await units.setWordTooEasy(
            lexemeID: lexeme.id, value: false,
            operationID: UUID(), at: Date())
        XCTAssertEqual(cleared, 2)
        let kClear = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(kClear, .unknown)
        // 审计：每 unit 恰好两条 tooEasySet 事件（set + clear）。
        let eventRows = try await pool.read { db in
            try Int.fetchOne(
                db, sql: """
                    SELECT COUNT(*) FROM learning_unit_events
                    WHERE kind = 'tooEasySet'
                    """) ?? 0
        }
        XCTAssertEqual(eventRows, 4)
    }

    /// 无活 unit 的 lexeme：标记返回 0、不写任何行——不臆造义项
    /// （OOV/未绑定词的「已知」暂无载体，调用方如实提示）。
    func testSetWordTooEasyNoUnitsWritesNothing() async throws {
        let lexeme = try await jmdictLexeme(entryID: 12, form: "仮")
        let units = GRDBLearningUnitRepository(pool: pool)
        let changed = try await units.setWordTooEasy(
            lexemeID: lexeme.id, value: true,
            operationID: UUID(), at: Date())
        XCTAssertEqual(changed, 0)
        let kNone = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(kNone, .unknown)
        let flagRows = try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM learning_unit_flags") ?? 0
        }
        XCTAssertEqual(flagRows, 0)
    }

    /// `lexeme_dictionary_bindings.status='current'` 优先于
    /// `lexemes.entry_id`——换库重绑后词级态跟新 entry 的 unit 走。
    func testBindingOverrideEntryWins() async throws {
        let lexeme = try await jmdictLexeme(entryID: 13, form: "分かる")
        // 旧 entry(13) 的 unit mastered——若按 lexemes.entry_id 解析
        // 会误报 known；活绑定指向 entry 99 应覆盖。
        let staleUnit = try insertUnit(
            entryID: 13, senseIndex: 1, lemma: "分かる")
        try insertUnitFlag(unitID: staleUnit, tooEasy: true)
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexeme_dictionary_bindings(
                        lexeme_id, entry_id, match_tier,
                        dataset_version, status, detail,
                        resolved_at_ms, updated_at_ms
                    ) VALUES (?, 99, 'exactWritten', 'v9', 'current',
                              NULL, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(lexeme.id)])
        }
        let s = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(s, .unknown)
    }

    /// userConfirmed link → linkedExistingNote 事件一次；
    /// 重复 linkNote 不双发；automatic/backfill 不发事件。
    /// （lexeme_note_links 仍是兼容镜像写面——mining/v8 导出依赖。）
    func testLinkNoteEvents() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "走る", deckID: deckID)
        let lexeme = try await jmdictLexeme(entryID: 7, form: "走る")

        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteID, origin: .backfill)
        XCTAssertEqual(try eventCount(), 0, "backfill 不写事件")
        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteID, origin: .userConfirmed)
        XCTAssertEqual(
            try eventCount(kind: .linkedExistingNote, lexemeID: lexeme.id), 1)
        // 重复同 origin → 幂等（无新事件、无新 receipt 形态变化）。
        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteID, origin: .userConfirmed)
        XCTAssertEqual(
            try eventCount(kind: .linkedExistingNote, lexemeID: lexeme.id), 1)
    }

    /// 改选：Note 先挂 local lexeme，confirmAssociation 到 jmdict
    /// 并摘除旧关联。
    func testConfirmAssociationReselect() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "見る", deckID: deckID)
        // local 占位（歧义时产物）
        let localKey = LexicalIdentityKey.local(
            writtenForm: "見る", reading: "みる", posFamily: nil)
        let localSeed = Lexeme(
            id: UUID(), key: localKey, writtenForm: "見る",
            reading: "みる", normalizedLemma: "みる", posFamily: nil,
            dictionaryVersionAtResolution: nil,
            resolutionStatus: .ambiguous,
            createdAt: Date())
        let localLexeme = try await repository.resolveLexeme(
            key: localKey, seed: localSeed)
        try await repository.linkNote(
            lexemeID: localLexeme.id, noteID: noteID, origin: .backfill)
        // D19：lexeme_note_links 单独不构成 learning——note 挂上
        // unit 才进入学习态。
        let carrier = try insertUnit(
            entryID: 900, senseIndex: 1, bindingStatus: "legacy",
            lemma: "見る")
        try linkUnit(unitID: carrier, noteID: noteID)
        let k16 = try await repository.state(lexemeID: localLexeme.id)
        XCTAssertEqual(k16, .learning)

        // 用户选定 jmdict 候选
        let key = LexicalIdentityKey.jmdict(
            entryID: 42, normalizedForm: "みる", reading: "みる")
        let seed = Lexeme(
            id: UUID(), key: key, writtenForm: "見る", reading: "みる",
            normalizedLemma: "みる", posFamily: "v1",
            dictionaryVersionAtResolution: "d1",
            resolutionStatus: .resolved, createdAt: Date())
        let jmdict = try await service.confirmAssociation(
            key: key, seed: seed, noteID: noteID,
            unlinking: localLexeme.id)
        XCTAssertEqual(jmdict.key.provider, .jmdict)
        let links = try await repository.linksForNote(noteID: noteID)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].lexemeID, jmdict.id)
        XCTAssertEqual(links[0].origin, .userConfirmed)
        // local lexeme 失去唯一关联 → unknown；jmdict → learning
        // （经新 lexeme_note_link 触达同一 note 的 unit）。
        let k17 = try await repository.state(lexemeID: localLexeme.id)
        XCTAssertEqual(k17, .unknown)
        let k18 = try await repository.state(lexemeID: jmdict.id)
        XCTAssertEqual(k18, .learning)
    }

    /// resolveLexeme 按 identity_key upsert：二次写入返回既有行
    /// （UUID 不重建——D08 稳定主键）。
    func testResolveLexemePreservesExistingID() async throws {
        let key = LexicalIdentityKey.jmdict(
            entryID: 9, normalizedForm: "たべる", reading: "たべる")
        let s1 = Lexeme(
            id: UUID(), key: key, writtenForm: "食べる", reading: "たべる",
            normalizedLemma: "たべる", posFamily: "v1",
            dictionaryVersionAtResolution: "d1",
            resolutionStatus: .resolved, createdAt: Date())
        let first = try await repository.resolveLexeme(key: key, seed: s1)
        // 同 key 不同 seed（旧 id/不同表记）→ 返回 first。
        let s2 = Lexeme(
            id: UUID(), key: key, writtenForm: "喰べる", reading: "たべる",
            normalizedLemma: "たべる", posFamily: "v1",
            dictionaryVersionAtResolution: "d2",
            resolutionStatus: .resolved, createdAt: Date())
        let second = try await repository.resolveLexeme(key: key, seed: s2)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.writtenForm, second.writtenForm)
    }

    /// 批量解析：N keys 一条 IN 查询；未命中 key 不出现。
    func testResolveLexemesBatch() async throws {
        var keys: [LexicalKey] = []
        for i: Int64 in 100..<120 {
            let k = LexicalIdentityKey.jmdict(
                entryID: i, normalizedForm: "f\(i)", reading: nil)
            let seed = Lexeme(
                id: UUID(), key: k, writtenForm: "f\(i)", reading: nil,
                normalizedLemma: "f\(i)", posFamily: nil,
                dictionaryVersionAtResolution: nil,
                resolutionStatus: .resolved, createdAt: Date())
            _ = try await repository.resolveLexeme(key: k, seed: seed)
            keys.append(k)
        }
        keys.append(LexicalIdentityKey.jmdict(
            entryID: 999, normalizedForm: "missing", reading: nil))
        let resolved = try await repository.resolveLexemes(keys: keys)
        XCTAssertEqual(resolved.count, 20)
        XCTAssertNil(resolved[keys.last!])
    }

    /// Service 层 key→state 查询：未入库 key → unknown 且不建行。
    func testServiceStateByKeyDoesNotCreate() async throws {
        let missing = LexicalIdentityKey.jmdict(
            entryID: 777, normalizedForm: "なし", reading: nil)
        let state = try await service.state(of: missing)
        XCTAssertEqual(state, .unknown)
        let fetched = try await repository.fetchLexeme(key: missing)
        XCTAssertNil(fetched)
    }

    /// 失效信号：每次写 bump revision（S09 缓存键组件）。
    /// D19 起 unit-flag 写后由调用方显式 `invalidate(lexemeID:)`。
    func testInvalidationSignals() async throws {
        let base = await invalidation.revision
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "読む", deckID: deckID)
        let lexeme = try await jmdictLexeme(entryID: 55, form: "読む")
        // link + unlink + 显式 invalidate 各 bump 一次。
        try await service.linkNote(
            lexemeID: lexeme.id, noteID: noteID, origin: .backfill)
        try await repository.unlinkNote(
            lexemeID: lexeme.id, noteID: noteID)
        await service.invalidate(lexemeID: lexeme.id)
        let after = await invalidation.revision
        XCTAssertEqual(after, base &+ 2)
        let perLexeme = await invalidation.lexemeRevision(lexeme.id)
        XCTAssertEqual(perLexeme, 2)
    }

    /// 同形异音 lexeme 并存：同 writtenForm 不同读音 → 两个 identity_key。
    func testHomographLexemesCoexist() async throws {
        let k1 = LexicalIdentityKey.local(
            writtenForm: "橋", reading: "はし", posFamily: "n")
        let k2 = LexicalIdentityKey.local(
            writtenForm: "箸", reading: "はし", posFamily: "n")
        let k3 = LexicalIdentityKey.local(
            writtenForm: "端", reading: "はし", posFamily: "n")
        XCTAssertEqual(Set([k1.identityKey, k2.identityKey, k3.identityKey]).count, 3)
    }

    /// 字典更新语义：lexeme 行的 entry_id/版本是 provenance——词典
    /// 不可达时状态与 unit 关联不受影响（不因 entry 失联降级）。
    func testLexemeSurvivesDictionaryChange() async throws {
        let lexeme = try await jmdictLexeme(entryID: 66, form: "読む")
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "読む", deckID: deckID)
        let unitID = try insertUnit(entryID: 66, lemma: "読む")
        try linkUnit(unitID: unitID, noteID: noteID)
        // 模拟词典更新：entry_id 在新库里不存在——仓储不感知词典库，
        // 状态纯由 unit flags/links 决定。
        let k19 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k19, .learning)
        let fetched = try await repository.fetchLexeme(key: lexeme.key)
        XCTAssertEqual(fetched?.dictionaryVersionAtResolution, "test-dict")
    }

    /// 并发写：同一 lexeme 上的并发词级标记不撕状态——
    /// DatabasePool 串行化 + 已相符短路 → flag 恰好一次翻转，
    /// `tooEasySet` 事件至多一条。
    func testConcurrentWordMarksSerialize() async throws {
        let lexeme = try await jmdictLexeme(entryID: 77, form: "見る")
        _ = try insertUnit(entryID: 77, lemma: "見る")
        let units = GRDBLearningUnitRepository(pool: pool)
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (try? await units.setWordTooEasy(
                        lexemeID: lexeme.id, value: true,
                        operationID: UUID(), at: Date())) ?? -1
                }
            }
            var totalChanged = 0
            for await changed in group { totalChanged += max(changed, 0) }
            // 串行化下首个写事务置位，其余全部见到已相符 → 合计 1。
            XCTAssertEqual(totalChanged, 1)
        }
        let k20 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k20, .known)
        let events = try await pool.read { db in
            try Int.fetchOne(
                db, sql: """
                    SELECT COUNT(*) FROM learning_unit_events
                    WHERE kind = 'tooEasySet'
                    """) ?? 0
        }
        XCTAssertEqual(events, 1)
    }

    /// 未找到 lexeme/note 的写路径：link 报错而非静默；词级标记在
    /// 无活 unit 时返回 0（无 unit 可写——不臆造）。
    func testWriteValidationErrors() async throws {
        let ghost = UUID()
        let units = GRDBLearningUnitRepository(pool: pool)
        let ghostChanged = try await units.setWordTooEasy(
            lexemeID: ghost, value: true, operationID: UUID(),
            at: Date())
        XCTAssertEqual(ghostChanged, 0)
        let lexeme = try await jmdictLexeme(entryID: 88, form: "行く")
        let ghostNote = UUID()
        do {
            try await repository.linkNote(
                lexemeID: lexeme.id, noteID: ghostNote, origin: .backfill)
            XCTFail("应抛 noteNotFound")
        } catch let error as VocabularyKnowledgeError {
            XCTAssertEqual(error, .noteNotFound(ghostNote))
        }
    }
}
