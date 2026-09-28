import Foundation
import GRDB

/// v23 `v23_learning_units`（v0.7.5 S04）：Learning Unit 六张表——
/// 义项身份、词典快照 alias、Note 关联、Too Easy flag、审计事件、
/// 存量迁移条目。
///
/// 注册方式与 v18/v22 相同：**M（主负责人）**在 `OboeDatabaseSchema` 的
/// `migrationIdentifiers` 追加 `"v23_learning_units"`（暂定编号，
/// D18 由 M 按合并顺序统一分配）、switch 指向本 `migrate`，并把
/// 下列表名加入 `tableNames`（本任务不直接改 `OboeDatabase.swift`）：
///   lexical_learning_units, learning_unit_dictionary_aliases,
///   learning_unit_note_links, learning_unit_flags,
///   learning_unit_events, learning_unit_migration_items
///
/// 契约依据（contracts-frozen rev2 §1/§6、技术文档 §3/§4）：
/// - `lexical_learning_units`：`identity_key` 全库 UNIQUE——同一可靠
///   义项只有一个 unit；`identity_kind` 三层（dictionarySense/
///   localNote/legacyUnresolved）；`sense_snapshot_json` 有界
///   （≤16 KiB 字符）+ `json_valid`；`binding_status` 四态；
///   `revision` 为 CAS 版本列。dictionarySense 完整性 CHECK：
///   provider/entry_id/fingerprint 三件套必须齐（对齐 lexemes 的
///   provider⇒entry_id 一致性写法）。
/// - `learning_unit_dictionary_aliases`：`(provider, dataset_version,
///   entry_id, sense_id)` UNIQUE——词典快照内精确定位，不 FK 词典文件；
///   unit 删除 CASCADE（绑定证据随身份陪葬）；`status` 四态含
///   `superseded`（rev2，历史被重绑替代的行）。
/// - `learning_unit_note_links`：PK(unit_id,note_id) + `note_id`
///   UNIQUE（一 Note 仅一有效 unit，D02）；`role='primary'` 部分唯一
///   索引实现「一 unit 至多一 primary」；unit/note 双 FK CASCADE。
/// - `learning_unit_flags`：PK/FK unit_id CASCADE；`too_easy` 0/1；
///   `revision` 承载 TooEasyCommand 的 CAS 与 Undo（§2.2）。无 Note
///   的 unit 也允许有 flag 行。
/// - `learning_unit_events`：`operation_id` UNIQUE 是幂等第三层锚点
///   （同 ID 重放不新增事件）；`unit_id` SET NULL + `unit_id_snapshot`
///   留史——unit 删除不抹事实；`kind` 六值对齐
///   `LearningUnitEventKind`（S07 冻结）；before/after JSON 可空
///   （如 `created` 无 before）+ `json_valid`；`undone_at_ms` 标记
///   已被 TooEasyUndo 撤销的事件。
/// - `learning_unit_migration_items`：`source_key` PK（旧数据来源稳定
///   键，回填幂等锚点）；note/lexeme/target_unit 引用全部
///   `ON DELETE SET NULL`——审计证据不随业务对象删除陪葬；
///   `evidence_json` 有界（≤32 KiB 字符）+ `json_valid`；不参与
///   运行态三态计算。
///
/// 枚举列存 rawValue 原文：role/alias.status/binding_status 用契约
/// 原文（`legacy_secondary`、`needsConfirmation` 等），origin/event
/// kind/migration status 用 camelCase（沿用 v18 枚举列约定）。
/// 通用约束：毫秒整数时间、小写 UUID、JSON 列 `json_valid`、枚举
/// CHECK（技术文档 §4 通用约束、contracts §6）。
public enum GRDBLearningUnitSchema {
    /// 期望迁移标识符——暂定 `v23_learning_units`（D18），主 agent
    /// 排号最终确定。
    public static let expectedMigrationIdentifier = "v23_learning_units"

    /// 本迁移新建的六张表（供注册方同步 `tableNames` 与测试断言）。
    public static let tableNames: [String] = [
        "lexical_learning_units",
        "learning_unit_dictionary_aliases",
        "learning_unit_note_links",
        "learning_unit_flags",
        "learning_unit_events",
        "learning_unit_migration_items",
    ]

    /// `sense_snapshot_json` 字符上界（有界义项快照——无正文/Prompt）。
    public static let senseSnapshotMaxLength = 16 * 1024
    /// `evidence_json` 字符上界。
    public static let migrationEvidenceMaxLength = 32 * 1024

    /// 建表（非幂等——重复执行 CREATE TABLE 会报已存在；幂等性由
    /// DatabaseMigrator 按标识符去重，与 v17–v22 各迁移同语义，D20）。
    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE lexical_learning_units (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                identity_kind TEXT NOT NULL CHECK (identity_kind IN
                    ('dictionarySense', 'localNote', 'legacyUnresolved')),
                identity_key TEXT NOT NULL UNIQUE
                    CHECK (length(identity_key) > 0),
                provider TEXT
                    CHECK (provider IS NULL OR length(provider) > 0),
                dictionary_entry_id INTEGER,
                semantic_fingerprint TEXT
                    CHECK (semantic_fingerprint IS NULL
                           OR length(semantic_fingerprint) = 64),
                fingerprint_version TEXT
                    CHECK (fingerprint_version IS NULL
                           OR length(fingerprint_version) > 0),
                lemma TEXT NOT NULL CHECK (length(trim(lemma)) > 0),
                reading TEXT,
                sense_snapshot_json TEXT
                    CHECK (sense_snapshot_json IS NULL
                           OR (json_valid(sense_snapshot_json)
                               AND length(sense_snapshot_json) <= 16384)),
                binding_status TEXT NOT NULL CHECK (binding_status IN
                    ('current', 'needsConfirmation', 'stale', 'legacy')),
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                CHECK (identity_kind != 'dictionarySense'
                       OR (provider IS NOT NULL
                           AND dictionary_entry_id IS NOT NULL
                           AND semantic_fingerprint IS NOT NULL))
            );

