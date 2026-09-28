import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S08 知识状态仓储测试（真值表全组合 + 幂等 receipt/事件 +
/// 关联语义 + 批量解析）。v18 schema 直接用
/// `GRDBKnowledgeSchema.migrate` 施加——主 agent 注册与否不影响。
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
        // 最小依赖集：notes/decks 由 v1 迁移提供；lexemes 等由 v18。
        // 需要 notes/source_contexts/reader_documents：跑全量迁移
        // 到 v17（注册路径与生产一致），再接 v18。
        try OboeDatabaseSchema.makeMigrator(applying:
            OboeDatabaseSchema.migrationIdentifiers).migrate(pool)
        var v18 = DatabaseMigrator()
        v18.registerMigration(
            "v18_lexical_knowledge", migrate: GRDBKnowledgeSchema.migrate)
        try v18.migrate(pool)
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

    // MARK: - 真值表（D05 全组合）

    /// override × link 全组合：ignored > known > link(vocab Note) > unknown。
    func testTruthTableAllCombinations() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "食べる", deckID: deckID)
        let lexeme = try await jmdictLexeme(entryID: 1, form: "食べる")

        // {nil, 0 link} → unknown
        let k01 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k01, .unknown)
        // {nil, 1 link} → learning
        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteID, origin: .backfill)
        let k02 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k02, .learning)
        // {known, 1 link} → known（override 优先）
        _ = try await repository.setOverride(
            lexemeID: lexeme.id, override: .known, at: Date())
        let k03 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k03, .known)
        // {ignored, 1 link} → ignored
        _ = try await repository.setOverride(
            lexemeID: lexeme.id, override: .ignored, at: Date())
        let k04 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k04, .ignored)
        // {ignored, 0 link} → ignored；{known, 0 link} → known
        try await repository.unlinkNote(lexemeID: lexeme.id, noteID: noteID)
        let k05 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k05, .ignored)
        _ = try await repository.setOverride(
            lexemeID: lexeme.id, override: .known, at: Date())
        let k06 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k06, .known)
        // 回 nil → {nil, 0 link} → unknown
        _ = try await repository.setOverride(
            lexemeID: lexeme.id, override: nil, at: Date())
        let k07 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k07, .unknown)
    }

    /// 暂停卡（is_enabled=0）不计入状态判定——仍是 learning（D05）。
    func testPausedCardNoteStillLearning() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "走る", deckID: deckID)
        try insertPausedCard(noteID: noteID)
        let lexeme = try await jmdictLexeme(entryID: 2, form: "走る")
        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteID, origin: .automaticHighConfidence)
        let k08 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k08, .learning)
    }

    /// grammar Note 的关联不驱动 learning（§6.3：vocabulary Note 才算）。
    func testGrammarNoteLinkDoesNotCount() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(
            headword: "〜によって", kind: "grammar", deckID: deckID)
        let lexeme = try await jmdictLexeme(entryID: 3, form: "によって")
        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteID, origin: .userConfirmed)
        let k09 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k09, .unknown)
    }

    /// 多 Note/多牌组：两条关联 → learning；删一条仍 learning；
    /// 删最后一条 → unknown。
    func testMultipleNotesAndDeletionFallback() async throws {
        let deckA = try insertDeck()
        let deckB = try insertDeck()
        let noteA = try insertNote(headword: "見る", deckID: deckA)
        let noteB = try insertNote(headword: "見る", deckID: deckB)
        let lexeme = try await jmdictLexeme(entryID: 4, form: "見る")

        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteA, origin: .backfill)
        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteB, origin: .userConfirmed)
        let k10 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k10, .learning)

        // 删除第一个 Note——FK 级联清 link。
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteA)])
        }
        let k11 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k11, .learning)
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

    // MARK: - 幂等 / 事件 / receipt

    /// 同一操作重复：返回同 receipt UUID、不新增事件、
    /// override/receipt 行数不膨胀。
    func testSetOverrideIdempotentReceipt() async throws {
        let lexeme = try await jmdictLexeme(entryID: 5, form: "読む")
        let date = Date(timeIntervalSince1970: 1_700_000_100)
        let r1 = try await repository.setOverride(
            lexemeID: lexeme.id, override: .known, at: date)
        let r2 = try await repository.setOverride(
            lexemeID: lexeme.id, override: .known, at: date)
        XCTAssertEqual(r1, r2)
        XCTAssertEqual(
            try eventCount(kind: .markedKnown, lexemeID: lexeme.id), 1)
        XCTAssertEqual(try receiptCount(), 1)
        let stored = try await repository.knowledgeReceipt(operationID: r1)
        XCTAssertEqual(stored?.kind, "knowledge_override")

        // 状态迁移再回放：known → reset → known。第三次 known 是新
        // 迁移（receipt 存在但当前态不符）→ 正常写入+新事件，receipt
        // 行被 REPLACE 指向新结果，返回仍是同一 opID。
        _ = try await repository.setOverride(
            lexemeID: lexeme.id, override: nil, at: date)
        XCTAssertEqual(
            try eventCount(kind: .resetKnowledge, lexemeID: lexeme.id), 1)
        let r3 = try await repository.setOverride(
            lexemeID: lexeme.id, override: .known,
            at: date.addingTimeInterval(60))
        XCTAssertEqual(r3, r1)
        XCTAssertEqual(
            try eventCount(kind: .markedKnown, lexemeID: lexeme.id), 2)
        XCTAssertEqual(try receiptCount(), 2) // override(known) + reset
    }

    /// ignored 无事件枚举——只写 receipt，不写 reader_activity_events。
    func testIgnoredWritesReceiptOnly() async throws {
        let lexeme = try await jmdictLexeme(entryID: 6, form: "高い")
        let r = try await repository.setOverride(
            lexemeID: lexeme.id, override: .ignored, at: Date())
        XCTAssertNotNil(r)
        XCTAssertEqual(try eventCount(lexemeID: lexeme.id), 0)
        let k13 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k13, .ignored)
    }

    /// userConfirmed link → linkedExistingNote 事件一次；
    /// 重复 linkNote 不双发；automatic/backfill 不发事件。
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

    /// 「加入学习」原子语义：known + 无关联 → 同事务清 override +
    /// 建关联 → learning；receipt + 事件齐。
    func testAddToLearningClearsOverrideAndLinks() async throws {
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "泳ぐ", deckID: deckID)
        let lexeme = try await jmdictLexeme(entryID: 8, form: "泳ぐ")
        _ = try await service.markKnown(lexemeID: lexeme.id)
        let k14 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k14, .known)

        let receipt = try await service.addToLearning(
            lexemeID: lexeme.id, noteID: noteID)
        let k15 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k15, .learning)
        // 再调一次 → 幂等（同 receipt、无新事件）。
        let receipt2 = try await service.addToLearning(
            lexemeID: lexeme.id, noteID: noteID)
        XCTAssertEqual(receipt, receipt2)
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
        // local lexeme 失去唯一关联 → unknown；jmdict → learning。
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
    func testInvalidationSignals() async throws {
        let base = await invalidation.revision
        let lexeme = try await jmdictLexeme(entryID: 55, form: "読む")
        _ = try await service.markKnown(lexemeID: lexeme.id)
        _ = try await service.markIgnored(lexemeID: lexeme.id)
        _ = try await service.resetKnowledge(lexemeID: lexeme.id)
        let after = await invalidation.revision
        XCTAssertEqual(after, base &+ 3)
        let perLexeme = await invalidation.lexemeRevision(lexeme.id)
        XCTAssertEqual(perLexeme, 3)
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

    /// 字典更新语义：lexeme 行的 dictionary_entry_id/版本是 provenance——
    /// 词典不可达时状态与关联不受影响（不因 entry 失联降级）。
    func testLexemeSurvivesDictionaryChange() async throws {
        let lexeme = try await jmdictLexeme(entryID: 66, form: "読む")
        let deckID = try insertDeck()
        let noteID = try insertNote(headword: "読む", deckID: deckID)
        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteID, origin: .backfill)
        // 模拟词典更新：entry_id 在新库里不存在——仓储不感知词典库，
        // 状态纯由 override+link 决定。
        let k19 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k19, .learning)
        let fetched = try await repository.fetchLexeme(key: lexeme.key)
        XCTAssertEqual(fetched?.dictionaryVersionAtResolution, "test-dict")
    }

    /// 并发写：同一 lexeme 上的并发 setOverride 不撕状态。
    func testConcurrentOverridesSerialize() async throws {
        let lexeme = try await jmdictLexeme(entryID: 77, form: "見る")
        let repository = self.repository!
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await repository.setOverride(
                        lexemeID: lexeme.id, override: .known, at: Date())
                }
            }
        }
        let k20 = try await repository.state(lexemeID: lexeme.id)
        XCTAssertEqual(k20, .known)
        // 幂等：8 次并发同操作 → 至多 1 事件、1 receipt。
        XCTAssertEqual(
            try eventCount(kind: .markedKnown, lexemeID: lexeme.id), 1)
        XCTAssertEqual(try receiptCount(), 1)
    }

    /// 未找到 lexeme/note 的写路径报错而非静默。
    func testWriteValidationErrors() async throws {
        let ghost = UUID()
        do {
            _ = try await repository.setOverride(
                lexemeID: ghost, override: .known, at: Date())
            XCTFail("应抛 lexemeNotFound")
        } catch let error as VocabularyKnowledgeError {
            XCTAssertEqual(error, .lexemeNotFound(ghost))
        }
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
