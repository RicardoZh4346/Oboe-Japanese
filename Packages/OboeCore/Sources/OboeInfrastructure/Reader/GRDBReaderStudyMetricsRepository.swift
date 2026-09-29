import Foundation
import GRDB
import OboeDomain

/// 文档级 Reader→学习项转化漏斗（v0.7.5 S20 统计页数据源）。
///
/// 口径（与 S15/S13 证据链一致，contracts §4/§6）：
/// - **准备**：`reader_study_occurrences` 在文档**当前**
///   `content_revision` 下的锚点计数（旧修订的历史行不计入）。
/// - **解析**：`resolution_status` 分组——已确认身份
///   （aiResolved/userConfirmed）/ 待确认（pending/lowConfidence/
///   rejected/skipped）/ OOV（unresolved）；与
///   `GRDBReaderCoverageSnapshotStore` 同一桶定义。
/// - **确认/应用**：`ai_study_selections` 按（job,unit_key）取**最高
///   selection_revision** 行的 decision；`applied_receipt_id` 非空 =
///   已应用（receipt 幂等链终点——s.selections 每 unit_key 至多
///   一行带 receipt）。
/// - **Job**：`ai_study_jobs` 按 status 分组计数。
public struct ReaderStudyFunnel: Equatable, Sendable {
    /// 文档当前修订的 occurrence 总数（准备产物）。
    public var preparedOccurrences = 0
    /// aiResolved + userConfirmed。
    public var resolvedOccurrences = 0
    /// pending + lowConfidence + rejected + skipped。
    public var pendingOccurrences = 0
    /// unresolved（无候选/未解析）。
    public var oovOccurrences = 0
    /// 已确认选择（最新 revision）按 decision 计数。
    public var selectedReuse = 0
    public var selectedCreate = 0
    public var selectedSkip = 0
    public var selectedTooEasy = 0
    public var selectedPending = 0
    /// 已应用（applied_receipt_id 非空）按 decision 计数。
    public var appliedReuse = 0
    public var appliedCreate = 0
    public var appliedSkip = 0
    public var appliedTooEasy = 0
    /// Job 计数：活跃（非终态）/ 完成 / 失败 / 取消。
    public var activeJobs = 0
    public var completedJobs = 0
    public var failedJobs = 0
    public var cancelledJobs = 0

    public init() {}

    /// 已应用动作总数。
    public var appliedTotal: Int {
        appliedReuse + appliedCreate + appliedSkip + appliedTooEasy
    }
    /// 已确认选择总数。
    public var selectedTotal: Int {
        selectedReuse + selectedCreate + selectedSkip + selectedTooEasy
            + selectedPending
    }
}

// MARK: - Coverage v2 趋势（v26 快照）

