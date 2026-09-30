import Foundation
import GRDB

/// v25 `ai_study_pipeline`（v0.7.5 S11，contracts-frozen §6 / 技术
/// 文档 §4 表冻结清单 / S11 领域模型字段映射）。
///
/// 八张表，四组职责：
///
/// - `reader_study_occurrences`：Reader 原文中每个已分析 token 的
///   解析锚点——(document, content_revision, locator_json, range,
///   tokenizer_version) 唯一；`unit_id` SET NULL（unit 删除不抹
///   occurrence 证据）、document CASCADE；`resolution_id` 弱引用
///   `ai_study_resolutions`（不设 FK——resolution 是审计行，业务
///   删除不级联）。`resolution_status` 取值复用
///   `AIStudyResolutionStatus` 词汇外加 `pending`（已分析未解析）
///   ——S15/S17 使用方复核该值集。
/// - `reader_translation_blocks`：段落译文历史——
///   UNIQUE(document_id,locator_key,source_hash,language,
///   translation_revision)；部分唯一 `(document_id,locator_key,
///   language) WHERE is_current=1` 保证一块一译文当前值；
///   prompt_version/request_hash 记录生成证据；document CASCADE。
/// - `ai_study_jobs` / `ai_study_job_blocks` / `ai_study_resolutions` /
///   `ai_study_selections` / `ai_study_receipts`：Job 十态/块十一态
///   枚举与 `AIStudyJobModels` 领域转移表一一对应；
///   `ai_study_jobs` 部分唯一 `(document_id, content_revision)
///   WHERE status 非终态`——同一文档修订至多一个活跃 Job；Job 上
///   的 processed/applied/confirmed/failed 四个计数列是**派生
///   冗余**（可随时由 blocks/resolutions 重算修复），v9 白名单
///   刻意不导出——恢复落默认值后由 Runner 重算，语义不破坏；
///   块 `UNIQUE(job_id, subblock_key)` + ready 索引（job 内按
///   status/next_retry 派发）；resolution `(request_hash,token_key,
///   revision)` 唯一；selection `PK(job_id,selection_revision,
///   unit_key)`；receipt `operation_id` PK + `action_key` UNIQUE。
/// - `ai_study_cache`：**本机表**——request_hash PK + LRU
///   （last_accessed_at_ms 支撑逐出）；不入备份白名单、不导 v9。
///
/// 通用约束（§6）：毫秒整数时间、小写 UUID、JSON 列 json_valid、
/// 枚举 CHECK、弱引用仅 block_id/result_id/resolution_id/
/// applied_receipt_id 不设 FK。`lease_epoch` 是本机并发租约
/// （§9.2），不入备份。
public enum GRDBAIStudyPipelineSchema {
    public static let expectedMigrationIdentifier = "v25_ai_study_pipeline"

    /// 本迁移新建的八张表（供注册方同步 `tableNames` 与测试断言）。
    /// `ai_study_cache` 虽不入备份，但属本 schema 的表清单。
    public static let tableNames: [String] = [
        "reader_study_occurrences",
        "reader_translation_blocks",
        "ai_study_jobs",
        "ai_study_job_blocks",
        "ai_study_resolutions",
        "ai_study_selections",
        "ai_study_receipts",
        "ai_study_cache",
    ]

    /// JSON 列字符上界（scope/snapshot/outcome/locator 有界，§6）。
    public static let jsonColumnMaxLength = 256 * 1024
    /// 译文行字符上界（整段译文+证据，远超单块输出预算仍受控）。
    public static let translatedTextMaxLength = 1 * 1024 * 1024

    /// 建表（非幂等——与全部已发布迁移一致，幂等性由
    /// DatabaseMigrator 按标识符去重，D20）。
    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE reader_study_occurrences (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                document_id TEXT NOT NULL
                    REFERENCES reader_documents(id) ON DELETE CASCADE,
                content_revision INTEGER NOT NULL,
                locator_json TEXT NOT NULL
                    CHECK (json_valid(locator_json)
                           AND length(locator_json) <= 8192),
                block_source_hash TEXT NOT NULL,
                tokenizer_version TEXT NOT NULL,
                start_utf16 INTEGER NOT NULL CHECK (start_utf16 >= 0),
                length_utf16 INTEGER NOT NULL CHECK (length_utf16 > 0),
                unit_id TEXT REFERENCES lexical_learning_units(id)
                    ON DELETE SET NULL,
                resolution_status TEXT NOT NULL
                    CHECK (resolution_status IN
                        ('pending', 'aiResolved', 'userConfirmed',
                         'lowConfidence', 'unresolved', 'rejected',
                         'skipped')),
                resolution_id TEXT,
                UNIQUE(document_id, content_revision, locator_json,
                       tokenizer_version, start_utf16, length_utf16)
            );

