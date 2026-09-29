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
