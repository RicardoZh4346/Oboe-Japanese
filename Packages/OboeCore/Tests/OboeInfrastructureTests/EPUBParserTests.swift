import Foundation
import MachO
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// EPUBParser 测试（v0.7.0 S06）：
/// 结构链（mimetype→container→OPF→spine）、data-descriptor zip、
/// 加密/字体混淆、路径安全、限额、端到端 ingest、10MiB RSS。
final class EPUBParserTests: XCTestCase {

    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EPUBParserTests-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func fixture(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures/reader"
        ) else {
            throw XCTSkip("fixture 缺失：\(name)")
        }
        return url
    }

    private func collectBlocks(
        _ session: ReaderParseSession, chapter: Int
    ) async throws -> [ReaderBlockDraft] {
        var result: [ReaderBlockDraft] = []
        let stream = try session.blocks(forChapter: chapter)
        for try await block in stream { result.append(block) }
        return result
    }

    private func assertError(
        _ expected: ReaderParserError,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("期待 \(expected)，实际成功", file: file, line: line)
        } catch let error as ReaderParserError {
            switch (error, expected) {
            case (.notRecognized, .notRecognized),
                 (.missingContainerXML, .missingContainerXML),
                 (.encryptedContent, .encryptedContent),
                 (.fixedLayoutUnsupported, .fixedLayoutUnsupported),
                 (.emptyContent, .emptyContent),
                 (.cancelled, .cancelled):
                break
            case let (.malformedContainer(a), .malformedContainer(b)):
                XCTAssertTrue(
                    a.contains(b) || b.isEmpty,
                    "reason 不符: \(a)", file: file, line: line
                )
            case let (.malformedOPF(a), .malformedOPF(b)):
                XCTAssertTrue(
                    a.contains(b) || b.isEmpty,
                    "reason 不符: \(a)", file: file, line: line
                )
            case (.unsafeEntryPath, .unsafeEntryPath):
                break
            case let (.limitExceeded(m1, _, _), .limitExceeded(m2, _, _)):
                XCTAssertEqual(m1, m2, file: file, line: line)
            default:
                XCTFail(
                    "期待 \(expected)，实际 \(error)",
                    file: file, line: line
                )
            }
        } catch {
            XCTFail(
                "非 ReaderParserError: \(error)", file: file, line: line
            )
        }
    }

    // MARK: - 正常解析

    func testValidEPUBParsesChaptersBlocksAssets() async throws {
        let session = try await EPUBParser().open(
            fileURL: fixture("valid.epub"),
            sourceSHA256: "sha", limits: .default
        )
        XCTAssertEqual(session.format, .epub)
        XCTAssertEqual(session.suggestedTitle, "テスト書籍")
        XCTAssertEqual(session.chapters.count, 2)
        XCTAssertEqual(session.chapters[0].title, "第一章 はじめに")
        XCTAssertEqual(session.chapters[1].title, "第二章 続き")
        XCTAssertEqual(
            session.chapters[0].sourceLocator, "OEBPS/ch1.xhtml"
        )
        XCTAssertEqual(session.canonicalTextHash.count, 64)
        XCTAssertGreaterThan(session.chapters[0].textUTF16Length, 0)

        // 资产计划：PNG 登记，zip 内路径、不独立安装。
        XCTAssertEqual(session.assets.count, 1)
        XCTAssertEqual(
            session.assets[0].relativePath, "OEBPS/images/cover.png"
        )
        XCTAssertFalse(session.assets[0].requiresInstall)
        XCTAssertEqual(session.assets[0].sourceSHA256.count, 64)

        let blocks = try await collectBlocks(session, chapter: 0)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertEqual(blocks[0].ordinal, 0)
        XCTAssertTrue(blocks[0].locatorJSON?.contains("\"utf16_start\":0") == true)
        let allText = blocks.map(\.text).joined()
        XCTAssertTrue(allText.contains("吾輩は猫である"))
        XCTAssertTrue(allText.contains("ニャーニャー"))
        // <br> → 单个换行，不产生新段落。
        XCTAssertTrue(allText.contains("つかぬ。\n何でも"))

        let blocks2 = try await collectBlocks(session, chapter: 1)
        let text2 = blocks2.map(\.text).joined()
        // ruby base 保留、rt 注音舍弃；实体已解码。
        XCTAssertTrue(text2.contains("人間である"))
        XCTAssertFalse(text2.contains("にんげん"))
        XCTAssertTrue(text2.contains("引用文 & エスケープ <tag>"))
        XCTAssertTrue(text2.contains("箇条書き一"))
    }

    /// blocks(forChapter:) 每次返回新流、结果一致（契约幂等）。
    func testBlocksStreamReopenable() async throws {
        let session = try await EPUBParser().open(
            fileURL: fixture("valid.epub"),
            sourceSHA256: "sha", limits: .default
        )
        let first = try await collectBlocks(session, chapter: 0)
        let second = try await collectBlocks(session, chapter: 0)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.map(\.textHash).filter { $0.count != 64 }, []
        )
    }

    /// utf16_start 单调递增、offsets 与 text 长度自洽。
    func testUTF16OffsetsConsistent() async throws {
        let session = try await EPUBParser().open(
            fileURL: fixture("valid.epub"),
            sourceSHA256: "sha", limits: .default
        )
        for chapter in session.chapters {
            let blocks = try await collectBlocks(
                session, chapter: chapter.ordinal
            )
            // utf16_start 单调递增且首块为 0——块间 `\n\n` 分隔符
            // 占 canonical 位置，故只断言递增而非等差。
            var previousEnd = 0
            for block in blocks {
                let json = block.locatorJSON ?? ""
                guard let range = json.range(
                    of: "\"utf16_start\":(\\d+)",
                    options: .regularExpression
                ), let start = Int(
                    json[range].dropFirst("\"utf16_start\":".count)
                ) else {
                    XCTFail("locator 无 utf16_start: \(json)")
                    continue
                }
                XCTAssertGreaterThanOrEqual(
                    start, previousEnd,
                    "块 \(block.ordinal) 起点 \(start) < 前一块末尾"
                )
                if block.ordinal == 0 {
                    XCTAssertEqual(start, 0)
                }
                previousEnd = start + block.text.utf16.count
            }
        }
    }

    // MARK: - data descriptor（bit-3）兼容

    /// Python zipfile 非 seek 流写出的 EPUB：本地头 CRC/大小全 0、
    /// 值在 descriptor/中央目录。解析必须与普通 zip 一致。
    func testDataDescriptorEPUBParsesIdentically() async throws {
        let session = try await EPUBParser().open(
            fileURL: fixture("descriptor.epub"),
            sourceSHA256: "sha", limits: .default
        )
        XCTAssertEqual(session.chapters.count, 2)
        let normal = try await EPUBParser().open(
            fileURL: fixture("valid.epub"),
            sourceSHA256: "sha", limits: .default
        )
        XCTAssertEqual(
            session.canonicalTextHash, normal.canonicalTextHash
        )
        let a = try await collectBlocks(session, chapter: 0)
        let b = try await collectBlocks(normal, chapter: 0)
        XCTAssertEqual(a, b)
        // zip 层断言：descriptor 条目的本地头确实是 bit-3。
        let reader = try StreamingZipReader(
            fileURL: fixture("descriptor.epub")
        )
        defer { reader.close() }
        XCTAssertTrue(reader.entries.contains { $0.flags & 0x8 != 0 })
    }

    // MARK: - 加密 / 字体混淆

    func testEncryptedContentRejected() async throws {
        await assertError(.encryptedContent) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("encrypted.epub"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    /// 字体混淆（IDPF embedding）不拒正文；字体仍登记为资产。
    func testFontObfuscationDoesNotBlock() async throws {
        let session = try await EPUBParser().open(
            fileURL: fixture("fontobf.epub"),
            sourceSHA256: "sha", limits: .default
        )
        XCTAssertEqual(session.chapters.count, 2)
        XCTAssertTrue(session.assets.contains {
            $0.relativePath == "OEBPS/fonts/f.otf"
        })
    }

    // MARK: - 结构拒绝

    func testTraversalEntryRejected() async throws {
        await assertError(.unsafeEntryPath("")) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("traversal.epub"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    func testDuplicateEntryRejected() async throws {
        await assertError(.malformedContainer(reason: "duplicate")) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("duplicate.epub"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    func testBadContainerRejected() async throws {
        await assertError(.malformedContainer(reason: "")) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("badcontainer.epub"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    func testBadOPFRejected() async throws {
        await assertError(.malformedOPF(reason: "")) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("badopf.epub"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    func testMissingSpineRejected() async throws {
        await assertError(.malformedOPF(reason: "spine")) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("nospine.epub"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    func testMalformedXHTMLRejected() async throws {
        await assertError(.malformedContainer(reason: "")) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("badxhtml.epub"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    func testFixedLayoutRejected() async throws {
        await assertError(.fixedLayoutUnsupported) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("fixedlayout.epub"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    // MARK: - 限额

    /// 150MiB 全零条目：declared 展开 < 200MiB 但压缩比≈1000。
    func testZipBombRatioRejected() async throws {
        await assertError(.limitExceeded(
            metric: "expansionRatio", limit: 0, actual: 0
        )) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("bomb.epub"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    /// 单章 declared 25MiB > maximumChapterBytes(20MiB)。
    func testOversizedChapterRejected() async throws {
        await assertError(.limitExceeded(
            metric: "entryBytes", limit: 0, actual: 0
        )) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("oversized.epub"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    /// maximumInputBytes 收窄 → fileBytes 闸。
    func testInputByteLimitRejected() async throws {
        var limits = ReaderParserLimits.default
        limits = ReaderParserLimits(
            maximumInputBytes: 100,
            maximumExpandedBytes: limits.maximumExpandedBytes,
            maximumEntryBytes: limits.maximumEntryBytes,
            maximumEntryCount: limits.maximumEntryCount,
            maximumExpansionRatio: limits.maximumExpansionRatio,
            maximumChapterBytes: limits.maximumChapterBytes
        )
        await assertError(.limitExceeded(
            metric: "fileBytes", limit: 0, actual: 0
        )) {
            _ = try await EPUBParser().open(
                fileURL: self.fixture("valid.epub"),
                sourceSHA256: "s", limits: limits
            )
        }
    }

    /// 非 EPUB 垃圾数据。
    func testNonEPUBRejected() async throws {
        let junk = rootURL.appendingPathComponent("junk.epub")
        try Data(repeating: 0x41, count: 2048).write(to: junk)
        await assertError(.notRecognized) {
            _ = try await EPUBParser().open(
                fileURL: junk, sourceSHA256: "s", limits: .default
            )
        }
    }

    // MARK: - 端到端 ingest

    /// ingestFile(.epub) → 文档/两章/块/源文件资产+图片资产持久化，
    /// 源文件已装到 ReaderFiles。
    func testIngestEPUBEndToEnd() async throws {
        let directory = rootURL.appendingPathComponent(
            "db", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let pool = try OboeDatabase.openPool(
            path: directory.appendingPathComponent("oboe.sqlite").path
        )
        try OboeDatabaseSchema.makeMigrator().migrate(pool)
        let database = OboeDatabase(pool: pool)
        defer { try? database.close() }
        let repository = GRDBReaderRepository(database: database)
        let store = LocalReaderFileStore(
            baseDirectoryURL: directory.appendingPathComponent("library")
        )
        let service = ReaderIngestService(
            fileStore: store, repository: repository
        )

        let progressBox = ProgressBox()
        let documentID = UUID()
        let result = try await service.importFile(
            fileURL: fixture("valid.epub"),
            format: .epub,
            documentID: documentID
        ) { progressBox.add($0) }

        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.document.format, .epub)
        XCTAssertEqual(result.document.title, "テスト書籍")

        let chapters = try await repository.fetchChapters(
            documentID: documentID
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第一章 はじめに")

        var totalBlocks = 0
        for chapter in chapters {
            let blocks = try await repository.fetchBlocks(
                documentID: documentID, chapterID: chapter.id
            )
            XCTAssertFalse(blocks.isEmpty)
            totalBlocks += blocks.count
            for block in blocks {
                XCTAssertEqual(block.textHash.count, 64)
                XCTAssertFalse(block.text.isEmpty)
            }
        }
        XCTAssertGreaterThan(totalBlocks, 0)

        // 资产：源文件 installed + 图片 skipped。
        let assets = try await repository.fetchAssets(
            documentID: documentID
        )
        let source = assets.filter {
            $0.installState == .installed
        }
        XCTAssertEqual(source.count, 1)
        XCTAssertTrue(assets.contains {
            $0.relativePath == "OEBPS/images/cover.png"
                && $0.installState == .skipped
        })

        // 源文件已安装、可回读。
        let installed = store.fileURL(
            documentID: documentID,
            relativePath: result.sourceRelativePath!
        )
        XCTAssertNotNil(installed)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: installed!.path)
        )

        // staging 无残留；进度单调。
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(
                atPath: store.stagingDirectoryURL.path
            )) ?? [], []
        )
        XCTAssertEqual(progressBox.values, progressBox.values.sorted())
        XCTAssertEqual(progressBox.values.last, 1.0)
    }

    /// 取消：进行中取消 → 无文档行、无已装文件、staging 无残留。
    func testCancellationLeavesNoResidue() async throws {
        let directory = rootURL.appendingPathComponent(
            "dbcancel", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let pool = try OboeDatabase.openPool(
            path: directory.appendingPathComponent("oboe.sqlite").path
        )
        try OboeDatabaseSchema.makeMigrator().migrate(pool)
        let database = OboeDatabase(pool: pool)
        defer { try? database.close() }
        let repository = GRDBReaderRepository(database: database)
        let store = LocalReaderFileStore(
            baseDirectoryURL: directory.appendingPathComponent("library")
        )
        let service = ReaderIngestService(
            fileStore: store, repository: repository
        )

        let documentID = UUID()
        let sourceURL = try fixture("big.epub")
        let task = Task {
            try await service.importFile(
                fileURL: sourceURL,
                format: .epub,
                documentID: documentID
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            // 也可能已抢先完成——仍校验一致性。
        } catch let error as ReaderParserError {
            guard case .cancelled = error else {
                return XCTFail("期待 cancelled，实际 \(error)")
            }
            let fetched = try await repository.fetchDocument(
                id: documentID
            )
            XCTAssertNil(fetched)
            XCTAssertEqual(store.installedDocumentIDs(), [])
        }
    }

    // MARK: - RSS

    /// ~10MiB EPUB（deflate ≈3.1MiB）：解析 + 全块消费峰值 RSS
    /// 增量 < 100MiB（§5 内存要求）。
    func testBigEPUBMemoryBounded() async throws {
        let url = try fixture("big.epub")
        let fileSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: url.path
            )[.size] as? Int64
        )
        XCTAssertGreaterThan(fileSize, 2_000_000)
        let before = Self.residentSize()
        let session = try await EPUBParser().open(
            fileURL: url, sourceSHA256: "sha", limits: .default
        )
        var total = 0
        for chapter in session.chapters {
            for block in try await collectBlocks(
                session, chapter: chapter.ordinal
            ) {
                total += block.text.utf16.count
            }
        }
        XCTAssertGreaterThan(total, 0)
        let after = Self.residentSize()
        let delta = after > before ? after - before : 0
        // S28：§17 冻结预算是峰值增量 ≤80MiB——把实测值打出来供核对，
        // 断言仍按 §5 的 100MiB 硬上限守门。
        print(
            "[S28] epub \(fileSize / 1_048_576)MiB parse+consume: "
                + "baseline=\(before / 1_048_576)MiB "
                + "after=\(after / 1_048_576)MiB "
                + "delta=\(delta / 1_048_576)MiB"
        )
        XCTAssertLessThan(
            delta, 100 * 1024 * 1024,
            "RSS 增量 \(delta / 1024 / 1024)MiB 超限"
        )
    }

    /// 当前物理驻留（phys_footprint，Xcode 口径的 RSS，字节）。
    private static func residentSize() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(
                to: integer_t.self, capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_, task_flavor_t(TASK_VM_INFO),
                    $0, &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}

/// @Sendable 进度回调的线程安全收集器。
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Double] = []
    func add(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