/// `reader_learning_coverage_snapshots` 的一个趋势点（S20 统计页）。
///
/// 覆盖读数是历史快照列的直读——`resolvedCoverage`/`masteredCoverage`
/// 按 §13.3 空分母 → nil 口径展示（不伪造 0%/100%）。
public struct ReaderStudyCoveragePoint: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let calculatedAt: Date
    public let metricVersion: String
    public let morphologyVersion: String
    public let dictionaryVersion: String
    /// 分母：已确认身份的 distinct unit 数。
    public let resolvedUnique: Int
    /// 已解析但仍 unknown 态的 unit 数（在分母不在分子）。
    public let unlearnedUnique: Int
    public let learningUnique: Int
    public let masteredUnique: Int
    /// 待确认 occurrence 数（不进分母，但必须相邻展示）。
    public let pendingOccurrences: Int
    /// OOV occurrence 数（同上进分母禁令）。
    public let oovOccurrences: Int
    public let analyzedBlocks: Int
    public let totalBlocks: Int

    public init(
        id: UUID,
        calculatedAt: Date,
        metricVersion: String,
        morphologyVersion: String,
        dictionaryVersion: String,
        resolvedUnique: Int,
        unlearnedUnique: Int,
        learningUnique: Int,
        masteredUnique: Int,
        pendingOccurrences: Int,
        oovOccurrences: Int,
        analyzedBlocks: Int,
        totalBlocks: Int
    ) {
        self.id = id
        self.calculatedAt = calculatedAt
        self.metricVersion = metricVersion
        self.morphologyVersion = morphologyVersion
        self.dictionaryVersion = dictionaryVersion
        self.resolvedUnique = resolvedUnique
        self.unlearnedUnique = unlearnedUnique
        self.learningUnique = learningUnique
        self.masteredUnique = masteredUnique
        self.pendingOccurrences = pendingOccurrences
        self.oovOccurrences = oovOccurrences
        self.analyzedBlocks = analyzedBlocks
        self.totalBlocks = totalBlocks
    }

    /// `(learning + mastered) / resolvedUnique`；空分母 → nil。
    public var resolvedCoverage: Double? {
        resolvedUnique > 0
            ? Double(learningUnique + masteredUnique)
                / Double(resolvedUnique)
            : nil
    }
    /// `mastered / resolvedUnique`；空分母 → nil。
    public var masteredCoverage: Double? {
        resolvedUnique > 0
            ? Double(masteredUnique) / Double(resolvedUnique)
            : nil
    }
    /// 只分析了部分块——展示为「已分析范围」，不得冒充全书。
    public var isPartial: Bool { analyzedBlocks < totalBlocks }
    /// 分段等价判据（同 S22 versionKey 语义）。
    public var versionKey: String {
        "\(metricVersion)|\(morphologyVersion)|\(dictionaryVersion)"
    }
}

/// 同一版本三元组下的一段连续 Coverage v2 趋势点。
/// 版本切换（含回退）开新段——图表按段连线，绝不跨版本连成
/// 误导性斜线（与 `ReaderCoverageTrendSegment` 同一纪律）。
public struct ReaderStudyCoverageSegment: Equatable, Sendable,
    Identifiable
{
    /// 趋势内的段序（稳定 id：同键回退不会与前段合并）。
    public let index: Int
    /// 覆盖率口径版本（如 `coverage-resolved-sense-2.0.0`）。
    public let metricVersion: String
    /// 形态管线版本。
    public let morphologyVersion: String
    /// 词典 dataset 版本（v26 列非空——无值行与有值行不混段）。
    public let dictionaryVersion: String
    public let points: [ReaderStudyCoveragePoint]

    public init(
        index: Int,
        metricVersion: String,
        morphologyVersion: String,
        dictionaryVersion: String,
        points: [ReaderStudyCoveragePoint]
    ) {
        self.index = index
        self.metricVersion = metricVersion
        self.morphologyVersion = morphologyVersion
        self.dictionaryVersion = dictionaryVersion
        self.points = points
    }

    public var id: Int { index }
    public var versionKey: String {
        "\(metricVersion)|\(morphologyVersion)|\(dictionaryVersion)"
    }
}

/// v0.7.5 S20：`ai_study_*` + `reader_study_occurrences` 的只读
/// 聚合——统计页与 e2e fixture 的口径出处。全部查询单文档粒度，
/// 全局 rollup 由调用方加总（跨文档 SQL 聚合留待需要时再加——
/// 今日口径一致由同函数保证）。
public struct GRDBReaderStudyMetricsRepository: Sendable {
    private let pool: DatabasePool

    public init(pool: DatabasePool) { self.pool = pool }

    public init(database: OboeDatabase) { self.init(pool: database.pool) }

    /// 文档漏斗（async facade）。
    public func funnel(documentID: UUID) async throws
        -> ReaderStudyFunnel
    {
        try await pool.read { db in
            try Self.funnel(documentID: documentID, in: db)
        }
    }

    // MARK: - Coverage v2（S20 统计页）

