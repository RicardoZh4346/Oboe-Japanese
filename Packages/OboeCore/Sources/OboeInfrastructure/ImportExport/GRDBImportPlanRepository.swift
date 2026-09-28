import Foundation
import GRDB
import OboeDomain

/// v0.7.0 S17：`ImportPlanRepository` 的 GRDB 实现（§10.3）。
///
/// 职责边界：job/receipt 的持久化读写。执行器在批事务里经
/// `insertReceipt(_:detail:in:)` 与同事务落 receipt——不走这里的
/// async 公开方法（协议方法留给外部/测试的独立写入）。
public struct GRDBImportPlanRepository: ImportPlanRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    // MARK: - ImportPlanRepository（冻结契约）

    public func createJob(_ job: ImportJob) async throws {
        let now = try DatabaseValueCodec.encode(job.createdAt)
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO import_jobs(
                        id, file_hash, mapping_hash, policy, target_deck_id,
                        status, committed_rows, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(job.id),
                    job.fileHash,
                    job.mappingHash,
                    job.policy.rawValue,
                    DatabaseValueCodec.encode(job.targetDeckID),
                    job.status.rawValue,
                    now,
                    now
                ]
            )
        }
    }

    public func fetchJob(id: UUID) async throws -> ImportJob? {
        try await pool.read { db in
            try Self.decodeJobRow(
                Row.fetchOne(
                    db,
                    sql: "SELECT * FROM import_jobs WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(id)]
                )
            )
        }
    }

    public func updateJobStatus(id: UUID, status: ImportJobStatus) async throws {
        try await pool.write { db in
            _ = try Self.updateJobStatus(
                id: id,
                status: status,
                updatedAtMilliseconds: DatabaseValueCodec.encode(Date()),
                in: db
            )
        }
    }

    public func recordReceipts(_ receipts: [ImportRowReceipt]) async throws {
        try await pool.write { db in
            for receipt in receipts {
                try Self.insertReceipt(
                    receipt,
                    detail: nil,
                    createdAtMilliseconds: DatabaseValueCodec.encode(Date()),
                    in: db
                )
            }
        }
    }

    public func completedRowNumbers(jobID: UUID) async throws -> Set<Int> {
        try await pool.read { db in
            try Set(Int.fetchAll(
                db,
                sql: "SELECT logical_row FROM import_row_receipts WHERE job_id = ?",
                arguments: [DatabaseValueCodec.encode(jobID)]
            ))
        }
    }

    // MARK: - Job 扩展状态（契约模型之外的执行字段）

    /// 契约 `ImportJob` 之外的持久化字段（staging 引用/进度/失败原因）。
    public struct JobDetail: Equatable, Sendable {
        public let job: ImportJob
        /// staging 文件名（相对 `OboeImportStaging` 目录；绝不存绝对路径）。
        public let stagingFileName: String?
        /// staging 文件 SHA-256（续跑校验）。
        public let stagingFingerprint: String?
        /// 预检行数。
        public let rowCount: Int?
        /// 已提交行数（= receipt 计数快照；崩溃恢复后据此显示进度）。
        public let committedRows: Int
        /// 映射参数摘要 JSON（供恢复 UI 展示）。
        public let mappingSummary: String?
        public let failureReason: String?

        public init(
            job: ImportJob,
            stagingFileName: String?,
            stagingFingerprint: String?,
            rowCount: Int?,
            committedRows: Int,
            mappingSummary: String?,
            failureReason: String?
        ) {
            self.job = job
            self.stagingFileName = stagingFileName
            self.stagingFingerprint = stagingFingerprint
            self.rowCount = rowCount
            self.committedRows = committedRows
            self.mappingSummary = mappingSummary
            self.failureReason = failureReason
        }
    }

    public func fetchJobDetail(id: UUID) async throws -> JobDetail? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM import_jobs WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            ) else { return nil }
            guard let job = try Self.decodeJobRow(row) else { return nil }
            return JobDetail(
                job: job,
                stagingFileName: row["staging_file_name"],
                stagingFingerprint: row["staging_fingerprint"],
                rowCount: row["row_count"],
                committedRows: row["committed_rows"],
                mappingSummary: row["mapping_summary"],
                failureReason: row["failure_reason"]
            )
        }
    }

    /// 绑定 staging（文件名 + 指纹 + 行数 + 映射摘要）。预检完成后调用。
    public func attachStagingInfo(
        jobID: UUID,
        stagingFileName: String,
        stagingFingerprint: String,
        rowCount: Int,
        mappingSummary: String?
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE import_jobs
                    SET staging_file_name = ?, staging_fingerprint = ?,
                        row_count = ?, mapping_summary = ?, updated_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    stagingFileName,
                    stagingFingerprint,
                    rowCount,
                    mappingSummary,
                    DatabaseValueCodec.encode(Date()),
                    DatabaseValueCodec.encode(jobID)
                ]
            )
        }
    }

    public func markFailed(id: UUID, reason: String) async throws {
        try await pool.write { db in
            let now = try DatabaseValueCodec.encode(Date())
            try db.execute(
                sql: """
                    UPDATE import_jobs
                    SET status = 'failed', failure_reason = ?, updated_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [reason, now, DatabaseValueCodec.encode(id)]
            )
        }
    }

    // MARK: - Receipt 明细（summary/导出/回放入口）

    /// receipt 行 + 实现侧 `detail`（失败原因等，不进契约模型）。
    public struct ReceiptDetail: Equatable, Sendable {
        public let receipt: ImportRowReceipt
        public let detail: String?

        public init(receipt: ImportRowReceipt, detail: String?) {
            self.receipt = receipt
            self.detail = detail
        }
    }

    public func fetchReceiptDetails(jobID: UUID) async throws -> [ReceiptDetail] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT job_id, logical_row, payload_digest, action,
                           target_note_id, detail
                    FROM import_row_receipts
                    WHERE job_id = ? ORDER BY logical_row
                    """,
                arguments: [DatabaseValueCodec.encode(jobID)]
            ).map { row in
                ReceiptDetail(
                    receipt: try Self.decodeReceiptRow(row),
                    detail: row["detail"]
                )
            }
        }
    }

    // MARK: - 事务内共享写路径（S17 执行器批事务复用）

    /// 批事务内落 receipt。`INSERT`（非 IGNORE）：`(job_id, logical_row)`
    /// 撞键意味着执行器逻辑漏洞——宁可让批回滚也不静默覆盖幂等记录。
    static func insertReceipt(
        _ receipt: ImportRowReceipt,
        detail: String?,
        createdAtMilliseconds: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO import_row_receipts(
                    job_id, logical_row, payload_digest, action,
                    target_note_id, detail, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(receipt.jobID),
                receipt.logicalRowNumber,
                receipt.payloadDigest,
                receipt.action.rawValue,
                receipt.targetNoteID.map(DatabaseValueCodec.encode),
                detail,
                createdAtMilliseconds
            ]
        )
    }

    /// 批事务内推进 `committed_rows`（与 receipt 同原子性）。
    static func setCommittedRows(
        jobID: UUID,
        committedRows: Int,
        updatedAtMilliseconds: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE import_jobs
                SET committed_rows = ?, updated_at_ms = ?
                WHERE id = ?
                """,
            arguments: [
                committedRows,
                updatedAtMilliseconds,
                DatabaseValueCodec.encode(jobID)
            ]
        )
    }

    /// 批事务外状态迁移（cancelled/completed/interrupted/running）。
    @discardableResult
    static func updateJobStatus(
        id: UUID,
        status: ImportJobStatus,
        updatedAtMilliseconds: Int64,
        in db: Database
    ) throws -> Bool {
        try db.execute(
            sql: "UPDATE import_jobs SET status = ?, updated_at_ms = ? WHERE id = ?",
            arguments: [
                status.rawValue,
                updatedAtMilliseconds,
                DatabaseValueCodec.encode(id)
            ]
        )
        return db.changesCount > 0
    }

    // MARK: - 解码

    static func decodeJobRow(_ row: Row?) throws -> ImportJob? {
        guard let row else { return nil }
        let idValue: String = row["id"]
        let policyValue: String = row["policy"]
        let statusValue: String = row["status"]
        let deckValue: String = row["target_deck_id"]
        guard let policy = DuplicatePolicy(rawValue: policyValue),
              let status = ImportJobStatus(rawValue: statusValue) else {
            throw DatabaseError(message: "corrupt import_jobs row for \(idValue)")
        }
        return ImportJob(
            id: try DatabaseValueCodec.decodeUUID(idValue),
            fileHash: row["file_hash"],
            mappingHash: row["mapping_hash"],
            policy: policy,
            targetDeckID: try DatabaseValueCodec.decodeUUID(deckValue),
            status: status,
            createdAt: DatabaseValueCodec.decodeDate(milliseconds: row["created_at_ms"])
        )
    }

    static func decodeReceiptRow(_ row: Row) throws -> ImportRowReceipt {
        let jobIDValue: String = row["job_id"]
        let actionValue: String = row["action"]
        guard let action = ImportRowReceipt.Action(rawValue: actionValue) else {
            throw DatabaseError(message: "corrupt import_row_receipts action \(actionValue)")
        }
        let targetValue: String? = row["target_note_id"]
        return ImportRowReceipt(
            jobID: try DatabaseValueCodec.decodeUUID(jobIDValue),
            logicalRowNumber: row["logical_row"],
            payloadDigest: row["payload_digest"],
            action: action,
            targetNoteID: try targetValue.map(DatabaseValueCodec.decodeUUID)
        )
    }
}
