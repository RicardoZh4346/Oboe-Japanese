import CryptoKit
import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// PlainTextParser 单元测试（v0.7.0 S05 验收 1/3）。
/// 覆盖：BOM/严格 UTF-8/UTF-16 检测、手动编码覆盖、切块不变性
/// （1/7/64KiB/整喂同结果）、UTF-16 偏移与 emoji/组合符完整性、
/// 段落硬边界与长无换行兜底、空/空白拒绝、标题规则。
final class PlainTextParserTests: XCTestCase {

    private var scratchDirectory: URL!
    private var scratchFiles: [URL] = []

    override func setUpWithError() throws {
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PlainTextParserTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: scratchDirectory, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    // MARK: - 编码检测

    func testUTF8NoBOMParsesAndTakesTitleFromFilename() async throws {
        let file = try writeFile(
            named: "小説.txt", contents: Data("一行目\r\n二行目\n\n三行目".utf8)
        )
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        XCTAssertEqual(session.suggestedTitle, "小説")
        XCTAssertEqual(session.format, .txt)
        XCTAssertEqual(session.chapters.count, 1)
        XCTAssertEqual(
            session.chapters[0].canonicalHash, session.canonicalTextHash
        )
        // canonical hash = SHA-256(NFC + LF 规范化全文)
        XCTAssertEqual(
            session.canonicalTextHash,
            ReaderHashing.sha256Hex(
                Data("一行目\n二行目\n\n三行目".utf8)
            )
        )
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(
            blocks.map(\.text).joined(), "一行目\n二行目\n\n三行目"
        )
        // 空行硬边界：两块
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.ordinal), [0, 1])
    }

    func testUTF8BOMIsStrippedFromCanonicalText() async throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("あいうえお".utf8))
        let file = try writeFile(named: "bom.txt", contents: data)
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.map(\.text).joined(), "あいうえお")
        XCTAssertFalse(blocks[0].text.contains("\u{FEFF}"))
    }

    func testUTF16LEWithBOMParses() async throws {
        let text = "吾輩は猫である。名前はまだ無い。\n\nどこで生れたか。"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        let file = try writeFile(named: "le.txt", contents: data)
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.map(\.text).joined(), text)
        XCTAssertEqual(session.chapters[0].textUTF16Length, text.utf16.count)
    }

    func testUTF16BEWithBOMParses() async throws {
        let text = "big endian\n\ntext"
        var data = Data([0xFE, 0xFF])
        data.append(text.data(using: .utf16BigEndian)!)
        let file = try writeFile(named: "be.txt", contents: data)
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.map(\.text).joined(), text)
    }

    /// 检测窗口可能截在多字节序列中间（64KiB 边界）——不得误判
    /// undetermined：泵会回退 ≤3 字节重试检测。
    func testDetectionHeadEndingMidSequenceStillDetectsUTF8() async throws {
        // 让第 64KiB 字节落在三字节序列中间：前 65534 字节 ASCII +
        // 「あ」占 65534-65536，头 64KiB 只含 E3 81（截断前缀）。
        var data = Data(repeating: 0x61 /* 'a' */, count: 65_534)
        data.append(Data("あ".utf8))  // E3 81 82：横跨 64KiB 界
        data.append(Data("いうえお".utf8))
        let file = try writeFile(named: "edge.txt", contents: data)
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(
            blocks.map(\.text).joined(),
            String(repeating: "a", count: 65_534) + "あいうえお"
        )
    }

    func testShiftJISBytesAreUndeterminedThenManualOverrideParses()
        async throws
    {
        let text = "こんにちは、世界。これはテストです。"
        let sjis = text.data(using: .shiftJIS)!
        // 前提：该字节流不是合法 UTF-8，才会走 undetermined。
        XCTAssertNil(String(data: sjis, encoding: .utf8))
        let file = try writeFile(named: "sjis.txt", contents: sjis)

        await assertThrowsAsync {
            try await PlainTextParser(format: .txt)
                .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        } errorHandler: { error in
            guard case let .undeterminedEncoding(candidates) =
                error as? ReaderParserError
            else {
                return XCTFail("期待 undeterminedEncoding，得 \(error)")
            }
            XCTAssertFalse(candidates.isEmpty)
        }

        // 手动编码重试（§10.1 手动指定路径）。
        let session = try await PlainTextParser(
            format: .txt, encodingOverride: .shiftJIS
        ).open(fileURL: file, sourceSHA256: "sha", limits: .default)
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.map(\.text).joined(), text)
    }

    /// 手动指定与内容不符的编码 → undeterminedEncoding（UI 应再弹
    /// 编码选择，不静默产出乱码）。奇数长 ASCII 强制 UTF-16LE 必败。
    func testWrongManualEncodingFailsClosed() async throws {
        let file = try writeFile(
            named: "odd.txt", contents: Data("abcde".utf8)
        )
        await assertThrowsAsync {
            try await PlainTextParser(
                format: .txt, encodingOverride: .utf16LE
            ).open(fileURL: file, sourceSHA256: "sha", limits: .default)
        } errorHandler: { error in
            guard case .undeterminedEncoding =
                error as? ReaderParserError
            else {
                return XCTFail("期待 undeterminedEncoding，得 \(error)")
            }
        }
    }

    /// BOM 声明的编码中途损坏 = 真损坏（malformedContainer），
    /// 不再回退猜编码。
    func testBOMDeclaredThenCorruptIsMalformed() async throws {
        // FF FE + 孤立高代理 + 尾字节
        var data = Data([0xFF, 0xFE])
        data.append(contentsOf: [0x61, 0x00])        // 'a'
        data.append(contentsOf: [0x00, 0xD8])        // lone high surrogate
        data.append(contentsOf: [0x62, 0x00])        // 'b'（非法续接）
        let file = try writeFile(named: "corrupt.txt", contents: data)
        await assertThrowsAsync {
            try await PlainTextParser(format: .txt)
                .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        } errorHandler: { error in
            guard case .malformedContainer =
                error as? ReaderParserError
            else {
                return XCTFail("期待 malformedContainer，得 \(error)")
            }
        }
    }

    // MARK: - 切块不变性（直接驱动内部管线）

    /// decoder→normalizer→blocker 三段管线：切块粒度不影响
    /// 块列表/hash/顺序。
    private func runPipeline(
        _ data: Data,
        chunkBytes: Int,
        encodingOverride: PlainTextEncoding? = nil
    ) throws -> (blocks: [String], hash: String) {
        let headSize = min(data.count, 4096)
        let head = data.prefix(headSize)
        let encoding: ImportTextEncoding
        var bomBytes = 0
        if let encodingOverride,
           let importEncoding = encodingOverride.importEncoding {
            encoding = importEncoding
        } else {
            var probe = Data(head)
            var detection = ImportEncodingDetector.detect(prefix: probe)
            var retries = 0
            while case .undetermined = detection,
                  retries < 3, !probe.isEmpty {
                probe = probe.dropLast()
                detection = ImportEncodingDetector.detect(prefix: probe)
                retries += 1
            }
            guard case let .detected(found, bom, _) = detection else {
                throw ReaderParserError.undeterminedEncoding(
                    sampledEncodings: []
                )
            }
            encoding = found
            bomBytes = bom
        }
        var decoder = IncrementalTextDecoder(
            encoding: encoding, bomBytes: bomBytes
        )
        var normalizer = CanonicalTextNormalizer()
        var blocker = PlainTextBlocker()
        var blocks: [String] = []
        var hasher = SHA256()
        func absorb(_ piece: String) {
            for cluster in normalizer.feed(piece) {
                hasher.update(data: Data(cluster.utf8))
                if let text = blocker.feed(cluster) {
                    blocks.append(text)
                }
            }
        }
        if chunkBytes <= 0 {
            absorb(try decoder.decode(data))
        } else {
            absorb(try decoder.decode(head))
            var index = headSize
            while index < data.count {
                let end = min(index + chunkBytes, data.count)
                absorb(try decoder.decode(data[index..<end]))
                index = end
            }
        }
        absorb(try decoder.finish())
        for cluster in normalizer.finish() {
            hasher.update(data: Data(cluster.utf8))
            if let text = blocker.feed(cluster) {
                blocks.append(text)
            }
        }
        if let tail = blocker.finish() {
            blocks.append(tail)
        }
        return (blocks, ReaderHashing.hex(hasher.finalize()))
    }

    func testChunkBoundaryInvarianceUTF8() throws {
        var text = "序盤の段落。😀👨‍👩‍👧‍👦 e\u{301}́ テスト。\r\n"
        text += String(repeating: "長い文。これは長い文です", count: 200)
        text += "\n\n次の段落\u{309}\r\n\n最後。"
        let data = Data(text.utf8)
        let whole = try runPipeline(data, chunkBytes: 0)
        for size in [1, 7, 64 * 1024] {
            let variant = try runPipeline(data, chunkBytes: size)
            XCTAssertEqual(
                variant.blocks, whole.blocks, "chunk=\(size) 块不一致"
            )
            XCTAssertEqual(
                variant.hash, whole.hash, "chunk=\(size) hash 不一致"
            )
        }
        // hash == 规范化全文 sha256
        let canonical = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .precomposedStringWithCanonicalMapping
        XCTAssertEqual(
            whole.hash, ReaderHashing.sha256Hex(Data(canonical.utf8))
        )
    }

    func testChunkBoundaryInvarianceUTF16LE() throws {
        var data = Data([0xFF, 0xFE])
        // か + U+3099（浊点）→ が（NFC 组合）；\r\n\r\n → \n\n。
        let text = "😀👨‍👩‍👧‍👦 結合か\u{3099}。\r\n\r\n分割テスト。"
        data.append(text.data(using: .utf16LittleEndian)!)
        let whole = try runPipeline(data, chunkBytes: 0)
        for size in [1, 7, 64 * 1024] {
            let variant = try runPipeline(data, chunkBytes: size)
            XCTAssertEqual(variant.blocks, whole.blocks)
            XCTAssertEqual(variant.hash, whole.hash)
        }
        XCTAssertEqual(
            whole.blocks.joined(),
            "😀👨‍👩‍👧‍👦 結合が。\n\n分割テスト。"
        )
    }

    // MARK: - UTF-16 偏移

    /// locatorJSON.utf16_start 必须是 canonical 文本中真实 UTF-16
    /// 起点；textUTF16Length 以 code unit 计（😀 = 2）。
    func testUTF16OffsetsAcrossSupplementaryAndCombining() async throws {
        // 😀(2 units) + e+◌́ → é NFC(1 unit) + ZWJ 家族(11) + "ab"
        let part1 = "😀e\u{301}👨‍👩‍👧‍👦ab"          // 2+1+11+2 = 16 units
        let part2 = String(repeating: "x", count: 3000) // 触发按长切
        let text = part1 + "\n\n" + part2
        let file = try writeFile(
            named: "u16.txt", contents: Data(text.utf8)
        )
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        // NFC 后 e+́ → é：canonical 比原文短 1 个 UTF-16 unit。
        let canonicalPart1 = part1.precomposedStringWithCanonicalMapping
        let canonical = canonicalPart1 + "\n\n" + part2
        XCTAssertEqual(
            session.chapters[0].textUTF16Length, canonical.utf16.count
        )
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.count, 2)
        // 块 0 从 0 起；块 1 起点 = 块 0 utf16 长度（含尾部空行）。
        XCTAssertEqual(utf16Start(of: blocks[0]), 0)
        XCTAssertEqual(
            utf16Start(of: blocks[1]), blocks[0].text.utf16.count
        )
        XCTAssertEqual(blocks[0].text, canonicalPart1 + "\n\n")
        // 「é」是 NFC 单 scalar：canonical 中该簇仅 1 个 UTF-16 unit。
        XCTAssertEqual(blocks[0].text.utf16.count, 18)
    }

    // MARK: - 结构

    func testLeadingBlankLinesDoNotProduceWhitespaceBlock() async throws {
        let text = "\n\n\n先頭段落\n\n二番目"
        let file = try writeFile(
            named: "lead.txt", contents: Data(text.utf8)
        )
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.map(\.text), ["先頭段落\n\n", "二番目"])
        // 丢弃的前导空行计入偏移：块 0 的真起点是 3。
        XCTAssertEqual(utf16Start(of: blocks[0]), 3)
    }

    /// 无换行长文本：硬上限内按句末尽量切，任何块 ≤8192 且
    /// 拼接还原原文。
    func testLongNoNewlineSplits() async throws {
        let sentence = "これはとても長い文章です。"
        let text = String(repeating: sentence, count: 600) // 7200 units
        let file = try writeFile(
            named: "long.txt", contents: Data(text.utf8)
        )
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        let blocks = try await collectBlocks(session)
        XCTAssertGreaterThan(blocks.count, 1)
        for block in blocks {
            XCTAssertLessThanOrEqual(
                block.text.utf16.count, ReaderBlock.maximumUTF16Length
            )
        }
        XCTAssertEqual(blocks.map(\.text).joined(), text)
        // 句末偏好：各块（除末块）应以句号收尾。
        for block in blocks.dropLast() {
            XCTAssertTrue(block.text.hasSuffix("。"))
        }
    }

    /// 超过 target 遇单换行即切（换行优先于句末兜底窗口）。
    func testSingleNewlineCutsPastTarget() async throws {
        let line = String(repeating: "x", count: 2_100)
        let text = line + "\n" + line + "\n"
        let file = try writeFile(
            named: "nl.txt", contents: Data(text.utf8)
        )
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(blocks.map(\.text), [line + "\n", line + "\n"])
    }

    func testEmptyAndWhitespaceOnlyFilesThrowEmptyContent() async throws {
        for (name, content) in [
            ("empty.txt", ""), ("ws.txt", "  \n\t \n\n")
        ] {
            let file = try writeFile(
                named: name, contents: Data(content.utf8)
            )
            await assertThrowsAsync {
                try await PlainTextParser(format: .txt)
                    .open(fileURL: file, sourceSHA256: "s", limits: .default)
            } errorHandler: { error in
                XCTAssertEqual(
                    error as? ReaderParserError, .emptyContent
                )
            }
        }
    }

    // MARK: - 标题（paste 路径）

    func testPasteTitleFromFirstLineTruncatedAt80() async throws {
        let long = String(repeating: "y", count: 120)
        let file = try writeFile(
            named: "p.txt",
            contents: Data("\(long)\n残り".utf8)
        )
        let session = try await PlainTextParser(format: .paste)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        XCTAssertEqual(session.suggestedTitle, String(repeating: "y", count: 80))
    }

    func testPasteTitleBlankFirstLineFallsBackToDate() async throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14
        let file = try writeFile(
            named: "p.txt", contents: Data("   \n内容".utf8)
        )
        let session = try await PlainTextParser(
            format: .paste, now: { fixed }
        ).open(fileURL: file, sourceSHA256: "sha", limits: .default)
        XCTAssertEqual(
            session.suggestedTitle,
            "Pasted \(Self.expectedDay(for: fixed))"
        )
    }

    // MARK: - 会话语义

    func testBlocksForWrongOrdinalThrows() async throws {
        let file = try writeFile(
            named: "o.txt", contents: Data("x".utf8)
        )
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        XCTAssertThrowsError(try session.blocks(forChapter: 7))
    }

    /// 块流可重复拉起（contentRevision 扫描/重切场景）。
    func testBlocksStreamIsReopenable() async throws {
        let file = try writeFile(
            named: "r.txt", contents: Data("a\n\nb".utf8)
        )
        let session = try await PlainTextParser(format: .txt)
            .open(fileURL: file, sourceSHA256: "sha", limits: .default)
        let first = try await collectBlocks(session)
        let second = try await collectBlocks(session)
        XCTAssertEqual(first, second)
    }

    // MARK: - Fixtures/reader 驱动

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

    /// 每个真实 fixture 的端到端期望（编码判定 + canonical + 块）。
    func testReaderFixturesParseAsExpected() async throws {
        struct Case {
            let file: String
            let expected: String?
            let expectError: ReaderParserError?
        }
        let cases: [Case] = [
            Case(
                file: "utf8-plain.txt",
                expected: "吾輩は猫である。名前はまだ無い。\n\nどこで生れたかとんと見当がつかぬ。\n何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。\n",
                expectError: nil
            ),
            Case(
                file: "utf8-bom.txt",
                expected: "BOM 付き本文\n\n二番目の段落。",
                expectError: nil
            ),
            Case(
                file: "utf16le-bom.txt",
                expected: "UTF-16 リトルエンディアン。\n\nemoji😀も含む。",
                expectError: nil
            ),
            Case(
                file: "utf16be-bom.txt",
                expected: "UTF-16 ビッグエンディアン。",
                expectError: nil
            ),
            Case(
                file: "emoji-mixed.txt",
                expected: nil,   // 组合符结果在专门用例断言
                expectError: nil
            ),
            Case(
                file: "long-no-newline.txt",
                expected: nil,
                expectError: nil
            ),
            Case(file: "empty.txt", expected: nil,
                 expectError: .emptyContent),
            Case(file: "whitespace-only.txt", expected: nil,
                 expectError: .emptyContent),
            Case(file: "utf16le-corrupt.txt", expected: nil,
                 expectError: .malformedContainer(
                     reason: "encoding declared by BOM is corrupt mid-stream"
                 )),
        ]
        for testCase in cases {
            let url = try fixture(testCase.file)
            if let expectedError = testCase.expectError {
                await assertThrowsAsync {
                    try await PlainTextParser(format: .txt).open(
                        fileURL: url, sourceSHA256: "s", limits: .default
                    )
                } errorHandler: { error in
                    XCTAssertEqual(
                        error as? ReaderParserError, expectedError,
                        testCase.file
                    )
                }
                continue
            }
            let session = try await PlainTextParser(format: .txt).open(
                fileURL: url, sourceSHA256: "s", limits: .default
            )
            let blocks = try await collectBlocks(session)
            if let expected = testCase.expected {
                XCTAssertEqual(
                    blocks.map(\.text).joined(), expected, testCase.file
                )
            }
            for block in blocks {
                XCTAssertLessThanOrEqual(
                    block.text.utf16.count,
                    ReaderBlock.maximumUTF16Length,
                    testCase.file
                )
            }
        }
    }

    /// Shift-JIS fixture：自动检测 undetermined → 手动覆盖成功。
    func testShiftJISFixtureUndeterminedThenOverride() async throws {
        let url = try fixture("shiftjis.txt")
        await assertThrowsAsync {
            try await PlainTextParser(format: .txt).open(
                fileURL: url, sourceSHA256: "s", limits: .default
            )
        } errorHandler: { error in
            guard case .undeterminedEncoding =
                error as? ReaderParserError
            else {
                return XCTFail("期待 undeterminedEncoding，得 \(error)")
            }
        }
        let session = try await PlainTextParser(
            format: .txt, encodingOverride: .shiftJIS
        ).open(fileURL: url, sourceSHA256: "s", limits: .default)
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(
            blocks.map(\.text).joined(),
            "こんにちは、世界。\n\n二行目です。"
        )
    }

    /// 无 BOM UTF-16LE（含高位字节）：UTF-8 校验失败 → undetermined；
    /// 手动 utf16LE 覆盖后正确解析。
    func testUTF16LENoBOMIsUndeterminedThenOverride() async throws {
        let url = try fixture("utf16le-nobom.txt")
        await assertThrowsAsync {
            try await PlainTextParser(format: .txt).open(
                fileURL: url, sourceSHA256: "s", limits: .default
            )
        } errorHandler: { error in
            guard case let .undeterminedEncoding(candidates) =
                error as? ReaderParserError
            else {
                return XCTFail("期待 undeterminedEncoding，得 \(error)")
            }
            // UTF-16 候选应出现在采样列表中（§10.1 手动选择依据）。
            XCTAssertTrue(candidates.contains("utf16LE"))
        }
        let session = try await PlainTextParser(
            format: .txt, encodingOverride: .utf16LE
        ).open(fileURL: url, sourceSHA256: "s", limits: .default)
        let blocks = try await collectBlocks(session)
        XCTAssertEqual(
            blocks.map(\.text).joined(),
            "日本語のテキスト。愛・鬱・櫻も含む。"
        )
    }

    /// 1MiB 无换行 fixture：块全部 ≤8192、句末收尾、拼接还原。
    func testLongNoNewlineFixtureBlocks() async throws {
        let url = try fixture("long-no-newline.txt")
        let session = try await PlainTextParser(format: .txt).open(
            fileURL: url, sourceSHA256: "s", limits: .default
        )
        let blocks = try await collectBlocks(session)
        XCTAssertGreaterThan(blocks.count, 1)
        let fileText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(blocks.map(\.text).joined(), fileText)
        for block in blocks.dropLast() {
            XCTAssertTrue(block.text.hasSuffix("。"))
        }
    }

    // MARK: - 辅助

    private func writeFile(named name: String, contents: Data) throws -> URL {
        let url = scratchDirectory.appendingPathComponent(name)
        try contents.write(to: url)
        scratchFiles.append(url)
        return url
    }

    private func collectBlocks(
        _ session: ReaderParseSession, ordinal: Int = 0
    ) async throws -> [ReaderBlockDraft] {
        var drafts: [ReaderBlockDraft] = []
        let stream = try session.blocks(forChapter: ordinal)
        for try await draft in stream {
            drafts.append(draft)
        }
        return drafts
    }

    private func utf16Start(of draft: ReaderBlockDraft) -> Int? {
        guard let json = draft.locatorJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any]
        else { return nil }
        return object["utf16_start"] as? Int
    }

    private static func expectedDay(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
