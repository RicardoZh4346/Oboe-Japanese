CREATE TABLE grdb_migrations (
    identifier TEXT NOT NULL PRIMARY KEY
);
INSERT INTO grdb_migrations(identifier) VALUES ('v1_content');

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

INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
VALUES ('00000000-0000-0000-0000-000000000001', '旧版测试牌组', 0, 1768478400000, 1768478400000);

INSERT INTO notes(
    id, deck_id, kind, headword, reading, meaning_zh,
    is_favorite, origin, content_version, created_at_ms, updated_at_ms
) VALUES (
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000001',
    'vocabulary', '食べる', 'たべる', '吃',
    0, 'manual', 1, 1768478400000, 1768478400000
);

INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
VALUES (
    '00000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000002',
    '毎朝パンを食べます。', '我每天早上吃面包。', 0
);

INSERT INTO tags(id, name, normalized_name)
VALUES ('00000000-0000-0000-0000-000000000004', '动词', '动词');

INSERT INTO note_tags(note_id, tag_id)
VALUES (
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000004'
);
