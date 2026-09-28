import Foundation
import GRDB

/// v0.7.0 S17：CSV/TSV 导入执行的持久化 schema（§10.3）。
///
/// 本文件只含迁移函数本体；主 agent 在 `OboeDatabaseSchema` 以
/// `"v20_import_execution"` 注册（v18/v19 为并行步骤的槽位）。
/// 测试里用 `OboeDatabaseSchema.makeMigrator(applying:)` 之后
/// 显式调用 `GRDBImportSchema.migrate` 直接建表。
///
/// 设计要点：
/// - `import_jobs`：job 级元数据。`staging_file_name` 只存文件名
///   （`import-staging-<uuid>.sqlite` 形式），绝不存绝对路径——恢复时由
///   调用方在受控 staging 目录内按文件名重定位；`staging_fingerprint`
///   （SHA-256）+ `file_hash` 一起做续跑校验（§10.3「崩溃后有
///   staging+hash 才允许续传」）。
/// - `import_row_receipts`：`(job_id, logical_row)` 唯一，行级幂等；
///   `target_note_id` 用 `ON DELETE SET NULL`——Note 事后删除不清除
///   回执明细。`detail` 承载失败原因/冲突说明（契约模型无该字段，
///   属实现侧增量，不进 Domain）。
/// - 两表都不进入 backup（原始 CSV 与 staging 同样不入备份，§10.3）。
///   backup 记录排除在 PortableBackupPackageExporter 的表清单里，
///   由该组件自己的白名单保证。
public enum GRDBImportSchema {

    public static let jobTableName = "import_jobs"
    public static let receiptTableName = "import_row_receipts"

    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS import_jobs (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                file_hash TEXT NOT NULL,
                mapping_hash TEXT NOT NULL,
                policy TEXT NOT NULL
                    CHECK (policy IN ('skip', 'update', 'mergeTags')),
                target_deck_id TEXT NOT NULL
                    REFERENCES decks(id) ON DELETE RESTRICT,
                status TEXT NOT NULL
                    CHECK (status IN (
                        'previewed', 'running', 'cancelled',
                        'interrupted', 'completed', 'failed'
                    )),
                staging_file_name TEXT,
                staging_fingerprint TEXT,
                row_count INTEGER,
                committed_rows INTEGER NOT NULL DEFAULT 0
                    CHECK (committed_rows >= 0),
                mapping_summary TEXT,
                failure_reason TEXT,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS import_row_receipts (
                job_id TEXT NOT NULL
                    REFERENCES import_jobs(id) ON DELETE CASCADE,
                logical_row INTEGER NOT NULL CHECK (logical_row >= 1),
                payload_digest TEXT NOT NULL,
                action TEXT NOT NULL
                    CHECK (action IN (
                        'created', 'updated', 'mergedTags',
                        'skipped', 'failed'
                    )),
                target_note_id TEXT
                    REFERENCES notes(id) ON DELETE SET NULL,
                detail TEXT,
                created_at_ms INTEGER NOT NULL,
                PRIMARY KEY (job_id, logical_row)
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS import_row_receipts_on_job
                ON import_row_receipts(job_id, logical_row);
            """)
    }
}
