import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// ReaderIngestService 端到端测试（v0.7.0 S05 验收 3/3）。
/// 覆盖：TXT/粘贴入库、文件安装与回读、hash 去重、坏编码/取消/
/// install 失败零残留、进度单调性、1MiB RSS 有界。
final class ReaderIngestServiceTests: XCTestCase {

    private struct Fixture {
        let database: OboeDatabase
        let repository: GRDBReaderRepository
        let store: LocalReaderFileStore
        let service: ReaderIngestService
        let directory: URL
        let sourceDirectory: URL

        func cleanup() {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ReaderIngestServiceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let sourceDirectory = directory.appendingPathComponent(
            "sources", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory, withIntermediateDirectories: true
        )
        let pool = try OboeDatabase.openPool(
            path: directory.appendingPathComponent("oboe.sqlite").path
        )
        try OboeDatabaseSchema.makeMigrator().migrate(pool)
        let database = OboeDatabase(pool: pool)
        let repository = GRDBReaderRepository(database: database)
        let store = LocalReaderFileStore(
            baseDirectoryURL: directory.appendingPathComponent("library")
        )
        let service = ReaderIngestService(
            fileStore: store, repository: repository
        )
        return Fixture(
            database: database,
            repository: repository,
            store: store,
            service: service,
            directory: directory,
            sourceDirectory: sourceDirectory
        )
    }

