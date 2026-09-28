import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// GRDBReaderRepository 全量 CRUD 与失败路径（v0.7.0 S04 验收 2/4）。
/// 覆盖：建文档（章+块同事务）、摘要排序、按章分页、位置 updatedAt
/// 冲突裁决、书签去重、删除级联但 source_contexts 保留、hash 重关联、
/// 资源相对路径与 token 缓存。
final class GRDBReaderRepositoryTests: XCTestCase {

    private var identifiersIncludingV17: [String] {
        OboeDatabaseSchema.migrationIdentifiers.contains("v17_reader_foundation")
            ? OboeDatabaseSchema.migrationIdentifiers
            : OboeDatabaseSchema.migrationIdentifiers + ["v17_reader_foundation"]
    }

    // MARK: - 建文档与读取

    func testCreateDocumentFetchesRoundTripAndPagesBlocks() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = GRDBReaderRepository(database: fixture.database)
        let document = Self.makeDocument()
        let chapterA = Self.makeChapter(
            documentID: document.id, ordinal: 0, title: "第一章"
        )
        let chapterB = Self.makeChapter(
            documentID: document.id, ordinal: 1, title: "第二章"
        )
        let blocksA = (0..<3).map { ordinal in
            Self.makeBlock(
                documentID: document.id, chapterID: chapterA.id,
                ordinal: ordinal, text: "A\(ordinal)"
            )
        }
        let blocksB = (0..<2).map { ordinal in
            Self.makeBlock(
                documentID: document.id, chapterID: chapterB.id,
                ordinal: ordinal, text: "B\(ordinal)"
            )
        }

        try await repository.createDocument(
            document,
            chapters: [chapterB, chapterA],  // 乱序输入，读取必须按 ordinal
            blocks: blocksA + blocksB
        )

        let fetched = try await repository.fetchDocument(id: document.id)
        XCTAssertEqual(fetched, document)

        let chapters = try await repository.fetchChapters(
            documentID: document.id
        )
        XCTAssertEqual(chapters, [chapterA, chapterB])

