import Foundation
import GRDB
import OboeDomain

/// v0.7.0 S22：`ReaderAnalyticsRepository` 的 GRDB 实现——Reader 域
/// 只读分析查询（§11.2 事件流 + §7 覆盖率快照 + §6.3 当前知识态）。
///
/// 口径总则：
/// - **事件计数**（`reader_activity_events`）：`undone_at_ms IS NULL`
///   的有效事件按 kind/学习日聚合；撤销事件单列 `undoneCount`。
///   事件是历史行为量——同一 lexeme 反复切换状态每次切换都各算一次
///   事件（如实呈现操作量），绝不与「当前掌握词数」混用。
/// - **当前掌握词数**（D19：learning unit 三态聚合）：
///   词→unit 解析与 `GRDBVocabularyKnowledgeRepository
///   .wordKnowledgeStates` 同规则（current 义项 ∪ note 链路
///   载体）；每 lexeme 取其 unit 最小态聚合（任一 unknown →
///   词级 unknown、全部 mastered → known）——不再读
///   `vocabulary_knowledge_overrides` 作运行态真值。
///   `ignored_count` 仅回传该表的历史存档行数（审计信息，
///   不参与任何运行态判定；D04：ignored 已退出运行态）。
/// - **学习日分桶**：事件无 `study_day_id` 列——按
///   `created_at_ms ∈ [starts_at_ms, ends_at_ms)` 归桶；多时区行
///   重叠窗口取 starts_at_ms 最新一行（每事件恰好归一天，不重数）；
///   同 `local_date` 的不同 study_days 行并入同桶（同 S20 裁决）。
/// - **覆盖率趋势**：只读 `scope_key='document'` 行；版本三元组
///   `(metric_version, morphology_version, dictionary_version)` 的
///   连续 run 分段——跨版本永不连线（`ReaderCoverageSegmentation`）。
/// - **删除语义**：对 `reader_documents` 一律 LEFT JOIN——事件
///   `document_id` SET NULL、快照 `document_id` 无 FK，删文档后
///   历史照常返回；`document_title` 快照字段兜底标题展示。
public struct GRDBReaderAnalyticsRepository: ReaderAnalyticsRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - 事件聚合（§11.2）

    /// 全时段有效事件按 kind 聚合；撤销事件单列。
    static let activityTotalsSQL = """
        SELECT
            COALESCE(SUM(CASE WHEN kind = 'minedNewNote'
                AND undone_at_ms IS NULL THEN 1 ELSE 0 END), 0) AS mined_new,
            COALESCE(SUM(CASE WHEN kind = 'linkedExistingNote'
                AND undone_at_ms IS NULL THEN 1 ELSE 0 END), 0) AS linked,
            COALESCE(SUM(CASE WHEN kind = 'createdCloze'
                AND undone_at_ms IS NULL THEN 1 ELSE 0 END), 0) AS cloze,
            COALESCE(SUM(CASE WHEN kind = 'markedKnown'
                AND undone_at_ms IS NULL THEN 1 ELSE 0 END), 0) AS known,
            COALESCE(SUM(CASE WHEN kind = 'resetKnowledge'
                AND undone_at_ms IS NULL THEN 1 ELSE 0 END), 0) AS reset,
            COALESCE(SUM(CASE WHEN undone_at_ms IS NOT NULL
                THEN 1 ELSE 0 END), 0) AS undone
        FROM reader_activity_events
        """

    public func activityTotals() async throws -> ReaderActivityTotals {
        try await pool.read { db in
            let row = try Row.fetchOne(db, sql: Self.activityTotalsSQL)
            return ReaderActivityTotals(
                minedNewNote: row?["mined_new"] ?? 0,
                linkedExistingNote: row?["linked"] ?? 0,
                createdCloze: row?["cloze"] ?? 0,
                markedKnown: row?["known"] ?? 0,
                resetKnowledge: row?["reset"] ?? 0,
                undoneCount: row?["undone"] ?? 0
            )
        }
    }

    /// 事件 → 学习日 local_date 的归桶片段（每事件至多匹配一行：
    /// 重叠窗口取 starts_at_ms 最新者）。
    private static let eventDayBucketSQL = """
        (SELECT s.local_date FROM study_days s
          WHERE e.created_at_ms >= s.starts_at_ms
            AND e.created_at_ms < s.ends_at_ms
          ORDER BY s.starts_at_ms DESC LIMIT 1)
        """

    /// 逐学习日聚合：窗口 = 最近 N 个已落库 study_days（不补日历——
    /// 与 S20/S21 同口径）；窗口内零事件日保留为全 0 行；落不进任何
    /// study_days 窗口的有效事件归入末尾的未归档桶。
    public func dailyActivity(
        dayCount: Int
    ) async throws -> [ReaderActivityDayPoint] {
        try await pool.read { db in
            // 1) 最近 N 个学习日（按开始时刻倒序取窗，再转正序）。
            //    同一 local_date 可能有多时区行——按日期去重成单点。
            let window: [(localDate: String, startsAt: Int64)] =
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT local_date, starts_at_ms FROM study_days
                        ORDER BY starts_at_ms DESC LIMIT ?
                        """,
                    arguments: [max(0, dayCount)]
                ).map { ($0["local_date"] as String, $0["starts_at_ms"] as Int64) }
                    .reversed()
            var seenDates = Set<String>()
            let orderedDates = window.compactMap { day -> String? in
                seenDates.insert(day.localDate).inserted
                    ? day.localDate : nil
            }

            // 2) 全量有效事件按归桶 local_date × kind 聚合。
            //    GROUP BY local_date 顺带把多时区同日期行合桶。
            var counts: [String: [String: Int]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT COALESCE(\(Self.eventDayBucketSQL), '')
                        AS local_date, kind, COUNT(*) AS n
                    FROM reader_activity_events e
                    WHERE undone_at_ms IS NULL
                    GROUP BY local_date, kind
                    """
            ) {
                let day: String = row["local_date"]
                counts[day, default: [:]][row["kind"]] = row["n"]
            }

            func point(localDate: String) -> ReaderActivityDayPoint {
                let kinds = counts[localDate] ?? [:]
                return ReaderActivityDayPoint(
                    localDate: localDate,
                    minedNewNote: kinds["minedNewNote"] ?? 0,
                    linkedExistingNote: kinds["linkedExistingNote"] ?? 0,
                    createdCloze: kinds["createdCloze"] ?? 0,
                    markedKnown: kinds["markedKnown"] ?? 0,
                    resetKnowledge: kinds["resetKnowledge"] ?? 0
                )
            }

            var points = orderedDates.map { point(localDate: $0) }
            // 未归档桶：不丢历史，但放在序列末尾并由 UI 标注。
            if let orphan = counts[""], orphan.values.reduce(0, +) > 0 {
                points.append(point(localDate: ""))
            }
            return points
        }
    }

    // MARK: - 当前知识态（真值表聚合）

    /// 词级聚合（与 `wordKnowledgeStates` 同一 merge）：unit 最小态
    /// ——任一 unknown → 词级 unknown；全部 mastered → known。
    /// `ignored_count` 读历史存档行数仅作审计展示（D19/D04）。
    static let knowledgeSummarySQL = """
        WITH lex_state AS (
            SELECT x.lexeme_id AS lexeme_id,
                   MIN(CASE
                       WHEN COALESCE(f.too_easy, 0) = 1 THEN 2
                       WHEN EXISTS(
                           SELECT 1 FROM learning_unit_note_links nl
                           JOIN notes n ON n.id = nl.note_id
                                AND n.kind = 'vocabulary'
                           WHERE nl.unit_id = x.unit_id) THEN 1
                       ELSE 0
                   END) AS st
            FROM (
                SELECT l.id AS lexeme_id, u.id AS unit_id
                FROM lexemes l
                JOIN lexical_learning_units u
                  ON u.identity_kind = 'dictionarySense'
                 AND u.binding_status = 'current'
                 AND u.dictionary_entry_id = COALESCE(
                       (SELECT b.entry_id
                          FROM lexeme_dictionary_bindings b
                         WHERE b.lexeme_id = l.id
                           AND b.status = 'current'),
                       l.entry_id)
                UNION
                SELECT x.lexeme_id, ul.unit_id
                FROM lexeme_note_links x
                JOIN learning_unit_note_links ul
                  ON ul.note_id = x.note_id
            ) x
            LEFT JOIN learning_unit_flags f ON f.unit_id = x.unit_id
            GROUP BY x.lexeme_id
        )
        SELECT
            (SELECT COUNT(*) FROM lex_state WHERE st = 2) AS known_count,
            -- D19：ignored 无运行时载体；字段保留恒 0，
            -- unmarkedCount = tracked - known - learning。
            0 AS ignored_count,
            (SELECT COUNT(*) FROM lex_state WHERE st = 1) AS learning_count,
            (SELECT COUNT(*) FROM lexemes) AS tracked_count
        """

    public func knowledgeSummary() async throws -> ReaderKnowledgeSummary {
        try await pool.read { db in
            let row = try Row.fetchOne(db, sql: Self.knowledgeSummarySQL)
            return ReaderKnowledgeSummary(
                knownCount: row?["known_count"] ?? 0,
                learningCount: row?["learning_count"] ?? 0,
                ignoredCount: row?["ignored_count"] ?? 0,
                trackedLexemeCount: row?["tracked_count"] ?? 0
            )
        }
    }

    // MARK: - 文档概览

    /// document_id 三方并集（现存文档 ∪ 快照 ∪ 事件归因）+ 最新
    /// 文档级快照（按 created_at_ms，任意版本）+ 活文档字段。
    /// 全部弱引用 LEFT JOIN——已删文档保留历史行。
    static let documentSummariesSQL = """
        WITH doc_ids AS (
            SELECT id AS doc_id FROM reader_documents
            UNION SELECT document_id FROM reader_coverage_snapshots
            UNION SELECT document_id FROM reader_activity_events
                WHERE document_id IS NOT NULL
        )
        SELECT
            i.doc_id,
            d.title AS live_title,
            d.last_opened_at_ms,
            d.progress_basis_points,
            s.document_title AS snapshot_title,
            s.study_day_id AS snap_day,
            s.metric_version AS snap_metric,
            s.morphology_version AS snap_morphology,
            s.known_count AS snap_known,
            s.learning_count AS snap_learning,
            s.unknown_count AS snap_unknown,
            s.unique_numerator AS snap_num,
            s.unique_denominator AS snap_den,
            s.analyzed_blocks AS snap_analyzed,
            s.total_blocks AS snap_total,
            s.created_at_ms AS snap_created,
            (SELECT COUNT(*) FROM reader_activity_events e
                WHERE e.document_id = i.doc_id
                  AND e.undone_at_ms IS NULL) AS event_count
        FROM doc_ids i
        LEFT JOIN reader_documents d ON d.id = i.doc_id
        LEFT JOIN reader_coverage_snapshots s ON s.id = (
            SELECT s2.id FROM reader_coverage_snapshots s2
            WHERE s2.document_id = i.doc_id AND s2.scope_key = 'document'
            ORDER BY s2.created_at_ms DESC, s2.id DESC LIMIT 1)
        ORDER BY COALESCE(
            d.last_opened_at_ms, s.created_at_ms, 0) DESC, i.doc_id ASC
        LIMIT ?
        """

    public func documentSummaries(
        limit: Int
    ) async throws -> [ReaderDocumentSummary] {
        try await pool.read { db in
            try Row.fetchAll(
                db, sql: Self.documentSummariesSQL,
                arguments: [max(0, limit)]
            ).map { row in
                let liveTitle: String? = row["live_title"]
                let snapshotTitle: String? = row["snapshot_title"]
                let latest: ReaderDocumentLatestCoverage? =
                    (row["snap_day"] as String?).map { day in
                        let num: Int = row["snap_num"]
                        let den: Int = row["snap_den"]
                        let known: Int = row["snap_known"]
                        let learning: Int = row["snap_learning"]
                        let unknown: Int = row["snap_unknown"]
                        let eligible = known + learning + unknown
                        let analyzed: Int = row["snap_analyzed"]
                        let total: Int = row["snap_total"]
                        return ReaderDocumentLatestCoverage(
                            studyDayID: day,
                            metricVersion: row["snap_metric"],
                            morphologyVersion: row["snap_morphology"],
                            uniqueKnownOrLearningCoverage: den > 0
                                ? Double(num) / Double(den) : nil,
                            tokenCoverage: eligible > 0
                                ? Double(known) / Double(eligible) : nil,
                            isPartial: analyzed < total,
                            analyzedBlocks: analyzed,
                            totalBlocks: total
                        )
                    }
                return ReaderDocumentSummary(
                    documentID: try DatabaseValueCodec.decodeUUID(
                        row["doc_id"]),
                    title: liveTitle ?? snapshotTitle ?? "（未命名文档）",
                    documentExists: liveTitle != nil,
                    lastOpenedAt: (row["last_opened_at_ms"] as Int64?)
                        .map(DatabaseValueCodec.decodeDate(milliseconds:)),
                    progressBasisPoints: row["progress_basis_points"],
                    eventCount: row["event_count"],
                    latestCoverage: latest
                )
            }
        }
    }

    // MARK: - 覆盖率趋势（版本分段）

    /// 文档级快照全历史（不限版本——分段在领域层做），按学习日 +
    /// 写入时刻升序；`study_day_id` 是 local_date，字典序即时间序。
    static let coverageTrendSQL = """
        SELECT id, study_day_id, created_at_ms,
               metric_version, morphology_version, dictionary_version,
               known_count, learning_count, unknown_count,
               unique_numerator, unique_denominator,
               analyzed_blocks, total_blocks
        FROM reader_coverage_snapshots
        WHERE document_id = ? AND scope_key = 'document'
        ORDER BY study_day_id ASC, created_at_ms ASC, id ASC
        """

    public func coverageTrend(
        documentID: UUID
    ) async throws -> [ReaderCoverageTrendSegment] {
        try await pool.read { db in
            let items = try Row.fetchAll(
                db,
                sql: Self.coverageTrendSQL,
                arguments: [DatabaseValueCodec.encode(documentID)]
            ).map { row -> (metricVersion: String, morphologyVersion: String,
                            dictionaryVersion: String?,
                            point: ReaderCoverageTrendPoint) in
                let num: Int = row["unique_numerator"]
                let den: Int = row["unique_denominator"]
                let known: Int = row["known_count"]
                let learning: Int = row["learning_count"]
                let unknown: Int = row["unknown_count"]
                let eligible = known + learning + unknown
                let analyzed: Int = row["analyzed_blocks"]
                let total: Int = row["total_blocks"]
                return (
                    metricVersion: row["metric_version"],
                    morphologyVersion: row["morphology_version"],
                    dictionaryVersion: row["dictionary_version"],
                    point: ReaderCoverageTrendPoint(
                        id: try DatabaseValueCodec.decodeUUID(row["id"]),
                        studyDayID: row["study_day_id"],
                        createdAt: DatabaseValueCodec.decodeDate(
                            milliseconds: row["created_at_ms"]),
                        uniqueKnownOrLearningCoverage: den > 0
                            ? Double(num) / Double(den) : nil,
                        tokenCoverage: eligible > 0
                            ? Double(known) / Double(eligible) : nil,
                        isPartial: analyzed < total,
                        analyzedBlocks: analyzed,
                        totalBlocks: total
                    )
                )
            }
            return ReaderCoverageSegmentation.segments(of: items)
        }
    }

    // MARK: - 事件时间线

    /// 最近 N 条事件（含已撤销——时间线是历史事实，UI 标灰）；
    /// document_id SET NULL 后 snapshot_title 兜底展示。
    static let activityTimelineSQL = """
        SELECT e.id, e.kind, e.created_at_ms, e.undone_at_ms,
               e.snapshot_json, d.title AS live_doc_title,
               \(eventDayBucketSQL) AS local_date
        FROM reader_activity_events e
        LEFT JOIN reader_documents d ON d.id = e.document_id
        ORDER BY e.created_at_ms DESC, e.id DESC
        LIMIT ?
        """

    public func activityTimeline(
        limit: Int
    ) async throws -> [ReaderTimelineEntry] {
        try await pool.read { db in
            try Row.fetchAll(
                db, sql: Self.activityTimelineSQL,
                arguments: [max(0, limit)]
            ).compactMap { row in
                guard let kind = ReaderActivityKind(
                    rawValue: row["kind"] as String
                ) else { return nil }  // 未知 kind（未来版本写入）跳过
                let snapshot = Self.decodeEventSnapshot(
                    row["snapshot_json"] as String?)
                let liveTitle: String? = row["live_doc_title"]
                return ReaderTimelineEntry(
                    id: try DatabaseValueCodec.decodeUUID(row["id"]),
                    kind: kind,
                    createdAt: DatabaseValueCodec.decodeDate(
                        milliseconds: row["created_at_ms"]),
                    localDate: row["local_date"] ?? "",
                    writtenForm: snapshot["written_form"],
                    documentTitle: snapshot["document_title"] ?? liveTitle,
                    isUndone: (row["undone_at_ms"] as Int64?) != nil
                )
            }
        }
    }

    /// `snapshot_json` 是 `{"written_form","document_title","sentence"}`
    /// 的小 JSON（ReaderMiningService.eventSnapshot /
    /// insertKnowledgeEvent 同构）——只取展示两键，宽容解码。
    private static func decodeEventSnapshot(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for key in ["written_form", "document_title"] {
            if let value = dict[key] as? String { result[key] = value }
        }
        return result
    }
}
