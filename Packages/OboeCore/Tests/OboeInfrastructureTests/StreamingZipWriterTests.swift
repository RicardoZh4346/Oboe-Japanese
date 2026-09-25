import CryptoKit
import Foundation
import XCTest
@testable import OboeInfrastructure

/// StreamingZipWriter（v0.6.0 §8.2）契约测试：
/// 与 ZipArchive 字节级兼容（旧 reader 能读新包）、短写/磁盘满/取消、
/// store/deflate、4GiB 拒绝、本地头回填正确性。
final class StreamingZipWriterTests: XCTestCase {

    // MARK: - 字节级兼容

    /// 同样的条目分别走内存版 archive 与流式 writer：输出必须逐字节一致
    /// （本地头回填值、中央目录字段序、EOCD 全部等价）。
    func testProducesByteIdenticalArchiveToInMemoryWriter() throws {
        let entries = [
            ZipArchive.WriteEntry(name: "manifest.json", data: Data("{}".utf8)),
            ZipArchive.WriteEntry(
                name: "records.ndjson",
                data: Data(repeating: 0x61, count: 300_000),
                dosDate: 0x2A21,
                dosTime: 0x1234
            ),
            ZipArchive.WriteEntry(
                name: "attachments/pic.jpg",
                data: Data(repeating: 0xFF, count: 10_000),
                method: .store
            ),
            ZipArchive.WriteEntry(
                name: "empty.bin",
                data: Data(),
                externalAttributes: UInt32(0o100600) << 16
            )
        ]
        let expected = try ZipArchive.archive(entries: entries)
        let output = InMemoryZipOutput()
        let writer = StreamingZipWriter(output: output)
        for entry in entries {
            try writer.beginEntry(
                name: entry.name,
                method: entry.method,
                dosDate: entry.dosDate,
                dosTime: entry.dosTime,
                externalAttributes: entry.externalAttributes
            )
            try writer.write(entry.data)
            _ = try writer.finishEntry()
        }
        try writer.finalizeArchive()
        XCTAssertEqual(output.data, expected)
    }

    /// 新 writer 产物可被旧内存版 reader 逐条读出（旧 reader 读新包）。
    func testWrittenArchiveReadsBackWithLegacyReader() throws {
        let payloads: [(String, Data, ZipArchive.Method)] = [
            ("a.txt", Data("hello".utf8), .deflate),
            ("b.bin", Data((0..<255).map { UInt8($0) }), .store),
            ("big.ndjson", Data(repeating: 0x62, count: 1_000_000), .deflate)
        ]
        let output = InMemoryZipOutput()
        let writer = StreamingZipWriter(output: output)
        for (name, data, method) in payloads {
            try writer.beginEntry(name: name, method: method)
            try writer.write(data)
            _ = try writer.finishEntry()
        }
        try writer.finalizeArchive()

        let reader = try ZipArchive.Reader(data: output.data)
        XCTAssertEqual(reader.entries.count, payloads.count)
        for (name, data, _) in payloads {
            let entry = try XCTUnwrap(reader.entries.first { $0.name == name })
            XCTAssertEqual(try reader.extract(entry), data)
        }
    }

    /// 旧内存版 writer 产物可被新流式 reader 逐条读出（新 reader 读旧包）。
    func testLegacyArchiveReadsBackWithStreamingReader() throws {
        let payloads: [(String, Data, ZipArchive.Method)] = [
            ("manifest.json", Data("{\"a\":1}".utf8), .deflate),
            ("records.ndjson", Data(repeating: 0x63, count: 500_000), .deflate),
            ("attachments/x.png", Data(repeating: 0x89, count: 7_777), .store)
        ]
        let data = try ZipArchive.archive(entries: payloads.map {
            ZipArchive.WriteEntry(name: $0.0, data: $0.1, method: $0.2)
        })
        let source = InMemoryZipSource(data: data)
        let reader = try StreamingZipReader(source: source)
        try reader.validateLocalHeaders()
        XCTAssertEqual(reader.entries.count, payloads.count)
        for (name, expected, _) in payloads {
            let entry = try XCTUnwrap(reader.entries.first { $0.name == name })
            XCTAssertEqual(
                try reader.extractToData(entry, byteLimit: .max),
                expected
            )
        }
        reader.close()
    }