        // 按章分页：只取目标章的块，不整书载入。
        let pagedA = try await repository.fetchBlocks(
            documentID: document.id, chapterID: chapterA.id
        )
        XCTAssertEqual(pagedA, blocksA)
        let pagedB = try await repository.fetchBlocks(
            documentID: document.id, chapterID: chapterB.id
        )
        XCTAssertEqual(pagedB, blocksB)
        // 未建文档返回 nil。
        let missing = try await repository.fetchDocument(id: UUID())
        XCTAssertNil(missing)
    }

    func testDocumentSummariesOrderedByMostRecentOpen() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = GRDBReaderRepository(database: fixture.database)
        let older = Self.makeDocument(
            title: "旧书",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_010_000)
        )
        let newerNeverOpened = Self.makeDocument(
            title: "新书",
            createdAt: Date(timeIntervalSince1970: 1_700_005_000),
            lastOpenedAt: nil
        )
        try await repository.createDocument(older, chapters: [], blocks: [])
        try await repository.createDocument(
            newerNeverOpened, chapters: [], blocks: []
        )

        // 旧书 lastOpened 更新——排在新书前。
        var summaries = try await repository.fetchDocumentSummaries()
        XCTAssertEqual(summaries.map(\.id), [older.id, newerNeverOpened.id])

        // 打开新书后顺序翻转。
        try await repository.touchLastOpened(
            id: newerNeverOpened.id,
            at: Date(timeIntervalSince1970: 1_700_020_000)
        )
        summaries = try await repository.fetchDocumentSummaries()
        XCTAssertEqual(summaries.map(\.id), [newerNeverOpened.id, older.id])
    }

    func testCreateDocumentRejectsInconsistentOwnershipAndDuplicateID() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = GRDBReaderRepository(database: fixture.database)
        let document = Self.makeDocument()
        let alienChapter = Self.makeChapter(
            documentID: UUID(), ordinal: 0, title: nil
        )

        await XCTAssertAsyncThrows(
            try await repository.createDocument(
                document, chapters: [alienChapter], blocks: []
            )
        ) { error in
            XCTAssertEqual(
                error as? ReaderRepositoryError,
                .inconsistentChildOwnership
            )
        }
        // 事务整批回滚——文档行未残留。
        let rolledBack = try await repository.fetchDocument(id: document.id)
        XCTAssertNil(rolledBack)

        try await repository.createDocument(document, chapters: [], blocks: [])
        await XCTAssertAsyncThrows(
            try await repository.createDocument(document, chapters: [], blocks: [])
        ) { error in
            XCTAssertEqual(
                error as? ReaderRepositoryError, .documentAlreadyExists
            )
        }

        // 块挂在别文档的章 → 拒绝。
        let otherDoc = Self.makeDocument()
        let foreignChapter = Self.makeChapter(
            documentID: document.id, ordinal: 0, title: nil
        )
        let orphanBlock = Self.makeBlock(
            documentID: otherDoc.id, chapterID: foreignChapter.id,
            ordinal: 0, text: "x"
        )
        await XCTAssertAsyncThrows(
            try await repository.createDocument(
                otherDoc, chapters: [], blocks: [orphanBlock]
            )
        ) { error in
            XCTAssertEqual(
                error as? ReaderRepositoryError,
                .inconsistentChildOwnership
            )
        }
        let orphanDoc = try await repository.fetchDocument(id: otherDoc.id)
        XCTAssertNil(orphanDoc)
    }

    // MARK: - 位置

    func testPositionSaveFetchAndUpdatedAtConflictRule() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = GRDBReaderRepository(database: fixture.database)
        let document = Self.makeDocument()
        let chapter = Self.makeChapter(
            documentID: document.id, ordinal: 0, title: nil
        )
        try await repository.createDocument(
            document, chapters: [chapter], blocks: []
        )

        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let t2 = Date(timeIntervalSince1970: 1_700_000_200)
        let newer = ReaderPosition(
            documentID: document.id,
            chapterID: chapter.id,
            location: ReaderLocation(
                chapterOrdinal: 0, blockOrdinal: 2, utf16Offset: 30,
                blockTextHash: "h2", prefix: "前", suffix: "后"
            ),
            updatedAt: t2
        )
        try await repository.savePosition(newer)

        // 旧写不得覆盖较新 updatedAt。
        let stale = ReaderPosition(
            documentID: document.id,
            chapterID: chapter.id,
            location: ReaderLocation(
                chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 0,
                blockTextHash: "h0", prefix: "", suffix: ""
            ),
            updatedAt: t1
        )
        try await repository.savePosition(stale)
        var fetched = try await repository.fetchPosition(
            documentID: document.id
        )
        XCTAssertEqual(fetched, newer)

        // 较新写覆盖。
        let newest = ReaderPosition(
            documentID: document.id,
            chapterID: nil,
            location: ReaderLocation(
                chapterOrdinal: 0, blockOrdinal: 5, utf16Offset: 7,
                blockTextHash: "h5", prefix: "p", suffix: "s"
            ),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        try await repository.savePosition(newest)
        fetched = try await repository.fetchPosition(documentID: document.id)
        XCTAssertEqual(fetched, newest)

        // 缺失文档写位置 → documentNotFound；别文档的章 → chapterNotInDocument。
        await XCTAssertAsyncThrows(
            try await repository.savePosition(
                ReaderPosition(
                    documentID: UUID(), chapterID: nil,
                    location: newest.location, updatedAt: t2
                )
            )
        ) { error in
            XCTAssertEqual(error as? ReaderRepositoryError, .documentNotFound)
        }
        let otherDoc = Self.makeDocument()
        let otherChapter = Self.makeChapter(
            documentID: otherDoc.id, ordinal: 0, title: nil
        )
        try await repository.createDocument(
            otherDoc, chapters: [otherChapter], blocks: []
        )
        await XCTAssertAsyncThrows(
            try await repository.savePosition(
                ReaderPosition(
                    documentID: document.id, chapterID: otherChapter.id,
                    location: newest.location,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_400)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ReaderRepositoryError, .chapterNotInDocument
            )
        }
        // 拒绝写入后原位置仍是 newest。
        let persisted = try await repository.fetchPosition(
            documentID: document.id
        )
        XCTAssertEqual(persisted, newest)
    }

    // MARK: - 书签

    func testBookmarkAddDeduplicateRemove() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = GRDBReaderRepository(database: fixture.database)
        let document = Self.makeDocument()
        let chapter = Self.makeChapter(
            documentID: document.id, ordinal: 0, title: nil
        )
        try await repository.createDocument(
            document, chapters: [chapter], blocks: []
        )
        let location = ReaderLocation(
            chapterOrdinal: 0, blockOrdinal: 1, utf16Offset: 9,
            blockTextHash: "h", prefix: "前", suffix: "后"
        )
        let first = ReaderBookmark(
            id: UUID(), documentID: document.id, chapterID: chapter.id,
            location: location, label: "a",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        // 不同 id、同一文档同一定位——幂等去重，不产生第二条。
        let duplicate = ReaderBookmark(
            id: UUID(), documentID: document.id, chapterID: chapter.id,
            location: location, label: "b",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let elsewhere = ReaderBookmark(
            id: UUID(), documentID: document.id, chapterID: nil,
            location: ReaderLocation(
                chapterOrdinal: 0, blockOrdinal: 2, utf16Offset: 0,
                blockTextHash: "x", prefix: "", suffix: ""
            ),
            label: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_050)
        )
        try await repository.addBookmark(first)
        try await repository.addBookmark(duplicate)
        try await repository.addBookmark(elsewhere)

        var bookmarks = try await repository.fetchBookmarks(
            documentID: document.id
        )
        XCTAssertEqual(bookmarks.count, 2)
        XCTAssertEqual(bookmarks, [first, elsewhere])

        try await repository.removeBookmark(id: first.id)
        bookmarks = try await repository.fetchBookmarks(
            documentID: document.id
        )
        XCTAssertEqual(bookmarks, [elsewhere])
        await XCTAssertAsyncThrows(
            try await repository.removeBookmark(id: first.id)
        ) { error in
            XCTAssertEqual(error as? ReaderRepositoryError, .bookmarkNotFound)
        }
    }

    // MARK: - 删除级联与可用性

    func testDeleteDocumentCascadesButKeepsSourceContexts() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = GRDBReaderRepository(database: fixture.database)
        let document = Self.makeDocument()
        let chapter = Self.makeChapter(
            documentID: document.id, ordinal: 0, title: nil
        )
        let block = Self.makeBlock(
            documentID: document.id, chapterID: chapter.id,
            ordinal: 0, text: "本文"
        )
        try await repository.createDocument(
            document, chapters: [chapter], blocks: [block]
        )
        try await repository.savePosition(ReaderPosition(
            documentID: document.id, chapterID: chapter.id,
            location: ReaderLocation(
                chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 0,
                blockTextHash: "h", prefix: "", suffix: ""
            ),
            updatedAt: Date()
        ))
        try await repository.addBookmark(ReaderBookmark(
            id: UUID(), documentID: document.id, chapterID: chapter.id,
            location: ReaderLocation(
                chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 0,
                blockTextHash: "h", prefix: "", suffix: ""
            ),
            label: nil, createdAt: Date()
        ))
        try await repository.registerAsset(
            documentID: document.id,
            relativePath: "cover.png",
            sourceSHA256: String(repeating: "f", count: 64),
            installState: .installed
        )
        try await repository.saveTokenPayload(
            blockID: block.id, textHash: "h",
            tokenizerVersion: "tok-1", dictionaryVersion: "dict-1",
            payload: Data([1, 2, 3])
        )
        // reader 来源的 SourceContext——不属文档级联，必须保留（§4.3-5）。
        let deckID = UUID()
        let noteID = UUID()
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order,
                                      created_at_ms, updated_at_ms)
                    VALUES (?, '牌组', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        is_favorite, origin, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '猫', '猫', 0,
                              'manual', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, original_sentence,
                        source_title, is_primary, created_at_ms
                    ) VALUES ('ctx-1', ?, 'reader', '吾輩は猫である',
                              '书名快照', 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }

        try await repository.deleteDocument(id: document.id)
        let deletedDoc = try await repository.fetchDocument(id: document.id)
        XCTAssertNil(deletedDoc)
        let deletedPosition = try await repository.fetchPosition(
            documentID: document.id
        )
        XCTAssertNil(deletedPosition)
        let remainingBookmarks = try await repository.fetchBookmarks(
            documentID: document.id
        )
        XCTAssertEqual(remainingBookmarks, [])
        let remainingChapters = try await repository.fetchChapters(
            documentID: document.id
        )
        XCTAssertEqual(remainingChapters, [])
        let remainingBlocks = try await repository.fetchBlocks(
            documentID: document.id, chapterID: chapter.id
        )
        XCTAssertEqual(remainingBlocks, [])
        let remainingAssets = try await repository.fetchAssets(
            documentID: document.id
        )
        XCTAssertEqual(remainingAssets, [])
        let remainingTokens = try await repository.fetchTokenPayload(
            blockID: block.id,
            tokenizerVersion: "tok-1", dictionaryVersion: "dict-1"
        )
        XCTAssertNil(remainingTokens)

        // SourceContext 快照原样保留；全库 FK 一致。
        let contextSurvives = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM source_contexts WHERE id = 'ctx-1'"
            )
        }
        XCTAssertEqual(contextSurvives, 1)
        let foreignKeyViolationCount = try await fixture.database.pool
            .read { db in
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
            }
        XCTAssertEqual(foreignKeyViolationCount, 0)

        await XCTAssertAsyncThrows(
            try await repository.deleteDocument(id: document.id)
        ) { error in
            XCTAssertEqual(error as? ReaderRepositoryError, .documentNotFound)
        }
    }

    func testUpdateAvailabilityAndHashLookup() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = GRDBReaderRepository(database: fixture.database)
        let shaA = String(repeating: "a", count: 64)
        let shaB = String(repeating: "b", count: 64)
        let documentA = Self.makeDocument(sourceSHA256: shaA)
        let documentB = Self.makeDocument(
            sourceSHA256: shaB, canonicalTextHash: "shared-canon"
        )
        let documentC = Self.makeDocument(
            sourceSHA256: String(repeating: "c", count: 64),
            canonicalTextHash: "shared-canon"
        )
        for document in [documentA, documentB, documentC] {
            try await repository.createDocument(
                document, chapters: [], blocks: []
            )
        }

        try await repository.updateAvailability(
            id: documentA.id, availability: .available
        )
        let availability = try await repository
            .fetchDocument(id: documentA.id)?.availability
        XCTAssertEqual(availability, .available)
        await XCTAssertAsyncThrows(
            try await repository.updateAvailability(
                id: UUID(), availability: .missing
            )
        ) { error in
            XCTAssertEqual(error as? ReaderRepositoryError, .documentNotFound)
        }

        let byFileHash = try await repository.findDocumentByHash(
            sourceSHA256: shaA
        )
        XCTAssertEqual(byFileHash?.id, documentA.id)
        let unknownHash = try await repository.findDocumentByHash(
            sourceSHA256: String(repeating: "9", count: 64)
        )
        XCTAssertNil(unknownHash)
        // canonical hash 命中两副本——重关联由调用方确认（§4.2）。
        let canonicalMatches = try await repository
            .findDocumentsByCanonicalHash("shared-canon")
        XCTAssertEqual(
            Set(canonicalMatches.map(\.id)),
            [documentB.id, documentC.id]
        )
    }

    // MARK: - 资源与派生缓存

    func testAssetsEnforceRelativePathsAndTokenCacheRoundTrips() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = GRDBReaderRepository(database: fixture.database)
        let document = Self.makeDocument()
        let chapter = Self.makeChapter(
            documentID: document.id, ordinal: 0, title: nil
        )
        let block = Self.makeBlock(
            documentID: document.id, chapterID: chapter.id,
            ordinal: 0, text: "本文"
        )
        try await repository.createDocument(
            document, chapters: [chapter], blocks: [block]
        )

        try await repository.registerAsset(
            documentID: document.id,
            relativePath: "OEBPS/images/cover.png",
            sourceSHA256: String(repeating: "1", count: 64),
            installState: .installed
        )
        try await repository.registerAsset(
            documentID: document.id,
            relativePath: "OEBPS/remote.mov",
            sourceSHA256: String(repeating: "2", count: 64),
            installState: .skipped
        )
        for badPath in ["/etc/passwd", "../x", "a/../b", "a\\b.png", "", "/"] {
            await XCTAssertAsyncThrows(
                try await repository.registerAsset(
                    documentID: document.id,
                    relativePath: badPath,
                    sourceSHA256: String(repeating: "3", count: 64),
                    installState: .pending
                )
            ) { error in
                guard case ReaderRepositoryError.unsafeRelativePath = error else {
                    return XCTFail("应拒绝路径 \(badPath)，实际 \(error)")
                }
            }
        }
        // 验收 4：库里绝不允许落绝对路径——原始 SQL 侧再断言一次。
        let absolutePathRows = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_assets
                    WHERE relative_path LIKE '/%'
                       OR instr(relative_path, '\\') > 0
                    """
            )
        }
        XCTAssertEqual(absolutePathRows, 0)

        var assets = try await repository.fetchAssets(documentID: document.id)
        XCTAssertEqual(assets.map(\.relativePath), [
            "OEBPS/images/cover.png", "OEBPS/remote.mov"
        ])
        XCTAssertEqual(assets[0].installState, .installed)
        XCTAssertEqual(assets[1].installState, .skipped)

        try await repository.updateAssetState(
            documentID: document.id,
            relativePath: "OEBPS/images/cover.png",
            installState: .missing
        )
        assets = try await repository.fetchAssets(documentID: document.id)
        XCTAssertEqual(assets[0].installState, .missing)

        // token cache：同 key upsert；按 key 命中；文档级清理。
        try await repository.saveTokenPayload(
            blockID: block.id, textHash: "h",
            tokenizerVersion: "tok-1", dictionaryVersion: "dict-1",
            payload: Data([0xAA])
        )
        try await repository.saveTokenPayload(
            blockID: block.id, textHash: "h",
            tokenizerVersion: "tok-1", dictionaryVersion: "dict-1",
            payload: Data([0xBB])
        )
        let cachedPayload = try await repository.fetchTokenPayload(
            blockID: block.id,
            tokenizerVersion: "tok-1", dictionaryVersion: "dict-1"
        )
        XCTAssertEqual(cachedPayload, Data([0xBB]))
        let otherTokenizerPayload = try await repository.fetchTokenPayload(
            blockID: block.id,
            tokenizerVersion: "tok-2", dictionaryVersion: "dict-1"
        )
        XCTAssertNil(otherTokenizerPayload)
        try await repository.clearTokenCache(documentID: document.id)
        let clearedPayload = try await repository.fetchTokenPayload(
            blockID: block.id,
            tokenizerVersion: "tok-1", dictionaryVersion: "dict-1"
        )
        XCTAssertNil(clearedPayload)
    }

    // MARK: - 夹具

    private struct Fixture {
        let database: OboeDatabase
        let directory: URL
        func cleanup() {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GRDBReaderRepositoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("oboe.sqlite")
        let pool = try OboeDatabase.openPool(path: file.path)
        try OboeDatabaseSchema
            .makeMigrator(applying: identifiersIncludingV17)
            .migrate(pool)
        return Fixture(database: OboeDatabase(pool: pool), directory: directory)
    }

    private static func makeDocument(
        title: String = "テスト本",
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lastOpenedAt: Date? = nil,
        sourceSHA256: String = String(repeating: "0", count: 64),
        canonicalTextHash: String = "canon-hash",
        availability: ReaderDocumentAvailability = .processing
    ) -> ReaderDocumentMetadata {
        ReaderDocumentMetadata(
            id: UUID(),
            title: title,
            format: .txt,
            createdAt: createdAt,
            lastOpenedAt: lastOpenedAt,
            sourceFileName: "source.txt",
            sourceSHA256: sourceSHA256,
            canonicalTextHash: canonicalTextHash,
            parserVersion: "txt-1.0",
            contentRevision: 1,
            progressBasisPoints: 0,
            availability: availability
        )
    }

    private static func makeChapter(
        documentID: UUID,
        ordinal: Int,
        title: String?
    ) -> ReaderChapterMetadata {
        ReaderChapterMetadata(
            id: UUID(),
            documentID: documentID,
            ordinal: ordinal,
            title: title,
            sourceLocator: "loc-\(ordinal)",
            canonicalHash: "ch-\(ordinal)",
            textUTF16Length: 100
        )
    }

    private static func makeBlock(
        documentID: UUID,
        chapterID: UUID,
        ordinal: Int,
        text: String
    ) -> ReaderBlock {
        ReaderBlock(
            id: UUID(),
            documentID: documentID,
            chapterID: chapterID,
            ordinal: ordinal,
            text: text,
            textHash: "hash-\(text)",
            locatorJSON: nil
        )
    }
}

/// async 版本的 XCTAssertThrowsError。
private func XCTAssertAsyncThrows(
    _ expression: @autoclosure () async throws -> some Any,
    _ message: String = "",
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("期待抛错但未抛 \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
