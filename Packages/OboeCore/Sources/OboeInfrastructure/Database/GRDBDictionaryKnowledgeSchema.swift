import Foundation
import GRDB

/// v22 `v22_dictionary_knowledge`（v0.7.0 S19 / 设计 §词典2.0）：
/// 词典产物校验台账 + lexeme→entry 分层绑定记录。
///
/// 注册方式与 v18/v21 相同：主 agent 在 `OboeDatabaseSchema` 的
/// `migrationIdentifiers` 追加 `"v22_dictionary_knowledge"`、switch
/// 指向本 `migrate`，并把下列表名加入 `tableNames`（本任务不直接改
/// `OboeDatabase.swift`）：
///   dictionary_artifact_records, lexeme_dictionary_bindings
///
/// 语义要点：
/// - `dictionary_artifact_records`：每次词典完整性核验一行，
///  `file_sha256` UNIQUE——同一字节产物重复核验只更新
///  `last_verified_at_ms`（幂等台账）；`dataset_version` 是语义版本
///  （换库检测键），`file_sha256` 是字节级身份。
/// - `lexeme_dictionary_bindings`：jmdict lexeme 的当前绑定事实——
///  `match_tier` 记录最初命中层级（exactWritten/exactReading/
///  deinflected/sourceContext；`verifiedExisting` 只标记 v22 前
///  无层级信息、经原 entry 核验确认的存量绑定）。
///  换库重绑只在原层级内进行：同层唯一命中才更新 `entry_id`
///  （并同步 `lexemes.entry_id`）；零命中 `stale`、多命中
///  `ambiguousAwaiting` 都保留旧值不静默换绑。
/// - `lexeme_id` FK CASCADE：lexeme 删除则绑定失效（与
///  `lexeme_note_links` 同语义）。
/// - `detail` 存机器可读原因：`entry_missing`/`surface_mismatch`/
///  `no_same_tier_match`/`ambiguous:<n>` 等。
public enum GRDBDictionaryKnowledgeSchema {
    /// 期望迁移标识符——主 agent 排号最终确定。
    public static let expectedMigrationIdentifier = "v22_dictionary_knowledge"

    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE dictionary_artifact_records (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                file_sha256 TEXT NOT NULL UNIQUE
                    CHECK (length(file_sha256) = 64),
                byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
                schema_version TEXT NOT NULL CHECK (length(schema_version) > 0),
                dataset_version TEXT NOT NULL CHECK (length(dataset_version) > 0),
                dictionary_version TEXT NOT NULL DEFAULT '',
                chinese_layer_version TEXT,
                zh_alignment_rate REAL,
                verification_status TEXT NOT NULL CHECK (
                    verification_status IN
                        ('verified', 'checksumMismatch', 'unreadable')),
                first_seen_at_ms INTEGER NOT NULL,
                last_verified_at_ms INTEGER NOT NULL
            );

            CREATE INDEX dictionary_artifact_records_on_dataset
                ON dictionary_artifact_records(dataset_version,
                                               last_verified_at_ms);

            CREATE TABLE lexeme_dictionary_bindings (
                lexeme_id TEXT PRIMARY KEY NOT NULL
                    REFERENCES lexemes(id) ON DELETE CASCADE
                    CHECK (length(lexeme_id) = 36),
                entry_id INTEGER NOT NULL,
                match_tier TEXT NOT NULL CHECK (match_tier IN (
                    'sourceContext', 'exactWritten', 'exactReading',
                    'deinflected', 'verifiedExisting')),
                dataset_version TEXT NOT NULL CHECK (length(dataset_version) > 0),
                status TEXT NOT NULL CHECK (status IN (
                    'current', 'stale', 'ambiguousAwaiting')),
                detail TEXT,
                resolved_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            ) WITHOUT ROWID;

            CREATE INDEX lexeme_dictionary_bindings_on_status
                ON lexeme_dictionary_bindings(status, match_tier);
            CREATE INDEX lexeme_dictionary_bindings_on_dataset
                ON lexeme_dictionary_bindings(dataset_version);
            """)
    }
}
