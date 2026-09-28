import Foundation

/// v9 记录协议（v0.7.5 S19 前置——backup-v9-wire.md rev1 / contracts-frozen rev2 §6）。
///
/// 相对 v8 的变化：
/// - 14 类新记录（wire §2.1）：learningUnit / learningUnitAlias /
///   learningUnitNoteLink / learningUnitFlag / learningUnitEvent /
///   learningUnitMigrationItem / readerStudyOccurrence /
///   readerTranslationBlock / aiStudyJob / aiStudyJobBlock /
///   aiStudyResolution / aiStudySelection / aiStudyReceipt /
///   readerLearningCoverageSnapshot。
/// - `readerDocument` 扩 2 列（wire §2.2，v24 schema）：study_deck_id /
///   study_deck_name_follows_title；v1–v8 源恢复时补 NULL = 未绑定/跟随。
/// - `sourceContext` 扩 1 列（wire §2.2，v24 schema）：study_dedup_key；
///   v1–v8 源恢复时补 NULL。
///
/// 不可导出红线（wire §2.3——任何 v9 文件里都不应出现）：
/// - `ai_study_cache`（本机有界 LRU）、lease_epoch 等 lease/next-retry
///   运行态字段、staging 候选快照大对象（block result 原文 payload）。
/// - API Key、含秘密 endpoint 配置；`provider_snapshot_json` 只允许非敏感
///   执行配置（provider kind/model/版本），不得含凭据。
/// - 原 EPUB/TXT/SRT/VTT/Paste 全文（沿用 v8 readerContent 红线）。
/// - `learningUnit` 的 sense_snapshot_json 只含有界义项快照，不得含整段
///   正文或 Prompt。
/// - 沿用 v8：reader_blocks / reader_token_cache / reader_assets、
///   词典产物与核验台账、import staging 文件与原始 CSV。
///
/// 记录序（wire §3——在 v8 顺序上插入，v8 既有相对顺序一字不动）：
///   deck → readerDocument → readerChapter → readerPosition →
///   readerBookmark → note → noteDeck →
///   learningUnit → learningUnitAlias → learningUnitNoteLink →
///   learningUnitFlag → learningUnitEvent → learningUnitMigrationItem →
///   lexeme → lexemeNoteLink → vocabularyKnowledgeOverride → sourceContext →
///   example → tag → noteTag → profile → card → clozeDefinition →
///   studyDay → dailyTask → review → draft → inboxItem →
///   inboxProcessingContext → captureImportReceipt → inboxCommitReceipt →
///   customStudySession → practiceAttempt → scheduledReviewOrigin →
///   readerStudyOccurrence → readerTranslationBlock → aiStudyJob →
///   aiStudyJobBlock → aiStudyResolution → aiStudySelection →
///   aiStudyReceipt → readerActivityEvent → readerMiningReceipt →
///   readerCoverageSnapshot → readerLearningCoverageSnapshot → importJob →
///   importRowReceipt → conjugationSession → conjugationPracticeAttempt →
///   settings
enum PortableBackupFormatV9 {
    // MARK: - Learning Unit 主体（wire §2.1；v23 schema，S04）
    // unit 系记录须在 noteDeck 之后：learningUnitNoteLink 同时引用
    // note 与 unit，父先子后满足 FK 解析方向。

    /// `lexical_learning_units` 全列白名单。sense_snapshot_json 是有界义项
    /// 快照（无全文/Prompt）；provider/dictionary_entry_id/
    /// semantic_fingerprint/fingerprint_version/sense_snapshot_json 对
    /// local/legacy 身份可为 NULL，列仍照导出（NULL 是合法值）。
    static let learningUnit = PortableBackupTableSpecification(
        tableName: "lexical_learning_units",
        recordType: "learningUnit",
        columns: [
            "id", "identity_kind", "identity_key", "provider",
            "dictionary_entry_id", "semantic_fingerprint",
            "fingerprint_version", "lemma", "reading",
            "sense_snapshot_json", "binding_status", "revision",
            "created_at_ms", "updated_at_ms"
        ],
        orderBy: "id"
    )

    /// `learning_unit_dictionary_aliases` 全列白名单。恢复端重绑定重算：
    /// 导出端 `current` 不当真，落地先 `needsConfirmation`（wire §2.1）。
    /// `fingerprint_version` 自 wire rev2 起导出（contracts rev2 §1.2）。
    static let learningUnitAlias = PortableBackupTableSpecification(
        tableName: "learning_unit_dictionary_aliases",
        recordType: "learningUnitAlias",
        columns: [
            "unit_id", "provider", "dataset_version", "entry_id",
            "sense_id", "fingerprint", "fingerprint_version",
            "status", "resolved_at_ms"
        ],
        orderBy: "unit_id, provider, dataset_version, entry_id, sense_id"
    )

    /// `learning_unit_note_links` 全列白名单。role enum 由恢复端校验；
    /// 双 primary 属 preflight 拒绝条件。
    static let learningUnitNoteLink = PortableBackupTableSpecification(
        tableName: "learning_unit_note_links",
        recordType: "learningUnitNoteLink",
        columns: ["unit_id", "note_id", "role", "origin", "created_at_ms"],
        orderBy: "unit_id, note_id"
    )

