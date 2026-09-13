import Foundation

public enum PortableBackupFormat {
    public static let identifier = "oboe-portable-backup"
    public static let currentVersion = 2
    public static let fileExtension = "oboe-backup"
    public static let checksumAlgorithm = "sha256"
}

struct PortableBackupTableSpecification: Sendable {
    let tableName: String
    let recordType: String
    let columns: [String]
    let orderBy: String
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
