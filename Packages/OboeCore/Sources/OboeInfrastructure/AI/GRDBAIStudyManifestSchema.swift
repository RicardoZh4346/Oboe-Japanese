import Foundation
import GRDB

/// v27 `ai_study_manifests`（v0.7.5 S15 准备/预检/预览/摘要）。
///
/// 一张表：`ai_study_job_manifests` 存 Job 的**冻结 planner 输入**
/// （`AIStudyJobManifest` JSON BLOB）——§9.1「Runner 恢复必须用
/// 确定性 planner 输出」的落地面：replan 只认清单，不认届时
/// 词典/系统/token 缓存状态，保证 requestHash 逐字节重建。
///
/// 备份 v9 语义：**本机执行态**，不在导出白名单（与 `ai_study_cache`
/// 同属 `aiStudyRuntime` 排除域）——恢复包的 Job 无清单时按
/// missingSource 拒绝续跑，不静默重算。`ON DELETE CASCADE` 随 Job
/// 陪葬（Job 删除则清单无独立价值）。
public enum GRDBAIStudyManifestSchema {
    public static let expectedMigrationIdentifier = "v27_ai_study_manifests"

    public static let tableNames: [String] = [
        "ai_study_job_manifests"
    ]

    /// 清单载荷上界（32 MiB——全书级 JSON；超界由 CHECK 拒绝，
    /// 调用方落 failed 而不截断写）。
    public static let manifestMaxBytes = 32 * 1024 * 1024

    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE ai_study_job_manifests (
                job_id TEXT PRIMARY KEY NOT NULL
                    CHECK (length(job_id) = 36)
                    REFERENCES ai_study_jobs(id) ON DELETE CASCADE,
                manifest BLOB NOT NULL
                    CHECK (length(manifest) <= 33554432),
                created_at_ms INTEGER NOT NULL
            );
            """)
    }
}
