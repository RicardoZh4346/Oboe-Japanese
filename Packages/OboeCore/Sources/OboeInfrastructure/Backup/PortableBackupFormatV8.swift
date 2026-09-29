import Foundation

/// v8 记录协议（v0.7.0 S23，设计 §14.1 / contracts-frozen §5）。
///
/// 相对 v7 的变化：
/// - 15 类新记录：readerDocument / readerChapter / readerPosition /
///   readerBookmark / lexeme / lexemeNoteLink / vocabularyKnowledgeOverride /
///   clozeDefinition / readerActivityEvent / readerCoverageSnapshot /
///   readerMiningReceipt / importJob / importRowReceipt /
///   conjugationSession / conjugationPracticeAttempt。
///   冻结清单只列 14 类——`conjugationSession` 是按父先子后红线补入的
///   契约增量：attempt.session_id 是 CASCADE FK，不导出父表必产生孤儿。
/// - `sourceContext` 扩 4 列（v19 schema 新增的 Reader 定位弱引用）：
///   reader_document_id / reader_chapter_id / reader_location /
///   selected_surface。
/// - `note`/`card` 列集合不变；v19 schema 已放行新合法值
///   （kind='sentence'、origin='reader'/'import'、
///   template_kind='sentence_cloze'），语义校验在恢复端补查组合不变量。
///
/// 排除红线（冻结 §5 / D06——以下数据在任何 v8 文件里都不应出现）：
/// - `reader_blocks`（正文）、`reader_token_cache`（派生 token 缓存）、
///   `reader_assets`（本地资源相对路径与安装态）、Reader 原文全文
///   （含粘贴导入的整本）、任何本地绝对路径。
/// - `dictionary_artifact_records` / `lexeme_dictionary_bindings` 不导出：
///   前者是本机词典产物的核验台账——词典文件本身不进备份，行离了文件
///   就是悬空状态；后者是可由词典重放推导的解析态（与
///   derivedSearchIndex 同一排除哲学）。均不在下方记录清单中。
/// - import staging 文件与原始 CSV/未提交计划态不进备份；importJob 只
///   承载 job 级元数据（staging_file_name 恒为受控文件名，非路径），
///   恢复时未终态 job 一律标 interrupted。
/// - API key / AI 连接配置继续不导出（沿用 v3 起 excludedScopes）。
///
/// 记录序（冻结 §5 约束链的完整展开，父先子后）：
///   deck → readerDocument → readerChapter → readerPosition →
///   readerBookmark → note → noteDeck → lexeme → lexemeNoteLink →
///   vocabularyKnowledgeOverride → sourceContext → example → tag →
///   noteTag → profile → card → clozeDefinition → studyDay → dailyTask →
///   review → draft → inboxItem → inboxProcessingContext →
///   captureImportReceipt → inboxCommitReceipt → customStudySession →
///   practiceAttempt → scheduledReviewOrigin → readerActivityEvent →
///   readerMiningReceipt → readerCoverageSnapshot → importJob →
///   importRowReceipt → conjugationSession → conjugationPracticeAttempt →
///   settings
/// v7 既有记录的相对顺序一字不动，新类型只插入依赖允许的位置。
enum PortableBackupFormatV8 {
    // MARK: - Reader 元数据（§4.1；blocks/assets/token cache 无对应记录）

    static let readerDocument = PortableBackupTableSpecification(
        tableName: "reader_documents",
        recordType: "readerDocument",
        columns: [
            "id", "title", "format", "created_at_ms", "last_opened_at_ms",
            "source_file_name", "source_sha256", "canonical_text_hash",
            "parser_version", "content_revision", "progress_basis_points",
            "availability"
        ],
        orderBy: "created_at_ms, id"
    )

    static let readerChapter = PortableBackupTableSpecification(
        tableName: "reader_chapters",
        recordType: "readerChapter",
        columns: [
            "id", "document_id", "ordinal", "title", "source_locator",
            "canonical_hash", "text_utf16_length"
        ],
        orderBy: "document_id, ordinal"
    )

    static let readerPosition = PortableBackupTableSpecification(
        tableName: "reader_positions",
        recordType: "readerPosition",
        columns: ["document_id", "chapter_id", "locator_json", "updated_at_ms"],
        orderBy: "document_id"
    )

    static let readerBookmark = PortableBackupTableSpecification(
        tableName: "reader_bookmarks",
        recordType: "readerBookmark",
        columns: [
            "id", "document_id", "chapter_id", "locator_json", "label",
            "created_at_ms"
        ],
        orderBy: "document_id, created_at_ms, id"
    )

    // MARK: - lexical knowledge（§6.3；identity_key 由 D08 单点构造）

    static let lexeme = PortableBackupTableSpecification(
        tableName: "lexemes",
        recordType: "lexeme",
        columns: [
            "id", "provider", "external_id", "entry_id", "written_form",
            "reading", "normalized_lemma", "pos_family", "identity_key",
            "dictionary_version_at_resolution", "resolution_status",
            "created_at_ms"
        ],
        orderBy: "id"
    )

