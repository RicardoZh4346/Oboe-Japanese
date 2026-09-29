import Foundation
import GRDB
@testable import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// S17 `reader_translation_blocks` 运行时面（v25）。
///
/// 覆盖：publish 原子 current 翻转/修订链、fetchCurrent/History、
/// fetchRenderable 活动原文 hash 过滤、updateLocators 重挂与合并
/// 冲突、invalidInput 守卫、document CASCADE。
final class GRDBReaderTranslationStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translation-store-tests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - publish / current 翻转

    func testPublishSetsCurrentAndFirstRevision() async throws {
        let env = try makeEnvironment()
        let row = try await env.pool.write { db in
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID,
                locatorKey: "b1",
                locatorJSON: #"{"block":"b1"}"#,
                sourceHash: "h1",
                language: "zh-Hans",
                translatedText: "译文一",
                provider: "fake", model: "m-1",
                promptVersion: "p-1", requestHash: "rq-1",
                at: Date(timeIntervalSince1970: 1_000),
                in: db)
        }
        XCTAssertEqual(row.translationRevision, 1)
        XCTAssertTrue(row.isCurrent)
        XCTAssertEqual(row.locatorKey, "b1")

        let current = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchCurrent(
                documentID: env.documentID, in: db)
        }
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.translatedText, "译文一")
    }

    func testPublishNewRevisionFlipsOldCurrentInSameTransaction()
        async throws
    {
        let env = try makeEnvironment()
        _ = try await env.pool.write { db in
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID, locatorKey: "b1",
                locatorJSON: #"{"block":"b1"}"#, sourceHash: "h1",
                language: "zh-Hans", translatedText: "旧译文",
                at: Date(timeIntervalSince1970: 1_000), in: db)
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID, locatorKey: "b1",
                locatorJSON: #"{"block":"b1"}"#, sourceHash: "h1",
                language: "zh-Hans", translatedText: "新译文",
                at: Date(timeIntervalSince1970: 2_000), in: db)
        }

        let current = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchCurrent(
                documentID: env.documentID, language: "zh-Hans", in: db)
        }
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.translatedText, "新译文")
        XCTAssertEqual(current.first?.translationRevision, 2)

        let history = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchHistory(
                documentID: env.documentID, locatorKey: "b1",
                language: "zh-Hans", in: db)
        }
        XCTAssertEqual(
            history.map(\.translatedText), ["新译文", "旧译文"])
        XCTAssertEqual(
            history.map(\.isCurrent), [true, false])
    }

    /// 「旧译文直到新结果成功后才替换」的失败半边——新结果未发表
    /// 前（publish 未调用/抛错）旧 current 原样保留。
    func testOldCurrentSurvivesUntilNewPublish() async throws {
        let env = try makeEnvironment()
        _ = try await env.pool.write { db in
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID, locatorKey: "b1",
                locatorJSON: #"{"block":"b1"}"#, sourceHash: "h1",
                language: "zh-Hans", translatedText: "旧译文",
                at: Date(timeIntervalSince1970: 1_000), in: db)
        }
        // 模拟一次失败的重译——publish 以 invalidInput 拒绝，事务
        // 内不得产生任何写入。
        await XCTAssertThrowsErrorAsync(
            try await env.pool.write { db in
                try GRDBReaderTranslationStore.publish(
                    documentID: env.documentID, locatorKey: "b1",
                    locatorJSON: #"{"block":"b1"}"#, sourceHash: "h1",
                    language: "zh-Hans", translatedText: "",
                    at: Date(timeIntervalSince1970: 2_000), in: db)
            })
        let current = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchCurrent(
                documentID: env.documentID, in: db)
        }
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.translatedText, "旧译文")
    }

    /// 不同 sourceHash（原文已改）发表是另一条修订链，从 1 起。
    func testPublishAfterSourceChangeStartsNewRevisionChain()
        async throws
    {
        let env = try makeEnvironment()
        let rows = try await env.pool.write { db in
            let first = try GRDBReaderTranslationStore.publish(
                documentID: env.documentID, locatorKey: "b1",
                locatorJSON: #"{"block":"b1"}"#, sourceHash: "h1",
                language: "zh-Hans", translatedText: "旧源译文",
                at: Date(timeIntervalSince1970: 1_000), in: db)
            let second = try GRDBReaderTranslationStore.publish(
                documentID: env.documentID, locatorKey: "b1",
                locatorJSON: #"{"block":"b1"}"#, sourceHash: "h2",
                language: "zh-Hans", translatedText: "新源译文",
                at: Date(timeIntervalSince1970: 2_000), in: db)
            return [first, second]
        }
        XCTAssertEqual(rows[0].translationRevision, 1)
        XCTAssertEqual(rows[1].translationRevision, 1)

        let history = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchHistory(
                documentID: env.documentID, locatorKey: "b1",
                language: "zh-Hans", in: db)
        }
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(
            Set(history.map(\.translationRevision)), [1])
        XCTAssertEqual(
            history.filter(\.isCurrent).count, 1)
        XCTAssertEqual(
            history.first(where: \.isCurrent)?.sourceHash, "h2")
    }

    /// 同一 locator 不同语言各自持有 current——部分唯一索引按
    /// language 隔离。
    func testLanguagesHoldIndependentCurrents() async throws {
        let env = try makeEnvironment()
        try await env.pool.write { db in
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID, locatorKey: "b1",
                locatorJSON: #"{"block":"b1"}"#, sourceHash: "h1",
                language: "zh-Hans", translatedText: "中译文",
                in: db)
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID, locatorKey: "b1",
                locatorJSON: #"{"block":"b1"}"#, sourceHash: "h1",
                language: "en", translatedText: "English",
                in: db)
        }
        let all = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchCurrent(
                documentID: env.documentID, in: db)
        }
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map(\.language)), ["zh-Hans", "en"])
    }

    // MARK: - fetchRenderable（不匹配原文不落位）

    func testFetchRenderableFiltersByLiveSourceHash() async throws {
        let env = try makeEnvironment()
        try await env.pool.write { db in
            // 两块原文。
            try Self.insertChapter(
                id: env.chapterID, documentID: env.documentID, in: db)
            try Self.insertBlock(
                id: env.block1ID, documentID: env.documentID,
                chapterID: env.chapterID, ordinal: 0,
                textHash: "h-live", in: db)
            try Self.insertBlock(
                id: env.block2ID, documentID: env.documentID,
                chapterID: env.chapterID, ordinal: 1,
                textHash: "h-dead", in: db)
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID,
                locatorKey: env.block1ID.uuidString.lowercased(),
                locatorJSON: #"{"block":"b1"}"#, sourceHash: "h-live",
                language: "zh-Hans", translatedText: "活译文", in: db)
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID,
                locatorKey: env.block2ID.uuidString.lowercased(),
                locatorJSON: #"{"block":"b2"}"#, sourceHash: "h-old",
                language: "zh-Hans", translatedText: "旧源译文",
                in: db)
        }

        let liveHashes = try await env.pool.read { db in
            try GRDBReaderTranslationStore.liveBlockSourceHashes(
                documentID: env.documentID, in: db)
        }
        // block1 hash 一致（可渲染）；block2 存的是 h-old 而活块
        // 已是 h-dead —— 不匹配，不落位。
        let renderable = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchRenderable(
                documentID: env.documentID, language: "zh-Hans",
                liveSourceHashes: liveHashes, in: db)
        }
        XCTAssertEqual(renderable.count, 1)
        XCTAssertEqual(
            renderable[env.block1ID.uuidString.lowercased()]?
                .translatedText,
            "活译文")

        // 不匹配的行仍在库里（历史/追溯），只是不渲染。
        let all = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchCurrent(
                documentID: env.documentID, in: db)
        }
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - updateLocators（重挂）

    func testUpdateLocatorsReanchorsWithoutTouchingMatchFields()
        async throws
    {
        let env = try makeEnvironment()
        _ = try await env.pool.write { db in
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID, locatorKey: "old-key",
                locatorJSON: #"{"block":"old"}"#, sourceHash: "h1",
                language: "zh-Hans", translatedText: "译文",
                in: db)
            try GRDBReaderTranslationStore.updateLocators(
                documentID: env.documentID,
                moves: [(
                    oldLocatorKey: "old-key",
                    newLocatorKey: "new-key",
                    newLocatorJSON: #"{"block":"new"}"#
                )], in: db)
        }
        let current = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchCurrent(
                documentID: env.documentID, in: db)
        }
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.locatorKey, "new-key")
        XCTAssertEqual(current.first?.locatorJSON, #"{"block":"new"}"#)
        XCTAssertEqual(current.first?.sourceHash, "h1")
        XCTAssertEqual(current.first?.translatedText, "译文")
    }

    /// 两锚点合并撞 current 唯一——必须显式失败，不许静默吞掉
    /// 一条译文。
    func testUpdateLocatorsRejectsCurrentCollision() async throws {
        let env = try makeEnvironment()
        await XCTAssertThrowsErrorAsync(
            try await env.pool.write { db in
                try GRDBReaderTranslationStore.publish(
                    documentID: env.documentID, locatorKey: "k1",
                    locatorJSON: #"{"block":"1"}"#, sourceHash: "h1",
                    language: "zh-Hans", translatedText: "一", in: db)
                try GRDBReaderTranslationStore.publish(
                    documentID: env.documentID, locatorKey: "k2",
                    locatorJSON: #"{"block":"2"}"#, sourceHash: "h2",
                    language: "zh-Hans", translatedText: "二", in: db)
                try GRDBReaderTranslationStore.updateLocators(
                    documentID: env.documentID,
                    moves: [(
                        oldLocatorKey: "k2",
                        newLocatorKey: "k1",
                        newLocatorJSON: #"{"block":"2"}"#
                    )], in: db)
            })
    }

    // MARK: - 守卫与 CASCADE

    func testInvalidInputsRejected() async throws {
        let env = try makeEnvironment()
        for (locatorKey, locatorJSON, sourceHash, language, text) in [
            ("", #"{"a":1}"#, "h", "zh-Hans", "x"),       // 空 locatorKey
            ("k", "not-json", "h", "zh-Hans", "x"),      // 非法 locatorJSON
            ("k", #"{"a":1}"#, "", "zh-Hans", "x"),      // 空 sourceHash
            ("k", #"{"a":1}"#, "h", "", "x"),            // 空 language
            ("k", #"{"a":1}"#, "h", "zh-Hans", ""),      // 空译文
        ] {
            await XCTAssertThrowsErrorAsync(
                try await env.pool.write { db in
                    try GRDBReaderTranslationStore.publish(
                        documentID: env.documentID,
                        locatorKey: locatorKey, locatorJSON: locatorJSON,
                        sourceHash: sourceHash, language: language,
                        translatedText: text, in: db)
                })
        }
        let count = try await env.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM reader_translation_blocks")
        }
        XCTAssertEqual(count, 0)
    }

    func testDocumentDeleteCascadesRows() async throws {
        let env = try makeEnvironment()
        try await env.pool.write { db in
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID, locatorKey: "b1",
                locatorJSON: #"{"block":"b1"}"#, sourceHash: "h1",
                language: "zh-Hans", translatedText: "译文", in: db)
            try db.execute(
                sql: "DELETE FROM reader_documents WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(env.documentID)])
        }
        let count = try await env.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM reader_translation_blocks")
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - 环境

    private struct Environment {
        let pool: DatabasePool
        let documentID: UUID
        let chapterID: UUID
        let block1ID: UUID
        let block2ID: UUID
    }

    private func makeEnvironment() throws -> Environment {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("db.sqlite").path,
            configuration: configuration)
        try OboeDatabaseSchema.makeMigrator(
            applying: OboeDatabaseSchema.migrationIdentifiers
        ).migrate(pool)
        let env = Environment(
            pool: pool, documentID: UUID(), chapterID: UUID(),
            block1ID: UUID(), block2ID: UUID())
        try pool.write { db in
            try Self.insertDocument(id: env.documentID, in: db)
        }
        return env
    }

    private static func insertDocument(id: UUID, in db: Database)
        throws
    {
        try db.execute(
            sql: """
                INSERT INTO reader_documents(
                    id, title, format, created_at_ms, source_sha256,
                    canonical_text_hash, parser_version, availability)
                VALUES (?, '翻译测试', 'paste', 1,
                        '0000000000000000000000000000000000000000000000000000000000000000',
                        'hash1', 'parser-1', 'available')
                """,
            arguments: [DatabaseValueCodec.encode(id)])
    }

    private static func insertChapter(
        id: UUID, documentID: UUID, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_chapters(
                    id, document_id, ordinal, title, source_locator,
                    canonical_hash, text_utf16_length)
                VALUES (?, ?, 0, '章节', NULL, 'ch-hash', 10)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(documentID),
            ])
    }

    private static func insertBlock(
        id: UUID, documentID: UUID, chapterID: UUID, ordinal: Int,
        textHash: String, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_blocks(
                    id, document_id, chapter_id, ordinal, text,
                    text_hash, locator_json)
                VALUES (?, ?, ?, ?, '原文', ?, NULL)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(documentID),
                DatabaseValueCodec.encode(chapterID),
                ordinal,
                textHash,
            ])
    }
}

/// async 抛错断言小助手（XCTest 无内建 async 变体）。
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
