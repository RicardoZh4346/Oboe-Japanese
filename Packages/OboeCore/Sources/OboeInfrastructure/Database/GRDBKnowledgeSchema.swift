import Foundation
import GRDB

/// v18 `v18_lexical_knowledge`（v0.7.0，设计 §6.3 / §11.2 / §13 迁移表、
/// contracts-frozen §3）：lexical identity、Note 关联、人工 override、
/// Reader 活动事件、operation receipt、覆盖率快照。
///
/// 注册方式与 v17 相同：主 agent 在 `OboeDatabaseSchema` 的
/// `migrationIdentifiers` 追加 `"v18_lexical_knowledge"`、switch 里
/// 指向本 `migrate`，并把下列表名加入 `tableNames`（本任务不直接改
/// `OboeDatabase.swift`）：
///   lexemes, lexeme_note_links, vocabulary_knowledge_overrides,
///   reader_activity_events, reader_mining_receipts,
///   reader_coverage_snapshots
///
/// 语义要点：
/// - `lexemes.identity_key` 全库唯一（provider + ent_seq/local 编码 +
///   规范化表记/读音，`LexicalIdentityKey` 单一实现点）；dataset
///   version 只作 provenance，不进 key——词典更新不冲掉已知状态。
/// - `lexeme_note_links` 双 FK CASCADE：Note 删除/lexeme 删除都使
///   关联失效，lexeme 行本身保留（§6.3：卡暂停/Note 删除后由真值表
///   回落，lexeme 是身份载体不陪葬）。
/// - `vocabulary_knowledge_overrides` 只存 known|ignored 两态；
///   reset = 删行。
/// - `reader_activity_events` 三引用全部 `ON DELETE SET NULL`
///   （弱引用 + 快照字段——卡/原文删除不抹历史事实，§11.2）；
///   `operation_id` UNIQUE 承载「重复点击返回同 receipt 不新增事件」。
/// - `reader_mining_receipts` 是 Reader 域通用 operation 级幂等表
///   （挖词/关联/知识写共用，kind 区分操作类型）。
/// - `reader_coverage_snapshots` 的 document_id/chapter_id 是**无 FK
///   弱引用**（文档删除后历史快照仍可聚合——标题等已快照）。
/// - 枚举列一律存 Swift rawValue 原文（camelCase），保证冻结枚举
///   `LexemeNoteLink.AssociationOrigin`/`ReaderActivityKind` 无损往返；
///   区别于库内蛇形风格是有意为之（解码即 rawValue 初始化）。
public enum GRDBKnowledgeSchema {
    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE lexemes (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                provider TEXT NOT NULL CHECK (provider IN ('jmdict', 'local')),
                external_id TEXT NOT NULL CHECK (length(external_id) > 0),
                entry_id INTEGER,
                written_form TEXT NOT NULL
                    CHECK (length(trim(written_form)) > 0),
                reading TEXT,
                normalized_lemma TEXT NOT NULL
                    CHECK (length(normalized_lemma) > 0),
                pos_family TEXT,
                identity_key TEXT NOT NULL UNIQUE
                    CHECK (length(identity_key) > 0),
                dictionary_version_at_resolution TEXT,
                resolution_status TEXT NOT NULL CHECK (resolution_status IN
                    ('resolved', 'ambiguous', 'unresolved')),
                created_at_ms INTEGER NOT NULL,
                CHECK (provider != 'jmdict' OR entry_id IS NOT NULL)
            );

            CREATE INDEX lexemes_on_entry
                ON lexemes(provider, entry_id) WHERE entry_id IS NOT NULL;
            CREATE INDEX lexemes_on_written_form ON lexemes(written_form);

            CREATE TABLE lexeme_note_links (
                lexeme_id TEXT NOT NULL
                    REFERENCES lexemes(id) ON DELETE CASCADE,
                note_id TEXT NOT NULL
                    REFERENCES notes(id) ON DELETE CASCADE,
                association_origin TEXT NOT NULL CHECK (association_origin IN
                    ('automaticHighConfidence', 'userConfirmed',
                     'backfill', 'imported')),
                confidence REAL
                    CHECK (confidence IS NULL
                           OR (confidence >= 0 AND confidence <= 1)),
                created_at_ms INTEGER NOT NULL,
                PRIMARY KEY (lexeme_id, note_id)
            ) WITHOUT ROWID;

