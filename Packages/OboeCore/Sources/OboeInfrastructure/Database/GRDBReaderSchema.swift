import Foundation
import GRDB

/// v17 `reader_*` foundation tables（v0.7.0，设计 §4.1 / §13 迁移表）。
/// 注册方式与 v16 相同：`OboeDatabaseSchema.makeMigrator` 的 switch 中
/// `case "v17_reader_foundation"` 指向本 migrate；标识符列入
/// `migrationIdentifiers`、`tableNames` 由主 agent 统一同步（§13 检查清单）。
///
/// 语义要点（§4.1–4.3）：
/// - 文档级 FK 全部 `ON DELETE CASCADE`：删文档连带位置/书签/正文/资源/缓存，
///   `source_contexts` 无 FK、原样保留（§4.3-5）。
/// - `positions.chapter_id` / `bookmarks.chapter_id` 用 `ON DELETE SET NULL`：
///   内容重建（content_revision 换章）时定位保留文档级 locator，不陪葬。
/// - `availability` 持久化 metadata 态（processing/failed 只能由库记住）；
///   `missing` 由本地文件状态推导，读取侧与服务层共同裁决——绝不从备份
///   恢复一个虚假的 available（§4.1 / §14.2）。
/// - `reader_assets` / `reader_blocks` / `reader_token_cache` 不导出备份；
///   路径一律为受控相对路径（DB CHECK 拒绝对路径，语义校验在仓储层）。
public enum GRDBReaderSchema {
    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE reader_documents (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                title TEXT NOT NULL,
                format TEXT NOT NULL
                    CHECK (format IN ('paste', 'txt', 'epub', 'srt', 'vtt')),
                created_at_ms INTEGER NOT NULL,
                last_opened_at_ms INTEGER,
                source_file_name TEXT,
                source_sha256 TEXT NOT NULL CHECK (length(source_sha256) = 64),
                canonical_text_hash TEXT NOT NULL
                    CHECK (length(canonical_text_hash) > 0),
                parser_version TEXT NOT NULL CHECK (length(parser_version) > 0),
                content_revision INTEGER NOT NULL DEFAULT 1
                    CHECK (content_revision >= 1),
                progress_basis_points INTEGER NOT NULL DEFAULT 0
                    CHECK (progress_basis_points BETWEEN 0 AND 10000),
                availability TEXT NOT NULL DEFAULT 'processing'
                    CHECK (availability IN
                        ('available', 'processing', 'missing', 'failed'))
            );

            CREATE INDEX reader_documents_on_source_sha256
                ON reader_documents(source_sha256);
            CREATE INDEX reader_documents_on_canonical_text_hash
                ON reader_documents(canonical_text_hash);

            CREATE TABLE reader_chapters (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                document_id TEXT NOT NULL
                    REFERENCES reader_documents(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
                title TEXT,
                source_locator TEXT,
                canonical_hash TEXT NOT NULL CHECK (length(canonical_hash) > 0),
                text_utf16_length INTEGER NOT NULL CHECK (text_utf16_length >= 0),
                UNIQUE (document_id, ordinal)
            );

            CREATE TABLE reader_blocks (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                document_id TEXT NOT NULL
                    REFERENCES reader_documents(id) ON DELETE CASCADE,
                chapter_id TEXT NOT NULL
                    REFERENCES reader_chapters(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
                text TEXT NOT NULL,
                text_hash TEXT NOT NULL CHECK (length(text_hash) > 0),
                locator_json TEXT
                    CHECK (locator_json IS NULL OR json_valid(locator_json)),
                UNIQUE (chapter_id, ordinal)
            );

            CREATE INDEX reader_blocks_on_document
                ON reader_blocks(document_id, chapter_id, ordinal);

            CREATE TABLE reader_positions (
                document_id TEXT PRIMARY KEY NOT NULL
                    REFERENCES reader_documents(id) ON DELETE CASCADE,
                chapter_id TEXT
                    REFERENCES reader_chapters(id) ON DELETE SET NULL,
                locator_json TEXT NOT NULL CHECK (json_valid(locator_json)),
                updated_at_ms INTEGER NOT NULL
            );

            CREATE TABLE reader_bookmarks (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                document_id TEXT NOT NULL
                    REFERENCES reader_documents(id) ON DELETE CASCADE,
                chapter_id TEXT
                    REFERENCES reader_chapters(id) ON DELETE SET NULL,
                locator_json TEXT NOT NULL CHECK (json_valid(locator_json)),
                label TEXT CHECK (label IS NULL OR length(label) <= 200),
                created_at_ms INTEGER NOT NULL
            );

            CREATE INDEX reader_bookmarks_on_document
                ON reader_bookmarks(document_id, created_at_ms);

            CREATE TABLE reader_assets (
                document_id TEXT NOT NULL
                    REFERENCES reader_documents(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL CHECK (
                    length(relative_path) > 0
                    AND relative_path NOT LIKE '/%'
                    AND instr(relative_path, '\\') = 0
                ),
                source_sha256 TEXT NOT NULL CHECK (length(source_sha256) = 64),
                install_state TEXT NOT NULL CHECK (install_state IN
                    ('pending', 'installed', 'skipped', 'missing')),
                PRIMARY KEY (document_id, relative_path)
            ) WITHOUT ROWID;

            CREATE TABLE reader_token_cache (
                block_id TEXT NOT NULL
                    REFERENCES reader_blocks(id) ON DELETE CASCADE,
                text_hash TEXT NOT NULL CHECK (length(text_hash) > 0),
                tokenizer_version TEXT NOT NULL
                    CHECK (length(tokenizer_version) > 0),
                dictionary_version TEXT NOT NULL
                    CHECK (length(dictionary_version) > 0),
                payload BLOB NOT NULL,
                PRIMARY KEY (block_id, tokenizer_version, dictionary_version)
            ) WITHOUT ROWID;
            """)
    }
}
