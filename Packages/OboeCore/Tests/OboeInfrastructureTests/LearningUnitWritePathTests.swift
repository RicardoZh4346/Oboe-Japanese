import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S06：统一词汇写路径 × Learning Unit 绑定 × Reader study
/// deck 生命周期。
///
/// 验收（分步开发计划 S06）：
/// - 任一词汇写入口（手动 executor / 句析批 / JLPT 导入 / Reader
///   挖词 linkExisting / builtin 去重提前返回）落库的词汇 Note
///   同事务获得 `learning_unit_note_links` 正式链接；
/// - `dictionaryBinding`（装配方已验证）→ dictionarySense unit +
///   current alias；无证据 → `local-note:` unit；
/// - 同义项第二 Note 共享 unit、非主链接，不撞 primary 唯一；
/// - 重放/重复调用幂等；
/// - `ensureStudyDeck` 同事务建牌组+绑定，标题跟随/手动改名断随。
final class LearningUnitWritePathTests: XCTestCase {

    // MARK: - commitVocabulary → localNote 兜底

    /// 无词典证据的提交：Note/Card 之外，同事务多一条 primary
    /// link 指向 `local-note:<noteID>` unit，link origin = manual。
    func testPlainCommitBindsLocalNoteUnit() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await database.pool.write { db in
            try Self.insertDeck(id: deckID, in: db)
        }
        let commit = Self.vocabularyCommit(deckID: deckID, headword: "食べる")

        _ = try await repository.commitVocabulary(commit, capture: nil)