    /// `learning_unit_flags` 全列白名单。恢复不改 Card/FSRS/ReviewLog。
    static let learningUnitFlag = PortableBackupTableSpecification(
        tableName: "learning_unit_flags",
        recordType: "learningUnitFlag",
        columns: ["unit_id", "too_easy", "revision", "updated_at_ms"],
        orderBy: "unit_id"
    )

    /// `learning_unit_events` 全列白名单。unit_id 弱引用语义——源端删除
    /// unit 时 SET NULL，unit_id_snapshot 留史。
    static let learningUnitEvent = PortableBackupTableSpecification(
        tableName: "learning_unit_events",
        recordType: "learningUnitEvent",
        columns: [
            "id", "operation_id", "unit_id", "unit_id_snapshot", "kind",
            "before_json", "after_json", "payload_hash", "created_at_ms",
            "undone_at_ms"
        ],
        orderBy: "created_at_ms, id"
    )

    /// `learning_unit_migration_items` 全列白名单。待确认证据必须导出，
    /// 防换机丢失旧 known 标记（D03）；不参与运行态。
    static let learningUnitMigrationItem = PortableBackupTableSpecification(
        tableName: "learning_unit_migration_items",
        recordType: "learningUnitMigrationItem",
        columns: [
            "source_key", "note_id", "legacy_lexeme_id", "old_state",
            "status", "evidence_json", "target_unit_id", "last_error"
        ],
        orderBy: "source_key"
    )

    // MARK: - Reader 学习派生（wire §2.1；v25 schema，S11）

    /// `reader_study_occurrences` 全列白名单。unit_id/resolution_id 弱引用；
    /// locator+block_source_hash 是无原文重链依据。
    static let readerStudyOccurrence = PortableBackupTableSpecification(
        tableName: "reader_study_occurrences",
        recordType: "readerStudyOccurrence",
        columns: [
            "id", "document_id", "content_revision", "locator_json",
            "block_source_hash", "tokenizer_version", "start_utf16",
            "length_utf16", "unit_id", "resolution_status", "resolution_id"
        ],
        orderBy: "document_id, start_utf16, id"
    )

    /// `reader_translation_blocks` 全列白名单。**不导出原文字串**——
    /// source_hash/locator 供重挂；translated_text 是译文本体（保留历史）。
    static let readerTranslationBlock = PortableBackupTableSpecification(
        tableName: "reader_translation_blocks",
        recordType: "readerTranslationBlock",
        columns: [
            "id", "document_id", "locator_key", "locator_json",
            "source_hash", "translation_revision", "translated_text",
            "language", "provider", "model", "prompt_version",
            "request_hash", "created_at_ms", "is_current"
        ],
        orderBy: "document_id, locator_key, id"
    )

    // MARK: - AI Study 流水线（wire §2.1；v25 schema，S11）

    /// `ai_study_jobs` 全列白名单。provider_snapshot_json 只含非敏感执行
    /// 配置（provider kind/model/版本），不得含 Key/endpoint 秘密。
    static let aiStudyJob = PortableBackupTableSpecification(
        tableName: "ai_study_jobs",
        recordType: "aiStudyJob",
        columns: [
            "id", "document_id", "study_deck_id", "scope_json",
            "input_fingerprint", "content_revision",
            "provider_snapshot_json", "model", "pipeline_version",
            "prompt_version", "policy_version", "status", "epoch",
            "selection_revision", "resume_reason",
            "created_at_ms", "updated_at_ms"
        ],
        orderBy: "created_at_ms, id"
    )

    /// `ai_study_job_blocks` 白名单。**lease_epoch 不导出**（wire §2.1 —
    /// 运行态租借信息留在本机）；requesting 态恢复时归一化为
    /// paused/retryScheduled 语义（wire §4.2）。
    static let aiStudyJobBlock = PortableBackupTableSpecification(
        tableName: "ai_study_job_blocks",
        recordType: "aiStudyJobBlock",
        columns: [
            "id", "job_id", "locator_json", "source_hash", "subblock_key",
            "candidate_set_hash", "request_hash", "status", "attempt_count",
            "next_retry_at_ms", "result_id", "last_error_code"
        ],
        orderBy: "job_id, subblock_key"
    )

    /// `ai_study_resolutions` 全列白名单。全部 ID 弱引用语义（SET NULL
    /// 留史）；有界审计快照。
    static let aiStudyResolution = PortableBackupTableSpecification(
        tableName: "ai_study_resolutions",
        recordType: "aiStudyResolution",
        columns: [
            "id", "job_id", "job_block_id", "document_id", "locator_json",
            "token_key", "request_hash", "selected_entry_id",
            "selected_sense_id", "selected_dataset_version", "unit_id",
            "confidence", "status", "reason_code", "origin", "revision",
            "created_at_ms"
        ],
        orderBy: "job_id, created_at_ms, id"
    )