            CREATE INDEX lexeme_note_links_on_note
                ON lexeme_note_links(note_id);

            CREATE TABLE vocabulary_knowledge_overrides (
                lexeme_id TEXT PRIMARY KEY NOT NULL
                    REFERENCES lexemes(id) ON DELETE CASCADE,
                state TEXT NOT NULL CHECK (state IN ('known', 'ignored')),
                updated_at_ms INTEGER NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE reader_activity_events (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                operation_id TEXT NOT NULL UNIQUE CHECK (length(operation_id) = 36),
                kind TEXT NOT NULL CHECK (kind IN (
                    'minedNewNote', 'linkedExistingNote', 'createdCloze',
                    'markedKnown', 'resetKnowledge')),
                lexeme_id TEXT
                    REFERENCES lexemes(id) ON DELETE SET NULL,
                note_id TEXT
                    REFERENCES notes(id) ON DELETE SET NULL,
                document_id TEXT
                    REFERENCES reader_documents(id) ON DELETE SET NULL,
                snapshot_json TEXT
                    CHECK (snapshot_json IS NULL OR json_valid(snapshot_json)),
                created_at_ms INTEGER NOT NULL,
                undone_at_ms INTEGER
            );

            CREATE INDEX reader_activity_events_on_kind_time
                ON reader_activity_events(kind, created_at_ms);
            CREATE INDEX reader_activity_events_on_lexeme
                ON reader_activity_events(lexeme_id);
            CREATE INDEX reader_activity_events_on_note
                ON reader_activity_events(note_id);
            CREATE INDEX reader_activity_events_on_document
                ON reader_activity_events(document_id);

            CREATE TABLE reader_mining_receipts (
                operation_id TEXT PRIMARY KEY NOT NULL
                    CHECK (length(operation_id) = 36),
                kind TEXT NOT NULL CHECK (kind IN (
                    'mine_vocabulary', 'link_existing_note', 'create_cloze',
                    'knowledge_override', 'knowledge_link',
                    'knowledge_unlink', 'knowledge_add_to_learning',
                    'lexeme_backfill')),
                payload_hash TEXT NOT NULL CHECK (length(payload_hash) > 0),
                result_json TEXT NOT NULL CHECK (json_valid(result_json)),
                committed_at_ms INTEGER NOT NULL
            );

            CREATE INDEX reader_mining_receipts_on_kind
                ON reader_mining_receipts(kind, committed_at_ms);

            CREATE TABLE reader_coverage_snapshots (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                document_id TEXT NOT NULL,
                document_title TEXT NOT NULL DEFAULT '',
                scope_key TEXT NOT NULL CHECK (length(scope_key) > 0),
                chapter_id TEXT,
                content_hash TEXT NOT NULL CHECK (length(content_hash) > 0),
                metric_version TEXT NOT NULL CHECK (length(metric_version) > 0),
                morphology_version TEXT NOT NULL
                    CHECK (length(morphology_version) > 0),
                dictionary_version TEXT,
                known_count INTEGER NOT NULL CHECK (known_count >= 0),
                learning_count INTEGER NOT NULL CHECK (learning_count >= 0),
                unknown_count INTEGER NOT NULL CHECK (unknown_count >= 0),
                ignored_count INTEGER NOT NULL CHECK (ignored_count >= 0),
                unique_numerator INTEGER NOT NULL CHECK (unique_numerator >= 0),
                unique_denominator INTEGER NOT NULL
                    CHECK (unique_denominator >= 0),
                analyzed_blocks INTEGER NOT NULL CHECK (analyzed_blocks >= 0),
                total_blocks INTEGER NOT NULL CHECK (total_blocks >= 0),
                study_day_id TEXT NOT NULL CHECK (length(study_day_id) > 0),
                created_at_ms INTEGER NOT NULL,
                CHECK (analyzed_blocks <= total_blocks),
                UNIQUE (document_id, scope_key, study_day_id,
                        metric_version, morphology_version)
            );

            CREATE INDEX reader_coverage_snapshots_on_study_day
                ON reader_coverage_snapshots(study_day_id);
            """)
    }
}
