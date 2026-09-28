import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.0 S18：CSV 导出器测试。
/// 红线断言：输出**只含 10 个内容字段**——表头与行数据绝不允许
/// 出现 UUID/FSRS 调度列/deck 成员/内部 key（扫描字节验证）。
/// 另测：RFC4180 转义边界、verbatim 原样模式、多例句策略、
/// 卡类型排除、deck 过滤、进度回调、round-trip 导出→导入等值。
final class CSVExporterTests: XCTestCase {

    private var root: URL!
    private var database: OboeDatabase!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("S18-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try OboeDatabase(path: root.appendingPathComponent("oboe.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? database.close()
        try? FileManager.default.removeItem(at: root)
    }

    private let deckID = UUID()

    private func seedDeck(_ id: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'd', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(id)]
            )
        }
    }

    /// 造全字段 vocabulary note + 卡 + 例句 + 标签。
    /// 返回 noteID。
    @discardableResult
    private func seedNote(
        deckID: UUID,
        headword: String,
        reading: String? = nil,
        meaningZH: String,
        partOfSpeech: String? = nil,
        pitchAccent: Int? = nil,
        jlpt: String? = nil,
        notes: String? = nil,
        cardTemplates: [String] = ["vocabulary_ja_zh"],
        examples: [(String, String?)] = [],
        tags: [String] = []
    ) async throws -> UUID {
        let noteID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        part_of_speech, jlpt, notes, pitch_accent,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', ?, ?, ?, ?, ?, ?, ?, 'manual', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    headword, reading, meaningZH, partOfSpeech,
                    jlpt, notes, pitchAccent
                ]
            )
            try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
            let profileID = UUID()
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, ?, 'FSRS-6.0', 't', '[]', 0.9, 36500, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(profileID), "cfg-\(profileID.uuidString)"]
            )
            for template in cardTemplates {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state,
                            due_at_ms, stability, difficulty, reps, lapses,
                            scheduled_days, elapsed_days, learning_step,
                            state_version, algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                  'FSRS-6.0', ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(noteID),
                        template,
                        DatabaseValueCodec.encode(profileID)
                    ]
                )
            }
            for (i, example) in examples.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(noteID),
                        example.0, example.1, i
                    ]
                )
            }
            for tagName in tags {
                let tagID = UUID()
                try db.execute(
                    sql: "INSERT OR IGNORE INTO tags(id, name, normalized_name) VALUES (?, ?, ?)",
                    arguments: [DatabaseValueCodec.encode(tagID), tagName, tagName.lowercased()]
                )
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO note_tags(note_id, tag_id)
                        VALUES (?, (SELECT id FROM tags WHERE normalized_name = ?))
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID), tagName.lowercased()
                    ]
                )
            }
        }
        return noteID
    }

    private func exportURL() -> URL {
        root.appendingPathComponent("export-\(UUID().uuidString).csv")
    }

    /// 读导出文件 → S16 parser 重解析 → (header, rows)。
    private func reparse(
        _ url: URL, delimiter: Character = ","
    ) throws -> (header: [String], rows: [[String]]) {
        let data = try Data(contentsOf: url)
        var bytes = Array(data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let text = String(decoding: bytes, as: UTF8.self)
        var parser = DelimitedTextParserImpl(delimiter: delimiter)
        var logical = try parser.feed(text)
        logical += try parser.finish()
        guard !logical.isEmpty else { return ([], []) }
        return (logical[0].fields, logical.dropFirst().map(\.fields))
    }

    // MARK: - 红线：无内部字段

    /// 扫描导出字节：不得出现任何内部字段名/UUID 形态。
    /// 这是「CSV 无任何 FSRS/Key」的计划红线。
    func testExportContainsNoInternalFields() async throws {
        try await seedDeck(deckID)
        try await seedNote(
            deckID: deckID, headword: "食べる", reading: "たべる",
            meaningZH: "吃", jlpt: "N5"
        )
        let url = exportURL()
        _ = try await CSVExporter(database: database).export(to: url)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let forbidden = [
            "state", "stability", "difficulty", "reps", "lapses",
            "due_at", "scheduled_days", "elapsed_days", "learning_step",
            "state_version", "algorithm_version", "profile_id",
            "note_id", "card_id", "deck_id", "content_version",
            "origin", "created_at", "updated_at", "review",
            "UUID", "uuid", "fsrs", "FSRS",
            // UUID 形态：8-4-4-4-12 hex。
            "0000-0000", "-4"
        ]
        for token in forbidden.dropLast(2) {
            XCTAssertFalse(
                text.contains(token),
                "导出文件不得含内部字段 token: \(token)"
            )
        }
        // UUID 正则不出现。
        let uuidPattern = try NSRegularExpression(
            pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        )
        XCTAssertEqual(
            uuidPattern.numberOfMatches(
                in: text, range: NSRange(text.startIndex..., in: text)
            ), 0,
            "导出文件不得含 UUID 形态字符串"
        )
    }

    /// 表头恰为 10 个中文字段名。
    func testHeaderIsTenChineseFields() async throws {
        try await seedDeck(deckID)
        try await seedNote(deckID: deckID, headword: "a", meaningZH: "b")
        let url = exportURL()
        _ = try await CSVExporter(database: database).export(to: url)
        let (header, _) = try reparse(url)
        XCTAssertEqual(
            header,
            ["单词", "读音", "释义", "词性", "音调", "JLPT", "例句", "例句翻译", "标签", "备注"]
        )
    }

    // MARK: - 10 字段内容 + 转义

    func testAllTenFieldsRoundTrip() async throws {
        try await seedDeck(deckID)
        try await seedNote(
            deckID: deckID,
            headword: "難しい",
            reading: "むずかしい",
            meaningZH: "困难的",
            partOfSpeech: "い形容词",
            pitchAccent: 4,
            jlpt: "N3",
            notes: "常考",
            examples: [("難しい問題です。", "是难题。")],
            tags: ["形容词", "N3必考"]
        )
        let url = exportURL()
        let summary = try await CSVExporter(database: database).export(to: url)
        XCTAssertEqual(summary.exportedRows, 1)
        let (_, rows) = try reparse(url)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows[0],
            ["難しい", "むずかしい", "困难的", "い形容词", "4", "N3",
             "難しい問題です。", "是难题。", #"["N3必考","形容词"]"#, "常考"]
        )
    }

    /// RFC4180 边界：逗号/引号/CRLF/emoji/分隔符==字段内字符。
    func testEscapingEdgeCases() async throws {
        try await seedDeck(deckID)
        try await seedNote(
            deckID: deckID,
            headword: "行\"列\"号",           // 内嵌引号
            reading: "ぎょう,れつ",            // 内嵌逗号
            meaningZH: "第一行\n第二行\r第三行", // 换行+CR
            notes: "emoji 📚✨、TAB\t分隔"      // emoji+tab
        )
        let url = exportURL()
        _ = try await CSVExporter(database: database).export(to: url)
        let (_, rows) = try reparse(url)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][0], "行\"列\"号")
        XCTAssertEqual(rows[0][1], "ぎょう,れつ")
        XCTAssertEqual(rows[0][2], "第一行\n第二行\r第三行")
        XCTAssertEqual(rows[0][9], "emoji 📚✨、TAB\t分隔")
    }

    /// safe 模式：BOM + CRLF；verbatim：无 BOM、LF、不转义（lossy 计数）。
    func testVerbatimModeIsRawAndLossyCounted() async throws {
        try await seedDeck(deckID)
        try await seedNote(
            deckID: deckID, headword: "ab", meaningZH: "含,逗号"
        )
        let url = exportURL()
        let summary = try await CSVExporter(database: database).export(
            to: url,
            options: CSVExportOptions(escapeMode: .verbatim)
        )
        XCTAssertEqual(summary.lossyRows, 1) // meaning 含逗号未转义
        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(bytes.starts(with: [0xEF, 0xBB, 0xBF]), "verbatim 无 BOM")
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("\r\n"), "verbatim 用 LF")
        XCTAssertTrue(text.contains("含,逗号"), "原样写出不转义")
        // 非可回读——这是 verbatim 的预期语义（向导应提示）。
    }

    // MARK: - 多例句 / 排除 / 过滤

    func testMultiExampleStrategies() async throws {
        try await seedDeck(deckID)
        try await seedNote(
            deckID: deckID, headword: "例", meaningZH: "m",
            examples: [
                ("例句一", "译一"), ("例句二", "译二"), ("例句三", nil)
            ]
        )
        // primaryOnly：只主例句，dropped=2。
        var url = exportURL()
        var summary = try await CSVExporter(database: database).export(to: url)
        var (_, rows) = try reparse(url)
        XCTAssertEqual(rows[0][6], "例句一")
        XCTAssertEqual(rows[0][7], "译一")
        XCTAssertEqual(summary.droppedExamples, 2)

        // mergeAll：全部并入，\n 连接。
        url = exportURL()
        summary = try await CSVExporter(database: database).export(
            to: url, options: CSVExportOptions(multiExampleRule: .mergeAll)
        )
        (_, rows) = try reparse(url)
        XCTAssertEqual(rows[0][6], "例句一\n例句二\n例句三")
        XCTAssertEqual(rows[0][7], "译一\n译二\n")
        XCTAssertEqual(summary.droppedExamples, 0)
    }

    /// 卡类型白名单：只有 excluded 卡的 note 被跳过。
    func testCardTemplateExclusion() async throws {
        try await seedDeck(deckID)
        try await seedNote(
            deckID: deckID, headword: "日译中卡", meaningZH: "a",
            cardTemplates: ["vocabulary_ja_zh"]
        )
        try await seedNote(
            deckID: deckID, headword: "仅听力卡", meaningZH: "b",
            cardTemplates: ["vocabulary_listening"]
        )
        let url = exportURL()
        let summary = try await CSVExporter(database: database).export(
            to: url,
            options: CSVExportOptions(
                includedCardTemplates: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
            )
        )
        XCTAssertEqual(summary.exportedRows, 1)
        XCTAssertEqual(summary.skippedByCardType, 1)
        let (_, rows) = try reparse(url)
        XCTAssertEqual(rows[0][0], "日译中卡")
    }

    /// deck 过滤：只导目标牌组成员。
    func testDeckFilter() async throws {
        let deckA = deckID, deckB = UUID()
        try await seedDeck(deckA)
        try await seedDeck(deckB)
        try await seedNote(deckID: deckA, headword: "牌组A", meaningZH: "a")
        try await seedNote(deckID: deckB, headword: "牌组B", meaningZH: "b")
        let url = exportURL()
        let summary = try await CSVExporter(database: database).export(
            to: url, options: CSVExportOptions(deckID: deckA)
        )
        XCTAssertEqual(summary.exportedRows, 1)
        let (_, rows) = try reparse(url)
        XCTAssertEqual(rows.map { $0[0] }, ["牌组A"])
    }

    /// 取消：导出中止。
    func testCancelAbortsExport() async throws {
        try await seedDeck(deckID)
        for i in 0..<600 {
            try await seedNote(deckID: deckID, headword: "w\(i)", meaningZH: "m")
        }
        let url = exportURL()
        do {
            _ = try await CSVExporter(database: database).export(
                to: url, isCancelled: { true }
            )
            XCTFail("expected cancelled")
        } catch CSVExportError.cancelled {}
    }

    /// 进度回调触发（≥ granularity 行时）。
    func testProgressCallback() async throws {
        try await seedDeck(deckID)
        for i in 0..<600 {
            try await seedNote(deckID: deckID, headword: "p\(i)", meaningZH: "m")
        }
        let url = exportURL()
        let progress = ProgressRecorder()
        _ = try await CSVExporter(database: database).export(
            to: url, onProgress: { progress.record($0) }
        )
        XCTAssertEqual(progress.values, [500]) // 600 行 → 第 500 触发一次
    }

    // MARK: - 端到端 round-trip：导出 → 新库 → 导入 → 内容等值

    func testExportReimportRoundTripEquivalent() async throws {
        try await seedDeck(deckID)
        let notesIn: [(hw: String, rd: String?, zh: String, pos: String?, pitch: Int?, jlpt: String?)] = [
            ("往復甲", "おうふく", "往返甲", "名词", 0, "N1"),
            // 词性必须是受控白名单原子——"动词" 不在其中（别名表也没有
            // 泛动词映射），导入会按「非法值不自动纠正」判 failed。
            ("往復乙", "おうふく", "往返乙", "五段动词", 3, "N2"),
            ("往復丙", nil, "往返丙", nil, nil, nil)
        ]
        for (i, n) in notesIn.enumerated() {
            try await seedNote(
                deckID: deckID, headword: n.hw, reading: n.rd,
                meaningZH: n.zh, partOfSpeech: n.pos,
                pitchAccent: n.pitch, jlpt: n.jlpt,
                notes: "note\(i)",
                examples: [("例\(i)。", "译\(i)")],
                tags: ["标签\(i)"]
            )
        }
        let exportURL = exportURL()
        _ = try await CSVExporter(database: database).export(to: exportURL)

        // 全新库导入该 CSV：10 字段映射 + hasHeader 跳过。
        let database2Path = root.appendingPathComponent("db2.sqlite").path
        let database2 = try OboeDatabase(path: database2Path)
        defer { try? database2.close() }
        let deckID = self.deckID
        try await database2.pool.write { db in
            try GRDBImportSchema.migrate(db)
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, '目标', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        let stagingDir = root.appendingPathComponent("staging-rt", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let staging = try ImportStaging(directory: stagingDir)
        let text = String(decoding: try Data(contentsOf: exportURL), as: UTF8.self)
        var parser = DelimitedTextParserImpl(delimiter: ",")
        var all = try parser.feed(text)
        all += try parser.finish()
        // 跳过表头行（logical 1）——wizard 的 hasHeaderRow 开关对应语义。
        try staging.append(all.dropFirst().map {
            ImportLogicalRow(
                logicalRowNumber: $0.logicalRowNumber - 1,
                rawLineRange: $0.rawLineRange, fields: $0.fields
            )
        })
        let mapping = ImportFieldMapping(
            columnToField: Dictionary(
                uniqueKeysWithValues: CSVExporter.fieldOrder.enumerated()
                    .map { ($0.offset, $0.element) }
            ),
            tagRule: .jsonArray,
            duplicatePolicy: .skip,
            allowEmptyOverwrite: false,
            exampleRule: .appendDeduplicated,
            newCardTemplates: [.vocabularyJapaneseToChinese],
            targetDeckID: deckID
        )
        let repo = GRDBImportPlanRepository(database: database2)
        let job = ImportJob(
            id: UUID(), fileHash: "h",
            mappingHash: ImportExecutor.mappingHash(mapping),
            policy: .skip, targetDeckID: deckID,
            status: .previewed, createdAt: Date()
        )
        try await repo.createJob(job)
        let executor = ImportExecutor(database: database2)
        _ = try await executor.precheck(mapping: mapping, staging: staging)
        let summary = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging
        )
        XCTAssertEqual(summary.created, 3)
        XCTAssertEqual(summary.failed, 0)

        // 回读断言 10 字段等值。
        struct Readback: Equatable {
            var headword: String, reading: String?, meaningZH: String
            var partOfSpeech: String?, pitchAccent: Int?, jlpt: String?
            var notes: String?
        }
        let rows = try await database2.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT headword, reading, meaning_zh, part_of_speech,
                           pitch_accent, jlpt, notes
                    FROM notes ORDER BY headword
                    """
            ).map { row in
                Readback(
                    headword: row["headword"], reading: row["reading"],
                    meaningZH: row["meaning_zh"], partOfSpeech: row["part_of_speech"],
                    pitchAccent: row["pitch_accent"], jlpt: row["jlpt"],
                    notes: row["notes"]
                )
            }
        }
        guard rows.count == 3 else {
            XCTFail("expected 3 notes, got \(rows.count)"); return
        }
        // 按 headword 配对断言（SQLite BINARY 排序与 Swift < 不一致）。
        let byHeadword = Dictionary(
            uniqueKeysWithValues: notesIn.enumerated().map { ($1.hw, $0) }
        )
        for row in rows {
            let i = try unwrap(byHeadword[row.headword])
            let n = notesIn[i]
            XCTAssertEqual(
                row,
                Readback(
                    headword: n.hw, reading: n.rd, meaningZH: n.zh,
                    partOfSpeech: n.pos, pitchAccent: n.pitch, jlpt: n.jlpt,
                    notes: "note\(i)"
                )
            )
        }
        // tags + example 也回来。
        let tagCount = try await database2.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_tags") ?? 0
        }
        XCTAssertEqual(tagCount, 3)
        let exCount = try await database2.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM examples") ?? 0
        }
        XCTAssertEqual(exCount, 3)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private(set) var values: [Int] = []
    func record(_ value: Int) { values.append(value) }
}

extension XCTestCase {
    /// unwrap 失败即 XCTFail + 抛错（避免可选下标崩溃）。
    fileprivate func unwrap<T>(
        _ value: T?, _ message: String = "unexpected nil"
    ) throws -> T {
        guard let value else {
            XCTFail(message)
            throw NSError(domain: "test", code: 1)
        }
        return value
    }
}
