import Foundation

public enum PortableBackupFormat {
    public static let identifier = "oboe-portable-backup"
    /// 记录协议版本（D05）：外层 ZIP 包格式仍是 7，本值只管
    /// records.ndjson / 纯备份文件的记录契约。
    public static let currentVersion = 7
    public static let fileExtension = "oboe-backup"
    public static let checksumAlgorithm = "sha256"

    /// Data categories the portable backup deliberately excludes. Surfaced in
    /// the v3 manifest (`excludedScopes`) so restore previews can explain scope
    /// without parsing the body.
    public static let excludedScopes: [String] = [
        "credentials",
        "aiConnectionConfiguration",
        "sharedTransferFiles",
        "imageAttachments",
        "derivedSearchIndex"
    ]
}

struct PortableBackupTableSpecification: Sendable {
    let tableName: String
    let recordType: String
    let columns: [String]
    let orderBy: String
    /// Overrides the default `SELECT <columns> FROM <table>` export query.
    /// Used by `noteDeck` so notes lacking a membership row still export
    /// their home-deck membership, keeping the home∈membership invariant
    /// even if a live database drifted (设计 §9).
    let selectSQL: String?

    init(
        tableName: String,
        recordType: String,
        columns: [String],
        orderBy: String,
        selectSQL: String? = nil
    ) {
        self.tableName = tableName
        self.recordType = recordType
        self.columns = columns
        self.orderBy = orderBy
        self.selectSQL = selectSQL
    }
}

enum PortableBackupFormatV1 {
    static let tableSpecifications: [PortableBackupTableSpecification] = [
        PortableBackupTableSpecification(
            tableName: "decks",
            recordType: "deck",
            columns: ["id", "name", "sort_order", "created_at_ms", "updated_at_ms"],
            orderBy: "sort_order, id"
        ),
        PortableBackupTableSpecification(
            tableName: "notes",
            recordType: "note",
            columns: [
                "id", "deck_id", "kind", "headword", "reading", "meaning_zh",
                "part_of_speech", "jlpt", "usage", "connection", "notes",
                "is_favorite", "source_text", "origin", "content_version",
                "created_at_ms", "updated_at_ms"
            ],
            orderBy: "id"
        ),
        PortableBackupTableSpecification(
            tableName: "examples",
            recordType: "example",
            columns: ["id", "note_id", "japanese", "translation_zh", "sort_order"],
            orderBy: "note_id, sort_order, id"
        ),
        PortableBackupTableSpecification(
            tableName: "tags",
            recordType: "tag",
            columns: ["id", "name", "normalized_name"],
            orderBy: "id"
        ),
        PortableBackupTableSpecification(
            tableName: "note_tags",
            recordType: "noteTag",
            columns: ["note_id", "tag_id"],
            orderBy: "note_id, tag_id"
        ),
        PortableBackupTableSpecification(
            tableName: "scheduler_profiles",
            recordType: "profile",
            columns: [
                "id", "configuration_version", "algorithm_version", "library_revision",
                "parameters_json", "desired_retention", "max_interval_days", "created_at_ms"
            ],
            orderBy: "id"
        ),
        PortableBackupTableSpecification(
            tableName: "cards",
            recordType: "card",
            columns: [
                "id", "note_id", "template_kind", "is_enabled", "state", "due_at_ms",
                "last_review_at_ms", "stability", "difficulty", "reps", "lapses",
                "scheduled_days", "elapsed_days", "learning_step", "first_studied_at_ms",
                "state_version", "algorithm_version", "profile_id"
            ],
            orderBy: "id"
        ),
        PortableBackupTableSpecification(
            tableName: "study_days",
            recordType: "studyDay",
            columns: [
                "id", "local_date", "time_zone_id", "starts_at_ms", "ends_at_ms", "new_limit"
            ],
            orderBy: "starts_at_ms, id"
        ),
        PortableBackupTableSpecification(
            tableName: "daily_tasks",
            recordType: "dailyTask",
            columns: [
                "study_day_id", "card_id", "category_at_admission", "admitted_at_ms",
                "cancelled_at_ms"
            ],
            orderBy: "study_day_id, card_id"
        ),
        PortableBackupTableSpecification(
            tableName: "review_logs",
            recordType: "review",
            columns: [
                "id", "event_id", "card_id", "card_key", "note_id", "deck_id_at_review",
                "reviewed_at_ms", "study_day_id", "was_first_study", "rating",
                "previous_state_json", "next_state_json", "duration_ms", "content_version",
                "profile_id", "algorithm_version", "undone_at_ms"
            ],
            orderBy: "reviewed_at_ms, id"
        ),
        PortableBackupTableSpecification(
            tableName: "drafts",
            recordType: "draft",
            columns: [
                "id", "draft_kind", "payload_version", "payload_json", "provider_id",
                "model_id", "prompt_version", "updated_at_ms"
            ],
            orderBy: "id"
        ),
        PortableBackupTableSpecification(
            tableName: "app_settings",
            recordType: "settings",
            columns: [
                "id", "schema_version", "learning_time_zone_id", "daily_new_card_limit",
                "retention_preset", "auto_play_word_audio", "auto_play_example_audio", "appearance"
            ],
            orderBy: "id"
        )
    ]

