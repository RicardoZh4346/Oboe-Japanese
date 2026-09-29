import Foundation
import GRDB
import OboeDomain

/// Reader 仓储错误（v0.7.0 §4）。SQLite 约束冲突不吞掉、不翻译为静默
/// 成功；归属/哈希等语义违例在写路径前置拒绝。
public enum ReaderRepositoryError: Error, Equatable, Sendable {
    case documentNotFound
    case documentAlreadyExists
    /// chapterID 不属于该 document——`chapter_id 必须属于同一 document`（§4.1）。
    case chapterNotInDocument
    /// createDocument 的 chapters/blocks 引用了别文档或不存在的章节。
    case inconsistentChildOwnership
    case bookmarkNotFound
    /// source_sha256 必须是小写 64 hex（与 attachments 同口径）。
    case invalidSHA256
    case unsafeRelativePath(String)
    /// 已持久化字段解码失败（枚举/JSON 损坏）——数据损坏，不静默降级。
    case persistedValueCorrupt(String)
}

/// `reader_assets.install_state` 的持久化值域（§4.1；schema CHECK 同源）。
public enum ReaderAssetInstallState: String, Codable, Sendable {
    /// 已登记待落盘（解析期登记、安装尚未完成）。
    case pending
    case installed
    /// requiresInstall = false（远程/不支持资源仅登记，§5 资产计划）。
    case skipped
    /// 曾安装但文件已缺失——驱动 missing 可用性降级。
    case missing
}

/// `reader_assets` 行的领域投影。
public struct ReaderAssetRecord: Equatable, Sendable {
    public let documentID: UUID
    public let relativePath: String
    public let sourceSHA256: String
    public let installState: ReaderAssetInstallState

    public init(
        documentID: UUID,
        relativePath: String,
        sourceSHA256: String,
        installState: ReaderAssetInstallState
    ) {
        self.documentID = documentID
        self.relativePath = relativePath
        self.sourceSHA256 = sourceSHA256
        self.installState = installState
    }
}

