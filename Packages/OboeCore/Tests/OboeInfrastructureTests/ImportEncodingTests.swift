import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.0 S16：编码检测与 `IncrementalTextDecoder` 测试——BOM 优先、
/// 严格 UTF-8、UTF-16LE/BE、跨 chunk 多字节拆分、手动 override、
/// 50MiB 文件预算、解码失败映射。
final class ImportEncodingTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures/import"
        ) ?? Bundle.module.url(forResource: name, withExtension: nil)
        return try Data(contentsOf: try XCTUnwrap(url, "missing fixture \(name)"))
    }

    /// 把字节按 `chunkSize` 切块解码成完整 String。
    private func decodeAll(
        _ data: Data,
        encoding: ImportTextEncoding,
        bomBytes: Int = 0,
        chunkSize: Int
    ) throws -> String {
        var decoder = IncrementalTextDecoder(encoding: encoding, bomBytes: bomBytes)
        var result = ""
        var offset = 0
        while offset < data.count {
            result += try decoder.decode(data[offset..<min(offset + chunkSize, data.count)])
            offset += chunkSize
        }
        return result + (try decoder.finish())
    }

    // MARK: - BOM 检测

    func testDetectUTF8BOM() throws {
        let data = try fixtureData("bom-utf8.csv")
        let result = ImportEncodingDetector.detect(prefix: data)
        XCTAssertEqual(result, .detected(encoding: .utf8, bomBytes: 3, viaBOM: true))
        let text = try decodeAll(data, encoding: .utf8, bomBytes: 3, chunkSize: 4)
        XCTAssertFalse(text.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(text.hasPrefix("head,tail"))
    }

    func testDetectUTF16LEBOM() throws {
        let data = try fixtureData("utf16le.csv")
        let result = ImportEncodingDetector.detect(prefix: data)
        XCTAssertEqual(result, .detected(encoding: .utf16LE, bomBytes: 2, viaBOM: true))
        let text = try decodeAll(data, encoding: .utf16LE, bomBytes: 2, chunkSize: 1)
        XCTAssertEqual(text, "詞,読み,意味\n本,ほん,book\n")
    }

    func testDetectUTF16BEBOM() {
        let data = Data([0xFE, 0xFF]) + "a,b\n".data(using: .utf16BigEndian)!
        XCTAssertEqual(
            ImportEncodingDetector.detect(prefix: data),
            .detected(encoding: .utf16BE, bomBytes: 2, viaBOM: true)
        )
    }

    func testDetectPlainUTF8() throws {
        let data = try fixtureData("quoted-newline.csv")
        XCTAssertEqual(
            ImportEncodingDetector.detect(prefix: data),
            .detected(encoding: .utf8, bomBytes: 0, viaBOM: false)
        )
    }

    func testUndeterminedListsCandidates() {
        // 非 UTF-8 且无 BOM：Latin-1 风格字节流。
        let data = Data([0xE9, 0xE8, 0xE7, 0x0A])
        guard case let .undetermined(candidates) = ImportEncodingDetector.detect(prefix: data) else {
            return XCTFail("expected undetermined")
        }
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.contains(.utf8))
    }

    // MARK: - 严格 UTF-8

    func testStrictUTF8RejectsInvalidSequence() {
        guard case let .undetermined(candidates) = ImportEncodingDetector.detect(
            prefix: Data([0x61, 0xC0, 0xAF, 0x62])
        ) else {
            return XCTFail("expected undetermined")
        }
        XCTAssertEqual(Set(candidates), Set(ImportTextEncoding.allCases))
    }

    func testUTF8SurrogateEncodingRejected() throws {
        // ED A0 80 = U+D800 的 UTF-8 编码——非法。
        var decoder = IncrementalTextDecoder(encoding: .utf8)
        XCTAssertThrowsError(try decoder.decode([0xED, 0xA0, 0x80])) { error in
            XCTAssertEqual(error as? ImportParseError, .invalidEncoding(offset: 0, reason: "invalid UTF-8 sequence"))
        }
    }

    func testUTF8TruncatedSequenceAtEOF() throws {
        var decoder = IncrementalTextDecoder(encoding: .utf8)
        _ = try decoder.decode([0x61, 0xF0, 0x9F]) // "a" + 半个 emoji
        XCTAssertThrowsError(try decoder.finish()) { error in
            guard case .invalidEncoding = error as? ImportParseError else {
                return XCTFail("expected invalidEncoding, got \(error)")
            }
        }
    }

    // MARK: - 跨 chunk 多字节

    /// multibyte-split.csv 逐字节喂 decoder：4 字节 emoji 被切到 4 个
    /// chunk 里，解码结果必须与整体解码一致。
    func testMultibyteScalarSplitAcrossByteChunks() throws {
        let data = try fixtureData("multibyte-split.csv")
        let baseline = String(decoding: data, as: UTF8.self)
        for size in [1, 2, 3, 7] {
            let text = try decodeAll(data, encoding: .utf8, chunkSize: size)
            XCTAssertEqual(text, baseline, "chunkSize=\(size)")
        }
    }

    /// UTF-16LE 逐字节 + 奇数尾字节缓存。
    func testUTF16OddByteBoundary() throws {
        let text = "ab😀cd\n"
        let data = text.data(using: .utf16LittleEndian)!
        for size in [1, 3, 5] {
            let decoded = try decodeAll(data, encoding: .utf16LE, chunkSize: size)
            XCTAssertEqual(decoded, text, "chunkSize=\(size)")
        }
    }

    /// UTF-16 高代理被切在两个 chunk 之间。
    func testUTF16SurrogatePairSplit() throws {
        let data = "😀".data(using: .utf16BigEndian)! // 4 字节
        var decoder = IncrementalTextDecoder(encoding: .utf16BE)
        XCTAssertEqual(try decoder.decode(data.prefix(2)), "") // 只有高代理
        XCTAssertEqual(try decoder.decode(data.suffix(2)), "😀")
        XCTAssertEqual(try decoder.finish(), "")
    }

    func testUTF16UnpairedLowSurrogate() throws {
        var decoder = IncrementalTextDecoder(encoding: .utf16LE)
        XCTAssertThrowsError(try decoder.decode([0x00, 0xDC])) { error in
            XCTAssertEqual(error as? ImportParseError, .invalidEncoding(offset: 0, reason: "lone low surrogate"))
        }
    }

    // MARK: - 手动 override 与字节预算

    func testManualOverrideDecodesUTF16WithoutBOM() throws {
        let data = "x,y\n".data(using: .utf16LittleEndian)! // 无 BOM
        let text = try decodeAll(data, encoding: .utf16LE, chunkSize: 4)
        XCTAssertEqual(text, "x,y\n")
    }

    func testFileByteBudget() throws {
        var decoder = IncrementalTextDecoder(encoding: .utf8, maximumInputBytes: 10)
        _ = try decoder.decode(Data(repeating: 0x61, count: 10))
        XCTAssertThrowsError(try decoder.decode([0x61])) { error in
            XCTAssertEqual(
                error as? ImportParseError,
                .limitExceeded(metric: "fileBytes", limit: 10)
            )
        }
    }

    // MARK: - 分隔符检测

    func testDelimiterDetectorPicksTab() throws {
        let sample = "a\tb\tc\n1\t2\t3\nx\ty\tz\n"
        let result = DelimiterDetector.detect(in: sample)
        guard case let .confident(delimiter, _) = result else {
            return XCTFail("expected confident, got \(result)")
        }
        XCTAssertEqual(delimiter, "\t")
    }

    func testDelimiterDetectorPicksComma() throws {
        let sample = "a,b,c\n1,2,3\nx,y,z\n"
        guard case let .confident(delimiter, _) = DelimiterDetector.detect(in: sample) else {
            return XCTFail("expected confident")
        }
        XCTAssertEqual(delimiter, ",")
    }

    func testDelimiterDetectorPicksSemicolon() throws {
        let sample = "a;b;c\n1;2;3\n"
        guard case let .confident(delimiter, _) = DelimiterDetector.detect(in: sample) else {
            return XCTFail("expected confident")
        }
        XCTAssertEqual(delimiter, ";")
    }

    /// 单列文件没有任何分隔符结构 → 必须让用户选择。
    func testSingleColumnNeedsUserChoice() {
        let result = DelimiterDetector.detect(in: "abc\ndef\nghi\n")
        guard case let .needsUserChoice(candidates) = result else {
            return XCTFail("expected needsUserChoice, got \(result)")
        }
        XCTAssertEqual(Set(candidates.map(\.delimiter)), Set([",", "\t", ";"]))
    }

    /// 逗号与分号都给出一致结构时置信不足 → 用户选择。
    func testAmbiguousDelimitersNeedUserChoice() {
        let result = DelimiterDetector.detect(in: "a,b;c\n1,2;3\n")
        guard case .needsUserChoice = result else {
            return XCTFail("expected needsUserChoice, got \(result)")
        }
    }
}
