import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.0 S17：导入执行器测试。
/// 覆盖：v20 schema、dry-run 零写入、三重复策略矩阵、update 保留调度、
/// 空值语义、冲突单列、文件内重复基准、取消续跑、行失败隔离、
/// receipt 幂等回放、100k 行内存有界。
final class ImportExecutorTests: XCTestCase {

    // MARK: - 夹具

    private var root: URL!
    private var database: OboeDatabase!
    private var stagingDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("S17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try OboeDatabase(path: root.appendingPathComponent("oboe.sqlite").path)
        // v20 迁移由主 agent 注册；测试直接建表（等价于迁移已应用的状态）。
        try database.pool.writeWithoutTransaction { db in
            try GRDBImportSchema.migrate(db)
        }
        stagingDir = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? database.close()
        try? FileManager.default.removeItem(at: root)
    }

    private let targetDeckID = UUID()

    /// Sendable 的 notes 快照（Row 不可跨 async 边界返回）。
    private struct NoteSnapshot: Equatable {
        var id: String
        var kind: String
        var headword: String
        var reading: String?
        var meaningZH: String
        var partOfSpeech: String?
        var jlpt: String?
        var notes: String?
        var pitchAccent: Int?
        var origin: String
        var contentVersion: Int
    }

    private struct CardSnapshot: Equatable {
        var id: String
        var state: Int
        var stability: Double
        var difficulty: Double
        var reps: Int
        var lapses: Int
        var stateVersion: Int
    }