    /// `ai_study_receipts` 全列白名单。恢复后 replay 只返回历史结果，
    /// 不触发网络/复制制卡（wire §2.1）。
    static let aiStudyReceipt = PortableBackupTableSpecification(
        tableName: "ai_study_receipts",
        recordType: "aiStudyReceipt",
        columns: [
            "operation_id", "action_key", "payload_hash", "outcome_json",
            "committed_at_ms"
        ],
        orderBy: "committed_at_ms, operation_id"
    )

    /// `ai_study_selections` 全列白名单。已确认选择随包走；
    /// 恢复不自动应用（wire §2.1）。
    static let aiStudySelection = PortableBackupTableSpecification(
        tableName: "ai_study_selections",
        recordType: "aiStudySelection",
        columns: [
            "job_id", "unit_key", "selection_revision", "decision",
            "proposed_action", "evidence_revision", "applied_receipt_id"
        ],
        orderBy: "job_id, selection_revision, unit_key"
    )

    // MARK: - 学习覆盖快照（wire §2.1；v26 schema，S20）

    /// `reader_learning_coverage_snapshots` 全列导出（wire：全部列）。
    /// document_id 快照列与弱引用并存——document 删除 SET NULL 留史（D09
    /// 分段）；列清单以详细技术实现 §4 冻结草案为准（wire 未逐项枚举）。
    static let readerLearningCoverageSnapshot = PortableBackupTableSpecification(
        tableName: "reader_learning_coverage_snapshots",
        recordType: "readerLearningCoverageSnapshot",
        columns: [
            "id", "document_id", "document_id_snapshot", "scope_hash",
            "content_revision", "knowledge_revision", "metric_version",
            "dictionary_version", "morphology_version", "resolved_unique",
            "unknown_unique", "learning_unique", "mastered_unique",
            "pending_occurrences", "oov_occurrences", "analyzed_blocks",
            "total_blocks", "calculated_at_ms"
        ],
        orderBy: "calculated_at_ms, id"
    )

    // MARK: - 既有记录扩列（wire §2.2；v24 schema，S06）

    /// v9 起 `readerDocument` 新增的文档牌组绑定列；v1–v8 备份没有这些
    /// 字段，恢复迁移按 NULL 补齐（未绑定/跟随标题，不伪造绑定）。
    static let readerDocumentColumnsAddedInV9 = [
        "study_deck_id", "study_deck_name_follows_title"
    ]

    static let readerDocument = PortableBackupTableSpecification(
        tableName: "reader_documents",
        recordType: "readerDocument",
        columns: PortableBackupFormatV8.readerDocument.columns
            + readerDocumentColumnsAddedInV9,
        orderBy: "created_at_ms, id"
    )

    /// v9 起 `sourceContext` 新增的学习去重键列；v1–v8 备份没有该字段，
    /// 恢复迁移按 NULL 补齐（不复制旧行、不伪造来源）。
    static let sourceContextColumnsAddedInV9 = ["study_dedup_key"]

    static let sourceContext = PortableBackupTableSpecification(
        tableName: "source_contexts",
        recordType: "sourceContext",
        columns: PortableBackupFormatV8.sourceContext.columns
            + sourceContextColumnsAddedInV9,
        orderBy: "note_id, created_at_ms, id"
    )

    /// v9 新增记录类型里、manifest `excludedScopes` 追加声明的排除范围
    /// （wire §2.3；在 v8 既有排除集合之后追加）。
    static let additionalExcludedScopes: [String] = [
        // ai_study_cache、lease/next-retry 运行态、staging 候选快照大对象。
        "aiStudyRuntime",
        // 显式重申：API Key/含秘密 endpoint 不导出；provider_snapshot
        // 字段不得含凭据。
        "providerSecrets"
    ]

    static let tableSpecifications: [PortableBackupTableSpecification] =
        PortableBackupFormatV8.tableSpecifications.flatMap { specification in
            switch specification.recordType {
            case "readerDocument":
                // v9 规格替换为含牌组绑定列的版本。
                return [readerDocument]
            case "noteDeck":
                // wire §3：learningUnit 组插在 noteDeck 之后、lexeme 之前。
                return [
                    specification,
                    learningUnit, learningUnitAlias, learningUnitNoteLink,
                    learningUnitFlag, learningUnitEvent,
                    learningUnitMigrationItem
                ]
            case "sourceContext":
                // v9 规格替换为含 study_dedup_key 的版本。
                return [sourceContext]
            case "scheduledReviewOrigin":
                // wire §3：Reader 派生 + aiStudy 组插在
                // scheduledReviewOrigin 之后、readerActivityEvent 之前。
                return [
                    specification,
                    readerStudyOccurrence, readerTranslationBlock,
                    aiStudyJob, aiStudyJobBlock, aiStudyResolution,
                    aiStudySelection, aiStudyReceipt
                ]
            case "readerCoverageSnapshot":
                return [specification, readerLearningCoverageSnapshot]
            default:
                return [specification]
            }
        }

    static let recordTypes = tableSpecifications.map(\.recordType)
    static let specificationByRecordType = Dictionary(
        uniqueKeysWithValues: tableSpecifications.map { ($0.recordType, $0) }
    )
}