    /// 分块喂入（非 256KiB 对齐的碎块）与一次性喂入产出相同的回填头与摘要。
    func testChunkedDeflateProducesSameDigestsAsSingleWrite() throws {
        let content = (0..<300_000).map { UInt8($0 % 251) }
        var reference: StreamingZipWriter.EntryResult!
        for chunkSize in [1, 777, 65_536, 300_000] {
            let output = InMemoryZipOutput()
            let writer = StreamingZipWriter(output: output)
            try writer.beginEntry(name: "data.bin", method: .deflate)
            var offset = 0
            while offset < content.count {
                let end = min(offset + chunkSize, content.count)
                try writer.write(Data(content[offset..<end]))
                offset = end
            }
            let result = try writer.finishEntry()
            try writer.finalizeArchive()
            if reference == nil {
                reference = result
            } else {
                XCTAssertEqual(result.crc32, reference.crc32)
                XCTAssertEqual(result.sha256, reference.sha256)
                XCTAssertEqual(result.uncompressedSize, reference.uncompressedSize)
                XCTAssertEqual(result.compressedSize, reference.compressedSize)
            }
        }
        XCTAssertEqual(Int(reference.uncompressedSize), content.count)
        XCTAssertEqual(
            reference.sha256,
            SHA256.hash(data: Data(content))
                .map { String(format: "%02x", $0) }.joined()
        )
    }

    /// store 条目直通：compressed == uncompressed，reader 端按原样解出。
    func testStoreMethodWritesRawBytes() throws {
        let content = Data(repeating: 0xAB, count: 4_096)
        let output = InMemoryZipOutput()
        let writer = StreamingZipWriter(output: output)
        try writer.beginEntry(name: "raw.img", method: .store)
        try writer.write(content)
        let result = try writer.finishEntry()
        try writer.finalizeArchive()
        XCTAssertEqual(result.compressedSize, result.uncompressedSize)
        XCTAssertEqual(result.uncompressedSize, Int64(content.count))
        let reader = try ZipArchive.Reader(data: output.data)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "raw.img" })
        XCTAssertEqual(entry.method, .store)
        XCTAssertEqual(try reader.extract(entry), content)
    }

    // MARK: - 输出故障

    /// 每次 write 只接受少量字节（短写）：writer 必须循环补齐，
    /// 产物仍与参考输出逐字节一致。
    func testShortWriteOutputStillProducesIdenticalArchive() throws {
        let entries = [
            ZipArchive.WriteEntry(name: "manifest.json", data: Data("{}".utf8)),
            ZipArchive.WriteEntry(
                name: "records.ndjson",
                data: Data(repeating: 0x61, count: 100_000)
            ),
            ZipArchive.WriteEntry(
                name: "attachments/a.jpg",
                data: Data(repeating: 0x42, count: 50_000),
                method: .store
            )
        ]
        let expected = try ZipArchive.archive(entries: entries)
        let output = InMemoryZipOutput(maxWriteChunk: 13)
        let writer = StreamingZipWriter(output: output)
        for entry in entries {
            try writer.beginEntry(
                name: entry.name,
                method: entry.method,
                dosDate: entry.dosDate,
                dosTime: entry.dosTime,
                externalAttributes: entry.externalAttributes
            )
            try writer.write(entry.data)
            _ = try writer.finishEntry()
        }
        try writer.finalizeArchive()
        XCTAssertEqual(output.data, expected)
    }

    /// 中途失败（磁盘满模拟）：错误向上传播，abort 关闭输出且不留完成态。
    func testOutputFailurePropagatesAndAbortCloses() throws {
        struct DiskFull: Error {}
        // "big.bin" 本地头 37 字节——第一个数据写调用即触发。
        let output = InMemoryZipOutput(
            failAfterBytes: 37,
            failure: DiskFull()
        )
        let writer = StreamingZipWriter(output: output)
        XCTAssertThrowsError(
            try {
                try writer.beginEntry(name: "big.bin")
                try writer.write(Data(repeating: 0x55, count: 1_000_000))
                _ = try writer.finishEntry()
            }()
        ) { XCTAssertTrue($0 is DiskFull) }
        writer.abort()
        XCTAssertTrue(output.closed)
        XCTAssertFalse(writer.isFinalized)
        // finalize 之后所有入口点都拒绝。
        XCTAssertThrowsError(try writer.finalizeArchive())
    }

    /// finalize 之后的调用一律拒绝。
    func testCallsAfterFinalizeThrow() throws {
        let output = InMemoryZipOutput()
        let writer = StreamingZipWriter(output: output)
        try writer.finalizeArchive()
        XCTAssertThrowsError(try writer.beginEntry(name: "x"))
        XCTAssertThrowsError(try writer.write(Data([1])))
        XCTAssertThrowsError(try writer.finishEntry())
        XCTAssertThrowsError(try writer.finalizeArchive())
    }

    /// 非法状态机转换全部报错。
    func testInvalidStateTransitionsThrow() throws {
        let writer = StreamingZipWriter(output: InMemoryZipOutput())
        XCTAssertThrowsError(try writer.write(Data([1])))
        XCTAssertThrowsError(try writer.finishEntry())
        try writer.beginEntry(name: "a")
        XCTAssertThrowsError(try writer.beginEntry(name: "b"))
        _ = try writer.finishEntry()
        try writer.finalizeArchive()
    }

    /// 本地头偏移超过 UInt32（归档 >4GiB）在写头前拒绝——
    /// 用注入偏移构造，不真写 4GiB。
    func testRejectsArchiveBeyond4GiB() throws {
        let writer = StreamingZipWriter(
            output: InMemoryZipOutput(),
            startingOffset: UInt64(UInt32.max)
        )
        XCTAssertThrowsError(try writer.beginEntry(name: "first")) { error in
            guard case PortableBackupPackageError.malformedArchive = error else {
                return XCTFail("应为 malformedArchive，实际 \(error)")
            }
        }
    }

    /// 文件名超长（>0xFFFF UTF-8 字节）拒绝。
    func testEntryNameTooLongThrows() throws {
        let writer = StreamingZipWriter(output: InMemoryZipOutput())
        let longName = String(repeating: "x", count: 0x1_0001)
        XCTAssertThrowsError(try writer.beginEntry(name: longName)) { error in
            XCTAssertEqual(
                error as? PortableBackupPackageError,
                .invalidEntryName(longName)
            )
        }
    }

    /// finishEntry 回填的本地头 CRC/sizes 字段与 archive() 逐字节一致
    /// （上面的 byte-identical 用例覆盖全字段，这里单点断言回填位置）。
    func testLocalHeaderBackfilledWithRealValues() throws {
        let content = Data(repeating: 0x77, count: 10_000)
        let output = InMemoryZipOutput()
        let writer = StreamingZipWriter(output: output)
        try writer.beginEntry(name: "e", method: .store)
        try writer.write(content)
        let result = try writer.finishEntry()
        try writer.finalizeArchive()

        XCTAssertEqual(output.data.littleEndianUInt32(at: 14), result.crc32)
        XCTAssertEqual(
            output.data.littleEndianUInt32(at: 18),
            UInt32(result.compressedSize)
        )
        XCTAssertEqual(
            output.data.littleEndianUInt32(at: 22),
            UInt32(result.uncompressedSize)
        )
        // 回填后写指针回到了数据末尾：中央目录签名紧跟数据区。
        let cdOffset = 30 + 1 + content.count
        XCTAssertEqual(
            output.data.littleEndianUInt32(at: cdOffset),
            0x02014B50
        )
    }
}