    private func seedDeck(_ id: UUID, name: String = "导入目标") async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, ?, 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(id), name]
            )
        }
    }

    /// 造一个既有 vocabulary Note（带卡与调度字段，供 update/skip/mergeTags 命中）。
    private func seedVocabularyNote(
        id: UUID = UUID(),
        deckID: UUID,
        headword: String,
        reading: String?,
        meaningZH: String = "旧意思",
        jlpt: String? = nil,
        notes: String? = "旧备注",
        pitchAccent: Int? = nil,
        contentVersion: Int = 3
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        part_of_speech, jlpt, notes, pitch_accent,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', ?, ?, ?, NULL, ?, ?, ?, 'manual', ?, 100, 100)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(deckID),
                    headword, reading, meaningZH, jlpt, notes, pitchAccent,
                    contentVersion
                ]
            )
            try insertHomeMembershipIfSupported(noteID: id, deckID: deckID, in: db)
            let profileID = UUID()
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, ?, 'FSRS-6.0', 'test', '[]', 0.9, 36500, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(profileID),
                    "cfg-\(profileID.uuidString)"
                ]
            )
            let cardID = UUID()
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        stability, difficulty, reps, lapses, scheduled_days,
                        elapsed_days, learning_step, state_version,
                        algorithm_version, profile_id
                    ) VALUES (?, ?, 'vocabulary_ja_zh', 1, 2, 999,
                              12.5, 5.5, 7, 2, 3, 10, 0, 4, 'FSRS-6.0', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(profileID)
                ]
            )
            // study_days(local_date, time_zone_id) UNIQUE——多个 seed 共享同一学习日。
            let studyDayID = UUID()
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2026-01-01', 'UTC', 0, 86400000, 10)
                    """,
                arguments: [DatabaseValueCodec.encode(studyDayID)]
            )
            let persistedDayID: String = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM study_days
                    WHERE local_date = '2026-01-01' AND time_zone_id = 'UTC'
                    """
            )!
            try db.execute(
                sql: """
                    INSERT INTO review_logs(
                        id, event_id, card_id, card_key, note_id, deck_id_at_review,
                        reviewed_at_ms, study_day_id, was_first_study,
                        rating, previous_state_json, next_state_json,
                        duration_ms, content_version, profile_id, algorithm_version
                    ) VALUES (?, ?, ?, ?, ?, ?,
                              5000, ?, 1,
                              3, '{"state":"learning"}', '{"state":"review"}',
                              100, ?, ?, 'FSRS-6.0')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(deckID),
                    persistedDayID,
                    contentVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
    }

    private func makeMapping(
        policy: DuplicatePolicy = .update,
        allowEmptyOverwrite: Bool = false,
        tagRule: ImportFieldMapping.TagRule = .jsonArray,
        exampleRule: ImportFieldMapping.ExampleRule = .appendDeduplicated,
        newCardTemplates: [CardTemplateKind] = [
            .vocabularyJapaneseToChinese, .vocabularyChineseToJapanese
        ],
        deck: UUID? = nil
    ) -> ImportFieldMapping {
        ImportFieldMapping(
            columnToField: [
                0: .headword, 1: .reading, 2: .meaningZH,
                3: .jlpt, 4: .pitchAccent, 5: .exampleJapanese,
                6: .exampleTranslationZH, 7: .notes, 8: .tags,
                9: .partOfSpeech
            ],
            tagRule: tagRule,
            duplicatePolicy: policy,
            allowEmptyOverwrite: allowEmptyOverwrite,
            exampleRule: exampleRule,
            newCardTemplates: newCardTemplates,
            targetDeckID: deck ?? targetDeckID
        )
    }

    private func makeStaging(
        rows: [String], delimiter: Character = ","
    ) throws -> ImportStaging {
        let staging = try ImportStaging(directory: stagingDir)
        var parser = DelimitedTextParserImpl(delimiter: delimiter)
        for row in rows {
            try staging.append(try parser.feed(row + "\n"))
        }
        try staging.append(try parser.finish())
        return staging
    }

    private func createJob(
        mapping: ImportFieldMapping,
        staging: ImportStaging,
        status: ImportJobStatus = .previewed
    ) async throws -> ImportJob {
        let repo = GRDBImportPlanRepository(database: database)
        let job = ImportJob(
            id: UUID(),
            fileHash: "testhash",
            mappingHash: ImportExecutor.mappingHash(mapping),
            policy: mapping.duplicatePolicy,
            targetDeckID: mapping.targetDeckID,
            status: status,
            createdAt: Date()
        )
        try await repo.createJob(job)
        try await repo.attachStagingInfo(
            jobID: job.id,
            stagingFileName: staging.fileURL.lastPathComponent,
            stagingFingerprint: "fp",
            rowCount: staging.rowCount,
            mappingSummary: nil
        )
        return job
    }

    private func tableCount(_ table: String) async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func count(
        sql: String, arguments: StatementArguments = []
    ) async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    private func businessTableCounts() async throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in ["notes", "cards", "examples", "tags", "note_tags",
                      "note_decks", "review_logs", "import_row_receipts"] {
            counts[table] = try await tableCount(table)
        }
        return counts
    }

    private func noteSnapshot(_ id: UUID) async throws -> NoteSnapshot? {
        try await database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            ) else { return nil }
            return NoteSnapshot(
                id: row["id"],
                kind: row["kind"],
                headword: row["headword"],
                reading: row["reading"],
                meaningZH: row["meaning_zh"],
                partOfSpeech: row["part_of_speech"],
                jlpt: row["jlpt"],
                notes: row["notes"],
                pitchAccent: row["pitch_accent"],
                origin: row["origin"],
                contentVersion: row["content_version"]
            )
        }
    }

    private func cardSnapshot(noteID: UUID) async throws -> CardSnapshot? {
        try await database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM cards WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            ) else { return nil }
            return CardSnapshot(
                id: row["id"],
                state: row["state"],
                stability: row["stability"],
                difficulty: row["difficulty"],
                reps: row["reps"],
                lapses: row["lapses"],
                stateVersion: row["state_version"]
            )
        }
    }

    private func unwrap<T>(_ value: T?, _ message: String = "unexpected nil") throws -> T {
        guard let value else {
            XCTFail(message)
            throw NSError(domain: "test", code: 1)
        }
        return value
    }

    // MARK: - v20 schema

    func testV20SchemaCreatesImportTables() async throws {
        // 幂等（重建不炸）。
        try await database.pool.write { db in
            try GRDBImportSchema.migrate(db)
            XCTAssertTrue(try db.tableExists("import_jobs"))
            XCTAssertTrue(try db.tableExists("import_row_receipts"))
        }
    }

    // MARK: - dry-run 零写入

    func testPrecheckWritesNothingToBusinessTables() async throws {
        try await seedDeck(targetDeckID)
        let existing = UUID()
        try await seedVocabularyNote(
            id: existing, deckID: targetDeckID, headword: "既存", reading: "きぞん"
        )
        let staging = try makeStaging(rows: [
            "新語,しんご,新意思",
            "既存,きぞん,覆盖意思",
            ",,坏行无词头"
        ])
        let mapping = makeMapping()
        let before = try await businessTableCounts()
        let executor = ImportExecutor(database: database)
        let summary = try await executor.precheck(mapping: mapping, staging: staging)
        let after = try await businessTableCounts()
        XCTAssertEqual(before, after, "precheck 不得写任何业务表")
        XCTAssertEqual(summary.totalRows, 3)
        XCTAssertEqual(summary.createCount, 1)
        XCTAssertEqual(summary.updateCount, 1)
        XCTAssertEqual(summary.invalidCount, 1)
        XCTAssertEqual(try staging.planRowCount(), 3)
    }

    // MARK: - create

    func testExecuteCreateNewVocabulary() async throws {
        try await seedDeck(targetDeckID)
        let staging = try makeStaging(rows: [
            #"食べる,たべる,吃,N5,2,パンを食べます。,吃面包,备注,"[""三餐""]",名词"#
        ])
        let mapping = makeMapping()
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        _ = try await executor.precheck(mapping: mapping, staging: staging)
        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )

        XCTAssertEqual(summary.status, .completed)
        XCTAssertEqual(summary.created, 1)
        XCTAssertEqual(summary.failed, 0)

        let noteRow = try await database.pool.read { db -> NoteSnapshot? in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM notes WHERE headword = '食べる'"
            ) else { return nil }
            return NoteSnapshot(
                id: row["id"], kind: row["kind"], headword: row["headword"],
                reading: row["reading"], meaningZH: row["meaning_zh"],
                partOfSpeech: row["part_of_speech"], jlpt: row["jlpt"],
                notes: row["notes"], pitchAccent: row["pitch_accent"],
                origin: row["origin"], contentVersion: row["content_version"]
            )
        }
        let note = try unwrap(noteRow)
        XCTAssertEqual(note.kind, "vocabulary")
        XCTAssertEqual(note.reading, "たべる")
        XCTAssertEqual(note.meaningZH, "吃")
        XCTAssertEqual(note.jlpt, "N5")
        XCTAssertEqual(note.pitchAccent, 2)
        XCTAssertEqual(note.notes, "备注")
        XCTAssertEqual(note.partOfSpeech, "名词")
        XCTAssertEqual(note.origin, "manual")

        let repo = GRDBImportPlanRepository(database: database)
        let detail = try await repo.fetchJobDetail(id: job.id)
        XCTAssertEqual(detail?.committedRows, 1)
        XCTAssertEqual(detail?.job.status, .completed)
        let receipts = try await repo.fetchReceiptDetails(jobID: job.id)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].receipt.action, .created)
        XCTAssertEqual(
            receipts[0].receipt.targetNoteID,
            try DatabaseValueCodec.decodeUUID(note.id)
        )
        // 两张方向卡 + membership + tag + example。
        let counts = try await businessTableCounts()
        XCTAssertEqual(counts["cards"], 2)
        XCTAssertEqual(counts["note_decks"], 1) // home == target
        XCTAssertEqual(counts["examples"], 1)
        XCTAssertEqual(counts["note_tags"], 1)
    }

    // MARK: - 重复策略矩阵

    /// skip：不写内容、不加 membership/tags。
    func testPolicySkipLeavesEverythingUntouched() async throws {
        try await seedDeck(targetDeckID)
        let noteID = UUID()
        try await seedVocabularyNote(
            id: noteID, deckID: targetDeckID,
            headword: "同键", reading: "どうけん"
        )
        let staging = try makeStaging(rows: ["同键,どうけん,新意思"])
        let mapping = makeMapping(policy: .skip)
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        _ = try await executor.precheck(mapping: mapping, staging: staging)
        let before = try unwrap(await noteSnapshot(noteID))
        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.updated, 0)
        let after = try unwrap(await noteSnapshot(noteID))
        XCTAssertEqual(before.meaningZH, after.meaningZH)
        XCTAssertEqual(before.contentVersion, after.contentVersion)
        let membership = try await count(
            sql: "SELECT COUNT(*) FROM note_decks WHERE note_id = ?",
            arguments: [DatabaseValueCodec.encode(noteID)]
        )
        XCTAssertEqual(membership, 1) // 只有 home；skip 不附加目标 membership
    }

    /// update：仅映射非空覆盖 + 附加 membership；调度字段与 ID 保留。
    func testPolicyUpdatePreservesSchedulingAndIDs() async throws {
        try await seedDeck(targetDeckID)
        let noteID = UUID()
        try await seedVocabularyNote(
            id: noteID, deckID: targetDeckID,
            headword: "更新", reading: "こうしん", contentVersion: 3
        )
        let cardIDBefore = try unwrap(await cardSnapshot(noteID: noteID)).id
        let staging = try makeStaging(rows: ["更新,こうしん,新释义,N3,,,,"])
        let mapping = makeMapping(policy: .update)
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        _ = try await executor.precheck(mapping: mapping, staging: staging)
        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        XCTAssertEqual(summary.updated, 1)

        let note = try unwrap(await noteSnapshot(noteID))
        XCTAssertEqual(note.meaningZH, "新释义")
        XCTAssertEqual(note.jlpt, "N3")
        XCTAssertEqual(note.notes, "旧备注") // 空值默认不覆盖
        XCTAssertEqual(note.contentVersion, 4)
        // 调度字段原样。
        let card = try unwrap(await cardSnapshot(noteID: noteID))
        XCTAssertEqual(
            card,
            CardSnapshot(
                id: cardIDBefore, state: 2, stability: 12.5,
                difficulty: 5.5, reps: 7, lapses: 2, stateVersion: 4
            )
        )
        let logs = try await count(
            sql: "SELECT COUNT(*) FROM review_logs WHERE note_id = ?",
            arguments: [DatabaseValueCodec.encode(noteID)]
        )
        XCTAssertEqual(logs, 1)
        let membership = try await count(
            sql: "SELECT COUNT(*) FROM note_decks WHERE note_id = ?",
            arguments: [DatabaseValueCodec.encode(noteID)]
        )
        XCTAssertEqual(membership, 1) // home == target，仍 1 行
    }

    /// allowEmptyOverwrite：显式清空可选列。
    func testPolicyUpdateAllowEmptyOverwriteClearsOptional() async throws {
        try await seedDeck(targetDeckID)
        let noteID = UUID()
        try await seedVocabularyNote(
            id: noteID, deckID: targetDeckID,
            headword: "清空", reading: "せいくう",
            jlpt: "N4", notes: "要清掉", pitchAccent: 1
        )
        // jlpt/pitchAccent/notes 映射但为空 → 清空。
        let staging = try makeStaging(rows: ["清空,せいくう,意思不变,,,,,"])
        let mapping = makeMapping(policy: .update, allowEmptyOverwrite: true)
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        _ = try await executor.precheck(mapping: mapping, staging: staging)
        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        XCTAssertEqual(summary.updated, 1)
        let note = try unwrap(await noteSnapshot(noteID))
        XCTAssertEqual(note.meaningZH, "意思不变")
        XCTAssertNil(note.jlpt)
        XCTAssertNil(note.notes)
        XCTAssertNil(note.pitchAccent)
        XCTAssertEqual(note.headword, "清空") // 必填列不受清空影响
    }

    /// mergeTags：内容不变、标签并集、附加 membership。
    func testPolicyMergeTagsUnionsOnly() async throws {
        try await seedDeck(targetDeckID)
        let otherDeck = UUID()
        try await seedDeck(otherDeck, name: "旧牌组")
        let noteID = UUID()
        try await seedVocabularyNote(
            id: noteID, deckID: otherDeck, headword: "并集", reading: "へいしゅう"
        )
        try await database.pool.write { db in
            let tagID = UUID()
            try db.execute(
                sql: "INSERT INTO tags(id, name, normalized_name) VALUES (?, '旧标签', '旧标签')",
                arguments: [DatabaseValueCodec.encode(tagID)]
            )
            try db.execute(
                sql: "INSERT INTO note_tags(note_id, tag_id) VALUES (?, ?)",
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(tagID)
                ]
            )
        }
        let staging = try makeStaging(rows: [
            #"并集,へいしゅう,意思,,,,,,"[""新标签""]""#
        ])
        let mapping = makeMapping(policy: .mergeTags)
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        _ = try await executor.precheck(mapping: mapping, staging: staging)
        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        XCTAssertEqual(summary.mergedTags, 1)
        let note = try unwrap(await noteSnapshot(noteID))
        XCTAssertEqual(note.meaningZH, "旧意思")
        XCTAssertEqual(note.contentVersion, 3) // 内容未变 → 不 bump
        let tagCount = try await count(
            sql: "SELECT COUNT(*) FROM note_tags WHERE note_id = ?",
            arguments: [DatabaseValueCodec.encode(noteID)]
        )
        XCTAssertEqual(tagCount, 2) // 旧标签 + 新标签并集
        let membership = try await count(
            sql: "SELECT COUNT(*) FROM note_decks WHERE note_id = ?",
            arguments: [DatabaseValueCodec.encode(noteID)]
        )
        XCTAssertEqual(membership, 2) // home(otherDeck) + targetDeck 附加
    }

    // MARK: - 冲突 / 文件内重复 / invalid

    func testConflictCandidatesListedAndSkippedAtExecute() async throws {
        try await seedDeck(targetDeckID)
        let first = UUID(), second = UUID()
        try await seedVocabularyNote(
            id: first, deckID: targetDeckID, headword: "同表记", reading: "どう"
        )
        try await seedVocabularyNote(
            id: second, deckID: targetDeckID, headword: "同表记", reading: "どう"
        )
        let staging = try makeStaging(rows: ["同表记,どう,意思"])
        let mapping = makeMapping()
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        let precheck = try await executor.precheck(
            mapping: mapping, staging: staging
        )
        XCTAssertEqual(precheck.conflictCount, 1)
        XCTAssertEqual(precheck.issues.count, 1)

        let plan = try staging.planRows(logicalRows: [1])[1]
        XCTAssertEqual(plan?.verdict, "conflict")
        XCTAssertEqual(Set(plan?.candidateNoteIDs ?? []), Set([first, second]))

        // 未消解的冲突执行期跳过。
        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.created, 0)
    }

    func testInFileDuplicateAnchoredToFirstPlannedRow() async throws {
        try await seedDeck(targetDeckID)
        let staging = try makeStaging(rows: [
            "重复,くりかえし,第一",
            "重复,くりかえし,第二",
            "重复,くりかえし,第三",
            ",,invalid", // invalid 不占位
            "重复,くりかえし,第四" // 仍以第 1 行为基准
        ])
        let mapping = makeMapping()
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        let precheck = try await executor.precheck(
            mapping: mapping, staging: staging
        )
        XCTAssertEqual(precheck.createCount, 1)
        XCTAssertEqual(precheck.inFileDuplicateCount, 3)
        XCTAssertEqual(precheck.invalidCount, 1)
        let plans = try staging.planRows(logicalRows: [2, 3, 5])
        XCTAssertEqual(plans[2]?.firstLogicalRow, 1)
        XCTAssertEqual(plans[3]?.firstLogicalRow, 1)
        XCTAssertEqual(plans[5]?.firstLogicalRow, 1)

        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        XCTAssertEqual(summary.created, 1)
        XCTAssertEqual(summary.skipped, 3)
        XCTAssertEqual(summary.failed, 1)
        let notes = try await count(
            sql: "SELECT COUNT(*) FROM notes WHERE headword = '重复'"
        )
        XCTAssertEqual(notes, 1, "文件内重复不得产生第二条 Note")
    }

    // MARK: - 行失败隔离

    /// 非法行 → failed receipt；同批其余行正常提交。
    func testRowFailureIsolatedWithinBatch() async throws {
        try await seedDeck(targetDeckID)
        let noteID = UUID()
        try await seedVocabularyNote(
            id: noteID, deckID: targetDeckID, headword: "既有", reading: "き"
        )
        let staging = try makeStaging(rows: [
            "既有,き,意思,N1,",   // 合法 update
            "新词,しん,新意思,,,例句。",   // create 正常
            "也有,き,意思,N9,"    // jlpt=N9 非法 → invalid（预检期）
        ])
        let mapping = makeMapping()
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        let precheck = try await executor.precheck(
            mapping: mapping, staging: staging
        )
        XCTAssertEqual(precheck.invalidCount, 1)
        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(summary.created, 1)
        XCTAssertEqual(summary.failed, 1)
        let receipts = try await GRDBImportPlanRepository(database: database)
            .fetchReceiptDetails(jobID: job.id)
        XCTAssertEqual(
            receipts.map(\.receipt.action), [.updated, .created, .failed]
        )
        XCTAssertNotNil(receipts[2].detail)
    }

    /// 取消 mid-job：已提交批保留，重跑同 job 续完且总数正确、无重复。
    func testCancelMidJobAndResume() async throws {
        try await seedDeck(targetDeckID)
        // 450 行 → 3 批（200+200+50）。
        let rows = (1...450).map { "取消語\($0),き\($0),意思\($0)" }
        let staging = try makeStaging(rows: rows)
        let mapping = makeMapping(policy: .skip) // 全是 create；policy 无关
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        _ = try await executor.precheck(mapping: mapping, staging: staging)

        // 第一批提交后取消。
        let flag = ImportTestCancelFlag()
        let first = try await executor.execute(
            jobID: job.id,
            mapping: mapping,
            staging: staging,
            isCancelled: { flag.cancelled },
            onBatchCommitted: { _ in flag.cancelled = true }
        )
        XCTAssertEqual(first.status, .cancelled)
        XCTAssertEqual(first.created, 200)

        // 续跑同 job（status cancelled → running）。
        let second = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        XCTAssertEqual(second.status, .completed)
        XCTAssertEqual(second.created, 250) // 只补剩余行
        let notes = try await count(
            sql: "SELECT COUNT(*) FROM notes WHERE headword LIKE '取消語%'"
        )
        XCTAssertEqual(notes, 450, "续跑不得重复建卡")
        let receipts = try await GRDBImportPlanRepository(database: database)
            .completedRowNumbers(jobID: job.id)
        XCTAssertEqual(receipts.count, 450)
    }

    /// 续跑时同 logical_row 的 staging 内容被换：digest 不一致记冲突，不改旧
    /// receipt；同 payload 行幂等跳过。（completed job 拒绝重跑，故用取消态进入。）
    func testResumeDigestConflict() async throws {
        try await seedDeck(targetDeckID)
        // 210 行 → 第一批 200 提交后取消。
        let base = (1...210).map { "摘要語\($0),こう\($0),意思\($0)" }
        let stagingA = try makeStaging(rows: base)
        let mapping = makeMapping()
        let job = try await createJob(mapping: mapping, staging: stagingA)
        let executor = ImportExecutor(database: database)
        _ = try await executor.precheck(mapping: mapping, staging: stagingA)
        let flag = ImportTestCancelFlag()
        let first = try await executor.execute(
            jobID: job.id,
            mapping: mapping,
            staging: stagingA,
            isCancelled: { flag.cancelled },
            onBatchCommitted: { _ in flag.cancelled = true }
        )
        XCTAssertEqual(first.status, .cancelled)
        XCTAssertEqual(first.created, 200)

        // 新 staging：第 1 行 payload 被改（模拟崩溃后重导了不同文件）。
        var altered = base
        altered[0] = "摘要語1,こう1,意思改"
        let stagingB = try makeStaging(rows: altered)
        let job2 = try await createJob(mapping: mapping, staging: stagingB)
        _ = try await executor.precheck(mapping: mapping, staging: stagingB)

        // 给 job2 手工回放 job 的 receipt（跨 job 用同 job_id 模拟崩溃续跑场景：
        // 直接把 job 的 200 条 receipt 复制给 job2）。
        let repo = GRDBImportPlanRepository(database: database)
        let oldReceipts = try await repo.fetchReceiptDetails(jobID: job.id)
        let copied = oldReceipts.map {
            ImportRowReceipt(
                jobID: job2.id,
                logicalRowNumber: $0.receipt.logicalRowNumber,
                payloadDigest: $0.receipt.payloadDigest,
                action: $0.receipt.action,
                targetNoteID: $0.receipt.targetNoteID
            )
        }
        try await repo.recordReceipts(copied)

        let conflict = try await executor.execute(
            jobID: job2.id, mapping: mapping, staging: stagingB
        )
        XCTAssertEqual(conflict.digestConflicts, 1)
        XCTAssertEqual(conflict.created, 10) // 只补 job 未覆盖的后 10 行
        let receipts = try await repo.fetchReceiptDetails(jobID: job2.id)
        XCTAssertEqual(receipts.count, 210, "冲突行不得追加第二条 receipt")
        let row1 = receipts.first { $0.receipt.logicalRowNumber == 1 }
        XCTAssertEqual(row1?.receipt.action, .created) // 原 receipt 保留
        XCTAssertEqual(
            row1?.receipt.payloadDigest,
            oldReceipts.first { $0.receipt.logicalRowNumber == 1 }?.receipt.payloadDigest,
            "digest 不一致时旧 receipt 原样保留"
        )

        // 同 payload 重跑 job → 幂等：已提交的 200 行不重复，补完后 10 行。
        // （job2 已把 201-210 建成 Note → 本轮按 update 命中；语义等价——行
        //   只被处理一次，无重复创建。）
        let stagingSame = try makeStaging(rows: base)
        _ = try await executor.precheck(mapping: mapping, staging: stagingSame)
        let rerun = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: stagingSame
        )
        XCTAssertEqual(rerun.digestConflicts, 0)
        XCTAssertEqual(rerun.created, 0)
        XCTAssertEqual(rerun.updated, 10)
        XCTAssertEqual(rerun.status, .completed)
        let completedRows = try await repo.completedRowNumbers(jobID: job.id)
        XCTAssertEqual(completedRows.count, 210)
    }

    /// mapping 变更 → mappingHash 不匹配 → 必须重建 plan。
    func testExecuteRejectsChangedMapping() async throws {
        try await seedDeck(targetDeckID)
        let staging = try makeStaging(rows: ["乙,おつ,意思"])
        let mapping = makeMapping()
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        _ = try await executor.precheck(mapping: mapping, staging: staging)
        let changed = makeMapping(policy: .mergeTags)
        do {
            _ = try await executor.execute(
                jobID: job.id, mapping: changed, staging: staging
            )
            XCTFail("expected mappingHashMismatch")
        } catch ImportExecutorError.mappingHashMismatch {}
    }

    /// 并发防线：预检后既有 Note 被改过 → update 行 failed(contentVersionChanged)。
    func testContentVersionDriftFailsRow() async throws {
        try await seedDeck(targetDeckID)
        let noteID = UUID()
        try await seedVocabularyNote(
            id: noteID, deckID: targetDeckID,
            headword: "漂移", reading: "ひょうい", contentVersion: 3
        )
        let staging = try makeStaging(rows: ["漂移,ひょうい,新意思"])
        let mapping = makeMapping(policy: .update)
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        _ = try await executor.precheck(mapping: mapping, staging: staging)
        // 模拟并发编辑 bump content_version。
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE notes SET content_version = content_version + 1
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertTrue(
            summary.rowDetails.contains {
                $0.reason?.contains("contentVersionChanged") == true
            }
        )
        let note = try unwrap(await noteSnapshot(noteID))
        XCTAssertEqual(note.meaningZH, "旧意思") // 未覆盖较新内容
    }

    /// 例句规则：appendDeduplicated 去重追加；replacePrimary 只改主例句。
    func testExampleRules() async throws {
        try await seedDeck(targetDeckID)
        let noteID = UUID()
        try await seedVocabularyNote(
            id: noteID, deckID: targetDeckID, headword: "例句", reading: "れい"
        )
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                    VALUES (?, ?, '旧例句', '旧译', 0)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(noteID)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                    VALUES (?, ?, '次例句', NULL, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(noteID)
                ]
            )
        }
        // appendDeduplicated：新例句追加。
        let staging = try makeStaging(rows: ["例句,れい,意思,,,新例句,新译"])
        let mapping = makeMapping(policy: .update)
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)
        _ = try await executor.precheck(mapping: mapping, staging: staging)
        _ = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        var examples = try await exampleJapaneses(noteID: noteID)
        XCTAssertEqual(examples, ["旧例句", "次例句", "新例句"])

        // 同例句再导 → 不重复追加。
        let staging2 = try makeStaging(rows: ["例句,れい,意思,,,新例句,新译"])
        let job2 = try await createJob(mapping: mapping, staging: staging2)
        _ = try await executor.precheck(mapping: mapping, staging: staging2)
        _ = try await executor.execute(
            jobID: job2.id, mapping: mapping, staging: staging2
        )
        examples = try await exampleJapaneses(noteID: noteID)
        XCTAssertEqual(examples, ["旧例句", "次例句", "新例句"], "dedupe-append 不得重复")

        // replacePrimary：主例句被替换，次例句保留。
        let staging3 = try makeStaging(rows: ["例句,れい,意思,,,替换主例句,替换译"])
        let mapping3 = makeMapping(policy: .update, exampleRule: .replacePrimary)
        let job3 = try await createJob(mapping: mapping3, staging: staging3)
        _ = try await executor.precheck(mapping: mapping3, staging: staging3)
        _ = try await executor.execute(
            jobID: job3.id, mapping: mapping3, staging: staging3
        )
        examples = try await exampleJapaneses(noteID: noteID)
        XCTAssertEqual(examples, ["替换主例句", "次例句", "新例句"])
    }

    private func exampleJapaneses(noteID: UUID) async throws -> [String] {
        try await database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT japanese FROM examples
                    WHERE note_id = ? ORDER BY sort_order
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
    }

    // MARK: - 100k 行内存有界

    func testExecute100kRowsBoundedMemory() async throws {
        try await seedDeck(targetDeckID)
        // 生成 100k 行 CSV 到 staging（生成器同构）。
        let staging = try ImportStaging(directory: stagingDir)
        var parser = DelimitedTextParserImpl(delimiter: ",")
        var lines: [String] = []
        lines.reserveCapacity(100_000)
        for i in 0..<100_000 {
            lines.append("語\(i),よみ\(i),意味\(i)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        lines = []
        try staging.append(try parser.feed(text))
        try staging.append(try parser.finish())
        XCTAssertEqual(staging.rowCount, 100_000)

        let mapping = makeMapping(
            newCardTemplates: [.vocabularyJapaneseToChinese]
        )
        let job = try await createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: database)

        let sampler = ImportPeakRSSSampler()
        let baseline = ImportResidentSize.current()
        sampler.start()

        _ = try await executor.precheck(mapping: mapping, staging: staging)
        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )

        let peak = sampler.stop()
        let delta = peak - baseline
        print("""
            [S17] 100k-row end-to-end import: baseline=\(baseline / 1_048_576)MiB \
            peak=\(peak / 1_048_576)MiB delta=\(delta / 1_048_576)MiB \
            created=\(summary.created) failed=\(summary.failed)
            """)
        XCTAssertEqual(summary.created, 100_000)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.status, .completed)
        XCTAssertLessThan(delta, 100 * 1_048_576)
        let noteCount = try await tableCount("notes")
        XCTAssertEqual(noteCount, 100_000)
    }

    // MARK: - staging 指纹绑定

    func testJobStagingInfoRoundTrip() async throws {
        try await seedDeck(targetDeckID)
        let staging = try makeStaging(rows: ["丙,へい,意思"])
        let mapping = makeMapping()
        let job = try await createJob(mapping: mapping, staging: staging)
        let detail = try await GRDBImportPlanRepository(database: database)
            .fetchJobDetail(id: job.id)
        XCTAssertEqual(detail?.stagingFileName, staging.fileURL.lastPathComponent)
        XCTAssertEqual(detail?.stagingFingerprint, "fp")
        XCTAssertEqual(detail?.rowCount, 1)
        XCTAssertEqual(detail?.committedRows, 0)
    }
}

/// 可跨并发送性边界传递的取消标志（测试用）。
private final class ImportTestCancelFlag: @unchecked Sendable {
    var cancelled = false
}
