import Foundation
import GRDB

/// v26 `learning_metrics`（v0.7.5 S20 前置，contracts §6 / 技术文档
/// §4）：`reader_learning_coverage_snapshots`——独立于旧
/// `reader_coverage_snapshots` 的新指标快照，承载
/// `coverage-resolved-sense-2.0.0` 度量（S14 `ReaderCoverageV2`）。
///
/// 设计要点：
/// - `document_id` 弱引用 SET NULL、`document_id_snapshot` 原文快照
///   并存——文档删除后历史快照仍可解释（D09 分段语义）。
/// - 唯一键：`document_id_snapshot + scope_hash + content_revision +
///   knowledge_revision + metric_version + dictionary_version +
///   morphology_version + analyzed_blocks`——同一度量上下文不重复
///   落快照（幂等写入锚点）。
/// - 计数列全部非负 CHECK；分母语义在领域层（空分母不落快照）。
/// - v9 备份白名单已含本表全部列（PortableBackupFormatV9
///   `readerLearningCoverageSnapshot`）。
public enum GRDBLearningMetricsSchema {
    public static let expectedMigrationIdentifier = "v26_learning_metrics"

    public static let tableNames: [String] = [
        "reader_learning_coverage_snapshots"
    ]

    /// 建表（非幂等——幂等性由 DatabaseMigrator 按标识符去重）。
    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE reader_learning_coverage_snapshots (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                document_id TEXT REFERENCES reader_documents(id)
                    ON DELETE SET NULL,
                document_id_snapshot TEXT NOT NULL,
                scope_hash TEXT NOT NULL
                    CHECK (length(scope_hash) > 0),
                content_revision INTEGER NOT NULL,
                knowledge_revision INTEGER NOT NULL,
                metric_version TEXT NOT NULL
                    CHECK (length(metric_version) > 0),
                dictionary_version TEXT NOT NULL,
                morphology_version TEXT NOT NULL,
                resolved_unique INTEGER NOT NULL
                    CHECK (resolved_unique >= 0),
                unknown_unique INTEGER NOT NULL
                    CHECK (unknown_unique >= 0),
                learning_unique INTEGER NOT NULL
                    CHECK (learning_unique >= 0),
                mastered_unique INTEGER NOT NULL
                    CHECK (mastered_unique >= 0),
                pending_occurrences INTEGER NOT NULL
                    CHECK (pending_occurrences >= 0),
                oov_occurrences INTEGER NOT NULL
                    CHECK (oov_occurrences >= 0),
                analyzed_blocks INTEGER NOT NULL
                    CHECK (analyzed_blocks >= 0),
                total_blocks INTEGER NOT NULL
                    CHECK (total_blocks >= 0),
                calculated_at_ms INTEGER NOT NULL,
                UNIQUE(document_id_snapshot, scope_hash, content_revision,
                       knowledge_revision, metric_version,
                       dictionary_version, morphology_version,
                       analyzed_blocks)
            );

            CREATE INDEX reader_learning_coverage_by_document
                ON reader_learning_coverage_snapshots(
                    document_id, calculated_at_ms);
            """)
    }
}
