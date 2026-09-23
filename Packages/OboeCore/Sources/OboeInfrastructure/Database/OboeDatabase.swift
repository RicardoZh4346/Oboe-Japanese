import Foundation
import GRDB
import OboeDomain

public final class OboeDatabase: Sendable {
    public let pool: DatabasePool

    public init(path: String) throws {
        let pool = try Self.openPool(path: path)
        do {
            try OboeDatabaseSchema.makeMigrator().migrate(pool)
        } catch {
            try? pool.close()
            throw error
        }
        self.pool = pool
    }

    init(pool: DatabasePool) {
        self.pool = pool
    }

    public func close() throws {
        try pool.close()
    }

    static func openPool(path: String) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.label = "Oboe"
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search",
                argumentCount: 1,
                pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0]) else {
                    return nil
                }
                return SearchTextNormalizer.normalize(value)
            })
        }
        return try DatabasePool(path: path, configuration: configuration)
    }
}

/// app_settings 单例行的统一创建入口。五个 *Repository 的 loadOrCreate 都经
/// 此插入首行：v0.5.5 起两个主动回忆输入开关的领域默认值为开启，而 v13
/// 冻结的列 DEFAULT 仍停留在 v0.4 的 0/1/0/1——行缺失时必须显式写入
/// `AdaptivePreferences.defaults`，不能依赖列默认；已有行一律保留原值
///（ON CONFLICT DO NOTHING，不擅自改写已存选择）。
enum AppSettingsRowDefaults {
    static func insertIfMissing(
        in db: Database,
        learningTimeZoneID: String
    ) throws {
        let defaults = AdaptivePreferences.defaults
        try db.execute(
            sql: """
                INSERT INTO app_settings(
                    id, schema_version, learning_time_zone_id, daily_new_card_limit,
                    typed_answer_zh_ja, auto_play_listening_audio,
                    typed_answer_listening, leech_reminders_enabled
                ) VALUES (1, 1, ?, 10, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
            arguments: [
                learningTimeZoneID,
                defaults.typedAnswerChineseToJapanese,
                defaults.autoPlayListeningAudio,
                defaults.typedAnswerListening,
                defaults.leechRemindersEnabled
            ]
        )
    }
}

public enum OboeDatabaseSchema {
    public static let migrationIdentifiers = [
        "v1_content",
        "v2_scheduling_and_app_state",
        "v3_search_index_maintenance",
        "v4_ai_configuration_privacy",
        "v5_ai_response_capability",
        "v6_builtin_jlpt_source",
        "v7_inbox_capture",
        "v8_adaptive_preferences",
        "v9_listening_template",
        "v10_ai_repair_drafts",
        "v11_primary_deck",
        "v12_fill_vocabulary_directions",
        "v13_note_deck_membership_and_pitch",
        "v14_attachments"
    ]

    public static let tableNames: Set<String> = [
        "decks",
        "notes",
        "examples",
        "tags",
        "note_tags",
        "scheduler_profiles",
        "cards",
        "study_days",
        "daily_tasks",
        "review_logs",
        "drafts",
        "app_settings",
        "search_documents",
        "inbox_items",
        "inbox_processing_contexts",
        "capture_import_receipts",
        "inbox_commit_receipts",
        "note_decks",
        "attachments"
    ]

    public static func makeMigrator() -> DatabaseMigrator {
        makeMigrator(applying: migrationIdentifiers)
    }

    /// Registering a strict prefix of the identifier list lets tests stage a
    /// database at an older schema version before exercising the upgrade path.
    public static func makeMigrator(applying identifiers: [String]) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Deliberately keep eraseDatabaseOnSchemaChange at its safe false default.
        for identifier in identifiers {
            switch identifier {
            case "v1_content":
                migrator.registerMigration(identifier, migrate: createContentSchema)
            case "v2_scheduling_and_app_state":
                migrator.registerMigration(
                    identifier,
                    migrate: createSchedulingAndAppStateSchema
                )
            case "v3_search_index_maintenance":
                migrator.registerMigration(identifier, migrate: createSearchIndexMaintenance)
            case "v4_ai_configuration_privacy":
                migrator.registerMigration(identifier) { db in
                    try db.execute(sql: """
                        ALTER TABLE app_settings
                        ADD COLUMN ai_enabled INTEGER NOT NULL DEFAULT 0
                        CHECK (ai_enabled IN (0, 1));

                        ALTER TABLE app_settings
                        ADD COLUMN ai_service_name TEXT;

                        ALTER TABLE app_settings
                        ADD COLUMN ai_credential_id TEXT;
                        """)
                }
            case "v5_ai_response_capability":
                migrator.registerMigration(identifier) { db in
                    try db.execute(sql: """
                        ALTER TABLE app_settings
                        ADD COLUMN ai_response_format_mode TEXT NOT NULL DEFAULT 'json_object'
                        CHECK (ai_response_format_mode IN (
                            'json_schema', 'json_object', 'prompted_json'
                        ));
                        """)
                }
            case "v6_builtin_jlpt_source":
                migrator.registerMigration(identifier, migrate: rebuildNotesForBuiltinJLPT)
            case "v7_inbox_capture":
                migrator.registerMigration(identifier, migrate: createInboxCaptureSchema)
            case "v8_adaptive_preferences":
                migrator.registerMigration(identifier, migrate: createAdaptivePreferences)
            case "v9_listening_template":
                migrator.registerMigration(identifier, migrate: rebuildCardsForListeningTemplate)
            case "v10_ai_repair_drafts":
                migrator.registerMigration(identifier, migrate: rebuildDraftsForAIRepair)
            case "v11_primary_deck":
                migrator.registerMigration(identifier) { db in
                    try db.execute(sql: """
                        ALTER TABLE app_settings
                        ADD COLUMN primary_deck_id TEXT;
                        """)
                }
            case "v12_fill_vocabulary_directions":
                migrator.registerMigration(identifier, migrate: fillVocabularyDirections)
            case "v13_note_deck_membership_and_pitch":
                migrator.registerMigration(identifier, migrate: createNoteDeckMembershipAndPitch)
            case "v14_attachments":
                migrator.registerMigration(identifier, migrate: createAttachmentsTable)
            default:
                preconditionFailure("Unknown migration identifier \(identifier)")
            }
        }
        return migrator
    }

    /// v0.5 (设计 §4.2): `note_decks` 是牌组成员关系的权威来源；
    /// `notes.deck_id` 保留为唯一归属牌组（home deck）。每个既有 Note
    /// 按其当前 deck_id 回填恰好一个初始 membership；`pitch_accent`
    /// 只加非负 CHECK，reading 依赖的完整校验在领域层执行。
    private static func createNoteDeckMembershipAndPitch(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE note_decks (
                note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
                added_at_ms INTEGER NOT NULL,
                PRIMARY KEY (note_id, deck_id)
            ) WITHOUT ROWID;

            CREATE INDEX note_decks_on_deck_note ON note_decks(deck_id, note_id);

            INSERT INTO note_decks(note_id, deck_id, added_at_ms)
            SELECT id, deck_id, created_at_ms FROM notes;

            ALTER TABLE notes
            ADD COLUMN pitch_accent INTEGER
            CHECK (pitch_accent IS NULL OR pitch_accent >= 0);
            """)
        // 迁移内断言：每个 Note 恰好一个初始 membership，且 home deck ∈ membership。
        let inconsistent = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM notes n
                WHERE NOT EXISTS (
                    SELECT 1 FROM note_decks nd
                    WHERE nd.note_id = n.id AND nd.deck_id = n.deck_id
                )
                """
        ) ?? 0
        guard inconsistent == 0 else {
            throw DatabaseError(message: "v13 backfill left \(inconsistent) notes without home membership")
        }
    }

    /// v14（便携备份 v7，设计 §11.1）：附件元数据表。`inbox_items.image_reference`
    /// 语义上引用 `attachments.id`，但故意不加外键——老数据可能有指向已删除
    /// 文件的宽松引用，强加 FK 会让既有行变成孤儿并阻塞迁移。资源 id 的字符集
    /// 契约（[A-Za-z0-9_-]{1,128}）由写入方（InboxImageStore/恢复管线）保证，
    /// 这里只约束长度下限与不可变字段的基本形态。
    private static func createAttachmentsTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE attachments (
                id TEXT PRIMARY KEY NOT NULL
                    CHECK (length(id) > 0 AND length(id) <= 128),
                relative_path TEXT NOT NULL CHECK (length(relative_path) > 0),
                mime_type TEXT NOT NULL CHECK (length(mime_type) > 0),
                byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
                sha256 TEXT NOT NULL CHECK (length(sha256) = 64),
                pixel_width INTEGER CHECK (pixel_width IS NULL OR pixel_width > 0),
                pixel_height INTEGER CHECK (pixel_height IS NULL OR pixel_height > 0),
                created_at_ms INTEGER NOT NULL
            );

            CREATE INDEX attachments_on_sha256 ON attachments(sha256);
            """)
    }

    private static func rebuildNotesForBuiltinJLPT(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE notes_v6 (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE RESTRICT,
                kind TEXT NOT NULL CHECK (kind IN ('vocabulary', 'grammar')),
                headword TEXT NOT NULL CHECK (length(trim(headword)) > 0),
                reading TEXT,
                meaning_zh TEXT NOT NULL CHECK (length(trim(meaning_zh)) > 0),
                part_of_speech TEXT,
                jlpt TEXT CHECK (jlpt IS NULL OR jlpt IN ('N1', 'N2', 'N3', 'N4', 'N5')),
                usage TEXT,
                connection TEXT,
                notes TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
                source_text TEXT,
                origin TEXT NOT NULL DEFAULT 'manual'
                    CHECK (origin IN ('manual', 'ai', 'builtin_jlpt')),
                source_ref TEXT,
                content_version INTEGER NOT NULL DEFAULT 1 CHECK (content_version >= 1),
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                CHECK (origin = 'builtin_jlpt' OR source_ref IS NULL)
            );

            INSERT INTO notes_v6(
                id, deck_id, kind, headword, reading, meaning_zh, part_of_speech,
                jlpt, usage, connection, notes, is_favorite, source_text, origin,
                source_ref, content_version, created_at_ms, updated_at_ms
            )
            SELECT id, deck_id, kind, headword, reading, meaning_zh, part_of_speech,
                   jlpt, usage, connection, notes, is_favorite, source_text, origin,
                   NULL, content_version, created_at_ms, updated_at_ms
            FROM notes;

            DROP TABLE notes;
            ALTER TABLE notes_v6 RENAME TO notes;
            CREATE INDEX notes_on_deck_id ON notes(deck_id);
            CREATE UNIQUE INDEX notes_on_builtin_source_ref
                ON notes(source_ref)
                WHERE origin = 'builtin_jlpt' AND source_ref IS NOT NULL;
            """)
        try createSearchIndexMaintenance(db)
    }

    /// v0.4 settings (需求 §16): typed-recall toggles, listening autoplay and
    /// leech reminders — deliberately separate from the speech auto-play
    /// columns. Plus the partial index Adaptive queries scan: every assessment
    /// reads a card's valid (non-undone) review samples in reviewed_at order.
    private static func createAdaptivePreferences(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE app_settings
            ADD COLUMN typed_answer_zh_ja INTEGER NOT NULL DEFAULT 0
            CHECK (typed_answer_zh_ja IN (0, 1));

            ALTER TABLE app_settings
            ADD COLUMN auto_play_listening_audio INTEGER NOT NULL DEFAULT 1
            CHECK (auto_play_listening_audio IN (0, 1));

            ALTER TABLE app_settings
            ADD COLUMN typed_answer_listening INTEGER NOT NULL DEFAULT 0
            CHECK (typed_answer_listening IN (0, 1));

            ALTER TABLE app_settings
            ADD COLUMN leech_reminders_enabled INTEGER NOT NULL DEFAULT 1
            CHECK (leech_reminders_enabled IN (0, 1));

            CREATE INDEX review_logs_on_card_key_valid_reviewed_at
                ON review_logs(card_key, reviewed_at_ms DESC)
                WHERE undone_at_ms IS NULL;
            """)
    }

    /// Canonical rebuild widening the template CHECK for `vocabulary_listening`.
    /// The migrator runs with deferred foreign-key checks (GRDB default), so
    /// referencing tables (daily_tasks, review_logs) keep resolving by name —
    /// the same mechanism the v6 notes rebuild already relies on.
    private static func rebuildCardsForListeningTemplate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE cards_v9 (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                template_kind TEXT NOT NULL CHECK (template_kind IN (
                    'vocabulary_ja_zh',
                    'vocabulary_zh_ja',
                    'vocabulary_listening',
                    'grammar_form_explanation'
                )),
                is_enabled INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0, 1)),
                state INTEGER NOT NULL CHECK (state BETWEEN 0 AND 3),
                due_at_ms INTEGER NOT NULL,
                last_review_at_ms INTEGER,
                stability REAL NOT NULL CHECK (stability >= 0),
                difficulty REAL NOT NULL CHECK (difficulty >= 0 AND difficulty <= 10),
                reps INTEGER NOT NULL CHECK (reps >= 0),
                lapses INTEGER NOT NULL CHECK (lapses >= 0),
                scheduled_days REAL NOT NULL CHECK (scheduled_days >= 0),
                elapsed_days REAL NOT NULL CHECK (elapsed_days >= 0),
                learning_step INTEGER NOT NULL CHECK (learning_step >= 0),
                first_studied_at_ms INTEGER,
                state_version INTEGER NOT NULL DEFAULT 0 CHECK (state_version >= 0),
                algorithm_version TEXT NOT NULL CHECK (length(algorithm_version) > 0),
                profile_id TEXT NOT NULL REFERENCES scheduler_profiles(id) ON DELETE RESTRICT,
                UNIQUE (note_id, template_kind)
            );

            INSERT INTO cards_v9(
                id, note_id, template_kind, is_enabled, state, due_at_ms,
                last_review_at_ms, stability, difficulty, reps, lapses,
                scheduled_days, elapsed_days, learning_step, first_studied_at_ms,
                state_version, algorithm_version, profile_id
            )
            SELECT id, note_id, template_kind, is_enabled, state, due_at_ms,
                   last_review_at_ms, stability, difficulty, reps, lapses,
                   scheduled_days, elapsed_days, learning_step, first_studied_at_ms,
                   state_version, algorithm_version, profile_id
            FROM cards;

            DROP TABLE cards;
            ALTER TABLE cards_v9 RENAME TO cards;
            CREATE INDEX cards_on_enabled_state_due ON cards(is_enabled, state, due_at_ms);
            CREATE INDEX cards_on_profile_id ON cards(profile_id);
            """)
    }

    /// Canonical rebuild widening the draft-kind CHECK for `ai_repair`.
    /// `inbox_processing_contexts.draft_id` keeps resolving by table name under
    /// deferred foreign-key checks.
    private static func rebuildDraftsForAIRepair(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE drafts_v10 (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                draft_kind TEXT NOT NULL CHECK (draft_kind IN (
                    'vocabulary', 'grammar', 'sentence_analysis', 'ai_repair'
                )),
                payload_version INTEGER NOT NULL CHECK (payload_version >= 1),
                payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
                provider_id TEXT,
                model_id TEXT,
                prompt_version TEXT,
                updated_at_ms INTEGER NOT NULL
            );

            INSERT INTO drafts_v10(
                id, draft_kind, payload_version, payload_json,
                provider_id, model_id, prompt_version, updated_at_ms
            )
            SELECT id, draft_kind, payload_version, payload_json,
                   provider_id, model_id, prompt_version, updated_at_ms
            FROM drafts;

            DROP TABLE drafts;
            ALTER TABLE drafts_v10 RENAME TO drafts;
            """)
    }

    /// v12（每日新卡额度改为按词计）：新建卡不再有方向选择，词汇固定三方向。
    /// 为所有词汇笔记补齐缺失的方向卡（New 状态进入候选池，按词额度逐日
    /// 消化）；已存在但被停用的卡保持停用——is_enabled=0 同时承载方向暂停
    /// 语义（含易错暂停），迁移不得擅自恢复。
    /// 备份恢复在导入后重跑同一逻辑，保证旧备份里的部分方向词条也被补齐。
    static func fillVocabularyDirections(_ db: Database) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let vocabularyTemplates = [
            "vocabulary_ja_zh", "vocabulary_zh_ja", "vocabulary_listening"
        ]
        let noteIDs = try String.fetchAll(
            db,
            sql: "SELECT id FROM notes WHERE kind = 'vocabulary'"
        )
        for noteID in noteIDs {
            let existingKinds = Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT template_kind FROM cards WHERE note_id = ?",
                    arguments: [noteID]
                )
            )
            let missingKinds = vocabularyTemplates.filter { !existingKinds.contains($0) }
            guard !missingKinds.isEmpty else { continue }
            guard let profileID = try String.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(
                        (SELECT profile_id FROM cards WHERE note_id = ? LIMIT 1),
                        (SELECT id FROM scheduler_profiles
                         ORDER BY created_at_ms DESC LIMIT 1)
                    )
                    """,
                arguments: [noteID]
            ) else {
                continue
            }
            for kind in missingKinds {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, state_version,
                            algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        noteID,
                        kind,
                        now,
                        SwiftFSRSReviewScheduler.algorithmVersion,
                        profileID
                    ]
                )
            }
        }
    }

    private static func createContentSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE decks (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );

            CREATE TABLE notes (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE RESTRICT,
                kind TEXT NOT NULL CHECK (kind IN ('vocabulary', 'grammar')),
                headword TEXT NOT NULL CHECK (length(trim(headword)) > 0),
                reading TEXT,
                meaning_zh TEXT NOT NULL CHECK (length(trim(meaning_zh)) > 0),
                part_of_speech TEXT,
                jlpt TEXT CHECK (jlpt IS NULL OR jlpt IN ('N1', 'N2', 'N3', 'N4', 'N5')),
                usage TEXT,
                connection TEXT,
                notes TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
                source_text TEXT,
                origin TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('manual', 'ai')),
                content_version INTEGER NOT NULL DEFAULT 1 CHECK (content_version >= 1),
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );

            CREATE TABLE examples (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                japanese TEXT NOT NULL CHECK (length(trim(japanese)) > 0),
                translation_zh TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE tags (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                normalized_name TEXT NOT NULL UNIQUE CHECK (length(normalized_name) > 0)
            );

            CREATE TABLE note_tags (
                note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (note_id, tag_id)
            ) WITHOUT ROWID;

            CREATE INDEX notes_on_deck_id ON notes(deck_id);
            CREATE INDEX examples_on_note_id_sort_order ON examples(note_id, sort_order);
            CREATE INDEX note_tags_on_tag_id ON note_tags(tag_id);
            """)
    }

    private static func createSchedulingAndAppStateSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE scheduler_profiles (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                configuration_version TEXT NOT NULL UNIQUE CHECK (length(configuration_version) > 0),
                algorithm_version TEXT NOT NULL CHECK (length(algorithm_version) > 0),
                library_revision TEXT NOT NULL CHECK (length(library_revision) > 0),
                parameters_json TEXT NOT NULL CHECK (json_valid(parameters_json)),
                desired_retention REAL NOT NULL CHECK (desired_retention > 0 AND desired_retention <= 1),
                max_interval_days REAL NOT NULL CHECK (max_interval_days >= 1),
                created_at_ms INTEGER NOT NULL
            );

            CREATE TRIGGER scheduler_profiles_are_immutable
            BEFORE UPDATE ON scheduler_profiles
            BEGIN
                SELECT RAISE(ABORT, 'scheduler profiles are immutable');
            END;

            CREATE TABLE cards (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                template_kind TEXT NOT NULL CHECK (template_kind IN (
                    'vocabulary_ja_zh',
                    'vocabulary_zh_ja',
                    'grammar_form_explanation'
                )),
                is_enabled INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0, 1)),
                state INTEGER NOT NULL CHECK (state BETWEEN 0 AND 3),
                due_at_ms INTEGER NOT NULL,
                last_review_at_ms INTEGER,
                stability REAL NOT NULL CHECK (stability >= 0),
                difficulty REAL NOT NULL CHECK (difficulty >= 0 AND difficulty <= 10),
                reps INTEGER NOT NULL CHECK (reps >= 0),
                lapses INTEGER NOT NULL CHECK (lapses >= 0),
                scheduled_days REAL NOT NULL CHECK (scheduled_days >= 0),
                elapsed_days REAL NOT NULL CHECK (elapsed_days >= 0),
                learning_step INTEGER NOT NULL CHECK (learning_step >= 0),
                first_studied_at_ms INTEGER,
                state_version INTEGER NOT NULL DEFAULT 0 CHECK (state_version >= 0),
                algorithm_version TEXT NOT NULL CHECK (length(algorithm_version) > 0),
                profile_id TEXT NOT NULL REFERENCES scheduler_profiles(id) ON DELETE RESTRICT,
                UNIQUE (note_id, template_kind)
            );

            CREATE TABLE study_days (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                local_date TEXT NOT NULL CHECK (length(local_date) = 10),
                time_zone_id TEXT NOT NULL CHECK (length(time_zone_id) > 0),
                starts_at_ms INTEGER NOT NULL,
                ends_at_ms INTEGER NOT NULL CHECK (ends_at_ms > starts_at_ms),
                new_limit INTEGER NOT NULL CHECK (new_limit >= 0),
                UNIQUE (local_date, time_zone_id)
            );

            CREATE TABLE daily_tasks (
                study_day_id TEXT NOT NULL REFERENCES study_days(id) ON DELETE CASCADE,
                card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
                category_at_admission TEXT NOT NULL CHECK (category_at_admission IN ('new', 'learning', 'review', 'relearning')),
                admitted_at_ms INTEGER NOT NULL,
                cancelled_at_ms INTEGER,
                PRIMARY KEY (study_day_id, card_id)
            ) WITHOUT ROWID;

            CREATE TABLE review_logs (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
                card_id TEXT REFERENCES cards(id) ON DELETE SET NULL,
                card_key TEXT NOT NULL CHECK (length(card_key) = 36),
                note_id TEXT NOT NULL CHECK (length(note_id) = 36),
                deck_id_at_review TEXT NOT NULL CHECK (length(deck_id_at_review) = 36),
                reviewed_at_ms INTEGER NOT NULL,
                study_day_id TEXT NOT NULL REFERENCES study_days(id) ON DELETE RESTRICT,
                was_first_study INTEGER NOT NULL CHECK (was_first_study IN (0, 1)),
                rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 4),
                previous_state_json TEXT NOT NULL CHECK (json_valid(previous_state_json)),
                next_state_json TEXT NOT NULL CHECK (json_valid(next_state_json)),
                duration_ms INTEGER NOT NULL CHECK (duration_ms >= 0),
                content_version INTEGER NOT NULL CHECK (content_version >= 1),
                profile_id TEXT NOT NULL REFERENCES scheduler_profiles(id) ON DELETE RESTRICT,
                algorithm_version TEXT NOT NULL CHECK (length(algorithm_version) > 0),
                undone_at_ms INTEGER
            );

            CREATE TABLE drafts (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                draft_kind TEXT NOT NULL CHECK (draft_kind IN ('vocabulary', 'grammar', 'sentence_analysis')),
                payload_version INTEGER NOT NULL CHECK (payload_version >= 1),
                payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
                provider_id TEXT,
                model_id TEXT,
                prompt_version TEXT,
                updated_at_ms INTEGER NOT NULL
            );

            CREATE TABLE app_settings (
                id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
                schema_version INTEGER NOT NULL CHECK (schema_version >= 1),
                learning_time_zone_id TEXT NOT NULL,
                daily_new_card_limit INTEGER NOT NULL DEFAULT 10 CHECK (daily_new_card_limit >= 0),
                retention_preset INTEGER NOT NULL DEFAULT 90 CHECK (retention_preset IN (85, 90, 95)),
                auto_play_word_audio INTEGER NOT NULL DEFAULT 0 CHECK (auto_play_word_audio IN (0, 1)),
                auto_play_example_audio INTEGER NOT NULL DEFAULT 0 CHECK (auto_play_example_audio IN (0, 1)),
                appearance TEXT NOT NULL DEFAULT 'system' CHECK (appearance IN ('system', 'light', 'dark')),
                ai_provider_id TEXT,
                ai_base_url TEXT,
                ai_model_id TEXT
            );

            CREATE TABLE search_documents (
                note_id TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                normalized_headword TEXT NOT NULL,
                normalized_reading TEXT NOT NULL,
                normalized_meaning TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE INDEX cards_on_enabled_state_due ON cards(is_enabled, state, due_at_ms);
            CREATE INDEX cards_on_profile_id ON cards(profile_id);
            CREATE INDEX review_logs_on_study_day_rating ON review_logs(study_day_id, rating);
            CREATE INDEX review_logs_on_card_reviewed_at ON review_logs(card_id, reviewed_at_ms);
            CREATE INDEX review_logs_on_card_key ON review_logs(card_key);
            CREATE INDEX daily_tasks_on_card_id ON daily_tasks(card_id);
            """)
    }

    private static func createSearchIndexMaintenance(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO search_documents(
                note_id, normalized_headword, normalized_reading, normalized_meaning
            )
            SELECT id,
                   oboe_normalize_search(headword),
                   oboe_normalize_search(COALESCE(reading, '')),
                   oboe_normalize_search(meaning_zh)
            FROM notes
            WHERE true
            ON CONFLICT(note_id) DO UPDATE SET
                normalized_headword = excluded.normalized_headword,
                normalized_reading = excluded.normalized_reading,
                normalized_meaning = excluded.normalized_meaning;

            CREATE TRIGGER notes_search_documents_after_insert
            AFTER INSERT ON notes
            BEGIN
                INSERT INTO search_documents(
                    note_id, normalized_headword, normalized_reading, normalized_meaning
                ) VALUES (
                    NEW.id,
                    oboe_normalize_search(NEW.headword),
                    oboe_normalize_search(COALESCE(NEW.reading, '')),
                    oboe_normalize_search(NEW.meaning_zh)
                );
            END;

            CREATE TRIGGER notes_search_documents_after_content_update
            AFTER UPDATE OF headword, reading, meaning_zh ON notes
            BEGIN
                INSERT INTO search_documents(
                    note_id, normalized_headword, normalized_reading, normalized_meaning
                ) VALUES (
                    NEW.id,
                    oboe_normalize_search(NEW.headword),
                    oboe_normalize_search(COALESCE(NEW.reading, '')),
                    oboe_normalize_search(NEW.meaning_zh)
                )
                ON CONFLICT(note_id) DO UPDATE SET
                    normalized_headword = excluded.normalized_headword,
                    normalized_reading = excluded.normalized_reading,
                    normalized_meaning = excluded.normalized_meaning;
            END;
            """)
    }

    private static func createInboxCaptureSchema(_ db: Database) throws {
        let textByteLimit = InboxText.maximumUTF8ByteCount
        let resumePayloadByteLimit = CaptureResumePayloadFormat.maximumUTF8ByteCount
        try db.execute(sql: """
            CREATE TABLE inbox_items (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                text TEXT NOT NULL CHECK (
                    length(trim(text)) > 0
                    AND length(CAST(text AS BLOB)) <= \(textByteLimit)
                ),
                source_type TEXT NOT NULL
                    CHECK (source_type IN ('manual', 'paste', 'share', 'ocr')),
                status TEXT NOT NULL CHECK (status IN (
                    'unprocessed', 'processing', 'processed', 'archived'
                )),
                content_revision INTEGER NOT NULL DEFAULT 1 CHECK (content_revision >= 1),
                source_app TEXT,
                source_url TEXT,
                image_reference TEXT,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                processed_at_ms INTEGER,
                archived_at_ms INTEGER,
                status_before_archive TEXT CHECK (status_before_archive IS NULL OR status_before_archive IN (
                    'unprocessed', 'processing', 'processed'
                )),
                CHECK (status = 'archived' OR (archived_at_ms IS NULL AND status_before_archive IS NULL)),
                CHECK (status != 'archived' OR (archived_at_ms IS NOT NULL AND status_before_archive IS NOT NULL)),
                CHECK (status != 'processed' OR processed_at_ms IS NOT NULL)
            );

            CREATE INDEX inbox_items_on_status_created_at
                ON inbox_items(status, created_at_ms DESC, id DESC);
            CREATE INDEX inbox_items_on_created_at
                ON inbox_items(created_at_ms DESC, id DESC);

            CREATE TABLE inbox_processing_contexts (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                inbox_item_id TEXT NOT NULL
                    REFERENCES inbox_items(id) ON DELETE CASCADE,
                content_revision INTEGER NOT NULL CHECK (content_revision >= 1),
                input_text TEXT NOT NULL CHECK (
                    length(trim(input_text)) > 0
                    AND length(CAST(input_text AS BLOB)) <= \(textByteLimit)
                ),
                mode TEXT NOT NULL CHECK (mode IN (
                    'vocabulary_generation', 'grammar_generation',
                    'sentence_analysis', 'manual_edit'
                )),
                draft_id TEXT REFERENCES drafts(id) ON DELETE SET NULL,
                payload_version INTEGER NOT NULL DEFAULT 1 CHECK (payload_version >= 1),
                resume_payload_json TEXT CHECK (resume_payload_json IS NULL OR (
                    json_valid(resume_payload_json)
                    AND length(CAST(resume_payload_json AS BLOB)) <= \(resumePayloadByteLimit)
                )),
                updated_at_ms INTEGER NOT NULL
            );

            CREATE INDEX inbox_processing_contexts_on_inbox_item_id
                ON inbox_processing_contexts(inbox_item_id);
            CREATE INDEX inbox_processing_contexts_on_draft_id
                ON inbox_processing_contexts(draft_id);

            CREATE TABLE capture_import_receipts (
                capture_id TEXT PRIMARY KEY NOT NULL CHECK (length(capture_id) = 36),
                payload_hash TEXT NOT NULL CHECK (length(payload_hash) > 0),
                inbox_item_id TEXT REFERENCES inbox_items(id) ON DELETE SET NULL,
                imported_at_ms INTEGER NOT NULL
            );

            CREATE INDEX capture_import_receipts_on_inbox_item_id
                ON capture_import_receipts(inbox_item_id);

            CREATE TABLE inbox_commit_receipts (
                operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id) = 36),
                processing_context_id TEXT
                    REFERENCES inbox_processing_contexts(id) ON DELETE SET NULL,
                payload_hash TEXT NOT NULL CHECK (length(payload_hash) > 0),
                result_json TEXT NOT NULL CHECK (json_valid(result_json)),
                committed_at_ms INTEGER NOT NULL
            );

            CREATE INDEX inbox_commit_receipts_on_processing_context_id
                ON inbox_commit_receipts(processing_context_id);
            """)
    }
}