    private func writeSource(
        _ fixture: Fixture, name: String, data: Data
    ) throws -> URL {
        let url = fixture.sourceDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func fetchBlocks(
        _ fixture: Fixture, documentID: UUID
    ) async throws -> [ReaderBlock] {
        let chapters = try await fixture.repository.fetchChapters(
            documentID: documentID
        )
        var all: [ReaderBlock] = []
        for chapter in chapters {
            all.append(
                contentsOf: try await fixture.repository.fetchBlocks(
                    documentID: documentID, chapterID: chapter.id
                )
            )
        }
        return all
    }

    private func stagingEntries(_ fixture: Fixture) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: fixture.store.stagingDirectoryURL.path
        )) ?? []
    }

    // MARK: - 端到端

    func testTextFileImportPersistsEverythingAndInstallsFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let text = "第一章です。\r\n\r\n第二章は長い。やはり長い。"
        let file = try writeSource(
            fixture, name: "我的书.txt", data: Data(text.utf8)
        )
        let result = try await fixture.service.importTextFile(fileURL: file)

        XCTAssertTrue(result.wasCreated)
        let document = result.document
        XCTAssertEqual(document.title, "我的书")
        XCTAssertEqual(document.format, .txt)
        XCTAssertEqual(document.sourceFileName, "我的书.txt")
        XCTAssertEqual(document.availability, .available)
        XCTAssertEqual(
            document.canonicalTextHash,
            ReaderHashing.sha256Hex(
                Data("第一章です。\n\n第二章は長い。やはり長い。".utf8)
            )
        )

        // 章/块已落库。
        let chapters = try await fixture.repository.fetchChapters(
            documentID: document.id
        )
        XCTAssertEqual(chapters.count, 1)
        let blocks = try await fetchBlocks(fixture, documentID: document.id)
        XCTAssertEqual(
            blocks.map(\.text).joined(),
            "第一章です。\n\n第二章は長い。やはり長い。"
        )
        XCTAssertEqual(blocks.count, 2)

        // 文件原子安装并可经 fileURL 解析回读。
        guard let relative = result.sourceRelativePath else {
            return XCTFail("sourceRelativePath 缺失")
        }
        let resolved = fixture.store.fileURL(
            documentID: document.id, relativePath: relative
        )
        guard let resolved else { return XCTFail("fileURL 解析失败") }
        XCTAssertEqual(try String(contentsOf: resolved, encoding: .utf8),
                       text)

        // 源文件登记为 installed 资产。
        let assets = try await fixture.repository.fetchAssets(
            documentID: document.id
        )
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets[0].installState, .installed)
        XCTAssertEqual(assets[0].sourceSHA256, document.sourceSHA256)
        XCTAssertEqual(assets[0].relativePath, relative)

        // canonical hash 重关联可查（§4.3-4）。
        let canonicalHits = try await fixture.repository
            .findDocumentsByCanonicalHash(document.canonicalTextHash)
        XCTAssertEqual(canonicalHits.map(\.id), [document.id])
        // staging 无残留。
        XCTAssertTrue(stagingEntries(fixture).isEmpty)
    }

    func testPasteImportWritesUTF8FileAndPersists() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let paste = "見出し行\r\n\r\n本文です😀"
        let result = try await fixture.service.importPaste(paste)

        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.document.format, .paste)
        XCTAssertEqual(result.document.title, "見出し行")
        XCTAssertNil(result.document.sourceFileName)

        // 粘贴文本落为本地 UTF-8 TXT（后续可导出原文）。
        guard let relative = result.sourceRelativePath,
              let fileURL = fixture.store.fileURL(
                  documentID: result.document.id, relativePath: relative
              ) else {
            return XCTFail("粘贴文件未安装")
        }
        XCTAssertTrue(relative.hasSuffix(".txt"))
        let readBack = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(readBack, "見出し行\n\n本文です😀")

        let blocks = try await fetchBlocks(
            fixture, documentID: result.document.id
        )
        XCTAssertEqual(blocks.map(\.text).joined(), readBack)

        // source_sha256 = 生成的 UTF-8 字节哈希（去重以落盘内容为准）。
        let fileBytes = try Data(contentsOf: fileURL)
        XCTAssertEqual(
            result.document.sourceSHA256,
            ReaderHashing.sha256Hex(fileBytes)
        )
    }

    // MARK: - 去重

    func testReimportIdenticalSourceReturnsExistingDocument() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let data = Data("重複チェック\n\n二段落目".utf8)
        let first = try writeSource(
            fixture, name: "dup-a.txt", data: data
        )
        let second = try writeSource(
            fixture, name: "dup-b.txt", data: data
        )
        let firstResult = try await fixture.service.importTextFile(
            fileURL: first
        )
        let secondResult = try await fixture.service.importTextFile(
            fileURL: second
        )
        XCTAssertTrue(firstResult.wasCreated)
        XCTAssertFalse(secondResult.wasCreated)
        XCTAssertEqual(firstResult.document.id, secondResult.document.id)
        // 命中去重时仍返回既有文档的源资产路径。
        XCTAssertEqual(
            secondResult.sourceRelativePath,
            firstResult.sourceRelativePath
        )
        let summaries = try await fixture.repository
            .fetchDocumentSummaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertTrue(stagingEntries(fixture).isEmpty)
    }

    // MARK: - 失败路径

    func testUndeterminedEncodingLeavesNoDocumentOrFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sjis = "こんにちは世界".data(using: .shiftJIS)!
        let file = try writeSource(fixture, name: "bad.txt", data: sjis)
        await assertThrowsAsync {
            try await fixture.service.importTextFile(fileURL: file)
        } errorHandler: { error in
            guard case .undeterminedEncoding =
                error as? ReaderParserError
            else {
                return XCTFail("期待 undeterminedEncoding，得 \(error)")
            }
        }
        let summaries = try await fixture.repository
            .fetchDocumentSummaries()
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertTrue(stagingEntries(fixture).isEmpty)
        XCTAssertTrue(installedDocumentDirectories(fixture).isEmpty)
    }

    /// install 失败（目标 documentID 被文件占用）→ install 发生在
    /// 任何 DB 写之前：无文档行、staging 槽位收敛。
    func testInstallFailureLeavesNoDocumentRow() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let documentID = UUID()
        // 在最终落地路径放一个普通文件：原子目录改名必失败。
        let blockerPath = fixture.store.documentDirectoryURL(
            documentID: documentID
        )
        try FileManager.default.createDirectory(
            at: fixture.store.documentsDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("占用".utf8).write(to: blockerPath)

        let file = try writeSource(
            fixture, name: "ok.txt", data: Data("正しい本文".utf8)
        )
        await assertThrowsAsync {
            try await fixture.service.importTextFile(
                fileURL: file, documentID: documentID
            )
        } errorHandler: { _ in }
        let summaries = try await fixture.repository
            .fetchDocumentSummaries()
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertTrue(stagingEntries(fixture).isEmpty)
        // 占位文件未被破坏。
        XCTAssertEqual(
            try String(contentsOf: blockerPath, encoding: .utf8),
            "占用"
        )
    }

    /// 消费中途取消（块流挂起）：无文档行、无安装目录、staging 清空。
    func testCancellationLeavesNoTrace() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let file = try writeSource(
            fixture, name: "c.txt", data: Data("内容".utf8)
        )
        let documentID = UUID()
        let task = Task {
            try await fixture.service.ingestFile(
                preparedFileURL: file,
                displayName: nil,
                parser: HangingParser(),
                limits: .default,
                documentID: documentID,
                progress: nil
            )
        }
        // 让管线推进到挂起的块流处再取消。
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await assertThrowsAsync {
            try await task.value
        } errorHandler: { error in
            XCTAssertEqual(error as? ReaderParserError, .cancelled)
        }
        let summaries = try await fixture.repository
            .fetchDocumentSummaries()
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertTrue(stagingEntries(fixture).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.store.documentDirectoryURL(
                    documentID: documentID
                ).path
            )
        )
    }

    func testWhitespacePasteRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        await assertThrowsAsync {
            try await fixture.service.importPaste("  \n\t ")
        } errorHandler: { error in
            XCTAssertEqual(error as? ReaderParserError, .emptyContent)
        }
        let summaries = try await fixture.repository
            .fetchDocumentSummaries()
        XCTAssertTrue(summaries.isEmpty)
    }

    // MARK: - 进度

    func testProgressIsMonotonicAndTerminatesAtOne() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let file = try writeSource(
            fixture,
            name: "p.txt",
            data: Data(String(repeating: "進捗。", count: 500).utf8)
        )
        let values = MutexBox<[Double]>([])
        _ = try await fixture.service.importTextFile(
            fileURL: file,
            progress: { value in values.withLock { $0.append(value) } }
        )
        let progress = values.withLock { $0 }
        XCTAssertEqual(progress.last, 1.0)
        XCTAssertTrue(progress.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(
            progress, progress.sorted(),
            "进度必须单调不减：\(progress)"
        )
        XCTAssertGreaterThanOrEqual(progress.count, 3)
    }

    // MARK: - RSS 有界（1MiB 文本）

    /// 1MiB 无换行文本（最坏切块路径）：导入全程 RSS 增量 < 50MiB。
    /// 证据行打进 CI 日志。
    func testOneMegabyteImportStaysUnder50MiBRSSDelta() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let text = String(repeating: "これは一文です", count: 76_000)
        let file = try writeSource(
            fixture, name: "big.txt", data: Data(text.utf8)
        )
        XCTAssertGreaterThanOrEqual(
            try Data(contentsOf: file).count, 1_048_576
        )

        let sampler = ImportPeakRSSSampler()
        let baseline = ImportResidentSize.current()
        sampler.start()
        let result = try await fixture.service.importTextFile(fileURL: file)
        let peak = sampler.stop()
        let delta = peak - baseline
        print("""
            [S05] 1MiB txt import: baseline=\(baseline / 1_048_576)MiB \
            peak=\(peak / 1_048_576)MiB delta=\(delta / 1_048_576)MiB
            """)
        XCTAssertTrue(result.wasCreated)
        XCTAssertLessThan(
            delta, 50 * 1_048_576,
            "1MiB 导入 RSS 增量越界：\(delta)B"
        )
        let blocks = try await fetchBlocks(
            fixture, documentID: result.document.id
        )
        XCTAssertEqual(blocks.map(\.text).joined(), text)
    }

    // MARK: - 辅助

    private func installedDocumentDirectories(_ fixture: Fixture) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: fixture.store.documentsDirectoryURL.path
        )) ?? []
    }

    private func assertThrowsAsync(
        _ expression: () async throws -> some Any,
        errorHandler: (Error) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("期待抛错但未抛", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}

/// 测试专用挂起 parser：open 正常返回，块流 yield 一块后永不
/// finish——把 ingest 钉在 for-await 上以便确定性取消。
private struct HangingParser: ReaderParser {
    let format: ReaderDocumentFormat = .txt
    let parserVersion = "hang-1.0"

    func open(
        fileURL: URL,
        sourceSHA256: String,
        limits: ReaderParserLimits
    ) async throws -> ReaderParseSession {
        HangingSession(sourceSHA256: sourceSHA256)
    }
}

private struct HangingSession: ReaderParseSession {
    let sourceSHA256: String
    let format: ReaderDocumentFormat = .txt
    let canonicalTextHash = "hang-canon"
    let parserVersion = "hang-1.0"
    var suggestedTitle: String { "hang" }
    var chapters: [ReaderChapterDraft] {
        [ReaderChapterDraft(
            ordinal: 0,
            title: nil,
            sourceLocator: nil,
            canonicalHash: canonicalTextHash,
            textUTF16Length: 1
        )]
    }
    var assets: [ReaderAssetPlan] { [] }

    func blocks(forChapter ordinal: Int) throws -> ReaderBlockStream {
        ReaderBlockStream { continuation in
            continuation.yield(
                ReaderBlockDraft(
                    ordinal: 0,
                    text: "x",
                    textHash: "h",
                    locatorJSON: nil
                )
            )
            // 永不 finish：消费侧取消 → for-await 以 nil 退出。
        }
    }
}

/// @Sendable 进度回调里收集值的锁盒（测试内单线程断言）。
private final class MutexBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