            CREATE INDEX reader_occurrences_by_unit
                ON reader_study_occurrences(unit_id, document_id);
            CREATE INDEX reader_occurrences_by_document
                ON reader_study_occurrences(document_id, content_revision);

            CREATE TABLE reader_translation_blocks (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                document_id TEXT NOT NULL
                    REFERENCES reader_documents(id) ON DELETE CASCADE,
                locator_key TEXT NOT NULL,
                locator_json TEXT NOT NULL
                    CHECK (json_valid(locator_json)
                           AND length(locator_json) <= 8192),
                source_hash TEXT NOT NULL,
                translation_revision INTEGER NOT NULL,
                translated_text TEXT NOT NULL,
                language TEXT NOT NULL,
                provider TEXT,
                model TEXT,
                prompt_version TEXT,
                request_hash TEXT,
                is_current INTEGER NOT NULL DEFAULT 0
                    CHECK (is_current IN (0, 1)),
                created_at_ms INTEGER NOT NULL,
                UNIQUE(document_id, locator_key, source_hash,
                       language, translation_revision)
            );

            CREATE UNIQUE INDEX reader_translation_one_current
                ON reader_translation_blocks(document_id, locator_key,
                                             language)
                WHERE is_current = 1;
            CREATE INDEX reader_translation_by_document
                ON reader_translation_blocks(document_id, is_current);

            CREATE TABLE ai_study_jobs (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                document_id TEXT NOT NULL
                    REFERENCES reader_documents(id) ON DELETE CASCADE,
                study_deck_id TEXT REFERENCES decks(id)
                    ON DELETE SET NULL,
                scope_json TEXT NOT NULL
                    CHECK (json_valid(scope_json)),
                input_fingerprint TEXT NOT NULL,
                content_revision INTEGER NOT NULL,
                provider_snapshot_json TEXT NOT NULL
                    CHECK (json_valid(provider_snapshot_json)),
                model TEXT NOT NULL,
                pipeline_version TEXT NOT NULL,
                prompt_version TEXT NOT NULL,
                policy_version TEXT NOT NULL,
                status TEXT NOT NULL
                    CHECK (status IN
                        ('pending', 'analyzing', 'waitingForAI',
                         'awaitingConfirmation', 'applying', 'paused',
                         'completed', 'partiallyCompleted', 'cancelled',
                         'failed')),
                epoch INTEGER NOT NULL DEFAULT 0,
                selection_revision INTEGER NOT NULL DEFAULT 0,
                resume_reason TEXT
                    CHECK (resume_reason IS NULL OR resume_reason IN
                        ('none', 'missingKey', 'missingSource',
                         'contentStale', 'backgroundPause',
                         'manualPause')),
                processed_blocks INTEGER NOT NULL DEFAULT 0,
                applied_units INTEGER NOT NULL DEFAULT 0,
                confirmed_units INTEGER NOT NULL DEFAULT 0,
                failed_blocks INTEGER NOT NULL DEFAULT 0,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );

            -- 同一 document/revision 至多一个活跃 Job（partiallyCompleted
            -- 非终态仍占活跃位；completed/cancelled/failed 释放）。
            CREATE UNIQUE INDEX ai_study_jobs_one_active_per_document
                ON ai_study_jobs(document_id, content_revision)
                WHERE status NOT IN ('completed', 'cancelled', 'failed');
            CREATE INDEX ai_study_jobs_by_document
                ON ai_study_jobs(document_id, status);

            CREATE TABLE ai_study_job_blocks (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                job_id TEXT NOT NULL
                    REFERENCES ai_study_jobs(id) ON DELETE CASCADE,
                locator_json TEXT NOT NULL
                    CHECK (json_valid(locator_json)
                           AND length(locator_json) <= 8192),
                source_hash TEXT NOT NULL,
                subblock_key TEXT NOT NULL,
                candidate_set_hash TEXT NOT NULL,
                request_hash TEXT NOT NULL,
                status TEXT NOT NULL
                    CHECK (status IN
                        ('pending', 'analyzing', 'readyForAI',
                         'requesting', 'resolved', 'awaitingConfirmation',
                         'applying', 'applied', 'retryScheduled',
                         'failed', 'cancelled')),
                attempt_count INTEGER NOT NULL DEFAULT 0,
                next_retry_at_ms INTEGER,
                lease_epoch INTEGER,
                result_id TEXT,
                last_error_code TEXT,
                UNIQUE(job_id, subblock_key)
            );