/// v0.7.0 Reader 元数据/书签/位置/块的 GRDB 仓储（§4.1–4.3，v17 表）。
///
/// - 写路径全部 `pool.write` 事务；`createDocument` 的
///   文档+章节+块是一条事务——失败整批回滚，没有半截文档。
/// - `savePosition` 用 UPSERT + `WHERE excluded.updated_at_ms >`
///   实现「旧写不覆盖新写」（§4.2 防抖窗口裁决）；同毫秒保留先写方，
///   位置冲突确定可复现。
/// - `addBookmark` 按 (document_id, locator_json) 幂等去重——定位
///   JSON 用 sortedKeys 编码保证同位必同串；label 由调用方管理。
/// - `deleteDocument` 只删 `reader_documents` 一行，位置/书签/块/
///   资源/缓存靠 FK CASCADE；`source_contexts`、Cloze、统计历史保留
///   （§4.3-5：Reader 来源行删除后快照仍在）。
/// - 恢复屏障插桩点：本层不感知 generation——恢复/导入屏障由
///   ReaderRuntime/ImportService 在进入 `pool.write` 前拒绝旧代请求
///   （§3 每请求携带 databaseGeneration）。hash 重关联入口 =
///   `findDocumentByHash`（文件 SHA-256 精确）→ `fileURL` 校验存在性；
///   canonical hash 仅作确认候选（§4.2），不自动接管旧 UUID（§4.3-6）。
public struct GRDBReaderRepository: ReaderRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    // MARK: - 文档

    public func createDocument(
        _ document: ReaderDocumentMetadata,
        chapters: [ReaderChapterMetadata],
        blocks: [ReaderBlock]
    ) async throws {
        guard PortableBackupPackageFormat.isLowercaseSHA256Hex(
            document.sourceSHA256
        ) else {
            throw ReaderRepositoryError.invalidSHA256
        }
        let chapterIDs = Set(chapters.map(\.id))
        let chapterOrdinals = Set(chapters.map(\.ordinal))
        guard chapters.allSatisfy({ $0.documentID == document.id }),
              chapterIDs.count == chapters.count,
              chapterOrdinals.count == chapters.count else {
            throw ReaderRepositoryError.inconsistentChildOwnership
        }
        guard blocks.allSatisfy({
            $0.documentID == document.id && chapterIDs.contains($0.chapterID)
        }) else {
            throw ReaderRepositoryError.inconsistentChildOwnership
        }
        try await pool.write { db in
            let documentID = DatabaseValueCodec.encode(document.id)
            guard try !Self.documentExists(documentID, in: db) else {
                throw ReaderRepositoryError.documentAlreadyExists
            }
            try Self.insertDocument(document, in: db)
            // 结构先行、块随后——仍同事务，见类型文档。
            for chapter in chapters.sorted(by: { $0.ordinal < $1.ordinal }) {
                try Self.insertChapter(chapter, in: db)
            }
            for block in blocks {
                try Self.insertBlock(block, in: db)
            }
        }
    }

    public func fetchDocument(id: UUID) async throws -> ReaderDocumentMetadata? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM reader_documents WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            ) else {
                return nil
            }
            return try Self.decodeDocument(row)
        }
    }

    /// 书库排序：最近打开优先、其后按创建时间倒序（§8.1 库列表）。
    public func fetchDocumentSummaries() async throws -> [ReaderDocumentMetadata] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM reader_documents
                    ORDER BY COALESCE(last_opened_at_ms, created_at_ms) DESC,
                             created_at_ms DESC, id ASC
                    """
            ).map(Self.decodeDocument)
        }
    }

    public func fetchChapters(
        documentID: UUID
    ) async throws -> [ReaderChapterMetadata] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM reader_chapters
                    WHERE document_id = ? ORDER BY ordinal
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            ).map(Self.decodeChapter)
        }
    }

    /// 按章分页取块，不整书载入（§17 内存约束）。
    public func fetchBlocks(
        documentID: UUID,
        chapterID: UUID
    ) async throws -> [ReaderBlock] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM reader_blocks
                    WHERE document_id = ? AND chapter_id = ?
                    ORDER BY ordinal
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    DatabaseValueCodec.encode(chapterID)
                ]
            ).map(Self.decodeBlock)
        }
    }

    // MARK: - 位置与书签

    public func savePosition(_ position: ReaderPosition) async throws {
        let locatorJSON = try Self.encodeLocation(position.location)
        try await pool.write { db in
            let documentID = DatabaseValueCodec.encode(position.documentID)
            guard try Self.documentExists(documentID, in: db) else {
                throw ReaderRepositoryError.documentNotFound
            }
            try Self.requireChapter(
                position.chapterID, belongsTo: documentID, in: db
            )
            // 较旧保存不得覆盖较新 updated_at_ms（§4.2）；
            // 同毫秒保留先写方（确定性），由 WHERE 条件吞掉过期写。
            try db.execute(
                sql: """
                    INSERT INTO reader_positions(
                        document_id, chapter_id, locator_json, updated_at_ms
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(document_id) DO UPDATE SET
                        chapter_id = excluded.chapter_id,
                        locator_json = excluded.locator_json,
                        updated_at_ms = excluded.updated_at_ms
                    WHERE excluded.updated_at_ms > reader_positions.updated_at_ms
                    """,
                arguments: [
                    documentID,
                    position.chapterID.map(DatabaseValueCodec.encode),
                    locatorJSON,
                    DatabaseValueCodec.encode(position.updatedAt)
                ]
            )
        }
    }

    public func fetchPosition(
        documentID: UUID
    ) async throws -> ReaderPosition? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM reader_positions WHERE document_id = ?",
                arguments: [DatabaseValueCodec.encode(documentID)]
            ) else {
                return nil
            }
            return try Self.decodePosition(row)
        }
    }

    /// 同文档同定位幂等：重复插入 (document_id, locator_json) 不产生第二条。
    /// label 上限 200 Character 由 schema CHECK 兜底（§4.1 表注）。
    public func addBookmark(_ bookmark: ReaderBookmark) async throws {
        let locatorJSON = try Self.encodeLocation(bookmark.location)
        try await pool.write { db in
            let documentID = DatabaseValueCodec.encode(bookmark.documentID)
            guard try Self.documentExists(documentID, in: db) else {
                throw ReaderRepositoryError.documentNotFound
            }
            try Self.requireChapter(
                bookmark.chapterID, belongsTo: documentID, in: db
            )
            try db.execute(
                sql: """
                    INSERT INTO reader_bookmarks(
                        id, document_id, chapter_id, locator_json,
                        label, created_at_ms
                    )
                    SELECT ?, ?, ?, ?, ?, ?
                    WHERE NOT EXISTS (
                        SELECT 1 FROM reader_bookmarks
                        WHERE document_id = ? AND locator_json = ?
                    )
                    """,
                arguments: [
                    DatabaseValueCodec.encode(bookmark.id),
                    documentID,
                    bookmark.chapterID.map(DatabaseValueCodec.encode),
                    locatorJSON,
                    bookmark.label,
                    DatabaseValueCodec.encode(bookmark.createdAt),
                    documentID,
                    locatorJSON
                ]
            )
        }
    }

    public func removeBookmark(id: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_bookmarks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            )
            guard db.changesCount == 1 else {
                throw ReaderRepositoryError.bookmarkNotFound
            }
        }
    }

    public func fetchBookmarks(
        documentID: UUID
    ) async throws -> [ReaderBookmark] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM reader_bookmarks
                    WHERE document_id = ? ORDER BY created_at_ms, id
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            ).map(Self.decodeBookmark)
        }
    }

    // MARK: - 生命周期

    /// 级联删除由 FK 承担（§4.3-5）：positions/bookmarks/blocks/
    /// assets/token_cache 随行消失；source_contexts 无 FK 故保留。
    /// 原文文件清理由 `ReaderFileStore.removeFiles` 负责——服务层编排，
    /// 仓储只管库内行。
    public func deleteDocument(id: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_documents WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            )
            guard db.changesCount == 1 else {
                throw ReaderRepositoryError.documentNotFound
            }
        }
    }

    public func updateAvailability(
        id: UUID,
        availability: ReaderDocumentAvailability
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE reader_documents SET availability = ?
                    WHERE id = ?
                    """,
                arguments: [availability.rawValue, DatabaseValueCodec.encode(id)]
            )
            guard db.changesCount == 1 else {
                throw ReaderRepositoryError.documentNotFound
            }
        }
    }

    // MARK: - 按内容重关联（§4.2 hash-relink 入口）

    /// 文件 SHA-256 精确优先；多副本时取最早创建者，确定性。
    public func findDocumentByHash(
        sourceSHA256: String
    ) async throws -> ReaderDocumentMetadata? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM reader_documents
                    WHERE source_sha256 = ?
                    ORDER BY created_at_ms, id LIMIT 1
                    """,
                arguments: [sourceSHA256]
            ) else {
                return nil
            }
            return try Self.decodeDocument(row)
        }
    }

    /// canonical hash 命中仅作确认候选——调用方须校验 parser_version
    /// 兼容并经用户确认后才可重关联（§4.2/§14.2）。
    public func findDocumentsByCanonicalHash(
        _ canonicalTextHash: String
    ) async throws -> [ReaderDocumentMetadata] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM reader_documents
                    WHERE canonical_text_hash = ?
                    ORDER BY created_at_ms, id
                    """,
                arguments: [canonicalTextHash]
            ).map(Self.decodeDocument)
        }
    }

    // MARK: - 基础设施扩展（非冻结契约；S05+ 安装/分词使用）

    /// 登记资源安装计划（`ReaderAssetPlan` 的持久化形态）。
    /// `relative_path` 必须是受控相对路径——与 `LocalReaderFileStore`
    /// 同一校验口径，绝对路径/穿越段直接拒绝，绝不落库。
    public func registerAsset(
        documentID: UUID,
        relativePath: String,
        sourceSHA256: String,
        installState: ReaderAssetInstallState
    ) async throws {
        guard ReaderControlledPath.isValid(relativePath) else {
            throw ReaderRepositoryError.unsafeRelativePath(relativePath)
        }
        guard PortableBackupPackageFormat.isLowercaseSHA256Hex(sourceSHA256) else {
            throw ReaderRepositoryError.invalidSHA256
        }
        try await pool.write { db in
            let documentKey = DatabaseValueCodec.encode(documentID)
            guard try Self.documentExists(documentKey, in: db) else {
                throw ReaderRepositoryError.documentNotFound
            }
            try db.execute(
                sql: """
                    INSERT INTO reader_assets(
                        document_id, relative_path, source_sha256, install_state
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(document_id, relative_path) DO UPDATE SET
                        source_sha256 = excluded.source_sha256,
                        install_state = excluded.install_state
                    """,
                arguments: [
                    documentKey, relativePath, sourceSHA256, installState.rawValue
                ]
            )
        }
    }

    public func fetchAssets(
        documentID: UUID
    ) async throws -> [ReaderAssetRecord] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM reader_assets
                    WHERE document_id = ? ORDER BY relative_path
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            ).map(Self.decodeAsset)
        }
    }

    /// 安装状态推进（installed/missing/skipped/pending），驱动
    /// availability 推导——文件缺失时服务层标记 missing 并降级文档。
    public func updateAssetState(
        documentID: UUID,
        relativePath: String,
        installState: ReaderAssetInstallState
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE reader_assets SET install_state = ?
                    WHERE document_id = ? AND relative_path = ?
                    """,
                arguments: [
                    installState.rawValue,
                    DatabaseValueCodec.encode(documentID),
                    relativePath
                ]
            )
            guard db.changesCount == 1 else {
                throw ReaderRepositoryError.persistedValueCorrupt(
                    "reader_assets \(relativePath) 不存在"
                )
            }
        }
    }

    /// 分词派生缓存 upsert（key = block+tokenizer+dictionary 版本）。
    /// 缓存可随时清理重建，不进备份（§4.1）。
    public func saveTokenPayload(
        blockID: UUID,
        textHash: String,
        tokenizerVersion: String,
        dictionaryVersion: String,
        payload: Data
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_token_cache(
                        block_id, text_hash, tokenizer_version,
                        dictionary_version, payload
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(block_id, tokenizer_version, dictionary_version)
                    DO UPDATE SET
                        text_hash = excluded.text_hash,
                        payload = excluded.payload
                    """,
                arguments: [
                    DatabaseValueCodec.encode(blockID),
                    textHash,
                    tokenizerVersion,
                    dictionaryVersion,
                    payload
                ]
            )
        }
    }

    public func fetchTokenPayload(
        blockID: UUID,
        tokenizerVersion: String,
        dictionaryVersion: String
    ) async throws -> Data? {
        try await pool.read { db in
            try Data.fetchOne(
                db,
                sql: """
                    SELECT payload FROM reader_token_cache
                    WHERE block_id = ? AND tokenizer_version = ?
                      AND dictionary_version = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(blockID),
                    tokenizerVersion,
                    dictionaryVersion
                ]
            )
        }
    }

    /// 清理文档全部派生缓存（覆盖重解析/字典升级前）。
    public func clearTokenCache(documentID: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    DELETE FROM reader_token_cache WHERE block_id IN (
                        SELECT id FROM reader_blocks WHERE document_id = ?
                    )
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            )
        }
    }

    /// 打开时间推进（书库排序依据）；文档缺失抛 documentNotFound。
    public func touchLastOpened(id: UUID, at date: Date) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE reader_documents SET last_opened_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(date),
                    DatabaseValueCodec.encode(id)
                ]
            )
            guard db.changesCount == 1 else {
                throw ReaderRepositoryError.documentNotFound
            }
        }
    }

    /// 阅读进度（万分比基点）；越界由 schema CHECK 拒回。
    public func updateProgress(id: UUID, basisPoints: Int) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE reader_documents SET progress_basis_points = ?
                    WHERE id = ?
                    """,
                arguments: [basisPoints, DatabaseValueCodec.encode(id)]
            )
            guard db.changesCount == 1 else {
                throw ReaderRepositoryError.documentNotFound
            }
        }
    }

    // MARK: - 行读写

    private static func documentExists(
        _ encodedID: String,
        in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM reader_documents WHERE id = ?)",
            arguments: [encodedID]
        ) ?? false
    }

    private static func requireChapter(
        _ chapterID: UUID?,
        belongsTo encodedDocumentID: String,
        in db: Database
    ) throws {
        guard let chapterID else { return }
        let owner: String? = try String.fetchOne(
            db,
            sql: "SELECT document_id FROM reader_chapters WHERE id = ?",
            arguments: [DatabaseValueCodec.encode(chapterID)]
        )
        guard owner == encodedDocumentID else {
            throw ReaderRepositoryError.chapterNotInDocument
        }
    }

    private static func insertDocument(
        _ document: ReaderDocumentMetadata,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_documents(
                    id, title, format, created_at_ms, last_opened_at_ms,
                    source_file_name, source_sha256, canonical_text_hash,
                    parser_version, content_revision, progress_basis_points,
                    availability
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(document.id),
                document.title,
                document.format.rawValue,
                DatabaseValueCodec.encode(document.createdAt),
                try document.lastOpenedAt.map(DatabaseValueCodec.encode),
                document.sourceFileName,
                document.sourceSHA256,
                document.canonicalTextHash,
                document.parserVersion,
                document.contentRevision,
                document.progressBasisPoints,
                document.availability.rawValue
            ]
        )
    }

    private static func insertChapter(
        _ chapter: ReaderChapterMetadata,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_chapters(
                    id, document_id, ordinal, title, source_locator,
                    canonical_hash, text_utf16_length
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(chapter.id),
                DatabaseValueCodec.encode(chapter.documentID),
                chapter.ordinal,
                chapter.title,
                chapter.sourceLocator,
                chapter.canonicalHash,
                chapter.textUTF16Length
            ]
        )
    }

    private static func insertBlock(
        _ block: ReaderBlock,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_blocks(
                    id, document_id, chapter_id, ordinal,
                    text, text_hash, locator_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(block.id),
                DatabaseValueCodec.encode(block.documentID),
                DatabaseValueCodec.encode(block.chapterID),
                block.ordinal,
                block.text,
                block.textHash,
                block.locatorJSON
            ]
        )
    }

    private static func decodeDocument(_ row: Row) throws -> ReaderDocumentMetadata {
        guard let format = ReaderDocumentFormat(rawValue: row["format"]),
              let availability = ReaderDocumentAvailability(
                  rawValue: row["availability"]
              ) else {
            throw ReaderRepositoryError.persistedValueCorrupt(
                "reader_documents 枚举值非法"
            )
        }
        let lastOpened: Int64? = row["last_opened_at_ms"]
        return ReaderDocumentMetadata(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            title: row["title"],
            format: format,
            createdAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["created_at_ms"]
            ),
            lastOpenedAt: lastOpened.map {
                DatabaseValueCodec.decodeDate(milliseconds: $0)
            },
            sourceFileName: row["source_file_name"],
            sourceSHA256: row["source_sha256"],
            canonicalTextHash: row["canonical_text_hash"],
            parserVersion: row["parser_version"],
            contentRevision: row["content_revision"],
            progressBasisPoints: row["progress_basis_points"],
            availability: availability
        )
    }

    private static func decodeChapter(_ row: Row) throws -> ReaderChapterMetadata {
        ReaderChapterMetadata(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            documentID: try DatabaseValueCodec.decodeUUID(row["document_id"]),
            ordinal: row["ordinal"],
            title: row["title"],
            sourceLocator: row["source_locator"],
            canonicalHash: row["canonical_hash"],
            textUTF16Length: row["text_utf16_length"]
        )
    }

    private static func decodeBlock(_ row: Row) throws -> ReaderBlock {
        ReaderBlock(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            documentID: try DatabaseValueCodec.decodeUUID(row["document_id"]),
            chapterID: try DatabaseValueCodec.decodeUUID(row["chapter_id"]),
            ordinal: row["ordinal"],
            text: row["text"],
            textHash: row["text_hash"],
            locatorJSON: row["locator_json"]
        )
    }

    private static func decodePosition(_ row: Row) throws -> ReaderPosition {
        let chapterID: String? = row["chapter_id"]
        return ReaderPosition(
            documentID: try DatabaseValueCodec.decodeUUID(row["document_id"]),
            chapterID: try chapterID.map(DatabaseValueCodec.decodeUUID),
            location: try decodeLocation(row["locator_json"]),
            updatedAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["updated_at_ms"]
            )
        )
    }

    private static func decodeBookmark(_ row: Row) throws -> ReaderBookmark {
        let chapterID: String? = row["chapter_id"]
        return ReaderBookmark(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            documentID: try DatabaseValueCodec.decodeUUID(row["document_id"]),
            chapterID: try chapterID.map(DatabaseValueCodec.decodeUUID),
            location: try decodeLocation(row["locator_json"]),
            label: row["label"],
            createdAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["created_at_ms"]
            )
        )
    }

    private static func decodeAsset(_ row: Row) throws -> ReaderAssetRecord {
        guard let state = ReaderAssetInstallState(
            rawValue: row["install_state"]
        ) else {
            throw ReaderRepositoryError.persistedValueCorrupt(
                "reader_assets.install_state 非法"
            )
        }
        return ReaderAssetRecord(
            documentID: try DatabaseValueCodec.decodeUUID(row["document_id"]),
            relativePath: row["relative_path"],
            sourceSHA256: row["source_sha256"],
            installState: state
        )
    }

    /// sortedKeys：同一定位编码恒为同一字符串——书签去重依赖字节相等。
    private static func encodeLocation(_ location: ReaderLocation) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(location), as: UTF8.self)
    }

    /// relink 事务内的文档行覆写（保留 title/created/lastOpened/
    /// progress；contentChanged 才推进 content_revision）。
    private static func applyRelinkDocumentUpdate(
        _ plan: ReaderRelinkPlan, in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE reader_documents SET
                    format = ?,
                    source_file_name = ?,
                    source_sha256 = ?,
                    canonical_text_hash = ?,
                    parser_version = ?,
                    content_revision = content_revision + ?,
                    availability = 'available'
                WHERE id = ?
                """,
            arguments: [
                plan.format.rawValue,
                plan.sourceFileName,
                plan.sourceSHA256,
                plan.canonicalTextHash,
                plan.parserVersion,
                plan.contentChanged ? 1 : 0,
                DatabaseValueCodec.encode(plan.documentID)
            ]
        )
        guard db.changesCount == 1 else {
            throw ReaderRepositoryError.documentNotFound
        }
    }
}

// MARK: - S24 relink：稳定 ID 内容重建单事务

extension GRDBReaderRepository: ReaderRelinkStore {
    /// 单事务提交 relink 计划：
    /// 1. 删除不复用的章/块（块删带动 token_cache 级联；章删带动其
    ///    下块级联 + positions/bookmarks 的 chapter_id SET NULL——
    ///    行保留，定位 JSON 仍在）；
    /// 2. 复用章/块刷新可变字段，新行插入；
    /// 3. 覆写 reader_documents 的 format/hash/parser/availability；
    /// 4. UPSERT 资产行。
    /// 任一步失败整体回滚——旧内容行零改动。
    public func commitRelink(_ plan: ReaderRelinkPlan) async throws {
        // 计划一致性前置：复用章必须都在最终集合；块不得引用
        // 非最终章（服务层保证，这里兜底校验）。
        let chapterIDs = Set(plan.chapters.map(\.id))
        guard plan.reusableChapterIDs.isSubset(of: chapterIDs),
              plan.chapters.allSatisfy({ $0.documentID == plan.documentID }),
              plan.blocks.allSatisfy({
                  $0.documentID == plan.documentID
                      && chapterIDs.contains($0.chapterID)
              }) else {
            throw ReaderRepositoryError.inconsistentChildOwnership
        }
        guard PortableBackupPackageFormat.isLowercaseSHA256Hex(
            plan.sourceSHA256
        ) else {
            throw ReaderRepositoryError.invalidSHA256
        }
        try await pool.write { db in
            let documentKey = DatabaseValueCodec.encode(plan.documentID)
            guard try Self.documentExists(documentKey, in: db) else {
                throw ReaderRepositoryError.documentNotFound
            }

            // 1) 非复用行删除。NOT IN 空集 → 全删（动态拼占位符）。
            if plan.reusableBlockIDs.isEmpty {
                try db.execute(
                    sql: """
                        DELETE FROM reader_blocks WHERE document_id = ?
                        """,
                    arguments: [documentKey]
                )
            } else {
                let keep = plan.reusableBlockIDs
                    .map { DatabaseValueCodec.encode($0) }
                try db.execute(
                    sql: """
                        DELETE FROM reader_blocks
                        WHERE document_id = ? AND id NOT IN (
                            \(Self.placeholders(count: keep.count))
                        )
                        """,
                    arguments: StatementArguments([documentKey] + keep)
                )
            }
            if plan.reusableChapterIDs.isEmpty {
                try db.execute(
                    sql: """
                        DELETE FROM reader_chapters WHERE document_id = ?
                        """,
                    arguments: [documentKey]
                )
            } else {
                let keep = plan.reusableChapterIDs
                    .map { DatabaseValueCodec.encode($0) }
                try db.execute(
                    sql: """
                        DELETE FROM reader_chapters
                        WHERE document_id = ? AND id NOT IN (
                            \(Self.placeholders(count: keep.count))
                        )
                        """,
                    arguments: StatementArguments([documentKey] + keep)
                )
            }

            // 2) 最终行集：复用者 UPDATE 可变字段，新行 INSERT。
            for chapter in plan.chapters.sorted(by: { $0.ordinal < $1.ordinal }) {
                if plan.reusableChapterIDs.contains(chapter.id) {
                    try db.execute(
                        sql: """
                            UPDATE reader_chapters SET
                                title = ?, source_locator = ?,
                                canonical_hash = ?, text_utf16_length = ?
                            WHERE id = ? AND document_id = ?
                            """,
                        arguments: [
                            chapter.title,
                            chapter.sourceLocator,
                            chapter.canonicalHash,
                            chapter.textUTF16Length,
                            DatabaseValueCodec.encode(chapter.id),
                            documentKey
                        ]
                    )
                } else {
                    try Self.insertChapter(chapter, in: db)
                }
            }
            for block in plan.blocks {
                if plan.reusableBlockIDs.contains(block.id) {
                    // 同 (章, ordinal, textHash) 复用：正文不变，
                    // 仅刷新 locator_json（容器内定位可能随重打包变）。
                    try db.execute(
                        sql: """
                            UPDATE reader_blocks SET
                                locator_json = ?, text_hash = ?
                            WHERE id = ?
                            """,
                        arguments: [
                            block.locatorJSON,
                            block.textHash,
                            DatabaseValueCodec.encode(block.id)
                        ]
                    )
                } else {
                    try Self.insertBlock(block, in: db)
                }
            }

            // 3) 文档 metadata 覆写 + availability=available。
            try Self.applyRelinkDocumentUpdate(plan, in: db)

            // 3.5) S17 译文重挂：译文行锚点随新块集复核——序数直中
            //    仅规范化 key，序数漂移按 (sourceHash, 相对顺序) 保序
            //    迁移 locator_key/locator_json；sourceHash/current/
            //    修订链不动（译文与原文的匹配仍在渲染侧按 hash 判定）。
            let translationMoves = try ReaderTranslationReanchor.moves(
                documentID: plan.documentID,
                chapters: plan.chapters,
                blocks: plan.blocks,
                in: db)
            try GRDBReaderTranslationStore.updateLocators(
                documentID: plan.documentID,
                moves: translationMoves,
                in: db)

            // 4) 旧 installed 资产行先降级：relink 已整体换新
            //    `ReaderFiles/<documentID>/`——旧 relative_path 对应文件
            //    不复存在，留 'installed' 会让 fileURL 解析拿到双源
            //    歧义（audit/relink 取首个 installed 行）。
            let livePaths = plan.assets.map(\.relativePath)
            if livePaths.isEmpty {
                try db.execute(
                    sql: """
                        UPDATE reader_assets SET install_state = 'missing'
                        WHERE document_id = ? AND install_state = 'installed'
                        """,
                    arguments: [documentKey]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE reader_assets SET install_state = 'missing'
                        WHERE document_id = ? AND install_state = 'installed'
                          AND relative_path NOT IN (
                            \(Self.placeholders(count: livePaths.count))
                          )
                        """,
                    arguments: StatementArguments(
                        [documentKey] + livePaths
                    )
                )
            }
            for asset in plan.assets {
                guard ReaderControlledPath.isValid(asset.relativePath) else {
                    throw ReaderRepositoryError.unsafeRelativePath(
                        asset.relativePath
                    )
                }
                try db.execute(
                    sql: """
                        INSERT INTO reader_assets(
                            document_id, relative_path, source_sha256,
                            install_state
                        ) VALUES (?, ?, ?, ?)
                        ON CONFLICT(document_id, relative_path) DO UPDATE SET
                            source_sha256 = excluded.source_sha256,
                            install_state = excluded.install_state
                        """,
                    arguments: [
                        documentKey,
                        asset.relativePath,
                        asset.sourceSHA256,
                        asset.installState.rawValue
                    ]
                )
            }
        }
    }

    private static func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func decodeLocation(_ json: String) throws -> ReaderLocation {
        do {
            return try JSONDecoder().decode(
                ReaderLocation.self,
                from: Data(json.utf8)
            )
        } catch {
            throw ReaderRepositoryError.persistedValueCorrupt(
                "locator_json 解码失败"
            )
        }
    }
}
