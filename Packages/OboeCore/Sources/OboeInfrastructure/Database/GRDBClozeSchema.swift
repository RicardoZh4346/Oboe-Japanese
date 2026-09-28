import Foundation
import GRDB

/// v19 `v19_cloze`（v0.7.0 S12，设计 §9.1–9.3 / §13 迁移表）：sentence
/// Note + 单 blank Cloze 的 schema 承载。
///
/// 注册方式与 v17/v18 相同（本任务不直接改 `OboeDatabase.swift`）：主
/// agent 在 `migrationIdentifiers` 中把 `"v19_cloze"` 插入
/// `"v18_lexical_knowledge"` 与 `"v20_import_execution"` 之间，switch 指
/// 向本 `migrate`，并把 `cloze_definitions` 加入 `tableNames`。GRDB 按
/// 注册序应用未跑过的迁移——已含 v20 的库升级时仍会补跑本迁移。
///
/// 语义要点：
/// - `notes` 重建：`kind` 放行 `sentence`，`origin` 放行
///   `reader`/`import`；`meaning_zh` 放宽为可空 + 条件 CHECK——
///   vocabulary/grammar 仍必须非空，sentence 可空但禁止空串。其余列、
///   `source_ref` 归属 CHECK、`pitch_accent`（v13）原样保留。
/// - `cards` 重建：`template_kind` 放行 `sentence_cloze`；调度列、
///   `UNIQUE(note_id, template_kind)`、profile FK RESTRICT 原样保留。
///   UNIQUE 同时天然保证「一张 sentence Note 至多一张 cloze 卡」。
/// - `source_contexts` 增 Reader 定位列（`reader_document_id`/
///   `reader_chapter_id`/`reader_location`/`selected_surface`）：延续
///   设计 §4.3-5 的**无 FK 弱引用**——原文删除后来源与定位原样保留，
///   Cloze 快照仍可复习。
/// - `cloze_definitions`：`note_id`/`card_id` 双 UNIQUE + CASCADE
///   （Note/卡消失则定义消失）；`source_context_id` SET NULL——来源
///   删除后快照独立存活（§9.3）。`accepted_answers_json` 用
///   `json_valid` + 长度 CHECK 兜底形态，「非空数组、含 surface」等
///   语义由 `ClozeValidator` 在写路径强制。
/// - 搜索触发器随 notes 重建被 DROP，本迁移以 COALESCE 版重建——
///   sentence 的 `meaning_zh` 为 NULL 时不得让 trigger 崩溃（§9.1
///   NULL 安全要求）。
/// - 重建沿用 v6/v9 的「临时表 + INSERT…SELECT + DROP + RENAME」，
///   依赖迁移事务的延迟外键检查；`lexeme_note_links`、
///   `reader_activity_events`、`import_row_receipts`、`daily_tasks`、
///   `review_logs` 等 v13–v20 子表按名字解析不受影响。迁移末尾跑
///   `PRAGMA foreign_key_check`，有违例即整体回滚。
public enum GRDBClozeSchema {
    public static func migrate(_ db: Database) throws {
        // 1) source_contexts：Reader 定位弱引用列（§4.3-5：无 FK，原样保留）。
        try db.execute(sql: """
            ALTER TABLE source_contexts
            ADD COLUMN reader_document_id TEXT
                CHECK (reader_document_id IS NULL OR length(reader_document_id) = 36);

            ALTER TABLE source_contexts
            ADD COLUMN reader_chapter_id TEXT
                CHECK (reader_chapter_id IS NULL OR length(reader_chapter_id) = 36);

            ALTER TABLE source_contexts
            ADD COLUMN reader_location TEXT
                CHECK (reader_location IS NULL OR json_valid(reader_location));

            ALTER TABLE source_contexts
            ADD COLUMN selected_surface TEXT;
            """)

        // 2) notes 重建：kind/origin 放行 + meaning_zh 条件 CHECK。
        try db.execute(sql: """
            CREATE TABLE notes_v19 (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE RESTRICT,
                kind TEXT NOT NULL CHECK (kind IN ('vocabulary', 'grammar', 'sentence')),
                headword TEXT NOT NULL CHECK (length(trim(headword)) > 0),
                reading TEXT,
                meaning_zh TEXT,
                part_of_speech TEXT,
                jlpt TEXT CHECK (jlpt IS NULL OR jlpt IN ('N1', 'N2', 'N3', 'N4', 'N5')),
                usage TEXT,
                connection TEXT,
                notes TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
                source_text TEXT,
                origin TEXT NOT NULL DEFAULT 'manual'
                    CHECK (origin IN ('manual', 'ai', 'builtin_jlpt', 'reader', 'import')),
                source_ref TEXT,
                content_version INTEGER NOT NULL DEFAULT 1 CHECK (content_version >= 1),
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                pitch_accent INTEGER
                    CHECK (pitch_accent IS NULL OR pitch_accent >= 0),
                CHECK (origin = 'builtin_jlpt' OR source_ref IS NULL),
                CHECK (
                    (kind IN ('vocabulary', 'grammar')
                        AND meaning_zh IS NOT NULL
                        AND length(trim(meaning_zh)) > 0)
                    OR (kind = 'sentence'
                        AND (meaning_zh IS NULL OR length(trim(meaning_zh)) > 0))
                )
            );

            INSERT INTO notes_v19(
                id, deck_id, kind, headword, reading, meaning_zh, part_of_speech,
                jlpt, usage, connection, notes, is_favorite, source_text, origin,
                source_ref, content_version, created_at_ms, updated_at_ms,
                pitch_accent
            )
            SELECT id, deck_id, kind, headword, reading, meaning_zh, part_of_speech,
                   jlpt, usage, connection, notes, is_favorite, source_text, origin,
                   source_ref, content_version, created_at_ms, updated_at_ms,
                   pitch_accent
            FROM notes;

            DROP TABLE notes;
            ALTER TABLE notes_v19 RENAME TO notes;
            CREATE INDEX notes_on_deck_id ON notes(deck_id);
            CREATE UNIQUE INDEX notes_on_builtin_source_ref
                ON notes(source_ref)
                WHERE origin = 'builtin_jlpt' AND source_ref IS NOT NULL;
            """)

        // 3) cards 重建：template CHECK 放行 sentence_cloze。
        try db.execute(sql: """
            CREATE TABLE cards_v19 (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                template_kind TEXT NOT NULL CHECK (template_kind IN (
                    'vocabulary_ja_zh',
                    'vocabulary_zh_ja',
                    'vocabulary_listening',
                    'grammar_form_explanation',
                    'sentence_cloze'
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

            INSERT INTO cards_v19(
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
            ALTER TABLE cards_v19 RENAME TO cards;
            CREATE INDEX cards_on_enabled_state_due ON cards(is_enabled, state, due_at_ms);
            CREATE INDEX cards_on_profile_id ON cards(profile_id);
            """)

        // 4) cloze_definitions：一张 sentence Note 恰一条定义、恰一张卡。
        //    note_id/card_id UNIQUE + CASCADE；source_context_id SET NULL。
        try db.execute(sql: """
            CREATE TABLE cloze_definitions (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                note_id TEXT NOT NULL UNIQUE
                    REFERENCES notes(id) ON DELETE CASCADE,
                card_id TEXT NOT NULL UNIQUE
                    REFERENCES cards(id) ON DELETE CASCADE,
                source_context_id TEXT
                    REFERENCES source_contexts(id) ON DELETE SET NULL,
                sentence_snapshot TEXT NOT NULL
                    CHECK (length(sentence_snapshot) > 0),
                sentence_sha256 TEXT NOT NULL CHECK (length(sentence_sha256) = 64),
                range_version INTEGER NOT NULL DEFAULT 1
                    CHECK (range_version >= 1),
                range_utf16_start INTEGER NOT NULL
                    CHECK (range_utf16_start >= 0),
                range_utf16_length INTEGER NOT NULL
                    CHECK (range_utf16_length > 0),
                target_surface TEXT NOT NULL
                    CHECK (length(target_surface) > 0),
                target_lemma TEXT,
                target_reading TEXT,
                accepted_answers_json TEXT NOT NULL
                    CHECK (json_valid(accepted_answers_json)),
                hint TEXT,
                content_version INTEGER NOT NULL DEFAULT 1
                    CHECK (content_version >= 1)
            );

            CREATE INDEX cloze_definitions_on_source_context
                ON cloze_definitions(source_context_id);
            """)

        // 5) 搜索回填 + 触发器重建（DROP TABLE notes 时旧触发器随之消失）。
        //    meaning_zh 现在可空——所有拼接必须 COALESCE，否则 sentence
        //    行会让 trigger 因 normalized_meaning NOT NULL 崩溃。
        try db.execute(sql: """
            INSERT INTO search_documents(
                note_id, normalized_headword, normalized_reading, normalized_meaning
            )
            SELECT id,
                   oboe_normalize_search(headword),
                   oboe_normalize_search(COALESCE(reading, '')),
                   oboe_normalize_search(COALESCE(meaning_zh, ''))
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
                    oboe_normalize_search(COALESCE(NEW.meaning_zh, ''))
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
                    oboe_normalize_search(COALESCE(NEW.meaning_zh, ''))
                )
                ON CONFLICT(note_id) DO UPDATE SET
                    normalized_headword = excluded.normalized_headword,
                    normalized_reading = excluded.normalized_reading,
                    normalized_meaning = excluded.normalized_meaning;
            END;
            """)

        // 6) 迁移内断言：重建后全库外键零违例（延迟检查在 commit 时也会
        //    兜底，这里把违例尽早归一化为迁移失败）。
        let violations = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"
        ) ?? 0
        guard violations == 0 else {
            throw DatabaseError(
                message: "v19_cloze rebuild left \(violations) foreign key violations"
            )
        }
    }
}