    static let recordTypes = tableSpecifications.map(\.recordType)
    static let specificationByRecordType = Dictionary(
        uniqueKeysWithValues: tableSpecifications.map { ($0.recordType, $0) }
    )
}

enum PortableBackupFormatV2 {
    static let tableSpecifications: [PortableBackupTableSpecification] =
        PortableBackupFormatV1.tableSpecifications.map { specification in
            guard specification.recordType == "note" else { return specification }
            return PortableBackupTableSpecification(
                tableName: "notes",
                recordType: "note",
                columns: [
                    "id", "deck_id", "kind", "headword", "reading", "meaning_zh",
                    "part_of_speech", "jlpt", "usage", "connection", "notes",
                    "is_favorite", "source_text", "origin", "source_ref", "content_version",
                    "created_at_ms", "updated_at_ms"
                ],
                orderBy: "id"
            )
        }

    static let recordTypes = tableSpecifications.map(\.recordType)
    static let specificationByRecordType = Dictionary(
        uniqueKeysWithValues: tableSpecifications.map { ($0.recordType, $0) }
    )
}

enum PortableBackupFormatV3 {
    static let inboxItem = PortableBackupTableSpecification(
        tableName: "inbox_items",
        recordType: "inboxItem",
        columns: [
            "id", "text", "source_type", "status", "content_revision",
            "source_app", "source_url", "image_reference",
            "created_at_ms", "updated_at_ms", "processed_at_ms",
            "archived_at_ms", "status_before_archive"
        ],
        orderBy: "created_at_ms, id"
    )

    static let processingContext = PortableBackupTableSpecification(
        tableName: "inbox_processing_contexts",
        recordType: "inboxProcessingContext",
        columns: [
            "id", "inbox_item_id", "content_revision", "input_text", "mode",
            "draft_id", "payload_version", "resume_payload_json", "updated_at_ms"
        ],
        orderBy: "inbox_item_id, id"
    )

    static let importReceipt = PortableBackupTableSpecification(
        tableName: "capture_import_receipts",
        recordType: "captureImportReceipt",
        columns: ["capture_id", "payload_hash", "inbox_item_id", "imported_at_ms"],
        orderBy: "capture_id"
    )

    static let commitReceipt = PortableBackupTableSpecification(
        tableName: "inbox_commit_receipts",
        recordType: "inboxCommitReceipt",
        columns: [
            "operation_id", "processing_context_id", "payload_hash",
            "result_json", "committed_at_ms"
        ],
        orderBy: "operation_id"
    )