            CREATE INDEX learning_units_on_binding_status
                ON lexical_learning_units(binding_status, identity_kind);
            CREATE INDEX learning_units_on_entry
                ON lexical_learning_units(provider, dictionary_entry_id)
                WHERE dictionary_entry_id IS NOT NULL;

            CREATE TABLE learning_unit_dictionary_aliases (
                unit_id TEXT NOT NULL
                    REFERENCES lexical_learning_units(id) ON DELETE CASCADE
                    CHECK (length(unit_id) = 36),
                provider TEXT NOT NULL CHECK (provider IN ('jmdict')),
                dataset_version TEXT NOT NULL
                    CHECK (length(dataset_version) > 0),
                entry_id INTEGER NOT NULL,
                sense_id INTEGER NOT NULL,
                fingerprint TEXT NOT NULL CHECK (length(fingerprint) = 64),
                fingerprint_version TEXT NOT NULL
                    CHECK (length(fingerprint_version) > 0),
                status TEXT NOT NULL CHECK (status IN
                    ('current', 'needsConfirmation', 'stale', 'superseded')),
                resolved_at_ms INTEGER,
                UNIQUE (provider, dataset_version, entry_id, sense_id)
            );

            CREATE INDEX learning_unit_aliases_on_unit
                ON learning_unit_dictionary_aliases(unit_id);
            CREATE INDEX learning_unit_aliases_on_entry
                ON learning_unit_dictionary_aliases(provider, entry_id);

            CREATE TABLE learning_unit_note_links (
                unit_id TEXT NOT NULL
                    REFERENCES lexical_learning_units(id) ON DELETE CASCADE
                    CHECK (length(unit_id) = 36),
                note_id TEXT NOT NULL UNIQUE
                    REFERENCES notes(id) ON DELETE CASCADE
                    CHECK (length(note_id) = 36),
                role TEXT NOT NULL
                    CHECK (role IN ('primary', 'legacy_secondary')),
                origin TEXT NOT NULL CHECK (origin IN
                    ('manual', 'automaticHighConfidence', 'userConfirmed',
                     'aiPipeline', 'backfill', 'imported')),
                created_at_ms INTEGER NOT NULL,
                PRIMARY KEY (unit_id, note_id)
            ) WITHOUT ROWID;

            CREATE UNIQUE INDEX learning_unit_one_primary
                ON learning_unit_note_links(unit_id) WHERE role = 'primary';
            CREATE INDEX learning_unit_notes_by_unit
                ON learning_unit_note_links(unit_id, note_id);

            CREATE TABLE learning_unit_flags (
                unit_id TEXT PRIMARY KEY NOT NULL
                    REFERENCES lexical_learning_units(id) ON DELETE CASCADE
                    CHECK (length(unit_id) = 36),
                too_easy INTEGER NOT NULL CHECK (too_easy IN (0, 1)),
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                updated_at_ms INTEGER NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE learning_unit_events (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                operation_id TEXT NOT NULL UNIQUE
                    CHECK (length(operation_id) = 36),
                unit_id TEXT
                    REFERENCES lexical_learning_units(id) ON DELETE SET NULL
                    CHECK (unit_id IS NULL OR length(unit_id) = 36),
                unit_id_snapshot TEXT NOT NULL
                    CHECK (length(unit_id_snapshot) = 36),
                kind TEXT NOT NULL CHECK (kind IN
                    ('created', 'migrated', 'tooEasySet', 'tooEasyUndone',
                     'noteLinked', 'noteUnlinked')),
                before_json TEXT
                    CHECK (before_json IS NULL OR json_valid(before_json)),
                after_json TEXT
                    CHECK (after_json IS NULL OR json_valid(after_json)),
                payload_hash TEXT
                    CHECK (payload_hash IS NULL OR length(payload_hash) > 0),
                created_at_ms INTEGER NOT NULL,
                undone_at_ms INTEGER
            );

            CREATE INDEX learning_unit_events_on_unit
                ON learning_unit_events(unit_id, created_at_ms);
            CREATE INDEX learning_unit_events_on_kind
                ON learning_unit_events(kind, created_at_ms);

            CREATE TABLE learning_unit_migration_items (
                source_key TEXT PRIMARY KEY NOT NULL
                    CHECK (length(source_key) > 0),
                note_id TEXT
                    REFERENCES notes(id) ON DELETE SET NULL
                    CHECK (note_id IS NULL OR length(note_id) = 36),
                legacy_lexeme_id TEXT
                    REFERENCES lexemes(id) ON DELETE SET NULL
                    CHECK (legacy_lexeme_id IS NULL
                           OR length(legacy_lexeme_id) = 36),
                old_state TEXT,
                status TEXT NOT NULL CHECK (status IN
                    ('pending', 'applied', 'needsConfirmation',
                     'skipped', 'failed')),
                evidence_json TEXT
                    CHECK (evidence_json IS NULL
                           OR (json_valid(evidence_json)
                               AND length(evidence_json) <= 32768)),
                target_unit_id TEXT
                    REFERENCES lexical_learning_units(id) ON DELETE SET NULL
                    CHECK (target_unit_id IS NULL
                           OR length(target_unit_id) = 36),
                last_error TEXT
            ) WITHOUT ROWID;

            CREATE INDEX learning_unit_migration_items_on_status
                ON learning_unit_migration_items(status);
            CREATE INDEX learning_unit_migration_items_on_note
                ON learning_unit_migration_items(note_id);
            """)
    }
}
