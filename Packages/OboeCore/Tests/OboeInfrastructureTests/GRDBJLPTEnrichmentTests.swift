import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T12（设计 §7.4）：schema v2 列解码、新导入写入、旧数据只补 NULL
/// 的幂等回填。夹具用真实 SQLite——词库为迷你 v2/v1 库，用户库走
/// 完整迁移到最新 schema。
final class GRDBJLPTEnrichmentTests: XCTestCase {

    // MARK: - 解码

    func testV2ColumnsAreDecodedInListAndDetail() async throws {
        let location = try TestLocation()
        defer { location.remove() }
        try makeLibraryV2(at: location.libraryURL)
        let repository = try GRDBJLPTLibraryRepository(databaseURL: location.libraryURL)

        let page = try await repository.vocabulary(
            level: .n5, query: "", sort: .source, limit: 10, offset: 0
        )
        let eater = try XCTUnwrap(page.items.first { $0.id == "openjlpt:N5:000001" })
        XCTAssertEqual(eater.pitchAccent, PitchAccent(rawValue: 2))
        XCTAssertEqual(eater.pitchSource, "unidic_cwj")
        XCTAssertEqual(eater.pitchSourceRef, "cwj:taberu")
        XCTAssertEqual(eater.examples.first?.translationZH, "吃饭。")

        let detailRow = try await repository.vocabulary(id: "openjlpt:N5:000001")
        let detail = try XCTUnwrap(detailRow)
        XCTAssertEqual(detail.pitchAccent, PitchAccent(rawValue: 2))
        XCTAssertEqual(detail.examples.count, 2)
        XCTAssertEqual(detail.examples[0].translationZH, "吃饭。")
        XCTAssertNil(detail.examples[1].translationZH)

        let schoolRow = try await repository.vocabulary(id: "openjlpt:N5:000002")
        let school = try XCTUnwrap(schoolRow)
        XCTAssertNil(school.pitchAccent)
        XCTAssertNil(school.pitchSource)
        XCTAssertEqual(school.examples.first?.translationZH, "去学校。")
    }

    func testV1LibraryDecodesNilForNewColumnsAndOffersNoEnrichment() async throws {
        let location = try TestLocation()
        defer { location.remove() }
        try makeLibraryV1(at: location.libraryURL)
        let repository = try GRDBJLPTLibraryRepository(databaseURL: location.libraryURL)

        XCTAssertFalse(repository.offersEnrichmentData)
        let page = try await repository.vocabulary(
            level: .n5, query: "", sort: .source, limit: 10, offset: 0
        )
        XCTAssertEqual(page.items.first?.headword, "食べる")
        XCTAssertNil(page.items.first?.pitchAccent)
        XCTAssertNil(page.items.first?.examples.first?.translationZH)
        let detail = try await repository.vocabulary(id: "openjlpt:N5:000001")
        XCTAssertNil(detail?.pitchAccent)
        XCTAssertNil(detail?.examples.first?.translationZH)
    }

    // MARK: - 新导入写入