    /// v2 records plus the Inbox pipeline. New records sit after `draft` (which
    /// processing contexts may reference via draft_id) and before `settings`,
    /// keeping every pre-existing record type in its original slot.
    static let tableSpecifications: [PortableBackupTableSpecification] =
        PortableBackupFormatV2.tableSpecifications.flatMap { specification in
            guard specification.recordType == "settings" else {
                return [specification]
            }
            return [inboxItem, processingContext, importReceipt, commitReceipt, specification]
        }

    static let recordTypes = tableSpecifications.map(\.recordType)
    static let specificationByRecordType = Dictionary(
        uniqueKeysWithValues: tableSpecifications.map { ($0.recordType, $0) }
    )
}

/// v4 (Oboe v0.4): identical record types and order as v3 — the only widening
/// is the `settings` record gaining the four Adaptive-preference columns
/// (`typed_answer_zh_ja`, `auto_play_listening_audio`,
/// `typed_answer_listening`, `leech_reminders_enabled`). The widened `cards`
/// template CHECK (`vocabulary_listening`) and `drafts` kind CHECK
/// (`ai_repair`) live in the schema, not the record contract.
enum PortableBackupFormatV4 {
    /// Column names a v3-or-earlier `settings` record lacks; restoration fills
    /// them with `AdaptivePreferences.defaults`（v0.5.5 起 ON/ON/ON/ON）。
    static let settingsColumnsAddedInV4 = [
        "typed_answer_zh_ja",
        "auto_play_listening_audio",
        "typed_answer_listening",
        "leech_reminders_enabled"
    ]

    static let settings = PortableBackupTableSpecification(
        tableName: "app_settings",
        recordType: "settings",
        columns: [
            "id", "schema_version", "learning_time_zone_id", "daily_new_card_limit",
            "retention_preset", "auto_play_word_audio", "auto_play_example_audio",
            "appearance", "typed_answer_zh_ja", "auto_play_listening_audio",
            "typed_answer_listening", "leech_reminders_enabled"
        ],
        orderBy: "id"
    )

    static let tableSpecifications: [PortableBackupTableSpecification] =
        PortableBackupFormatV3.tableSpecifications.map { specification in
            specification.recordType == "settings" ? settings : specification
        }

    static let recordTypes = tableSpecifications.map(\.recordType)
    static let specificationByRecordType = Dictionary(
        uniqueKeysWithValues: tableSpecifications.map { ($0.recordType, $0) }
    )
}

/// v5: identical record types and order as v4 — the `settings` record gains
/// the nullable `primary_deck_id` column (每日主牌组). Restoring a v4 or
/// earlier settings record fills it with NULL.
enum PortableBackupFormatV5 {
    static let settings = PortableBackupTableSpecification(
        tableName: "app_settings",
        recordType: "settings",
        columns: PortableBackupFormatV4.settings.columns + ["primary_deck_id"],
        orderBy: "id"
    )

    static let tableSpecifications: [PortableBackupTableSpecification] =
        PortableBackupFormatV4.tableSpecifications.map { specification in
            specification.recordType == "settings" ? settings : specification
        }

    static let recordTypes = tableSpecifications.map(\.recordType)
    static let specificationByRecordType = Dictionary(
        uniqueKeysWithValues: tableSpecifications.map { ($0.recordType, $0) }
    )
}

/// v6 (Oboe v0.5): the `note` record gains `pitch_accent` and a new
/// `noteDeck` record carries the many-to-many membership table (设计 §9).
/// `noteDeck` sits immediately after `note` so its foreign keys resolve in
/// record order. `notes.deck_id` is retained — it is the home deck and must
/// be one of the note's memberships.
enum PortableBackupFormatV6 {
    static let note = PortableBackupTableSpecification(
        tableName: "notes",
        recordType: "note",
        columns: PortableBackupFormatV2.specificationByRecordType["note"]!.columns
            + ["pitch_accent"],
        orderBy: "id"
    )

