import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S22 Reader Analytics 仓储测试：
/// - 事件聚合（逐日/总计）含 undo 排除与未归档桶；
/// - 当前掌握词数 = 当前态聚合（反复切状态不放大）；
/// - learning 口径只数 vocabulary 关联且 override 优先；
/// - 文档删除后事件/快照历史仍可读；
/// - 覆盖率趋势按版本三元组分段（含回退开新段）；
/// - 无正文文档 / 空库边界；
/// - 事件时间线的 snapshot 解码与撤销标记。
final class GRDBReaderAnalyticsTests: XCTestCase {

    private var directory: URL!
    private var pool: DatabasePool!
    private var repository: GRDBReaderAnalyticsRepository!
    private var knowledge: GRDBVocabularyKnowledgeRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ReaderAnalytics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        // 迁移内含 search_documents FTS 触发器——注册与
        // GRDBReaderCoverageServiceTests 相同的规范化函数。
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
        try OboeDatabaseSchema.makeMigrator(
            applying: OboeDatabaseSchema.migrationIdentifiers).migrate(pool)
        repository = GRDBReaderAnalyticsRepository(pool: pool)
        knowledge = GRDBVocabularyKnowledgeRepository(pool: pool)
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - fixture helpers

    private func insertLexeme(writtenForm: String = "見る") async throws -> UUID {
        let id = UUID()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexemes(
                        id, provider, external_id, written_form,
                        normalized_lemma, identity_key,
                        resolution_status, created_at_ms)
                    VALUES (?, 'local', ?, ?, ?, ?, 'resolved', 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id), id.uuidString.lowercased(),
                    writtenForm, writtenForm,
                    "local|\(id.uuidString.lowercased())|\(writtenForm)|"
                ])
        }
        return id
    }

    private func insertDocument(
        id: UUID = UUID(), title: String = "doc",
        lastOpenedAt: Int64? = nil, progressBasisPoints: Int = 0
    ) async throws -> UUID {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, last_opened_at_ms,
                        source_sha256, canonical_text_hash, parser_version,
                        progress_basis_points, availability)
                    VALUES (?, ?, 'paste', 1, ?,
                            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                            'canon', 'parser-1', ?, 'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id), title, lastOpenedAt,
                    progressBasisPoints
                ])
        }
        return id
    }

    private func insertStudyDay(
        localDate: String, startsAt: Int64, endsAt: Int64,
        timeZoneID: String = "Asia/Shanghai"
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms,
                        ends_at_ms, new_limit)
                    VALUES (?, ?, ?, ?, ?, 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()), localDate,
                    timeZoneID, startsAt, endsAt
                ])
        }
    }

    /// 直写事件行（可显式构造 undone/孤儿事件）。
    private func insertEvent(
        kind: String,
        at: Int64,
        lexemeID: UUID? = nil,
        noteID: UUID? = nil,
        documentID: UUID? = nil,
        snapshotJSON: String? = nil,
        undoneAt: Int64? = nil
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_activity_events(
                        id, operation_id, kind, lexeme_id, note_id,
                        document_id, snapshot_json, created_at_ms,
                        undone_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()),
                    kind,
                    lexemeID.map(DatabaseValueCodec.encode),
                    noteID.map(DatabaseValueCodec.encode),
                    documentID.map(DatabaseValueCodec.encode),
                    snapshotJSON, at, undoneAt
                ])
        }
    }

    private func insertSnapshot(
        documentID: UUID, documentTitle: String,
        studyDayID: String, createdAt: Int64,
        metricVersion: String = "coverage-1.0.0",
        morphologyVersion: String = "morph-1",
        dictionaryVersion: String? = "dict-1",
        known: Int, learning: Int, unknown: Int, ignored: Int = 0,
        uniqueNum: Int, uniqueDen: Int,
        analyzed: Int, total: Int
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_coverage_snapshots(
                        id, document_id, document_title, scope_key,
                        chapter_id, content_hash, metric_version,
                        morphology_version, dictionary_version,
                        known_count, learning_count, unknown_count,
                        ignored_count, unique_numerator, unique_denominator,
                        analyzed_blocks, total_blocks, study_day_id,
                        created_at_ms)
                    VALUES (?, ?, ?, 'document', NULL, 'hash', ?, ?, ?,
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(documentID), documentTitle,
                    metricVersion, morphologyVersion, dictionaryVersion,
                    known, learning, unknown, ignored, uniqueNum, uniqueDen,
                    analyzed, total, studyDayID, createdAt
                ])
        }
    }

    private func insertNote(
        kind: String = "vocabulary", headword: String = "w"
    ) async throws -> UUID {
        let deckID = UUID()
        let noteID = UUID()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)])
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        is_favorite, origin, content_version,
                        created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, ?, 'm', 0, 'manual', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID), kind, headword])
        }
        return noteID
    }

    private func link(lexemeID: UUID, noteID: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexeme_note_links(
                        lexeme_id, note_id, association_origin,
                        created_at_ms)
                    VALUES (?, ?, 'backfill', 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(lexemeID),
                    DatabaseValueCodec.encode(noteID)])
        }
    }

    // MARK: - 空库边界

    func testEmptyDatabaseReturnsZeroes() async throws {
        let totals = try await repository.activityTotals()
        XCTAssertEqual(totals.totalEffective, 0)
        XCTAssertEqual(totals.undoneCount, 0)

        let summary = try await repository.knowledgeSummary()
        XCTAssertEqual(
            summary, ReaderKnowledgeSummary(
                knownCount: 0, learningCount: 0, ignoredCount: 0,
                trackedLexemeCount: 0))
        XCTAssertEqual(summary.unmarkedCount, 0)

        let days = try await repository.dailyActivity(dayCount: 30)
        XCTAssertTrue(days.isEmpty)
        let docs = try await repository.documentSummaries(limit: 50)
        XCTAssertTrue(docs.isEmpty)
        let timeline = try await repository.activityTimeline(limit: 50)
        XCTAssertTrue(timeline.isEmpty)
        let trend = try await repository.coverageTrend(documentID: UUID())
        XCTAssertTrue(trend.isEmpty)
    }

    // MARK: - 事件聚合

    /// 逐日聚合：窗口内零事件日保留；落在任何 study_days 窗外的
    /// 有效事件进入未归档桶而不是被丢弃。
    func testDailyActivityBucketsAndUnfiled() async throws {
        // day1: [100_000, 200_000), day2: [200_000, 300_000)
        try await insertStudyDay(
            localDate: "2026-09-14", startsAt: 100_000, endsAt: 200_000)
        try await insertStudyDay(
            localDate: "2026-09-15", startsAt: 200_000, endsAt: 300_000)
        try await insertStudyDay(
            localDate: "2026-09-16", startsAt: 300_000, endsAt: 400_000)

        try await insertEvent(kind: "minedNewNote", at: 110_000)
        try await insertEvent(kind: "markedKnown", at: 120_000)
        try await insertEvent(kind: "markedKnown", at: 130_000)
        try await insertEvent(kind: "createdCloze", at: 210_000)
        // 已撤销事件不计入日桶。
        try await insertEvent(
            kind: "minedNewNote", at: 220_000, undoneAt: 240_000)
        // 未归档：早于首个学习日窗口 + 晚于所有窗口。
        try await insertEvent(kind: "linkedExistingNote", at: 50_000)
        try await insertEvent(kind: "markedKnown", at: 500_000)

        let days = try await repository.dailyActivity(dayCount: 30)
        XCTAssertEqual(days.count, 4)  // 3 窗口日 + 1 未归档
        XCTAssertEqual(days[0].localDate, "2026-09-14")
        XCTAssertEqual(days[0].minedNewNote, 1)
        XCTAssertEqual(days[0].markedKnown, 2)
        XCTAssertEqual(days[1].localDate, "2026-09-15")
        XCTAssertEqual(days[1].createdCloze, 1)
        XCTAssertEqual(days[1].minedNewNote, 0)  // undo 排除
        // 零事件学习日保留为全 0 行。
        XCTAssertEqual(days[2].localDate, "2026-09-16")
        XCTAssertEqual(days[2].total, 0)
        let unfiled = try XCTUnwrap(days.last)
        XCTAssertTrue(unfiled.isUnfiled)
        XCTAssertEqual(unfiled.linkedExistingNote, 1)
        XCTAssertEqual(unfiled.markedKnown, 1)
    }

    /// 窗口上限只取最近 N 个学习日。
    func testDailyActivityHonoursDayCountWindow() async throws {
        try await insertStudyDay(
            localDate: "2026-09-14", startsAt: 100_000, endsAt: 200_000)
        try await insertStudyDay(
            localDate: "2026-09-15", startsAt: 200_000, endsAt: 300_000)
        try await insertStudyDay(
            localDate: "2026-09-16", startsAt: 300_000, endsAt: 400_000)
        try await insertEvent(kind: "minedNewNote", at: 110_000)
        try await insertEvent(kind: "minedNewNote", at: 310_000)

        let days = try await repository.dailyActivity(dayCount: 2)
        XCTAssertEqual(days.map(\.localDate), ["2026-09-15", "2026-09-16"])
        // 窗口外事件被窗裁掉（且不落未归档——它本可归桶，只是不在窗内）。
        XCTAssertEqual(days.reduce(0) { $0 + $1.minedNewNote }, 1)
    }

    /// 总计口径：撤销单列、per-kind 有效计数。
    func testActivityTotalsSeparateUndone() async throws {
        try await insertEvent(kind: "minedNewNote", at: 1_000)
        try await insertEvent(kind: "minedNewNote", at: 1_100)
        try await insertEvent(kind: "createdCloze", at: 1_200)
        try await insertEvent(
            kind: "markedKnown", at: 1_300, undoneAt: 1_400)

        let totals = try await repository.activityTotals()
        XCTAssertEqual(totals.minedNewNote, 2)
        XCTAssertEqual(totals.createdCloze, 1)
        XCTAssertEqual(totals.markedKnown, 0)   // 已撤销不进有效桶
        XCTAssertEqual(totals.undoneCount, 1)
        XCTAssertEqual(totals.totalEffective, 3)
        XCTAssertEqual(totals.miningCount, 2)
        XCTAssertEqual(totals.cardCreationCount, 3)
    }

    // MARK: - 当前态聚合（反复切状态不放大）

    /// 验收项：known↔ignored↔reset 反复切换后掌握数只反映最终态。
    /// 走真实 `setOverride` 写路径——事件照常记录（操作量），
    /// 但 `knowledgeSummary` 的 known 桶是单行当前态。
    func testRepeatedStateTogglesDoNotInflateKnownCount() async throws {
        let lexeme = try await insertLexeme(writtenForm: "切替")
        var at: Int64 = 10_000
        func tick() -> Date {
            at += 1_000
            return Date(timeIntervalSince1970: Double(at) / 1_000)
        }
        // known → ignored → known → ignored → known（终态 known）。
        for target in [
            KnowledgeOverride.known, .ignored, .known, .ignored, .known
        ] {
            _ = try await knowledge.setOverride(
                lexemeID: lexeme, override: target, at: tick())
        }
        // 同态重放不写新事件；reset 再清掉。
        _ = try await knowledge.setOverride(
            lexemeID: lexeme, override: .known, at: tick())
        _ = try await knowledge.setOverride(
            lexemeID: lexeme, override: nil, at: tick())
        _ = try await knowledge.setOverride(
            lexemeID: lexeme, override: .known, at: tick())

        let summary = try await repository.knowledgeSummary()
        XCTAssertEqual(summary.knownCount, 1)   // 只算当前态一次
        XCTAssertEqual(summary.ignoredCount, 0)
        XCTAssertEqual(summary.trackedLexemeCount, 1)

        // 事件侧如实记录每次迁移（历史行为量与当前态分离）。
        let totals = try await repository.activityTotals()
        XCTAssertEqual(totals.markedKnown, 4)   // 4 次有效 known 迁移
        XCTAssertEqual(totals.resetKnowledge, 1)
        XCTAssertEqual(totals.totalEffective, 5)
    }

    /// 终态落在 ignored：事件里有 markedKnown 历史但当前态是 ignored。
    func testTogglesEndingAtIgnoredYieldZeroKnown() async throws {
        let lexeme = try await insertLexeme()
        var at: Int64 = 20_000
        func tick() -> Date {
            at += 1_000
            return Date(timeIntervalSince1970: Double(at) / 1_000)
        }
        for _ in 0..<6 {
            _ = try await knowledge.setOverride(
                lexemeID: lexeme, override: .known, at: tick())
            _ = try await knowledge.setOverride(
                lexemeID: lexeme, override: .ignored, at: tick())
        }
        let summary = try await repository.knowledgeSummary()
        XCTAssertEqual(summary.knownCount, 0)
        XCTAssertEqual(summary.ignoredCount, 1)
        let totals = try await repository.activityTotals()
        XCTAssertEqual(totals.markedKnown, 6)
    }

    /// learning 口径：只数 vocabulary 关联；grammar 关联不进桶；
    /// override 优先于关联（known+link → known，不重复计 learning）。
    func testLearningBucketFollowsTruthTable() async throws {
        let vocabLexeme = try await insertLexeme(writtenForm: "学習")
        let grammarLexeme = try await insertLexeme(writtenForm: "文法")
        let overriddenLexeme = try await insertLexeme(writtenForm: "上書")
        _ = try await insertLexeme(writtenForm: "未触")  // unknown 桶

        let vocabNote = try await insertNote(kind: "vocabulary")
        try await link(lexemeID: vocabLexeme, noteID: vocabNote)
        let grammarNote = try await insertNote(kind: "grammar")
        try await link(lexemeID: grammarLexeme, noteID: grammarNote)
        let overriddenNote = try await insertNote(kind: "vocabulary")
        try await link(lexemeID: overriddenLexeme, noteID: overriddenNote)
        _ = try await knowledge.setOverride(
            lexemeID: overriddenLexeme, override: .known, at: Date())

        let summary = try await repository.knowledgeSummary()
        XCTAssertEqual(summary.knownCount, 1)      // overridden
        XCTAssertEqual(summary.learningCount, 1)   // vocabLexeme only
        XCTAssertEqual(summary.ignoredCount, 0)
        XCTAssertEqual(summary.trackedLexemeCount, 4)
        // grammarLexeme（仅 grammar 关联）+ 未触 = 2 个 unmarked。
        XCTAssertEqual(summary.unmarkedCount, 2)
    }

    // MARK: - 删除语义（历史不陪葬）

    /// 验收项：删除文档后——事件仍在总计里、快照仍可读、概览行
    /// 凭快照标题呈现；document_id SET NULL 后该文档的事件归因数
    /// 归零（事件已不可归属，但全局计数保留）。
    func testDeletedDocumentHistoryRemainsReadable() async throws {
        let docID = UUID()
        _ = try await insertDocument(id: docID, title: "生き甲斐")
        try await insertSnapshot(
            documentID: docID, documentTitle: "生き甲斐",
            studyDayID: "2026-09-14", createdAt: 100_000,
            known: 8, learning: 1, unknown: 1,
            uniqueNum: 9, uniqueDen: 10, analyzed: 2, total: 2)
        try await insertEvent(
            kind: "minedNewNote", at: 110_000, documentID: docID,
            snapshotJSON: """
                {"document_title":"生き甲斐","written_form":"生き甲斐"}
                """)

        // 删除文档（reader_documents 行没了；事件 document_id SET NULL）。
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_documents WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(docID)])
        }

        let totals = try await repository.activityTotals()
        XCTAssertEqual(totals.minedNewNote, 1)  // 全局历史保留

        let docs = try await repository.documentSummaries(limit: 50)
        let doc = try XCTUnwrap(
            docs.first { $0.documentID == docID })
        XCTAssertFalse(doc.documentExists)
        XCTAssertEqual(doc.title, "生き甲斐")  // 快照标题兜底
        XCTAssertEqual(doc.eventCount, 0)      // 归因已断（SET NULL）
        XCTAssertEqual(
            doc.latestCoverage?.uniqueKnownOrLearningCoverage, 0.9)

        let trend = try await repository.coverageTrend(documentID: docID)
        XCTAssertEqual(trend.count, 1)
        XCTAssertEqual(trend[0].points.count, 1)

        let timeline = try await repository.activityTimeline(limit: 10)
        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(timeline[0].writtenForm, "生き甲斐")
        XCTAssertEqual(timeline[0].documentTitle, "生き甲斐")
    }

    /// 事件的 note_id SET NULL 同理：Note 删除后事件仍计入。
    func testDeletedNoteKeepsEvent() async throws {
        let noteID = try await insertNote()
        try await insertEvent(
            kind: "minedNewNote", at: 1_000, noteID: noteID,
            snapshotJSON: #"{"written_form":"雨"}"#)
        // 直接删 notes 行（绕业务路径测 SET NULL 行为）。
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)])
        }
        let totals = try await repository.activityTotals()
        XCTAssertEqual(totals.minedNewNote, 1)
        let timeline = try await repository.activityTimeline(limit: 10)
        XCTAssertEqual(timeline[0].writtenForm, "雨")
    }

    // MARK: - 覆盖率趋势分段

    /// 验收项：版本切换分段，绝不跨版本连线；回退旧版本开新段。
    func testCoverageTrendSegmentsByVersionRuns() async throws {
        let docID = UUID()
        _ = try await insertDocument(id: docID)
        // v1 两天 → v2 一天 → v1 再来一天（回退也开新段）。
        try await insertSnapshot(
            documentID: docID, documentTitle: "doc",
            studyDayID: "2026-09-14", createdAt: 100_000,
            morphologyVersion: "morph-1",
            known: 5, learning: 0, unknown: 5,
            uniqueNum: 5, uniqueDen: 10, analyzed: 1, total: 1)
        try await insertSnapshot(
            documentID: docID, documentTitle: "doc",
            studyDayID: "2026-09-15", createdAt: 200_000,
            morphologyVersion: "morph-1",
            known: 6, learning: 0, unknown: 4,
            uniqueNum: 6, uniqueDen: 10, analyzed: 1, total: 1)
        try await insertSnapshot(
            documentID: docID, documentTitle: "doc",
            studyDayID: "2026-09-16", createdAt: 300_000,
            morphologyVersion: "morph-2",
            known: 7, learning: 0, unknown: 3,
            uniqueNum: 7, uniqueDen: 10, analyzed: 1, total: 1)
        try await insertSnapshot(
            documentID: docID, documentTitle: "doc",
            studyDayID: "2026-09-17", createdAt: 400_000,
            morphologyVersion: "morph-1",
            known: 8, learning: 0, unknown: 2,
            uniqueNum: 8, uniqueDen: 10, analyzed: 1, total: 1)

        let segments = try await repository.coverageTrend(documentID: docID)
        XCTAssertEqual(segments.count, 3)  // v1 | v2 | v1（回退新段）
        XCTAssertEqual(segments[0].morphologyVersion, "morph-1")
        XCTAssertEqual(segments[0].points.map(\.studyDayID),
                       ["2026-09-14", "2026-09-15"])
        XCTAssertEqual(segments[1].morphologyVersion, "morph-2")
        XCTAssertEqual(segments[1].points.map(\.studyDayID), ["2026-09-16"])
        XCTAssertEqual(segments[2].morphologyVersion, "morph-1")
        XCTAssertEqual(segments[2].points.map(\.studyDayID), ["2026-09-17"])
        // 段 id 稳定递增（供图表 series 区分）。
        XCTAssertEqual(segments.map(\.id), [0, 1, 2])
    }

    /// dictionary_version 变化同样断开段；metric_version 同理。
    func testCoverageTrendSegmentsOnDictionaryAndMetricChanges() async throws {
        let docID = UUID()
        try await insertSnapshot(
            documentID: docID, documentTitle: "doc",
            studyDayID: "2026-09-14", createdAt: 100_000,
            metricVersion: "coverage-1.0.0", dictionaryVersion: "dict-1",
            known: 5, learning: 0, unknown: 5,
            uniqueNum: 5, uniqueDen: 10, analyzed: 1, total: 1)
        try await insertSnapshot(
            documentID: docID, documentTitle: "doc",
            studyDayID: "2026-09-15", createdAt: 200_000,
            metricVersion: "coverage-1.0.0", dictionaryVersion: "dict-2",
            known: 6, learning: 0, unknown: 4,
            uniqueNum: 6, uniqueDen: 10, analyzed: 1, total: 1)
        try await insertSnapshot(
            documentID: docID, documentTitle: "doc",
            studyDayID: "2026-09-16", createdAt: 300_000,
            metricVersion: "coverage-2.0.0", dictionaryVersion: "dict-2",
            known: 7, learning: 0, unknown: 3,
            uniqueNum: 7, uniqueDen: 10, analyzed: 1, total: 1)

        let segments = try await repository.coverageTrend(documentID: docID)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].dictionaryVersion, "dict-1")
        XCTAssertEqual(segments[1].dictionaryVersion, "dict-2")
        XCTAssertEqual(segments[2].metricVersion, "coverage-2.0.0")
    }

    /// partial 行照常入段（UI 标记为已分析范围）；unique 分母 0 → nil。
    func testCoverageTrendPartialAndEmptyDenominator() async throws {
        let docID = UUID()
        try await insertSnapshot(
            documentID: docID, documentTitle: "doc",
            studyDayID: "2026-09-14", createdAt: 100_000,
            known: 0, learning: 0, unknown: 0,
            uniqueNum: 0, uniqueDen: 0, analyzed: 0, total: 0)
        try await insertSnapshot(
            documentID: docID, documentTitle: "doc",
            studyDayID: "2026-09-15", createdAt: 200_000,
            known: 3, learning: 0, unknown: 2,
            uniqueNum: 3, uniqueDen: 5, analyzed: 1, total: 3)

        let segments = try await repository.coverageTrend(documentID: docID)
        XCTAssertEqual(segments.count, 1)
        let points = segments[0].points
        XCTAssertNil(points[0].uniqueKnownOrLearningCoverage)
        XCTAssertNil(points[0].tokenCoverage)
        XCTAssertFalse(points[0].isPartial)   // 0/0 不算 partial
        XCTAssertTrue(points[1].isPartial)
        XCTAssertEqual(points[1].uniqueKnownOrLearningCoverage, 0.6)
    }

    // MARK: - 无正文文档 / 概览行

    /// 验收项：无正文文档——快照 0/0 行保留、覆盖率为 nil 语义，
    /// `hasNoBody` 置真供 UI 走「无正文」态而非「未分析」。
    func testNoBodyDocumentShowsHistory() async throws {
        let docID = try await insertDocument(title: "空文档")
        try await insertSnapshot(
            documentID: docID, documentTitle: "空文档",
            studyDayID: "2026-09-14", createdAt: 100_000,
            known: 0, learning: 0, unknown: 0,
            uniqueNum: 0, uniqueDen: 0, analyzed: 0, total: 0)

        let docs = try await repository.documentSummaries(limit: 50)
        let doc = try XCTUnwrap(docs.first { $0.documentID == docID })
        XCTAssertTrue(doc.documentExists)
        let coverage = try XCTUnwrap(doc.latestCoverage)
        XCTAssertTrue(coverage.hasNoBody)
        XCTAssertNil(coverage.uniqueKnownOrLearningCoverage)
        XCTAssertNil(coverage.tokenCoverage)
        // 趋势也照常返回 0/0 点（历史可读，不是「无数据」）。
        let trend = try await repository.coverageTrend(documentID: docID)
        XCTAssertEqual(trend.count, 1)
        XCTAssertEqual(trend[0].points.count, 1)
    }

    /// 概览集 = 三方 document_id 并集；排序 = 最近活动优先；
    /// 从未分析过的文档 `latestCoverage` 为 nil（不是 0%）。
    func testDocumentSummariesUnionAndOrdering() async throws {
        let liveUnanalyzed = try await insertDocument(
            title: "未分析", lastOpenedAt: 500_000, progressBasisPoints: 2500)
        let liveWithSnapshot = try await insertDocument(
            title: "有快照", lastOpenedAt: 600_000)
        let snapshotOnly = UUID()  // 只存在于快照（文档行从未落库/已删）
        try await insertSnapshot(
            documentID: liveWithSnapshot, documentTitle: "有快照",
            studyDayID: "2026-09-14", createdAt: 100_000,
            known: 4, learning: 1, unknown: 5,
            uniqueNum: 5, uniqueDen: 10, analyzed: 1, total: 1)
        try await insertSnapshot(
            documentID: snapshotOnly, documentTitle: "仅快照",
            studyDayID: "2026-09-15", createdAt: 700_000,
            known: 2, learning: 0, unknown: 8,
            uniqueNum: 2, uniqueDen: 10, analyzed: 1, total: 1)
        try await insertEvent(
            kind: "minedNewNote", at: 610_000, documentID: liveWithSnapshot)
        try await insertEvent(
            kind: "markedKnown", at: 620_000, documentID: liveWithSnapshot)

        let docs = try await repository.documentSummaries(limit: 50)
        XCTAssertEqual(docs.count, 3)
        // 排序：snapshotOnly(snap@700k) > liveWithSnapshot(open@600k)
        //      > liveUnanalyzed(open@500k)。
        XCTAssertEqual(docs.map(\.documentID),
                       [snapshotOnly, liveWithSnapshot, liveUnanalyzed])

        let live = try XCTUnwrap(
            docs.first { $0.documentID == liveWithSnapshot })
        XCTAssertEqual(live.eventCount, 2)
        XCTAssertEqual(
            live.latestCoverage?.uniqueKnownOrLearningCoverage, 0.5)
        XCTAssertFalse(live.latestCoverage?.isPartial ?? true)

        let unanalyzed = try XCTUnwrap(
            docs.first { $0.documentID == liveUnanalyzed })
        XCTAssertNil(unanalyzed.latestCoverage)
        XCTAssertEqual(unanalyzed.progress, 0.25)
        XCTAssertEqual(unanalyzed.title, "未分析")

        let ghost = try XCTUnwrap(
            docs.first { $0.documentID == snapshotOnly })
        XCTAssertFalse(ghost.documentExists)
        XCTAssertEqual(ghost.title, "仅快照")
        XCTAssertNil(ghost.lastOpenedAt)
        XCTAssertNil(ghost.progressBasisPoints)
    }

    // MARK: - 时间线

    /// 时间线：新→旧排序、snapshot_json 解码、撤销标记、未归档
    /// 事件的 localDate 为空串。（kind 列有 CHECK 约束，未知值
    /// 写不进来——`compactMap` 仍是防御，不测库层不可达分支。）
    func testActivityTimelineDecodeAndOrdering() async throws {
        try await insertStudyDay(
            localDate: "2026-09-15", startsAt: 200_000, endsAt: 300_000)
        let docID = try await insertDocument(title: "夏目")
        try await insertEvent(
            kind: "minedNewNote", at: 210_000, documentID: docID,
            snapshotJSON:
                #"{"document_title":"夏目","written_form":"夢"}"#)
        try await insertEvent(
            kind: "markedKnown", at: 220_000,
            snapshotJSON: #"{"written_form":"知る"}"#)
        try await insertEvent(
            kind: "resetKnowledge", at: 230_000,
            snapshotJSON: #"{"written_form":"戻る"}"#, undoneAt: 240_000)
        try await insertEvent(kind: "createdCloze", at: 50_000)  // 未归档

        let timeline = try await repository.activityTimeline(limit: 10)
        XCTAssertEqual(timeline.count, 4)
        XCTAssertEqual(
            timeline.map(\.kind),
            [.resetKnowledge, .markedKnown, .minedNewNote, .createdCloze])
        XCTAssertEqual(timeline[0].writtenForm, "戻る")
        XCTAssertTrue(timeline[0].isUndone)
        XCTAssertEqual(timeline[2].documentTitle, "夏目")
        XCTAssertEqual(timeline[0].localDate, "2026-09-15")
        XCTAssertEqual(timeline[3].localDate, "")  // 未归档事件
    }
}