    static let lexemeNoteLink = PortableBackupTableSpecification(
        tableName: "lexeme_note_links",
        recordType: "lexemeNoteLink",
        columns: [
            "lexeme_id", "note_id", "association_origin", "confidence",
            "created_at_ms"
        ],
        orderBy: "lexeme_id, note_id"
    )

    static let vocabularyKnowledgeOverride = PortableBackupTableSpecification(
        tableName: "vocabulary_knowledge_overrides",
        recordType: "vocabularyKnowledgeOverride",
        columns: ["lexeme_id", "state", "updated_at_ms"],
        orderBy: "lexeme_id"
    )

    // MARK: - 来源定位扩展（v19 加列；旧版本恢复时四列填 NULL）

    /// v8 起 `sourceContext` 新增的 Reader 定位列；v1–v7 备份没有这些
    /// 字段，恢复迁移按 NULL 补齐（弱引用列，不伪造来源）。
    static let sourceContextColumnsAddedInV8 = [
        "reader_document_id", "reader_chapter_id",
        "reader_location", "selected_surface"
    ]

    static let sourceContext = PortableBackupTableSpecification(
        tableName: "source_contexts",
        recordType: "sourceContext",
        columns: PortableBackupFormatV7.sourceContext.columns
            + sourceContextColumnsAddedInV8,
        orderBy: "note_id, created_at_ms, id"
    )

    // MARK: - Cloze 独立快照（§9.1/D07；缺正文仍可复习）

    static let clozeDefinition = PortableBackupTableSpecification(
        tableName: "cloze_definitions",
        recordType: "clozeDefinition",
        columns: [
            "id", "note_id", "card_id", "source_context_id",
            "sentence_snapshot", "sentence_sha256",
            "range_version", "range_utf16_start", "range_utf16_length",
            "target_surface", "target_lemma", "target_reading",
            "accepted_answers_json", "hint", "content_version"
        ],
        orderBy: "id"
    )

    // MARK: - Reader 历史/幂等（§11.2；三引用弱引用，删对象不抹历史）

    static let readerActivityEvent = PortableBackupTableSpecification(
        tableName: "reader_activity_events",
        recordType: "readerActivityEvent",
        columns: [
            "id", "operation_id", "kind", "lexeme_id", "note_id",
            "document_id", "snapshot_json", "created_at_ms", "undone_at_ms"
        ],
        orderBy: "created_at_ms, id"
    )

    static let readerMiningReceipt = PortableBackupTableSpecification(
        tableName: "reader_mining_receipts",
        recordType: "readerMiningReceipt",
        columns: [
            "operation_id", "kind", "payload_hash", "result_json",
            "committed_at_ms"
        ],
        orderBy: "committed_at_ms, operation_id"
    )

    static let readerCoverageSnapshot = PortableBackupTableSpecification(
        tableName: "reader_coverage_snapshots",
        recordType: "readerCoverageSnapshot",
        columns: [
            "id", "document_id", "document_title", "scope_key", "chapter_id",
            "content_hash", "metric_version", "morphology_version",
            "dictionary_version", "known_count", "learning_count",
            "unknown_count", "ignored_count", "unique_numerator",
            "unique_denominator", "analyzed_blocks", "total_blocks",
            "study_day_id", "created_at_ms"
        ],
        orderBy: "created_at_ms, id"
    )

    // MARK: - Import 已提交历史（S17；staging 文件与原始 CSV 不入包）

    static let importJob = PortableBackupTableSpecification(
        tableName: "import_jobs",
        recordType: "importJob",
        columns: [
            "id", "file_hash", "mapping_hash", "policy", "target_deck_id",
            "status", "staging_file_name", "staging_fingerprint", "row_count",
            "committed_rows", "mapping_summary", "failure_reason",
            "created_at_ms", "updated_at_ms"
        ],
        orderBy: "created_at_ms, id"
    )

    static let importRowReceipt = PortableBackupTableSpecification(
        tableName: "import_row_receipts",
        recordType: "importRowReceipt",
        columns: [
            "job_id", "logical_row", "payload_digest", "action",
            "target_note_id", "detail", "created_at_ms"
        ],
        orderBy: "job_id, logical_row"
    )

    // MARK: - 活用练习（S15/§12；与正式调度零 FK，快照字段自含）

    static let conjugationSession = PortableBackupTableSpecification(
        tableName: "conjugation_sessions",
        recordType: "conjugationSession",
        columns: [
            "id", "planned_question_count", "status",
            "started_at_ms", "finished_at_ms"
        ],
        orderBy: "started_at_ms, id"
    )