    /// The export query unions real membership rows with a home-deck
    /// fallback for notes that somehow lack one, so every exported note is
    /// guaranteed at least its home membership. A synthesized row can never
    /// collide with a real row on the (note_id, deck_id) key: it is emitted
    /// only when the note has no membership rows at all.
    static let noteDeck = PortableBackupTableSpecification(
        tableName: "note_decks",
        recordType: "noteDeck",
        columns: ["note_id", "deck_id", "added_at_ms"],
        orderBy: "note_id, deck_id",
        selectSQL: """
            SELECT note_id, deck_id, added_at_ms FROM note_decks
            UNION
            SELECT id, deck_id, created_at_ms FROM notes n
            WHERE NOT EXISTS (
                SELECT 1 FROM note_decks nd WHERE nd.note_id = n.id
            )
            """
    )

    static let tableSpecifications: [PortableBackupTableSpecification] =
        PortableBackupFormatV5.tableSpecifications.flatMap { specification in
            specification.recordType == "note" ? [note, noteDeck] : [specification]
        }

    static let recordTypes = tableSpecifications.map(\.recordType)
    static let specificationByRecordType = Dictionary(
        uniqueKeysWithValues: tableSpecifications.map { ($0.recordType, $0) }
    )
}

/// v7（Oboe v0.6）：新增 `sourceContext`（v15 表，Note 来源）与
/// Custom Study 三表记录（v16：session/attempt/origin）。
///
/// 记录序遵守外键解析方向：`sourceContext` 紧随 `noteDeck`（note_id
/// 指向已全部写入的 notes）；`customStudySession`/`practiceAttempt`/
/// `scheduledReviewOrigin` 排在 `commitReceipt` 之后、`settings` 之前
/// ——origin 的 event_id 指向 review_logs（更早写入）、session_id 指向
/// 紧邻其前的 sessions（设计 §7.2/§2.5）。旧备份无这四类记录——
/// 表留空即可，无需字段回填。
enum PortableBackupFormatV7 {
    static let sourceContext = PortableBackupTableSpecification(
        tableName: "source_contexts",
        recordType: "sourceContext",
        columns: [
            "id", "note_id", "source_type", "original_sentence",
            "surrounding_text", "source_title", "source_url", "source_app",
            "image_reference", "dictionary_entry_id", "dictionary_version",
            "dictionary_sense_key", "selected_gloss_language", "is_primary",
            "created_at_ms"
        ],
        orderBy: "note_id, created_at_ms, id"
    )

    static let customStudySession = PortableBackupTableSpecification(
        tableName: "custom_study_sessions",
        recordType: "customStudySession",
        columns: [
            "id", "filter_json", "mode", "status",
            "started_at_ms", "finished_at_ms", "queue_json"
        ],
        orderBy: "started_at_ms, id"
    )

    static let practiceAttempt = PortableBackupTableSpecification(
        tableName: "practice_attempts",
        recordType: "practiceAttempt",
        columns: [
            "id", "event_id", "session_id", "card_key", "note_id", "rating",
            "answered_at_ms", "duration_ms", "content_version", "undone_at_ms"
        ],
        orderBy: "session_id, answered_at_ms, id"
    )

    static let scheduledReviewOrigin = PortableBackupTableSpecification(
        tableName: "scheduled_review_origins",
        recordType: "scheduledReviewOrigin",
        columns: ["event_id", "session_id", "submission_kind"],
        orderBy: "event_id"
    )

    static let tableSpecifications: [PortableBackupTableSpecification] =
        PortableBackupFormatV6.tableSpecifications.flatMap { specification in
            switch specification.recordType {
            case "noteDeck":
                return [specification, sourceContext]
            case "settings":
                return [
                    customStudySession, practiceAttempt,
                    scheduledReviewOrigin, specification
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
