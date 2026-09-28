import Foundation
import GRDB

/// v0.7.0 S15 活用练习 schema（技术文档 §12 / §13 迁移表）。
///
/// **期望迁移标识符：`v21_conjugation_practice`**——v17/v18/v20 已被
/// 占用（v19_sentence_cloze 为 S12 预留位），最终编号由主 agent 统一
/// 排定。注册方式与 v17/v18 相同：主 agent 在 `OboeDatabaseSchema`
/// 的 `migrationIdentifiers` 追加标识符、switch 指向本 `migrate`，
/// 并把下列表名加入 `tableNames`（本任务不直接改 `OboeDatabase.swift`）：
///   conjugation_sessions, conjugation_practice_attempts
///
/// 隔离红线（技术文档 §12）：练习记录**不填虚构 cardID、不写
/// review_logs、不影响正式 streak/retention**——两表与调度/统计
/// 体系零 FK， attempt 只弱引用会话行。
///
/// - `conjugation_practice_attempts.event_id` UNIQUE 幂等（对齐
///   v16 `practice_attempts` 语义）：同 eventID + 同内容重放返回
///   已存行，内容冲突抛 `conflictingEventID`。
/// - lemma/reading/类别/形/accepted 答案全部快照入列——词典更新、
///   Note 删除、规则版本演进不抹历史题面（v8 备份记录
///   `conjugationPracticeAttempt` 由此表导出）。
/// - `undone_at_ms` 软删除撤销，不删行。
public enum GRDBConjugationSchema {
    public static let expectedMigrationIdentifier = "v21_conjugation_practice"
    public static let tableNames: [String] = [
        "conjugation_sessions", "conjugation_practice_attempts"
    ]

    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE conjugation_sessions (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                planned_question_count INTEGER NOT NULL
                    CHECK (planned_question_count >= 0),
                status TEXT NOT NULL CHECK (status IN
                    ('active', 'finished', 'abandoned')),
                started_at_ms INTEGER NOT NULL,
                finished_at_ms INTEGER
            );

            CREATE TABLE conjugation_practice_attempts (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
                session_id TEXT NOT NULL CHECK (length(session_id) = 36)
                    REFERENCES conjugation_sessions(id) ON DELETE CASCADE,
                question_id TEXT NOT NULL CHECK (length(question_id) = 36),
                lemma TEXT NOT NULL CHECK (length(trim(lemma)) > 0),
                reading TEXT,
                conjugation_class TEXT NOT NULL
                    CHECK (length(conjugation_class) > 0),
                form TEXT NOT NULL CHECK (length(form) > 0),
                rule_id TEXT NOT NULL CHECK (length(rule_id) > 0),
                prompt TEXT NOT NULL CHECK (length(prompt) > 0),
                expected_primary TEXT NOT NULL
                    CHECK (length(expected_primary) > 0),
                accepted_json TEXT NOT NULL CHECK (json_valid(accepted_json)),
                user_input TEXT NOT NULL,
                normalized_input TEXT NOT NULL,
                result TEXT NOT NULL
                    CHECK (result IN ('correct', 'incorrect')),
                matched_answer TEXT,
                duration_ms INTEGER NOT NULL CHECK (duration_ms >= 0),
                answered_at_ms INTEGER NOT NULL,
                undone_at_ms INTEGER,
                CHECK (result != 'correct' OR matched_answer IS NOT NULL)
            );

            CREATE INDEX conjugation_attempts_on_session
                ON conjugation_practice_attempts(session_id, answered_at_ms);
            CREATE INDEX conjugation_attempts_on_result
                ON conjugation_practice_attempts(result, answered_at_ms)
                WHERE undone_at_ms IS NULL;
            """)
    }
}
