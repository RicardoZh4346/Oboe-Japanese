import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// SRT/VTT SubtitleParser 测试（v0.7.0 S06）：
/// cue 切分/时间轴/identifier/NOTE·REGION 跳过/标签剥离/
/// locator 往返/行号错误/端到端 ingest。
final class SubtitleParserTests: XCTestCase {

    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SubtitleParserTests-\(UUID().uuidString)",
                isDirectory: true
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
        _ session: ReaderParseSession
    ) async throws -> [ReaderBlockDraft] {
        var result: [ReaderBlockDraft] = []
        for try await block in try session.blocks(forChapter: 0) {
            result.append(block)
        }
        return result
    }

    /// 解析 locatorJSON → 字典（字段断言用）。
    private func locator(_ json: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(json?.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
    }

    private func assertParserError(
        _ check: (ReaderParserError) -> Bool,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("期待失败，实际成功", file: file, line: line)
        } catch let error as ReaderParserError {
            XCTAssertTrue(
                check(error), "错误语义不符: \(error)",
                file: file, line: line
            )
        } catch {
            XCTFail(
                "非 ReaderParserError: \(error)", file: file, line: line
            )
        }
    }

    // MARK: - SRT

    func testSRTValidCues() async throws {
        let session = try await SubtitleParser(format: .srt).open(
            fileURL: fixture("valid.srt"),
            sourceSHA256: "sha", limits: .default
        )
        XCTAssertEqual(session.format, .srt)
        XCTAssertEqual(session.chapters.count, 1)
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.count, 3)

        XCTAssertEqual(blocks[0].text, "吾輩は猫である。")
        XCTAssertEqual(blocks[1].text, "名前はまだ無い。\nどこで生れたか")
        XCTAssertEqual(blocks[2].text, "見当がつかぬ。")

        // locator 往返：序号/时间轴/utf16 起点。
        var loc = try locator(blocks[0].locatorJSON)
        XCTAssertEqual(loc["cue"] as? Int, 0)
        XCTAssertEqual(loc["ident"] as? String, "1")
        XCTAssertEqual(loc["start_ms"] as? Int, 1_000)
        XCTAssertEqual(loc["end_ms"] as? Int, 3_500)
        XCTAssertEqual(loc["utf16_start"] as? Int, 0)

        loc = try locator(blocks[1].locatorJSON)
        XCTAssertEqual(loc["ident"] as? String, "2")
        XCTAssertEqual(loc["start_ms"] as? Int, 4_000)
        // 第二块起点 = 第一块 utf16 长 + \n\n 间隔。
        XCTAssertEqual(
            loc["utf16_start"] as? Int,
            blocks[0].text.utf16.count + 2
        )
        loc = try locator(blocks[2].locatorJSON)
        XCTAssertEqual(loc["end_ms"] as? Int, 9_000)
    }

    /// 空 cue（时间轴行后无正文）跳过，不产生块。
    func testSRTEmptyCueSkipped() async throws {
        let session = try await SubtitleParser(format: .srt).open(
            fileURL: fixture("empty-cue.srt"),
            sourceSHA256: "sha", limits: .default
        )
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "残る cue。")
    }

    /// 中段时间轴行非法 → malformedCue 携带源行号。
    func testSRTMalformedTimestamp() async throws {
        await assertParserError({
            guard case let .malformedCue(line, _) = $0 else {
                return false
            }
            return line > 1  // fixture 第 6 行 "not-a-timestamp"
        }) {
            _ = try await SubtitleParser(format: .srt).open(
                fileURL: self.fixture("badtime.srt"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    /// 首块即无时间轴 → notRecognized（签名不符）。
    func testSRTBareTextNotRecognized() async throws {
        await assertParserError({ $0 == .notRecognized }) {
            _ = try await SubtitleParser(format: .srt).open(
                fileURL: self.fixture("bare.srt"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    /// UTF-16LE SRT（BOM）走同一编码检测管线。
    func testSRTUTF16LE() async throws {
        let url = rootURL.appendingPathComponent("utf16.srt")
        let text = """
            1
            00:00:01,000 --> 00:00:02,000
            UTF-16 字幕 cue。

            """
        try text.data(using: .utf16LittleEndian).map { data in
            var bom = Data([0xFF, 0xFE])
            bom.append(data)
            try bom.write(to: url)
        }
        let session = try await SubtitleParser(format: .srt).open(
            fileURL: url, sourceSHA256: "s", limits: .default
        )
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "UTF-16 字幕 cue。")
    }

    // MARK: - VTT

    func testVTTParses() async throws {
        let session = try await SubtitleParser(format: .vtt).open(
            fileURL: fixture("valid.vtt"),
            sourceSHA256: "sha", limits: .default
        )
        XCTAssertEqual(session.format, .vtt)
        let blocks = try await collectBlocks(session)
        // NOTE/REGION/STYLE 块跳过 → 只剩 2 cue。
        XCTAssertEqual(blocks.count, 2)

        // cue-1：identifier + settings + <v> 剥离 + 实体解码。
        XCTAssertEqual(
            blocks[0].text,
            "吾輩は猫である。 名前は<まだ>無い&。"
        )
        var loc = try locator(blocks[0].locatorJSON)
        XCTAssertEqual(loc["ident"] as? String, "cue-1")
        XCTAssertEqual(loc["start_ms"] as? Int, 1_000)
        XCTAssertEqual(loc["end_ms"] as? Int, 3_500)
        // cue settings 保真进 locator。
        XCTAssertEqual(
            loc["settings"] as? String, "align:center line:90%"
        )

        // 第二 cue：无 identifier（裸时间轴行）、MM:SS.mmm。
        XCTAssertEqual(blocks[1].text, "第二 cue 太字")
        loc = try locator(blocks[1].locatorJSON)
        XCTAssertNil(loc["ident"])
        XCTAssertEqual(loc["start_ms"] as? Int, 5_000)
        XCTAssertEqual(loc["end_ms"] as? Int, 6_250)
    }

    func testVTTMissingHeaderRejected() async throws {
        await assertParserError({ $0 == .notRecognized }) {
            _ = try await SubtitleParser(format: .vtt).open(
                fileURL: self.fixture("noheader.vtt"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    func testVTTMalformedTimestamp() async throws {
        await assertParserError({
            guard case let .malformedCue(line, _) = $0 else {
                return false
            }
            return line > 1
        }) {
            _ = try await SubtitleParser(format: .vtt).open(
                fileURL: self.fixture("badtime.vtt"),
                sourceSHA256: "s", limits: .default
            )
        }
    }

    /// HH:MM:SS.mmm 与 MM:SS.mmm 两种时间格式。
    func testVTTBothTimestampForms() async throws {
        let url = rootURL.appendingPathComponent("forms.vtt")
        try """
        WEBVTT

        00:12.500 --> 00:15.000
        短分秒。

        01:02:03.250 --> 01:02:04.000
        带小时。

        """.data(using: .utf8).map { try $0.write(to: url) }
        let session = try await SubtitleParser(format: .vtt).open(
            fileURL: url, sourceSHA256: "s", limits: .default
        )
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.count, 2)
        let loc0 = try locator(blocks[0].locatorJSON)
        XCTAssertEqual(loc0["start_ms"] as? Int, 12_500)
        let loc1 = try locator(blocks[1].locatorJSON)
        XCTAssertEqual(loc1["start_ms"] as? Int, 3_723_250)
        XCTAssertEqual(loc1["end_ms"] as? Int, 3_724_000)
    }

    /// 块流幂等（重开结果一致）。
    func testSubtitleBlocksReopenable() async throws {
        let session = try await SubtitleParser(format: .vtt).open(
            fileURL: fixture("valid.vtt"),
            sourceSHA256: "sha", limits: .default
        )
        let first = try await collectBlocks(session)
        let second = try await collectBlocks(session)
        XCTAssertEqual(first, second)
    }

    // MARK: - 端到端 ingest

    private struct DBFixture {
        let database: OboeDatabase
        let repository: GRDBReaderRepository
        let store: LocalReaderFileStore
        let service: ReaderIngestService
    }

    private func makeDB() throws -> DBFixture {
        let directory = rootURL.appendingPathComponent(
            "db-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
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
        return DBFixture(
            database: database,
            repository: repository,
            store: store,
            service: ReaderIngestService(
                fileStore: store, repository: repository
            )
        )
    }

    func testIngestSRTAndVTT() async throws {
        for format in [ReaderDocumentFormat.srt, .vtt] {
            let fixture = try makeDB()
            defer { try? fixture.database.close() }
            let name = format == .srt ? "valid.srt" : "valid.vtt"
            let documentID = UUID()
            let result = try await fixture.service.importFile(
                fileURL: try self.fixture(name),
                format: format,
                documentID: documentID
            )
            XCTAssertTrue(result.wasCreated)
            XCTAssertEqual(result.document.format, format)

            let chapters = try await fixture.repository.fetchChapters(
                documentID: documentID
            )
            XCTAssertEqual(chapters.count, 1)
            let blocks = try await fixture.repository.fetchBlocks(
                documentID: documentID, chapterID: chapters[0].id
            )
            XCTAssertFalse(blocks.isEmpty)
            for block in blocks {
                let loc = try locator(block.locatorJSON)
                XCTAssertNotNil(loc["cue"])
                XCTAssertNotNil(loc["start_ms"])
                XCTAssertNotNil(loc["utf16_start"])
            }
            // 源文件资产登记为 installed。
            let assets = try await fixture.repository.fetchAssets(
                documentID: documentID
            )
            XCTAssertEqual(
                assets.filter { $0.installState == .installed }.count, 1
            )
        }
    }

    /// 取消中的 open：大输入循环里 checkCancellation → cancelled。
    func testCancellation() async throws {
        let url = rootURL.appendingPathComponent("big.srt")
        var content = ""
        for i in 0..<20_000 {
            content += """
                \(i + 1)
                00:00:0\(i % 10),000 --> 00:00:0\(i % 10),900
                cue \(i) 正文。

                """
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        let task = Task {
            try await SubtitleParser(format: .srt).open(
                fileURL: url, sourceSHA256: "s", limits: .default
            )
        }
        task.cancel()
        await assertParserError({ $0 == .cancelled }) {
            _ = try await task.value
        }
    }
}