            CREATE INDEX ai_study_blocks_ready
                ON ai_study_job_blocks(job_id, status, next_retry_at_ms);

            CREATE TABLE ai_study_resolutions (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                job_id TEXT REFERENCES ai_study_jobs(id)
                    ON DELETE SET NULL,
                job_block_id TEXT REFERENCES ai_study_job_blocks(id)
                    ON DELETE SET NULL,
                document_id TEXT REFERENCES reader_documents(id)
                    ON DELETE SET NULL,
                locator_json TEXT NOT NULL
                    CHECK (json_valid(locator_json)
                           AND length(locator_json) <= 8192),
                token_key TEXT NOT NULL,
                request_hash TEXT NOT NULL,
                selected_entry_id INTEGER,
                selected_sense_id INTEGER,
                selected_dataset_version TEXT,
                unit_id TEXT REFERENCES lexical_learning_units(id)
                    ON DELETE SET NULL,
                confidence REAL
                    CHECK (confidence IS NULL
                           OR (confidence >= 0 AND confidence <= 1)),
                status TEXT NOT NULL
                    CHECK (status IN
                        ('aiResolved', 'userConfirmed', 'lowConfidence',
                         'unresolved', 'rejected')),
                reason_code TEXT
                    CHECK (reason_code IS NULL OR reason_code IN
                        ('noCandidate', 'missingWord',
                         'tokenNotInRequest', 'candidateNotInSet',
                         'restrictionNotSatisfied', 'duplicateTokenID',
                         'invalidConfidence', 'incompleteSelection',
                         'malformedItem', 'unknownStatus',
                         'envelopeRejected', 'candidateOverflow',
                         'belowConfidenceThreshold')),
                origin TEXT NOT NULL
                    CHECK (origin IN ('ai', 'user', 'local')),
                revision INTEGER NOT NULL DEFAULT 0,
                created_at_ms INTEGER NOT NULL,
                -- v28 起另有 sentence_translation（ALTER 补列）——
                -- 本建表语句保持 v25 冻结形态，新装同样走 v28 补列。
                UNIQUE(request_hash, token_key, revision)
            );

            CREATE INDEX ai_study_resolutions_by_job
                ON ai_study_resolutions(job_id, status);
            CREATE INDEX ai_study_resolutions_by_document
                ON ai_study_resolutions(document_id, token_key);

            CREATE TABLE ai_study_receipts (
                operation_id TEXT PRIMARY KEY NOT NULL
                    CHECK (length(operation_id) = 36),
                action_key TEXT NOT NULL UNIQUE,
                payload_hash TEXT NOT NULL,
                outcome_json TEXT NOT NULL
                    CHECK (json_valid(outcome_json)),
                committed_at_ms INTEGER NOT NULL
            );

            CREATE TABLE ai_study_selections (
                job_id TEXT NOT NULL
                    REFERENCES ai_study_jobs(id) ON DELETE CASCADE,
                unit_key TEXT NOT NULL,
                selection_revision INTEGER NOT NULL,
                decision TEXT NOT NULL
                    CHECK (decision IN
                        ('reuse', 'create', 'skip', 'tooEasy',
                         'pending')),
                proposed_action TEXT
                    CHECK (proposed_action IS NULL
                           OR json_valid(proposed_action)),
                evidence_revision INTEGER NOT NULL DEFAULT 0,
                applied_receipt_id TEXT,
                PRIMARY KEY (job_id, selection_revision, unit_key)
            ) WITHOUT ROWID;

            CREATE INDEX ai_study_selections_by_job
                ON ai_study_selections(job_id, decision);

            CREATE TABLE ai_study_cache (
                request_hash TEXT PRIMARY KEY NOT NULL,
                validated_result_json TEXT NOT NULL
                    CHECK (json_valid(validated_result_json)),
                size_bytes INTEGER NOT NULL,
                created_at_ms INTEGER NOT NULL,
                last_accessed_at_ms INTEGER NOT NULL
            ) WITHOUT ROWID;

            CREATE INDEX ai_study_cache_lru
                ON ai_study_cache(last_accessed_at_ms);
            """)
    }
}