    static let conjugationPracticeAttempt = PortableBackupTableSpecification(
        tableName: "conjugation_practice_attempts",
        recordType: "conjugationPracticeAttempt",
        columns: [
            "id", "event_id", "session_id", "question_id", "lemma", "reading",
            "conjugation_class", "form", "rule_id", "prompt",
            "expected_primary", "accepted_json", "user_input",
            "normalized_input", "result", "matched_answer", "duration_ms",
            "answered_at_ms", "undone_at_ms"
        ],
        orderBy: "session_id, answered_at_ms, id"
    )

    /// v8 新增记录类型里、manifest `excludedScopes` 追加声明的排除范围
    /// （在容器既有排除集合之后追加；预览用它向用户说明边界）。
    static let additionalExcludedScopes: [String] = [
        // Reader 原文全文（含粘贴整本）与 reader_blocks。
        "readerContent",
        // reader_token_cache 派生缓存、reader_assets 相对路径/安装态。
        "readerDerivedData",
        // 词典产物、核验台账与 lexeme 绑定（v22）——本地文件与可重放状态。
        "dictionaryData",
        // import staging 文件、原始 CSV 与未提交输入。
        "importStaging"
    ]

    static let tableSpecifications: [PortableBackupTableSpecification] =
        PortableBackupFormatV7.tableSpecifications.flatMap { specification in
            switch specification.recordType {
            case "deck":
                return [
                    specification, readerDocument, readerChapter,
                    readerPosition, readerBookmark
                ]
            case "noteDeck":
                return [
                    specification, lexeme, lexemeNoteLink,
                    vocabularyKnowledgeOverride
                ]
            case "sourceContext":
                // v8 规格替换为含 Reader 定位列的版本。
                return [sourceContext]
            case "card":
                return [specification, clozeDefinition]
            case "settings":
                return [
                    readerActivityEvent, readerMiningReceipt,
                    readerCoverageSnapshot, importJob, importRowReceipt,
                    conjugationSession, conjugationPracticeAttempt,
                    specification
                ]
            default:
                return [specification]
            }
        }

    static let recordTypes = tableSpecifications.map(\.recordType)
    static let specificationByRecordType = Dictionary(
        uniqueKeysWithValues: tableSpecifications.map { ($0.recordType, $0) }
    )
}

/// 记录协议 registry（设计 §14.1）：按 source version 返回不可变表规格，
/// 替换 exporter/preparer 里对 `PortableBackupFormatV7` 的当前版本硬编码。
/// 旧 V1–V8 规格保持冻结、不随现行表结构漂移。
enum PortableBackupFormatRegistry {
    /// v8 记录/包协议版本号（v0.7.0 起为导出默认；v1–v7 只读——
    /// 见 docs/v0.7/s23-backup-v8-records.md）。
    static let v8Version = 8

    /// v9 记录协议版本号（v0.7.5 S19，backup-v9-wire.md）：登记为可读
    /// 恢复源 + opt-in 导出版本（`recordFormatVersion:` 显式传入）。
    /// 默认导出仍由 `PortableBackupFormat.currentVersion` 控制——v9
    /// 默认切换是独立 gate，不在本结构内决定。
    static let v9Version = 9

    /// 恢复端可接受的最高记录协议版本——超出即判 future。
    static let maximumSupportedVersion = v9Version

    /// 按源版本取不可变表规格；未知版本返回 nil（由调用方报
    /// unsupportedFormatVersion）。
    static func tableSpecifications(
        forVersion version: Int
    ) -> [PortableBackupTableSpecification]? {
        switch version {
        case 1: return PortableBackupFormatV1.tableSpecifications
        case 2: return PortableBackupFormatV2.tableSpecifications
        case 3: return PortableBackupFormatV3.tableSpecifications
        case 4: return PortableBackupFormatV4.tableSpecifications
        case 5: return PortableBackupFormatV5.tableSpecifications
        case 6: return PortableBackupFormatV6.tableSpecifications
        case 7: return PortableBackupFormatV7.tableSpecifications
        case 8: return PortableBackupFormatV8.tableSpecifications // v8Version
        case 9: return PortableBackupFormatV9.tableSpecifications // v9Version
        default: return nil
        }
    }

    /// 按源版本取记录类型顺序（manifest recordOrder / counts 校验用）。
    static func recordTypes(forVersion version: Int) -> [String]? {
        tableSpecifications(forVersion: version)?.map(\.recordType)
    }

    /// 恢复写入目标规格：当前库 schema（v26）对应的记录协议 = v9。
    /// v1–v8 源记录由 migrateRecordToCurrentFormat 补齐缺列后按此规格
    /// 严格插入；v9 源记录的列集合与本规格逐字一致。
    static let targetSpecifications = PortableBackupFormatV9.tableSpecifications
    static let targetSpecificationByRecordType =
        PortableBackupFormatV9.specificationByRecordType

    /// 导出允许的版本集合：当前默认版本 + opt-in 登记的 v9。
    /// 早于当前默认的版本不可再生成——旧格式只能读不能写。
    static func isExportable(version: Int) -> Bool {
        version == PortableBackupFormat.currentVersion || version == v9Version
    }
}