    /// 当前态活算投影（不落库）——统计页「当前状态」口径；历史
    /// 快照是另一口径（见 `coverageTrend`），两列在 UI 分开标注。
    /// 文档不存在/已删 → nil（不是错误）。
    public func liveCoverage(
        documentID: UUID
    ) async throws
        -> GRDBReaderCoverageSnapshotStore.DocumentCoverageProjection?
    {
        try await pool.read { db in
            do {
                return try GRDBReaderCoverageSnapshotStore
                    .projectDocumentCoverage(
                        documentID: documentID, in: db)
            } catch GRDBReaderCoverageSnapshotStore.StoreError
                .documentMissing {
                return nil
            }
        }
    }

    /// v26 快照历史（async facade）：`document_id` 直查 ∪
    /// `document_id_snapshot` 追溯——已删文档（SET NULL）的历史
    /// 照常返回（D09）。按 `calculated_at_ms` 升序分版本段。
    public func coverageTrend(
        documentID: UUID
    ) async throws -> [ReaderStudyCoverageSegment] {
        try await pool.read { db in
            try Self.coverageTrend(documentID: documentID, in: db)
        }
    }

    /// 事务内形态。快照 `document_id_snapshot` 是
    /// `DatabaseValueCodec.encode(documentID)` 的字符串快照——
    /// OR 双列匹配覆盖 SET NULL 孤儿行。
    public static func coverageTrend(
        documentID: UUID, in db: Database
    ) throws -> [ReaderStudyCoverageSegment] {
        let encoded = DatabaseValueCodec.encode(documentID)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(snapshotColumns)
                FROM reader_learning_coverage_snapshots
                WHERE document_id = ? OR document_id_snapshot = ?
                ORDER BY calculated_at_ms ASC, rowid ASC
                """,
            arguments: [encoded, encoded]
        )
        let points = try rows.map { row -> ReaderStudyCoveragePoint in
            ReaderStudyCoveragePoint(
                id: try DatabaseValueCodec.decodeUUID(row["id"]),
                calculatedAt: DatabaseValueCodec.decodeDate(
                    milliseconds: row["calculated_at_ms"]),
                metricVersion: row["metric_version"],
                morphologyVersion: row["morphology_version"],
                dictionaryVersion: row["dictionary_version"],
                resolvedUnique: row["resolved_unique"],
                unlearnedUnique: row["unknown_unique"],
                learningUnique: row["learning_unique"],
                masteredUnique: row["mastered_unique"],
                pendingOccurrences: row["pending_occurrences"],
                oovOccurrences: row["oov_occurrences"],
                analyzedBlocks: row["analyzed_blocks"],
                totalBlocks: row["total_blocks"])
        }
        return segmentCoveragePoints(points)
    }

    private static let snapshotColumns = """
        id, metric_version, morphology_version, dictionary_version,
        resolved_unique, unknown_unique, learning_unique,
        mastered_unique, pending_occurrences, oov_occurrences,
        analyzed_blocks, total_blocks, calculated_at_ms
        """

    /// 连续 run 分段：相邻点版本三元组一致即并段，切换（含回退）
    /// 开新段；单点也成段（孤立版本行照常显示为点）。
    private static func segmentCoveragePoints(
        _ points: [ReaderStudyCoveragePoint]
    ) -> [ReaderStudyCoverageSegment] {
        var result: [ReaderStudyCoverageSegment] = []
        for point in points {
            if let last = result.last,
               last.versionKey == point.versionKey {
                result[result.count - 1] = ReaderStudyCoverageSegment(
                    index: last.index,
                    metricVersion: last.metricVersion,
                    morphologyVersion: last.morphologyVersion,
                    dictionaryVersion: last.dictionaryVersion,
                    points: last.points + [point])
            } else {
                result.append(ReaderStudyCoverageSegment(
                    index: result.count,
                    metricVersion: point.metricVersion,
                    morphologyVersion: point.morphologyVersion,
                    dictionaryVersion: point.dictionaryVersion,
                    points: [point]))
            }
        }
        return result
    }

    /// 文档漏斗（静态 in-transaction）。
    public static func funnel(
        documentID: UUID, in db: Database
    ) throws -> ReaderStudyFunnel {
        let documentIDValue = DatabaseValueCodec.encode(documentID)
        var funnel = ReaderStudyFunnel()

        // 文档当前修订——occurrence 只按当前修订计（历史修订的
        // 锚点是旧口径证据，不进漏斗）。
        let contentRevision: Int? = try Int.fetchOne(
            db,
            sql: """
                SELECT content_revision FROM reader_documents
                WHERE id = ?
                """,
            arguments: [documentIDValue]
        )
        guard let contentRevision else {
            return funnel  // 文档不存在/已删——空漏斗。
        }

        // 1) occurrence 桶。
        let occurrenceRows = try Row.fetchAll(
            db,
            sql: """
                SELECT resolution_status AS status, COUNT(*) AS n
                FROM reader_study_occurrences
                WHERE document_id = ? AND content_revision = ?
                GROUP BY resolution_status
                """,
            arguments: [documentIDValue, contentRevision]
        )
        for row in occurrenceRows {
            let status: String = row["status"]
            let count: Int = row["n"]
            funnel.preparedOccurrences += count
            switch status {
            case "aiResolved", "userConfirmed":
                funnel.resolvedOccurrences += count
            case "unresolved":
                funnel.oovOccurrences += count
            default:
                // pending/lowConfidence/rejected/skipped/未知。
                funnel.pendingOccurrences += count
            }
        }

        // 2) selections：每 (job,unit_key) 只计最高 revision 行。
        let selectionRows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.decision AS decision,
                       s.applied_receipt_id IS NOT NULL AS applied,
                       COUNT(*) AS n
                FROM ai_study_selections s
                JOIN ai_study_jobs j ON j.id = s.job_id
                JOIN (
                    SELECT job_id, unit_key,
                           MAX(selection_revision) AS maxRev
                    FROM ai_study_selections GROUP BY job_id, unit_key
                ) latest
                  ON latest.job_id = s.job_id
                 AND latest.unit_key = s.unit_key
                 AND latest.maxRev = s.selection_revision
                WHERE j.document_id = ?
                GROUP BY s.decision, applied
                """,
            arguments: [documentIDValue]
        )
        for row in selectionRows {
            let decision: String = row["decision"]
            let applied = (row["applied"] as Int) != 0
            let count: Int = row["n"]
            // applied ⊂ selected：先计入确认桶，再计入应用桶。
            switch decision {
            case "reuse": funnel.selectedReuse += count
            case "create": funnel.selectedCreate += count
            case "skip": funnel.selectedSkip += count
            case "tooEasy": funnel.selectedTooEasy += count
            default: funnel.selectedPending += count
            }
            if applied {
                switch decision {
                case "reuse": funnel.appliedReuse += count
                case "create": funnel.appliedCreate += count
                case "skip": funnel.appliedSkip += count
                case "tooEasy": funnel.appliedTooEasy += count
                default: break
                }
            }
        }

        // 3) jobs 按态计数。
        let jobRows = try Row.fetchAll(
            db,
            sql: """
                SELECT status, COUNT(*) AS n FROM ai_study_jobs
                WHERE document_id = ? GROUP BY status
                """,
            arguments: [documentIDValue]
        )
        for row in jobRows {
            let status: String = row["status"]
            let count: Int = row["n"]
            switch status {
            case "completed", "partiallyCompleted":
                funnel.completedJobs += count
            case "failed":
                funnel.failedJobs += count
            case "cancelled":
                funnel.cancelledJobs += count
            default:
                // pending/analyzing/waitingForAI/awaitingConfirmation/
                // applying/paused——活跃集。
                funnel.activeJobs += count
            }
        }

        return funnel
    }
}
