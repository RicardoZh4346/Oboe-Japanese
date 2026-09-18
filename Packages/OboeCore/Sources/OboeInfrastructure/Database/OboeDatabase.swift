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

public enum OboeDatabaseSchema {
    public static let migrationIdentifiers = [
        "v1_content",
        "v2_scheduling_and_app_state",
        "v3_search_index_maintenance",
        "v4_ai_configuration_privacy",
        "v5_ai_response_capability",
        "v6_builtin_jlpt_source",
        "v7_inbox_capture"
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
        "inbox_commit_receipts"
    ]

    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Deliberately keep eraseDatabaseOnSchemaChange at its safe false default.
        migrator.registerMigration(migrationIdentifiers[0]) { db in
            try createContentSchema(db)
        }
        migrator.registerMigration(migrationIdentifiers[1]) { db in
            try createSchedulingAndAppStateSchema(db)
        }
        migrator.registerMigration(migrationIdentifiers[2]) { db in
            try createSearchIndexMaintenance(db)
        }
        migrator.registerMigration(migrationIdentifiers[3]) { db in
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
        migrator.registerMigration(migrationIdentifiers[4]) { db in
            try db.execute(sql: """
                ALTER TABLE app_settings
                ADD COLUMN ai_response_format_mode TEXT NOT NULL DEFAULT 'json_object'
                CHECK (ai_response_format_mode IN (
                    'json_schema', 'json_object', 'prompted_json'
                ));
                """)
        }
        migrator.registerMigration(migrationIdentifiers[5]) { db in
            try rebuildNotesForBuiltinJLPT(db)
        }
        migrator.registerMigration(migrationIdentifiers[6]) { db in
            try createInboxCaptureSchema(db)
        }
        return migrator
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