// MARK: - 测试替身

/// 内存版 StreamingZipOutput：支持短写上限、中途失败注入、随机 seek。
final class InMemoryZipOutput: StreamingZipOutput, @unchecked Sendable {
    private(set) var data = Data()
    private var position = 0
    private let maxWriteChunk: Int
    private let failAfterBytes: Int?
    private let failure: Error?
    private(set) var closed = false

    init(
        maxWriteChunk: Int = Int.max,
        failAfterBytes: Int? = nil,
        failure: Error? = nil
    ) {
        self.maxWriteChunk = maxWriteChunk
        self.failAfterBytes = failAfterBytes
        self.failure = failure
    }

    func write(_ chunk: Data) throws -> Int {
        if let failAfterBytes, position >= failAfterBytes,
           let failure {
            throw failure
        }
        let accepted = min(chunk.count, maxWriteChunk)
        let end = position + accepted
        if end > data.count {
            data.append(Data(repeating: 0, count: end - data.count))
        }
        data.replaceSubrange(position..<end, with: chunk.prefix(accepted))
        position = end
        return accepted
    }

    func seek(toOffset offset: UInt64) throws {
        position = Int(offset)
    }

    func synchronize() throws {}

    func close() throws {
        closed = true
    }
}

/// 内存版 StreamingZipByteSource：可限制单次读长度模拟短读。
final class InMemoryZipSource: StreamingZipByteSource, @unchecked Sendable {
    let data: Data
    let maxReadChunk: Int
    private(set) var closed = false

    init(data: Data, maxReadChunk: Int = Int.max) {
        self.data = data
        self.maxReadChunk = maxReadChunk
    }

    var sizeInBytes: Int64 { Int64(data.count) }

    func read(at offset: Int64, maximumCount: Int) throws -> Data {
        guard offset >= 0, maximumCount > 0, offset < Int64(data.count) else {
            return Data()
        }
        let count = min(maximumCount, maxReadChunk, data.count - Int(offset))
        return data.subdata(in: Int(offset)..<(Int(offset) + count))
    }

    func close() {
        closed = true
    }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
