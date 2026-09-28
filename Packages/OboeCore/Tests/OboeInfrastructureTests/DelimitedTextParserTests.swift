import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.0 S16：`DelimitedTextParserImpl` 契约测试——逐 fixture 结果表、
/// chunk 边界不变性（1/7/64KiB + 随机字节切块）、错误位置、限额、取消、
/// 以及 100k 行流式解析的内存有界证据（mach_task_basic_info RSS 采样）。
final class DelimitedTextParserTests: XCTestCase {

    // MARK: - 辅助

    private func fixtureData(_ name: String) throws -> Data {
        let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures/import"
        ) ?? Bundle.module.url(forResource: name, withExtension: nil)
        return try Data(contentsOf: try XCTUnwrap(url, "missing fixture \(name)"))
    }

    /// 端到端流式解析：检测编码 → 逐 `byteChunkSize` 字节切块喂 decoder →
    /// 解码文本喂 parser。模拟文件读取的真实字节切块。
    private func parseBytes(
        _ bytes: Data,
        delimiter: Character,
        byteChunkSize: Int,
        limits: DelimitedTextParserImpl.Limits = .init()
    ) throws -> [ImportLogicalRow] {
        let detection = ImportEncodingDetector.detect(prefix: bytes.prefix(4096))
        guard var decoder = IncrementalTextDecoder(detection: detection) else {
            throw ImportParseError.undeterminedEncoding
        }
        var parser = DelimitedTextParserImpl(delimiter: delimiter, limits: limits)
        var rows: [ImportLogicalRow] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + byteChunkSize, bytes.count)
            let text = try decoder.decode(bytes[offset..<end])
            if !text.isEmpty {
                rows.append(contentsOf: try parser.feed(text))
            }
            offset = end
        }
        let tail = try decoder.finish()
        if !tail.isEmpty {
            rows.append(contentsOf: try parser.feed(tail))
        }
        rows.append(contentsOf: try parser.finish())
        return rows
    }

    private func rows(_ fields: [[String]], lines: [Range<Int>]) -> [ImportLogicalRow] {
        zip(fields, lines).enumerated().map { index, pair in
            ImportLogicalRow(
                logicalRowNumber: index + 1,
                rawLineRange: pair.1,
                fields: pair.0
            )
        }
    }

    // MARK: - Fixture 结果表

    func testQuotedNewlineFixture() throws {
        let parsed = try parseBytes(
            fixtureData("quoted-newline.csv"), delimiter: ",", byteChunkSize: 1024
        )
        XCTAssertEqual(parsed, rows([
            ["a", "b"],
            ["line one\nline two", "second"],
            ["carriage\r\nreturn", "x"],
            ["last", "row"]
        ], lines: [1..<2, 2..<4, 4..<6, 6..<7]))
    }

    func testEscapedQuotesFixture() throws {
        let parsed = try parseBytes(
            fixtureData("escaped-quotes.csv"), delimiter: ",", byteChunkSize: 1024
        )
        XCTAssertEqual(parsed, rows([
            ["say \"hi\"", "plain"],
            ["\"leading and trailing\"", "2"],
            ["a\"b\"c", "3"]
        ], lines: [1..<2, 2..<3, 3..<4]))
    }

    func testBOMUTF8Fixture() throws {
        let parsed = try parseBytes(
            fixtureData("bom-utf8.csv"), delimiter: ",", byteChunkSize: 1024
        )
        XCTAssertEqual(parsed, rows([
            ["head", "tail"],
            ["値", "1"]
        ], lines: [1..<2, 2..<3]))
    }

    func testUTF16LEFixture() throws {
        let parsed = try parseBytes(
            fixtureData("utf16le.csv"), delimiter: ",", byteChunkSize: 1024
        )
        XCTAssertEqual(parsed, rows([
            ["詞", "読み", "意味"],
            ["本", "ほん", "book"]
        ], lines: [1..<2, 2..<3]))
    }

    func testTSVFixture() throws {
        let parsed = try parseBytes(
            fixtureData("tsv-basic.tsv"), delimiter: "\t", byteChunkSize: 1024
        )
        XCTAssertEqual(parsed, rows([
            ["a", "b", "c"],
            ["1", "x\ty", "3"],
            ["last", "row", "here"]
        ], lines: [1..<2, 2..<3, 3..<4]))
    }

    func testTrailingEmptyFieldsFixture() throws {
        let parsed = try parseBytes(
            fixtureData("trailing-empty-fields.csv"), delimiter: ",", byteChunkSize: 1024
        )
        XCTAssertEqual(parsed, rows([
            ["a", "b", ""],
            ["only", ""],
            ["", ""],
            ["x", "y", "z"]
        ], lines: [1..<2, 2..<3, 3..<4, 4..<5]))
    }

    func testNoFinalNewlineFixture() throws {
        let parsed = try parseBytes(
            fixtureData("no-final-newline.csv"), delimiter: ",", byteChunkSize: 1024
        )
        XCTAssertEqual(parsed, rows([
            ["a", "b"],
            ["c", "d"]
        ], lines: [1..<2, 2..<3]))
    }

    func testMultibyteSplitFixture() throws {
        let parsed = try parseBytes(
            fixtureData("multibyte-split.csv"), delimiter: ",", byteChunkSize: 1024
        )
        XCTAssertEqual(parsed, rows([
            ["field", "value"],
            ["emoji", "😀🎉日本語"],
            ["combining", "e\u{301}"],
            ["done", "👍🏽"]
        ], lines: [1..<2, 2..<3, 3..<4, 4..<5]))
    }

    func testEmptyInputProducesNoRows() throws {
        var parser = DelimitedTextParserImpl(delimiter: ",")
        XCTAssertEqual(try parser.feed(""), [])
        XCTAssertEqual(try parser.finish(), [])
    }

    // MARK: - Chunk 边界不变性

    /// 所有良性 fixture 在字节切块 1 / 7 / 64KiB / 随机尺寸下产出
    /// 完全相同的逻辑行序列（含 rawLineRange）。
    func testChunkBoundaryInvariance() throws {
        let cases: [(String, Character)] = [
            ("quoted-newline.csv", ","),
            ("escaped-quotes.csv", ","),
            ("bom-utf8.csv", ","),
            ("utf16le.csv", ","),
            ("tsv-basic.tsv", "\t"),
            ("trailing-empty-fields.csv", ","),
            ("no-final-newline.csv", ","),
            ("multibyte-split.csv", ",")
        ]
        for (name, delimiter) in cases {
            let data = try fixtureData(name)
            let baseline = try parseBytes(data, delimiter: delimiter, byteChunkSize: data.count)
            for size in [1, 7, 64 * 1024] {
                let parsed = try parseBytes(data, delimiter: delimiter, byteChunkSize: size)
                XCTAssertEqual(parsed, baseline, "\(name) chunk=\(size)")
            }
            // 随机切块（定长种子保证可复现）。
            var rng = SeededGenerator(seed: 0xC0FFEE)
            var parser = DelimitedTextParserImpl(delimiter: delimiter)
            var decoder = try XCTUnwrap(
                IncrementalTextDecoder(
                    detection: ImportEncodingDetector.detect(prefix: data.prefix(4096))
                )
            )
            var parsed: [ImportLogicalRow] = []
            var offset = 0
            while offset < data.count {
                let size = 1 + Int(rng.next() % UInt64(37))
                let end = min(offset + size, data.count)
                let text = try decoder.decode(data[offset..<end])
                if !text.isEmpty { parsed.append(contentsOf: try parser.feed(text)) }
                offset = end
            }
            let tail = try decoder.finish()
            if !tail.isEmpty { parsed.append(contentsOf: try parser.feed(tail)) }
            parsed.append(contentsOf: try parser.finish())
            XCTAssertEqual(parsed, baseline, "\(name) random chunks")
        }
    }

    /// Character 级 1 字粒度 feed（String 切块而不是字节切块）。
    func testCharacterGranularityInvariance() throws {
        let data = try fixtureData("quoted-newline.csv")
        let text = String(decoding: data, as: UTF8.self)
        var parser = DelimitedTextParserImpl(delimiter: ",")
        var parsed: [ImportLogicalRow] = []
        for character in text {
            parsed.append(contentsOf: try parser.feed(String(character)))
        }
        parsed.append(contentsOf: try parser.finish())
        let baseline = try parseBytes(data, delimiter: ",", byteChunkSize: data.count)
        XCTAssertEqual(parsed, baseline)
    }

    // MARK: - 错误路径：位置与原因

    func testUnclosedQuoteCarriesPosition() throws {
        let data = try fixtureData("bad-unclosed-quote.csv")
        do {
            _ = try parseBytes(data, delimiter: ",", byteChunkSize: 1024)
            XCTFail("expected malformedRow")
        } catch let error as ImportParseError {
            guard case let .malformedRow(logicalRow, rawLines, reason) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(logicalRow, 2)
            XCTAssertEqual(rawLines, 2..<4)
            XCTAssertTrue(reason.contains("unterminated"))
        }
    }

    /// 未闭合引号的错误位置必须与 chunk 切块无关。
    func testUnclosedQuotePositionInvariantAcrossChunks() throws {
        let data = try fixtureData("bad-unclosed-quote.csv")
        for size in [1, 3, 1024] {
            do {
                _ = try parseBytes(data, delimiter: ",", byteChunkSize: size)
                XCTFail("chunk \(size): expected malformedRow")
            } catch let error as ImportParseError {
                guard case let .malformedRow(logicalRow, rawLines, _) = error else {
                    return XCTFail("chunk \(size): unexpected error \(error)")
                }
                XCTAssertEqual(logicalRow, 2, "chunk \(size)")
                XCTAssertEqual(rawLines, 2..<4, "chunk \(size)")
            }
        }
    }

    func testQuoteInsideUnquotedFieldIsMalformed() throws {
        var parser = DelimitedTextParserImpl(delimiter: ",")
        XCTAssertThrowsError(try parser.feed("a,b\"c\n")) { error in
            guard case let .malformedRow(row, lines, _) = error as? ImportParseError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(row, 1)
            XCTAssertEqual(lines, 1..<2)
        }
    }

    func testJunkAfterClosingQuoteIsMalformed() throws {
        var parser = DelimitedTextParserImpl(delimiter: ",")
        XCTAssertThrowsError(try parser.feed("\"a\"x\n")) { error in
            guard case let .malformedRow(row, lines, _) = error as? ImportParseError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(row, 1)
            XCTAssertEqual(lines, 1..<2)
        }
    }

    /// 错误发生在第二条记录时携带正确的逻辑行号与行范围。
    func testMalformedErrorOnSecondRecord() throws {
        var parser = DelimitedTextParserImpl(delimiter: ",")
        _ = try parser.feed("ok,fine\n")
        XCTAssertThrowsError(try parser.feed("\"a\"x\n")) { error in
            guard case let .malformedRow(row, lines, _) = error as? ImportParseError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(row, 2)
            XCTAssertEqual(lines, 2..<3)
        }
    }

    // MARK: - 限额

    func testFieldSizeLimit() throws {
        var parser = DelimitedTextParserImpl(delimiter: ",")
        let big = String(repeating: "x", count: 64 * 1024 + 1)
        XCTAssertThrowsError(try parser.feed(big)) { error in
            XCTAssertEqual(
                error as? ImportParseError,
                .limitExceeded(metric: "fieldUTF8Bytes", limit: 64 * 1024)
            )
        }
    }

    func testRecordSizeLimit() throws {
        var parser = DelimitedTextParserImpl(delimiter: ",")
        let fields = String(repeating: "y,", count: 300_000) // ~600KiB 每次
        XCTAssertThrowsError(try {
            for _ in 0..<4 { _ = try parser.feed(fields) }
        }()) { error in
            XCTAssertEqual(
                error as? ImportParseError,
                .limitExceeded(metric: "recordUTF8Bytes", limit: 1024 * 1024)
            )
        }
    }

    func testLogicalRowLimit() throws {
        var parser = DelimitedTextParserImpl(
            delimiter: ",",
            limits: .init(maximumLogicalRows: 3)
        )
        _ = try parser.feed("a,b\nc,d\ne,f\n")
        XCTAssertThrowsError(try parser.feed("g,h\n")) { error in
            XCTAssertEqual(
                error as? ImportParseError,
                .limitExceeded(metric: "logicalRows", limit: 3)
            )
        }
    }

    // MARK: - 取消

    /// 取消粒度 = 每次 feed() 调用边界（§10.3 的「记录解析与批之间」由
    /// 调用方的切块粒度实现）：已取消任务的下一次 feed 抛 `.cancelled`，
    /// 此前已产出的记录不受影响。
    func testCancellationBetweenFeeds() async throws {
        let task = Task.detached { () -> (Int, ImportParseError?) in
            var parser = DelimitedTextParserImpl(delimiter: ",")
            var produced = 0
            do {
                produced += try parser.feed("a,b\n").count
                // 等待外部取消生效（不抛错的轮询）。
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                produced += try parser.feed("c,d\n").count
                return (produced, nil)
            } catch let error as ImportParseError {
                return (produced, error)
            } catch {
                return (produced, nil)
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let (produced, error) = try await task.value
        XCTAssertEqual(produced, 1) // 第一行已正常产出
        XCTAssertEqual(error, .cancelled)
    }

    // MARK: - 100k 行内存有界证据

    /// 流式解析 100k 行 + staging 落盘：进程常驻内存增量必须 <100MB。
    /// 峰值 RSS 通过 2ms 采样线程取得。
    func testStreamingParse100kRowsBoundedMemory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("S16Memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 生成 100k 行 CSV（与 generate_import_fixtures.py --rows100k 同构）。
        let csvURL = directory.appendingPathComponent("rows100k.csv")
        var content = String()
        for i in 0..<100_000 {
            content += "単語\(i),よみ\(i),\"意味 \(i), with comma\",tag\(i)\n"
        }
        try content.write(to: csvURL, atomically: true, encoding: .utf8)
        let data = try Data(contentsOf: csvURL)

        let sampler = ImportPeakRSSSampler()
        let baseline = ImportResidentSize.current()
        sampler.start()

        var decoder = IncrementalTextDecoder(encoding: .utf8)
        var parser = DelimitedTextParserImpl(delimiter: ",")
        let staging = try ImportStaging(directory: directory)
        defer { staging.preservesFileOnDeinit = false }

        var emitted = 0
        var batch: [ImportLogicalRow] = []
        batch.reserveCapacity(ImportBatchPolicy.maximumRowsPerBatch)
        var offset = 0
        let chunkSize = 256 * 1024
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let text = try decoder.decode(data[offset..<end])
            let produced = text.isEmpty ? [] : try parser.feed(text)
            for row in produced {
                batch.append(row)
                if batch.count == ImportBatchPolicy.maximumRowsPerBatch {
                    try staging.append(batch)
                    emitted += batch.count
                    batch.removeAll(keepingCapacity: true)
                }
            }
            offset = end
        }
        let tail = try decoder.finish()
        let produced = (tail.isEmpty ? [] : try parser.feed(tail)) + (try parser.finish())
        for row in produced {
            batch.append(row)
            if batch.count == ImportBatchPolicy.maximumRowsPerBatch {
                try staging.append(batch)
                emitted += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try staging.append(batch)
            emitted += batch.count
        }

        // 重放全程也保持有界。
        var replayed = 0
        try staging.forEachBatch { rows in replayed += rows.count }

        let peak = sampler.stop()
        let delta = peak - baseline
        // 供 CI 日志查验的证据行。
        print("""
            [S16] 100k-row streaming parse: baseline=\(baseline / 1_048_576)MiB \
            peak=\(peak / 1_048_576)MiB delta=\(delta / 1_048_576)MiB \
            rows=\(emitted) replayed=\(replayed)
            """)
        XCTAssertEqual(emitted, 100_000)
        XCTAssertEqual(replayed, 100_000)
        XCTAssertEqual(staging.rowCount, 100_000)
        XCTAssertLessThan(delta, 100 * 1_048_576, "streaming parse exceeded 100MiB RSS delta")
    }
}

// MARK: - 测试辅助

/// 确定性伪随机切块（SplitMix64）。
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// 当前进程 RSS（字节）。
enum ImportResidentSize {
    static func current() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
        ) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: 1) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}

/// 2ms 周期采样 RSS 取峰值。
final class ImportPeakRSSSampler: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var peakValue: Int64 = 0

    func start() {
        lock.lock()
        peakValue = ImportResidentSize.current()
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let rss = ImportResidentSize.current()
            self.lock.lock()
            self.peakValue = max(self.peakValue, rss)
            self.lock.unlock()
        }
        timer.resume()
        self.timer = timer
    }

    @discardableResult
    func stop() -> Int64 {
        timer?.cancel()
        timer = nil
        lock.lock()
        defer { lock.unlock() }
        return peakValue
    }
}