    func testImportWritesPitchAndExampleTranslation() async throws {
        let location = try TestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let importer = GRDBJLPTImporter(database: database)
        let deckID = try await makeDeck(in: database)
        let vocabulary = BuiltinJLPTVocabulary(
            id: "openjlpt:N5:000001",
            level: .n5,
            headword: "食べる",
            reading: "たべる",
            meaningZH: "吃",
            meaningsEN: ["to eat"],
            partOfSpeech: "动词",
            frequencyRank: 1,
            dataFlags: 0,
            examples: [
                BuiltinJLPTExample(
                    id: "ex-1a",
                    japanese: "ご飯を食べる。",
                    english: "Eat a meal.",
                    sortOrder: 0,
                    translationZH: "吃饭。"
                ),
            ],
            pitchAccent: PitchAccent(rawValue: 2)
        )

        let result = try await importer.importVocabulary(
            vocabulary,
            deckID: deckID,
            meaningZH: "吃",
            directions: [.japaneseToChinese]
        )
        XCTAssertEqual(result.imported, 1)

        let rows = try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT pitch_accent FROM notes"),
                try String.fetchOne(db, sql: "SELECT translation_zh FROM examples")
            )
        }
        XCTAssertEqual(rows.0, 2)
        XCTAssertEqual(rows.1, "吃饭。")
    }

    // MARK: - 回填

    /// 覆盖必须验证口径的主体：只补 NULL、用户非空值保持、日文不匹配
    /// 不更新、缺失 sourceRef 安全跳过、重复运行零额外变化。
    func testEnrichmentFillsOnlyNullsAndIsIdempotent() async throws {
        let location = try TestLocation()
        defer { location.remove() }
        try makeLibraryV2(at: location.libraryURL)
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let deckID = try await makeDeck(in: database)

        // 可回填：pitch NULL + 例句可匹配/词库 NULL/用户改写日文三类。
        let fillable = try await addBuiltinNote(
            in: database, deckID: deckID,
            sourceRef: "openjlpt:N5:000001", reading: "たべる", pitch: nil
        )
        try await addExample(
            in: database, noteID: fillable,
            japanese: "ご飯を食べる。", translationZH: nil, sortOrder: 0
        )
        try await addExample(
            in: database, noteID: fillable,
            japanese: "朝ご飯を食べる。", translationZH: nil, sortOrder: 1
        )
        try await addExample(
            in: database, noteID: fillable,
            japanese: "手作り例文", translationZH: nil, sortOrder: 0
        )

        // 用户已填 pitch 保持不覆盖；无匹配例句时仍是候选。
        let userPitch = try await addBuiltinNote(
            in: database, deckID: deckID,
            sourceRef: "openjlpt:N5:000002", reading: "がっこう", pitch: 5
        )
        try await addExample(
            in: database, noteID: userPitch,
            japanese: "学校で待つ。", translationZH: nil, sortOrder: 1
        )

        // 新库中不存在的旧 sourceRef：安全跳过。
        _ = try await addBuiltinNote(
            in: database, deckID: deckID,
            sourceRef: "openjlpt:N5:absent", reading: "なし", pitch: nil
        )

        // 词库音调与用户当前读音 mora 不一致：不写违例值。
        _ = try await addBuiltinNote(
            in: database, deckID: deckID,
            sourceRef: "openjlpt:N4:000001", reading: "あ", pitch: nil
        )

        // manual Note 不参与；其 NULL 例句不受影响。
        let manualNote = try await addNote(
            in: database, deckID: deckID,
            origin: "manual", sourceRef: nil, pitch: nil
        )
        try await addExample(
            in: database, noteID: manualNote,
            japanese: "ご飯を食べる。", translationZH: nil, sortOrder: 0
        )

        // 已完备的 builtin Note 不是候选。
        let complete = try await addBuiltinNote(
            in: database, deckID: deckID,
            sourceRef: "openjlpt:N4:000002", reading: "いけん", pitch: 1
        )
        try await addExample(
            in: database, noteID: complete,
            japanese: "彼の意見を聞く。", translationZH: "听他的意见。", sortOrder: 0
        )

        let service = try makeService(location: location, database: database)
        let progress = ProgressRecorder()
        let report = try await service.enrich { await progress.append($0) }

        XCTAssertEqual(report.candidateCount, 4)
        XCTAssertEqual(report.missingEntries, 1)
        XCTAssertEqual(report.pitchFilled, 1)
        XCTAssertEqual(report.pitchSkippedInconsistent, 1)
        XCTAssertEqual(report.examplesFilled, 1)
        let progressValues = await progress.values
        XCTAssertEqual(progressValues.last, JLPTEnrichmentProgress(processed: 4, total: 4))

        let state = try await snapshotUserState(in: database)
        XCTAssertEqual(state.pitchByRef["openjlpt:N5:000001"], 2)
        XCTAssertEqual(state.pitchByRef["openjlpt:N5:000002"], 5)
        XCTAssertNil(state.pitchByRef["openjlpt:N5:absent"])
        XCTAssertNil(state.pitchByRef["openjlpt:N4:000001"])
        let fillableTranslations = state.translationsByNote[fillable, default: [:]]
        XCTAssertEqual(fillableTranslations["ご飯を食べる。\u{1F}0"], "吃饭。")
        XCTAssertNil(fillableTranslations["朝ご飯を食べる。\u{1F}1"])
        XCTAssertNil(fillableTranslations["手作り例文\u{1F}0"])
        XCTAssertNil(state.translationsByNote[userPitch]?["学校で待つ。\u{1F}1"] ?? nil)
        XCTAssertNil(state.translationsByNote[manualNote])

        // 重复运行：不可满足的候选仍在，但零写入——幂等。
        let second = try await service.enrich()
        XCTAssertEqual(second.candidateCount, 4)
        XCTAssertEqual(second.pitchFilled, 0)
        XCTAssertEqual(second.examplesFilled, 0)
    }

    /// 中断重试：第二批失败后第一批已提交的内容保留，重跑补齐剩余。
    func testEnrichmentInterruptionResumesRemainingBatches() async throws {
        let location = try TestLocation()
        defer { location.remove() }
        try makeLibraryV2(at: location.libraryURL)
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let deckID = try await makeDeck(in: database)
        // 两个候选的词库 pitch 均可填；批大小 1 + 第 2 次写注入失败，
        // 保证恰好一条已提交后中断（候选顺序按 UUID，不指定谁在前）。
        _ = try await addFillableNotes(
            in: database, deckID: deckID,
            refs: ["openjlpt:N5:000001", "openjlpt:N4:000002"]
        )

        let store = GRDBJLPTEnrichmentRepository(database: database)
        let flaky = FlakyEnrichmentStore(base: store, throwOnCall: 2)
        let repository = try GRDBJLPTLibraryRepository(databaseURL: location.libraryURL)
        let interrupted = JLPTLibraryEnrichmentService(
            source: repository, store: flaky, batchSize: 1
        )

        do {
            _ = try await interrupted.enrich()
            XCTFail("第二批应抛出注入错误")
        } catch {
            XCTAssertEqual(
                error as? FlakyEnrichmentStore.InjectedError, .injected
            )
        }
        var state = try await snapshotUserState(in: database)
        XCTAssertEqual(state.pitchByRef.count, 1)

        let resumed = JLPTLibraryEnrichmentService(
            source: repository, store: flaky, batchSize: 1
        )
        let report = try await resumed.enrich()
        XCTAssertEqual(report.candidateCount, 1)
        XCTAssertEqual(report.pitchFilled, 1)
        state = try await snapshotUserState(in: database)
        XCTAssertEqual(state.pitchByRef["openjlpt:N5:000001"], 2)
        XCTAssertEqual(state.pitchByRef["openjlpt:N4:000002"], 1)
    }

    /// 取消发生在批边界：已提交批次不回滚，任务以 CancellationError 结束；
    /// 重跑补齐全部剩余。
    func testEnrichmentCancellationStopsAtBatchBoundary() async throws {
        let location = try TestLocation()
        defer { location.remove() }
        try makeLibraryV2(at: location.libraryURL)
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let deckID = try await makeDeck(in: database)
        _ = try await addFillableNotes(
            in: database, deckID: deckID,
            refs: ["openjlpt:N5:000001", "openjlpt:N4:000002", "openjlpt:N5:000002"]
        )

        let repository = try GRDBJLPTLibraryRepository(databaseURL: location.libraryURL)
        let service = JLPTLibraryEnrichmentService(
            source: repository,
            store: GRDBJLPTEnrichmentRepository(database: database),
            batchSize: 1
        )
        let canceller = Canceller()
        let task = Task {
            try await service.enrich { _ in
                await canceller.requestCancel()
            }
        }
        await canceller.set(task)

        let outcome = await task.result
        guard case .failure(let error) = outcome else {
            return XCTFail("取消的运行应以 CancellationError 结束")
        }
        XCTAssertTrue(error is CancellationError)

        // 重跑补齐：000001→2、N4:000002→1；N5:000002 词库 pitch 为 NULL
        // 保持 NULL。
        _ = try await service.enrich()
        let state = try await snapshotUserState(in: database)
        XCTAssertEqual(state.pitchByRef["openjlpt:N5:000001"], 2)
        XCTAssertEqual(state.pitchByRef["openjlpt:N4:000002"], 1)
        XCTAssertNil(state.pitchByRef["openjlpt:N5:000002"])
    }

    /// 全量规模冒烟（设计 §7.4「8,334 条批量性能可接受」）：合成
    /// 8,334 条 v2 词条与等量已导入 Note（pitch/例句翻译全 NULL），
    /// 默认批大小跑完整回填。宽松上限只挡病态回退，不做微基准。
    func testEnrichmentAtFullLibraryScale() async throws {
        let location = try TestLocation()
        defer { location.remove() }
        try makeScaledLibraryV2(at: location.libraryURL, wordCount: 8_334)
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let deckID = try await makeDeck(in: database)
        try await database.pool.write { db in
            for index in 0..<8_334 {
                let noteID = UUID()
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, reading, meaning_zh,
                            origin, source_ref, pitch_accent,
                            content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', '語', 'あいう', '义',
                                  'builtin_jlpt', ?, NULL, 1, 1, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID),
                        DatabaseValueCodec.encode(deckID),
                        "scale:\(index)",
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                        VALUES (?, ?, ?, NULL, 0)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(noteID),
                        "scale sentence \(index)",
                    ]
                )
            }
        }

        let service = try makeService(location: location, database: database)
        let started = Date()
        let report = try await service.enrich()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(report.candidateCount, 8_334)
        XCTAssertEqual(report.pitchFilled, 8_334)
        XCTAssertEqual(report.examplesFilled, 8_334)
        XCTAssertEqual(report.batches, 42)
        XCTAssertLessThan(elapsed, 60)
    }

    /// v1 词库无可回填字段：立即返回，不读候选、不写库。
    func testEnrichmentAgainstV1LibraryIsANoOp() async throws {
        let location = try TestLocation()
        defer { location.remove() }
        try makeLibraryV1(at: location.libraryURL)
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let deckID = try await makeDeck(in: database)
        _ = try await addFillableNotes(
            in: database, deckID: deckID, refs: ["openjlpt:N5:000001"]
        )

        let service = try makeService(location: location, database: database)
        let report = try await service.enrich()
        XCTAssertEqual(report, JLPTEnrichmentReport())
        let state = try await snapshotUserState(in: database)
        XCTAssertNil(state.pitchByRef["openjlpt:N5:000001"])
    }

    // MARK: - Fixture

    private struct TestLocation {
        let rootURL: URL
        let libraryURL: URL
        let userDatabaseURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("GRDBJLPTEnrichmentTests-\(UUID().uuidString)", isDirectory: true)
            libraryURL = rootURL.appendingPathComponent("library.sqlite")
            userDatabaseURL = rootURL.appendingPathComponent("user.sqlite")
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private func makeService(
        location: TestLocation,
        database: OboeDatabase
    ) throws -> JLPTLibraryEnrichmentService {
        JLPTLibraryEnrichmentService(
            source: try GRDBJLPTLibraryRepository(databaseURL: location.libraryURL),
            store: GRDBJLPTEnrichmentRepository(database: database)
        )
    }

    private func makeDeck(in database: OboeDatabase) async throws -> UUID {
        let deckID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '牌组', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        return deckID
    }

    @discardableResult
    private func addNote(
        in database: OboeDatabase,
        deckID: UUID,
        origin: String,
        sourceRef: String?,
        pitch: Int?
    ) async throws -> UUID {
        let noteID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        origin, source_ref, pitch_accent,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '語', 'たべる', '义', ?, ?, ?, 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    origin,
                    sourceRef,
                    pitch,
                ]
            )
            try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
        }
        return noteID
    }

    private func addBuiltinNote(
        in database: OboeDatabase,
        deckID: UUID,
        sourceRef: String,
        reading: String,
        pitch: Int?
    ) async throws -> UUID {
        let noteID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        origin, source_ref, pitch_accent,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '語', ?, '义',
                              'builtin_jlpt', ?, ?, 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    reading,
                    sourceRef,
                    pitch,
                ]
            )
            try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
        }
        return noteID
    }

    private func addFillableNotes(
        in database: OboeDatabase,
        deckID: UUID,
        refs: [String]
    ) async throws -> [UUID] {
        var ids: [UUID] = []
        for ref in refs {
            ids.append(try await addBuiltinNote(
                in: database, deckID: deckID,
                sourceRef: ref, reading: "たべる", pitch: nil
            ))
        }
        return ids
    }

    private func addExample(
        in database: OboeDatabase,
        noteID: UUID,
        japanese: String,
        translationZH: String?,
        sortOrder: Int
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(noteID),
                    japanese,
                    translationZH,
                    sortOrder,
                ]
            )
        }
    }

    private struct UserState {
        var pitchByRef: [String: Int] = [:]
        /// noteID → "japanese\u{1F}sortOrder" → translation_zh（仅非空行）。
        var translationsByNote: [UUID: [String: String]] = [:]
    }

    private func snapshotUserState(in database: OboeDatabase) async throws -> UserState {
        try await database.pool.read { db in
            var state = UserState()
            let noteRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_ref, pitch_accent FROM notes
                    WHERE origin = 'builtin_jlpt' AND source_ref IS NOT NULL
                    """
            )
            for row in noteRows {
                let ref: String = row["source_ref"]
                if let pitch: Int = row["pitch_accent"] {
                    state.pitchByRef[ref] = pitch
                }
            }
            let exampleRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT note_id, japanese, sort_order, translation_zh
                    FROM examples
                    """
            )
            for row in exampleRows {
                guard let translation: String = row["translation_zh"] else { continue }
                let noteID = try DatabaseValueCodec.decodeUUID(row["note_id"])
                let japanese: String = row["japanese"]
                let sortOrder: Int = row["sort_order"]
                state.translationsByNote[noteID, default: [:]][
                    "\(japanese)\u{1F}\(sortOrder)"
                ] = translation
            }
            return state
        }
    }

    /// 迷你 schema v2 词库：000001 有音调+两条例句（其一翻译 NULL）、
    /// 000002 音调 NULL + 一条已翻译例句、N4:000001 音调 5（供越界用例）、
    /// N4:000002 音调 1 + 一条例句。
    private func makeLibraryV2(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE vocab (
                    id TEXT PRIMARY KEY NOT NULL,
                    level TEXT NOT NULL,
                    headword TEXT NOT NULL,
                    reading TEXT NOT NULL,
                    meaning_zh TEXT,
                    meaning_en_json TEXT NOT NULL,
                    part_of_speech TEXT,
                    pitch_accent INTEGER,
                    pitch_source TEXT,
                    pitch_source_ref TEXT,
                    frequency_rank INTEGER,
                    normalized_headword TEXT NOT NULL,
                    normalized_reading TEXT NOT NULL,
                    normalized_meaning_zh TEXT,
                    sort_order INTEGER NOT NULL,
                    data_flags INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE vocab_examples (
                    id TEXT PRIMARY KEY NOT NULL,
                    vocab_id TEXT NOT NULL REFERENCES vocab(id) ON DELETE CASCADE,
                    japanese TEXT NOT NULL,
                    english TEXT,
                    translation_zh TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO vocab(
                    id, level, headword, reading, meaning_zh, meaning_en_json,
                    part_of_speech, pitch_accent, pitch_source, pitch_source_ref,
                    frequency_rank, normalized_headword, normalized_reading,
                    normalized_meaning_zh, sort_order, data_flags
                ) VALUES
                    ('openjlpt:N5:000001', 'N5', '食べる', 'たべる', '吃',
                     '["to eat"]', '动词', 2, 'unidic_cwj', 'cwj:taberu',
                     1, '食べる', 'たべる', '吃', 0, 0),
                    ('openjlpt:N5:000002', 'N5', '学校', 'がっこう', '学校',
                     '["school"]', '名词', NULL, NULL, NULL,
                     5, '学校', 'がっこう', '学校', 1, 0),
                    ('openjlpt:N4:000001', 'N4', '破格', 'はかく', '破格',
                     '["exceptional"]', '名词', 5, 'kanjium', 'kanjium:hakaku',
                     2, '破格', 'はかく', '破格', 0, 0),
                    ('openjlpt:N4:000002', 'N4', '意見', 'いけん', '意见',
                     '["opinion"]', '名词', 1, 'unidic_cwj', 'cwj:iken',
                     3, '意見', 'いけん', '意见', 1, 0);
                INSERT INTO vocab_examples(
                    id, vocab_id, japanese, english, translation_zh, sort_order
                ) VALUES
                    ('ex-1a', 'openjlpt:N5:000001', 'ご飯を食べる。', 'Eat a meal.', '吃饭。', 0),
                    ('ex-1b', 'openjlpt:N5:000001', '朝ご飯を食べる。', 'I eat breakfast.', NULL, 1),
                    ('ex-2', 'openjlpt:N5:000002', '学校へ行く。', 'I go to school.', '去学校。', 0),
                    ('ex-4', 'openjlpt:N4:000002', '彼の意見を聞く。', 'I listen to his opinion.', '听他的意见。', 0);
                """)
        }
        try queue.close()
    }

    /// 规模夹具：`wordCount` 条 v2 词（pitch=2 + 一条带中文例句），
    /// sourceRef 为 `scale:<index>`。
    private func makeScaledLibraryV2(at url: URL, wordCount: Int) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE vocab (
                    id TEXT PRIMARY KEY NOT NULL,
                    level TEXT NOT NULL,
                    headword TEXT NOT NULL,
                    reading TEXT NOT NULL,
                    meaning_zh TEXT,
                    meaning_en_json TEXT NOT NULL,
                    part_of_speech TEXT,
                    pitch_accent INTEGER,
                    pitch_source TEXT,
                    pitch_source_ref TEXT,
                    frequency_rank INTEGER,
                    normalized_headword TEXT NOT NULL,
                    normalized_reading TEXT NOT NULL,
                    normalized_meaning_zh TEXT,
                    sort_order INTEGER NOT NULL,
                    data_flags INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE vocab_examples (
                    id TEXT PRIMARY KEY NOT NULL,
                    vocab_id TEXT NOT NULL REFERENCES vocab(id) ON DELETE CASCADE,
                    japanese TEXT NOT NULL,
                    english TEXT,
                    translation_zh TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0
                );
                """)
            for index in 0..<wordCount {
                let ref = "scale:\(index)"
                try db.execute(
                    sql: """
                        INSERT INTO vocab VALUES
                        (?, 'N5', '語', 'あいう', '义', '["meaning"]', '名词',
                         2, 'unidic_cwj', 'cwj:scale', ?, '語', 'あいう', '义', ?, 0)
                        """,
                    arguments: [ref, index, index]
                )
                try db.execute(
                    sql: """
                        INSERT INTO vocab_examples VALUES
                        (?, ?, ?, 'English.', '译文。', 0)
                        """,
                    arguments: ["ex-\(index)", ref, "scale sentence \(index)"]
                )
            }
        }
        try queue.close()
    }

    /// 迷你 schema v1 词库：无音调/翻译列，验证解码回退为 nil。
    private func makeLibraryV1(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE vocab (
                    id TEXT PRIMARY KEY NOT NULL,
                    level TEXT NOT NULL,
                    headword TEXT NOT NULL,
                    reading TEXT NOT NULL,
                    meaning_zh TEXT,
                    meaning_en_json TEXT NOT NULL,
                    part_of_speech TEXT,
                    frequency_rank INTEGER,
                    normalized_headword TEXT NOT NULL,
                    normalized_reading TEXT NOT NULL,
                    normalized_meaning_zh TEXT,
                    sort_order INTEGER NOT NULL,
                    data_flags INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE vocab_examples (
                    id TEXT PRIMARY KEY NOT NULL,
                    vocab_id TEXT NOT NULL REFERENCES vocab(id) ON DELETE CASCADE,
                    japanese TEXT NOT NULL,
                    english TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO vocab VALUES
                    ('openjlpt:N5:000001', 'N5', '食べる', 'たべる', '吃',
                     '["to eat"]', '动词', 1, '食べる', 'たべる', '吃', 0, 0);
                INSERT INTO vocab_examples VALUES
                    ('ex-1', 'openjlpt:N5:000001', 'ご飯を食べる。', 'Eat a meal.', 0);
                """)
        }
        try queue.close()
    }
}

private actor ProgressRecorder {
    private(set) var values: [JLPTEnrichmentProgress] = []
    func append(_ value: JLPTEnrichmentProgress) {
        values.append(value)
    }
}

/// 第 `throwOnCall` 次 `applyEnrichment` 注入失败的包装存储——验证
/// 中断时已提交批次保留、重跑补齐，等价于崩溃/强退的恢复路径。
private actor FlakyEnrichmentStore: JLPTEnrichmentStore {
    enum InjectedError: Error, Equatable {
        case injected
    }

    private let base: GRDBJLPTEnrichmentRepository
    private let throwOnCall: Int
    private var calls = 0

    init(base: GRDBJLPTEnrichmentRepository, throwOnCall: Int) {
        self.base = base
        self.throwOnCall = throwOnCall
    }

    nonisolated func enrichmentCandidates() async throws -> [JLPTEnrichmentCandidate] {
        try await base.enrichmentCandidates()
    }

    func applyEnrichment(
        _ writes: [JLPTEnrichmentWrite]
    ) async throws -> JLPTEnrichmentBatchResult {
        calls += 1
        if calls == throwOnCall {
            throw InjectedError.injected
        }
        return try await base.applyEnrichment(writes)
    }
}

/// 把「请求取消」记录为状态：无论 progress 先于还是后于 `set`，
/// 取消都生效——测试不依赖时序。
private actor Canceller {
    private var task: Task<JLPTEnrichmentReport, Error>?
    private var cancelRequested = false

    func set(_ task: Task<JLPTEnrichmentReport, Error>) {
        self.task = task
        if cancelRequested { task.cancel() }
    }

    func requestCancel() {
        cancelRequested = true
        task?.cancel()
    }
}