        try await database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT l.unit_id, l.role, l.origin,
                           u.identity_kind, u.identity_key, u.lemma
                    FROM learning_unit_note_links l
                    JOIN lexical_learning_units u ON u.id = l.unit_id
                    WHERE l.note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(commit.noteID)]
            )
            guard let row else {
                XCTFail("新 Note 必须有 unit 链接")
                return
            }
            XCTAssertEqual(row["role"], "primary")
            XCTAssertEqual(row["origin"], "manual")
            XCTAssertEqual(row["identity_kind"], "localNote")
            XCTAssertEqual(
                row["identity_key"],
                "local-note:\(commit.noteID.uuidString.lowercased())")
            XCTAssertEqual(row["lemma"], "食べる")
            // localNote unit 每 Note 一个
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM lexical_learning_units"),
                1)
        }
    }

    // MARK: - dictionaryBinding → dictionarySense unit

    /// 装配方验证过的绑定 → resolve-or-create `jmdict:sense-v1:`
    /// unit（current alias + primary link），同一事务可见。
    func testBindingCommitCreatesDictionarySenseUnit() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await database.pool.write { db in
            try Self.insertDeck(id: deckID, in: db)
        }
        let fingerprint = String(repeating: "a", count: 64)
        let binding = DictionarySenseBinding(
            entryID: 1578850, senseID: 42,
            datasetVersion: "jmdict-2025.01",
            fingerprint: fingerprint,
            senseSnapshotJSON: "{\"glosses_en\":[\"to eat\"]}")
        let commit = Self.vocabularyCommit(
            deckID: deckID, headword: "食べる",
            origin: .reader, binding: binding)

        _ = try await repository.commitVocabulary(commit, capture: nil)

        try await database.pool.read { db in
            let unit = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, identity_kind, identity_key, provider,
                           dictionary_entry_id, semantic_fingerprint,
                           fingerprint_version, binding_status
                    FROM lexical_learning_units
                    """)
            guard let unit else {
                XCTFail("dictionarySense unit 未创建")
                return
            }
            XCTAssertEqual(unit["identity_kind"], "dictionarySense")
            XCTAssertEqual(
                unit["identity_key"],
                "jmdict:sense-v1:1578850:\(fingerprint)")
            XCTAssertEqual(unit["provider"], "jmdict")
            XCTAssertEqual(unit["dictionary_entry_id"], 1578850)
            XCTAssertEqual(unit["fingerprint_version"], "sense-fp-1")
            XCTAssertEqual(unit["binding_status"], "current")

            let alias = try Row.fetchOne(
                db,
                sql: """
                    SELECT status, sense_id, dataset_version,
                           fingerprint_version
                    FROM learning_unit_dictionary_aliases
                    """)
            XCTAssertEqual(alias?["status"], "current")
            XCTAssertEqual(alias?["sense_id"], 42)
            XCTAssertEqual(alias?["dataset_version"], "jmdict-2025.01")
            XCTAssertEqual(alias?["fingerprint_version"], "sense-fp-1")

            let link = try Row.fetchOne(
                db,
                sql: """
                    SELECT role, origin FROM learning_unit_note_links
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(commit.noteID)])
            XCTAssertEqual(link?["role"], "primary")
            XCTAssertEqual(link?["origin"], "userConfirmed")
        }
    }

    /// 同义项第二 Note：unit 共享、第二条链接落
    /// `legacy_secondary`——primary 唯一索引不炸，双方 Note
    /// 都绑定到同一学习对象。
    func testSecondNoteSameBindingSharesUnit() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await database.pool.write { db in
            try Self.insertDeck(id: deckID, in: db)
        }
        let fingerprint = String(repeating: "b", count: 64)
        let binding = DictionarySenseBinding(
            entryID: 1578850, senseID: 7,
            datasetVersion: "jmdict-2025.01",
            fingerprint: fingerprint,
            senseSnapshotJSON: "{}")

        _ = try await repository.commitVocabulary(
            Self.vocabularyCommit(deckID: deckID, headword: "食べる",
                             origin: .reader, binding: binding),
            capture: nil)
        _ = try await repository.commitVocabulary(
            Self.vocabularyCommit(deckID: deckID, headword: "食べる",
                             origin: .reader, binding: binding),
            capture: nil)

        try await database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM lexical_learning_units"),
                1, "同 fingerprint 的两次提交必须共享 unit")
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM learning_unit_note_links"),
                2)
            let roles = try String.fetchAll(
                db,
                sql: "SELECT role FROM learning_unit_note_links"
            )
            XCTAssertEqual(
                Set(roles), ["primary", "legacy_secondary"],
                "一主一附属——共享 unit 不撞 primary 唯一")
        }
    }

    /// builtin_jlpt 去重提前返回：既有未绑 Note 在同事务兜底落
    /// 链接（旧数据/并发窗口不漏绑）。
    func testBuiltinJLPTDedupEarlyReturnStillBinds() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        let existingNoteID = UUID()
        try await database.pool.write { db in
            try Self.insertDeck(id: deckID, in: db)
            // 模拟 v22 存量 builtin_jlpt Note（无 unit 链接）。
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        origin, source_ref, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '猫', 'ねこ',
                              'builtin_jlpt', 'builtin-n5-neko', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(existingNoteID),
                    DatabaseValueCodec.encode(deckID)
                ])
        }
        var commit = Self.vocabularyCommit(
            deckID: deckID, headword: "猫", origin: .builtinJLPT)
        commit = VocabularyContentCommit(
            noteID: commit.noteID, exampleID: commit.exampleID,
            draftID: nil, deckID: deckID, content: commit.content,
            tags: [], cards: commit.cards,
            schedulerProfileID: commit.schedulerProfileID,
            createdAt: commit.createdAt, origin: .builtinJLPT,
            sourceRef: "builtin-n5-neko", deckIDs: [deckID])

        let result = try await repository.commitVocabulary(
            commit, capture: nil)

        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.noteID, existingNoteID)
        try await database.pool.read { db in
            let link = try Row.fetchOne(
                db,
                sql: """
                    SELECT role, origin FROM learning_unit_note_links
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(existingNoteID)])
            XCTAssertEqual(link?["role"], "primary")
            XCTAssertEqual(link?["origin"], "imported")
            // 去重路径不得新增第二张 Note
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM notes WHERE kind = 'vocabulary'
                        """),
                1)
        }
    }

    // MARK: - 句析批写路径

    /// `GRDBSentenceAnalysisCardRepository.insertVocabulary`（句析
    /// 制卡/AI 拆分共用）同事务绑定 unit。
    func testSentenceAnalysisInsertVocabularyBinds() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let deckID = UUID()
        let commit = Self.vocabularyCommit(
            deckID: deckID, headword: "走る", origin: .ai)
        try await database.pool.write { db in
            try Self.insertDeck(id: deckID, in: db)
            try GRDBSentenceAnalysisCardRepository.insertVocabulary(
                commit, in: db)
        }
        try await database.pool.read { db in
            let link = try Row.fetchOne(
                db,
                sql: """
                    SELECT role, origin FROM learning_unit_note_links
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(commit.noteID)])
            XCTAssertEqual(link?["role"], "primary")
            XCTAssertEqual(link?["origin"], "automaticHighConfidence")
        }
    }

    /// 既有链接幂等：重复 ensureUnit 返回同一 unit，不产生第二行。
    func testEnsureUnitIdempotent() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await database.pool.write { db in
            try Self.insertDeck(id: deckID, in: db)
        }
        let commit = Self.vocabularyCommit(deckID: deckID, headword: "読む")
        _ = try await repository.commitVocabulary(commit, capture: nil)

        try await database.pool.write { db in
            let first = try LearningUnitWriteBridge.ensureUnit(
                noteID: commit.noteID, headword: "読む", reading: nil,
                binding: nil, linkOrigin: .manual,
                atMilliseconds: 9_999, in: db)
            let second = try LearningUnitWriteBridge.ensureUnit(
                noteID: commit.noteID, headword: "読む", reading: nil,
                binding: nil, linkOrigin: .manual,
                atMilliseconds: 9_999, in: db)
            XCTAssertEqual(first.id, second.id)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM learning_unit_note_links
                        WHERE note_id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(commit.noteID)]),
                1)
        }
    }

    /// 链接不回写：已绑 localNote 的 Note 之后带词典绑定再提交
    /// （去重路径）不得静默换绑——换绑只能走显式 unlink+link。
    func testExistingLinkNeverRebound() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await database.pool.write { db in
            try Self.insertDeck(id: deckID, in: db)
        }
        let commit = Self.vocabularyCommit(deckID: deckID, headword: "猫")
        _ = try await repository.commitVocabulary(commit, capture: nil)
        let localUnitID = try await database.pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT unit_id FROM learning_unit_note_links
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(commit.noteID)])
        }

        let binding = DictionarySenseBinding(
            entryID: 1, senseID: 1, datasetVersion: "v",
            fingerprint: String(repeating: "c", count: 64),
            senseSnapshotJSON: "{}")
        try await database.pool.write { db in
            let unit = try LearningUnitWriteBridge.ensureUnit(
                noteID: commit.noteID, headword: "猫", reading: nil,
                binding: binding, linkOrigin: .userConfirmed,
                atMilliseconds: 9_999, in: db)
            XCTAssertEqual(unit.id.uuidString.lowercased(), localUnitID)
        }
        try await database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM lexical_learning_units
                        WHERE identity_kind = 'dictionarySense'
                        """),
                0, "已有链接的 Note 不得换绑")
        }
    }

    // MARK: - Reader study deck 生命周期（v24）

    /// ensureStudyDeck：无绑定时同事务建牌组（`阅读·《标题》`）+
    /// 绑定 + follows flag；再调用幂等返回同一 deck。
    func testEnsureStudyDeckCreatesAndIdempotent() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let documentID = UUID()
        try await database.pool.write { db in
            try Self.insertReaderDocument(id: documentID, title: "吾輩は猫である", in: db)
        }

        let (deck1, deck2) = try await database.pool.write { db in
            let first = try GRDBReaderStudyDeckService.ensureStudyDeck(
                documentID: documentID, in: db)
            let second = try GRDBReaderStudyDeckService.ensureStudyDeck(
                documentID: documentID, in: db)
            return (first, second)
        }
        XCTAssertEqual(deck1, deck2)

        try await database.pool.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db, sql: "SELECT name FROM decks WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(deck1)]),
                "阅读·《吾輩は猫である》")
            let flags = try Row.fetchOne(
                db,
                sql: """
                    SELECT study_deck_id, study_deck_name_follows_title
                    FROM reader_documents WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)])
            XCTAssertEqual(
                flags?["study_deck_id"],
                deck1.uuidString.lowercased())
            XCTAssertEqual(flags?["study_deck_name_follows_title"], 1)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decks"),
                1, "幂等调用不得建第二个牌组")
        }
    }

    /// 同名不同文档 → 各自独立的 study deck（不按名查重）。
    func testSameTitleDocumentsGetSeparateDecks() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let (docA, docB) = (UUID(), UUID())
        try await database.pool.write { db in
            try Self.insertReaderDocument(id: docA, title: "同题", in: db)
            try Self.insertReaderDocument(id: docB, title: "同题", in: db)
            let deckA = try GRDBReaderStudyDeckService.ensureStudyDeck(
                documentID: docA, in: db)
            let deckB = try GRDBReaderStudyDeckService.ensureStudyDeck(
                documentID: docB, in: db)
            XCTAssertNotEqual(deckA, deckB)
        }
    }

    /// contentRevision 不符 → staleContentRevision，且不写任何行。
    func testEnsureStudyDeckRejectsStaleRevision() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let documentID = UUID()
        try await database.pool.write { db in
            try Self.insertReaderDocument(id: documentID, title: "檔", in: db)
            XCTAssertThrowsError(
                try GRDBReaderStudyDeckService.ensureStudyDeck(
                    documentID: documentID,
                    expectedContentRevision: 99, in: db)
            ) { error in
                XCTAssertEqual(
                    error as? ReaderStudyDeckError,
                    .staleContentRevision(expected: 99, current: 1))
            }
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decks"),
                0)
            XCTAssertNil(
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT study_deck_id FROM reader_documents
                        WHERE id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(documentID)]))
        }
    }

    /// 标题跟随：follows=1 时文档改名同步牌组名；手动改牌组名后
    /// follows=0，文档改名不再跟随；删除文档不删牌组。
    func testRenameFollowsTitleUntilManualRename() async throws {
        let location = try WritePathLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBDeckRepository(database: database)
        let documentID = UUID()
        try await database.pool.write { db in
            try Self.insertReaderDocument(id: documentID, title: "旧题", in: db)
        }
        let deckID = try await database.pool.write { db in
            try GRDBReaderStudyDeckService.ensureStudyDeck(
                documentID: documentID, in: db)
        }

        // follows=1：文档改名 → 牌组跟随
        _ = try await database.pool.write { db in
            try GRDBReaderStudyDeckService.documentTitleChanged(
                documentID: documentID, newTitle: "新题", in: db)
        }
        var name = try await database.pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT name FROM decks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deckID)])
        }
        XCTAssertEqual(name, "阅读·《新题》")

        // 用户手动改牌组名 → follows=0 → 文档改名不再动牌组
        _ = try await repository.renameDeck(
            id: deckID, name: "我的收藏", at: Date())
        _ = try await database.pool.write { db in
            try GRDBReaderStudyDeckService.documentTitleChanged(
                documentID: documentID, newTitle: "又改名", in: db)
        }
        name = try await database.pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT name FROM decks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deckID)])
        }
        XCTAssertEqual(name, "我的收藏")

        // 删除文档 → 绑定随文档消失，牌组保留
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_documents WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(documentID)])
        }
        let deckAlive = try await database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM decks WHERE id = ?)",
                arguments: [DatabaseValueCodec.encode(deckID)])
        }
        XCTAssertEqual(deckAlive, true)
    }

    // MARK: - helpers

    private struct WritePathLocation {
        let directoryURL: URL
        var databaseURL: URL {
            directoryURL.appendingPathComponent("db.sqlite")
        }

        init() throws {
            directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    private static func vocabularyCommit(
        deckID: UUID,
        headword: String,
        origin: ContentOrigin = .manual,
        binding: DictionarySenseBinding? = nil
    ) -> VocabularyContentCommit {
        VocabularyContentCommit(
            noteID: UUID(),
            exampleID: UUID(),
            draftID: nil,
            deckID: deckID,
            content: try! VocabularyFormData(
                headword: headword,
                meaningZH: "释义"
            ).validatedContent(),
            tags: [],
            cards: [
                NewCardSeed(
                    id: UUID(),
                    templateKind: .vocabularyJapaneseToChinese)
            ],
            schedulerProfileID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_768_000_000),
            origin: origin,
            deckIDs: [deckID],
            dictionaryBinding: binding
        )
    }

    private static func insertDeck(id: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                VALUES (?, '牌组', 0, 1, 1)
                """,
            arguments: [DatabaseValueCodec.encode(id)]
        )
    }

    private static func insertReaderDocument(
        id: UUID, title: String, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_documents(
                    id, title, format, created_at_ms,
                    source_sha256, canonical_text_hash,
                    parser_version, content_revision,
                    progress_basis_points, availability
                ) VALUES (?, ?, 'txt', 1, ?, ?, 'v1', 1, 0, 'available')
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                title,
                String(repeating: "a", count: 64),
                String(repeating: "b", count: 64)
            ]
        )
    }
}
