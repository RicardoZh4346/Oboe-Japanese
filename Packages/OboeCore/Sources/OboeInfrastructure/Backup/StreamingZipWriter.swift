import CryptoKit
import Foundation
import zlib

/// StreamingZipWriter 的写出端抽象：可定位（seekable）字节流。
/// `write` 允许短写并返回实际写入字节数，writer 循环到写完；
/// 返回 0 视为写入停滞并报错。文件型实现是 FileHandle，
/// 测试可注入内存/短写/中途失败替身。
protocol StreamingZipOutput: AnyObject {
    func write(_ data: Data) throws -> Int
    func seek(toOffset offset: UInt64) throws
    func synchronize() throws
    func close() throws
}

/// FileHandle 输出：创建（或截断）目标文件后顺序写。
/// FileHandle.write 要么全写要么抛错，按合同返回 data.count。
final class FileHandleStreamingZipOutput: StreamingZipOutput {
    private let handle: FileHandle

    init(fileURL: URL) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
        // createFile 不会截断已存在文件——pending 命名按 UUID 生成通常不撞，
        // 但显式截断保证任何路径下输出都从空文件开始。
        try handle.truncate(atOffset: 0)
    }

    func write(_ data: Data) throws -> Int {
        try handle.write(contentsOf: data)
        return data.count
    }

    func seek(toOffset offset: UInt64) throws {
        try handle.seek(toOffset: offset)
    }

    func synchronize() throws {
        try handle.synchronize()
    }

    func close() throws {
        try handle.close()
    }
}

/// 流式 ZIP 写入器（设计 §8.2）：文件型输出，不聚合完整归档 Data。
///
/// `beginEntry → write(chunk)* → finishEntry() → finalizeArchive()`。
/// 本地头先以 CRC/sizes = 0 占位，条目数据写完后 seek 回填再回末尾——
/// 与 `ZipArchive.archive` 相同的「无 data descriptor」布局，
/// 产物可被既有内存版 reader 逐字节兼容读取。
///
/// CRC32 与 SHA-256 随写随算（SHA-256 供 checksums.json 使用）；
/// deflate 走系统 zlib raw 流（windowBits = -15），与 ZipArchive 同参数。
final class StreamingZipWriter {
    /// 单个条目写完后的摘要——供调用方填 manifest/checksums，无需重读文件。
    struct EntryResult: Sendable, Equatable {
        let name: String
        let crc32: UInt32
        /// 未压缩内容的 SHA-256（小写十六进制）。
        let sha256: String
        let compressedSize: Int64
        let uncompressedSize: Int64
    }

    /// 推荐的调用方喂入粒度。
    static let chunkSize = 256 * 1_024

    private static let localHeaderSignature: UInt32 = 0x04034B50
    private static let centralDirectorySignature: UInt32 = 0x02014B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054B50
    private static let flagUTF8Names: UInt16 = 0x0800
    private static let maximumEntryCount = 0xFFFF

    private struct OpenEntry {
        let name: String
        let nameData: Data
        let method: ZipArchive.Method
        let dosDate: UInt16
        let dosTime: UInt16
        let externalAttributes: UInt32
        let localHeaderOffset: UInt64
        var crc32: UInt32 = 0
        var sha256 = SHA256()
        var compressedSize: UInt64 = 0
        var uncompressedSize: UInt64 = 0
    }

    /// 内存中有界保留的中央目录元数据（条目数受 maximumEntryCount 约束）。
    private struct CentralRecord {
        let nameData: Data
        let method: ZipArchive.Method
        let dosDate: UInt16
        let dosTime: UInt16
        let externalAttributes: UInt32
        let localHeaderOffset: UInt32
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
    }

    private let output: any StreamingZipOutput
    /// 当前写出位置（字节）。writer 全权管理 seek，内部计数与文件一致。
    private var position: UInt64
    private var open: OpenEntry?
    private var deflateStream = z_stream()
    private var deflateActive = false
    private var central: [CentralRecord] = []
    private var finalized = false
    private var closed = false

    /// 固定大小的 zlib 工作缓冲，避免每个 chunk 重新分配。
    private var deflateBuffer = Data(count: StreamingZipWriter.chunkSize)

    /// 文件型输出：归档直接写入 fileURL（调用方负责 .pending 命名与原子 rename）。
    init(fileURL: URL) throws {
        output = try FileHandleStreamingZipOutput(fileURL: fileURL)
        position = 0
    }

    /// 注入型输出（测试/替代 sink）。`startingOffset` 用于构造越界断言，
    /// 正常调用方保持 0。
    init(output: any StreamingZipOutput, startingOffset: UInt64 = 0) {
        self.output = output
        self.position = startingOffset
    }

    deinit {
        if deflateActive {
            deflateEnd(&deflateStream)
        }
        if !closed {
            try? output.close()
        }
    }

    // MARK: - 条目写入

    func beginEntry(
        name: String,
        method: ZipArchive.Method = .deflate,
        dosDate: UInt16 = 0x21,
        dosTime: UInt16 = 0,
        externalAttributes: UInt32 = UInt32(0o100644) << 16
    ) throws {
        try ensureOpen()
        guard open == nil else {
            throw PortableBackupPackageError.malformedArchive("上一个条目尚未结束。")
        }
        guard let nameData = name.data(using: .utf8),
              nameData.count <= 0xFFFF else {
            throw PortableBackupPackageError.invalidEntryName(name)
        }
        guard central.count < Self.maximumEntryCount else {
            throw PortableBackupPackageError.tooManyEntries(
                actual: central.count + 1,
                limit: Self.maximumEntryCount
            )
        }
        // 0xFFFFFFFF 是 ZIP64 哨兵——本地头偏移必须严格小于它。
        guard position < UInt64(UInt32.max) else {
            throw PortableBackupPackageError.malformedArchive("归档超过 4GiB 上限。")
        }

        // 本地文件头：CRC/sizes 占位 0，finishEntry 里 seek 回填。
        var header = Data()
        header.reserveCapacity(30 + nameData.count)
        header.appendLittleEndian(Self.localHeaderSignature)
        header.appendLittleEndian(UInt16(20))               // version needed
        header.appendLittleEndian(Self.flagUTF8Names)       // flags
        header.appendLittleEndian(method.rawValue)
        header.appendLittleEndian(dosTime)
        header.appendLittleEndian(dosDate)
        header.appendLittleEndian(UInt32(0))                // crc32 占位
        header.appendLittleEndian(UInt32(0))                // compressed 占位
        header.appendLittleEndian(UInt32(0))                // uncompressed 占位
        header.appendLittleEndian(UInt16(nameData.count))
        header.appendLittleEndian(UInt16(0))                // extra length
        header.append(nameData)
        try writeAll(header)

        open = OpenEntry(
            name: name,
            nameData: nameData,
            method: method,
            dosDate: dosDate,
            dosTime: dosTime,
            externalAttributes: externalAttributes,
            localHeaderOffset: position - UInt64(header.count)
        )
        if method == .deflate {
            guard deflateInit2_(
                &deflateStream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK else {
                throw PortableBackupPackageError.malformedArchive("deflate 初始化失败。")
            }
            deflateActive = true
        }
    }

    /// 写入一段未压缩内容。空 chunk 是合法 no-op。
    /// 单次调用不得超过 4GiB（zlib avail_in 是 uInt）。
    func write(_ data: Data) throws {
        try ensureOpen()
        guard var entry = open else {
            throw PortableBackupPackageError.malformedArchive("没有打开的条目。")
        }
        guard data.count <= Int(UInt32.max) else {
            throw PortableBackupPackageError.entryTooLarge(
                name: entry.name,
                actual: Int64(data.count),
                limit: Int64(UInt32.max)
            )
        }
        if !data.isEmpty {
            entry.crc32 = Self.incrementalCRC32(entry.crc32, of: data)
            entry.sha256.update(data: data)
            entry.uncompressedSize += UInt64(data.count)
            // 0xFFFFFFFF 是 ZIP64 哨兵——条目大小必须严格小于它。
            guard entry.uncompressedSize < UInt64(UInt32.max) else {
                throw PortableBackupPackageError.entryTooLarge(
                    name: entry.name,
                    actual: Int64(bitPattern: entry.uncompressedSize),
                    limit: Int64(UInt32.max)
                )
            }
            switch entry.method {
            case .store:
                try writeAll(data)
                entry.compressedSize += UInt64(data.count)
            case .deflate:
                let produced = try deflateWrite(data)
                entry.compressedSize += produced
            }
        }
        open = entry
    }

    /// 结束当前条目：flush deflate、回填本地头 CRC/sizes、登记中央目录。
    @discardableResult
    func finishEntry() throws -> EntryResult {
        try ensureOpen()
        guard var entry = open else {
            throw PortableBackupPackageError.malformedArchive("没有打开的条目。")
        }
        if entry.method == .deflate {
            let produced = try deflateFinish()
            entry.compressedSize += produced
        }
        guard entry.uncompressedSize < UInt64(UInt32.max),
              entry.compressedSize < UInt64(UInt32.max) else {
            throw PortableBackupPackageError.entryTooLarge(
                name: entry.name,
                actual: Int64(bitPattern: entry.uncompressedSize),
                limit: Int64(UInt32.max)
            )
        }

        // 回填本地头 CRC32/compressed/uncompressed（偏移 14 起 12 字节）。
        let endOfData = position
        try output.seek(toOffset: entry.localHeaderOffset + 14)
        position = entry.localHeaderOffset + 14
        var patch = Data()
        patch.appendLittleEndian(entry.crc32)
        patch.appendLittleEndian(UInt32(entry.compressedSize))
        patch.appendLittleEndian(UInt32(entry.uncompressedSize))
        try writeAll(patch)
        try output.seek(toOffset: endOfData)
        position = endOfData

        central.append(CentralRecord(
            nameData: entry.nameData,
            method: entry.method,
            dosDate: entry.dosDate,
            dosTime: entry.dosTime,
            externalAttributes: entry.externalAttributes,
            localHeaderOffset: UInt32(entry.localHeaderOffset),
            crc32: entry.crc32,
            compressedSize: UInt32(entry.compressedSize),
            uncompressedSize: UInt32(entry.uncompressedSize)
        ))
        let digest = entry.sha256.finalize()
        let result = EntryResult(
            name: entry.name,
            crc32: entry.crc32,
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            compressedSize: Int64(bitPattern: entry.compressedSize),
            uncompressedSize: Int64(bitPattern: entry.uncompressedSize)
        )
        open = nil
        return result
    }

    /// 写中央目录 + EOCD、fsync、关闭输出。之后 writer 不再可用。
    func finalizeArchive() throws {
        try ensureOpen()
        guard open == nil else {
            throw PortableBackupPackageError.malformedArchive("仍有条目未结束。")
        }
        let centralOffset = position
        guard centralOffset < UInt64(UInt32.max) else {
            throw PortableBackupPackageError.malformedArchive("归档超过 4GiB 上限。")
        }

        for record in central {
            var entryData = Data()
            entryData.reserveCapacity(46 + record.nameData.count)
            entryData.appendLittleEndian(Self.centralDirectorySignature)
            entryData.appendLittleEndian(UInt16(20))     // version made by
            entryData.appendLittleEndian(UInt16(20))     // version needed
            entryData.appendLittleEndian(Self.flagUTF8Names)
            entryData.appendLittleEndian(record.method.rawValue)
            entryData.appendLittleEndian(record.dosTime)
            entryData.appendLittleEndian(record.dosDate)
            entryData.appendLittleEndian(record.crc32)
            entryData.appendLittleEndian(record.compressedSize)
            entryData.appendLittleEndian(record.uncompressedSize)
            entryData.appendLittleEndian(UInt16(record.nameData.count))
            entryData.appendLittleEndian(UInt16(0))      // extra
            entryData.appendLittleEndian(UInt16(0))      // comment
            entryData.appendLittleEndian(UInt16(0))      // disk start
            entryData.appendLittleEndian(UInt16(0))      // internal attrs
            entryData.appendLittleEndian(record.externalAttributes)
            entryData.appendLittleEndian(record.localHeaderOffset)
            entryData.append(record.nameData)
            try writeAll(entryData)
        }
        let centralSize = position - centralOffset
        guard centralSize < UInt64(UInt32.max) else {
            throw PortableBackupPackageError.malformedArchive("归档超过 4GiB 上限。")
        }

        var eocd = Data()
        eocd.appendLittleEndian(Self.endOfCentralDirectorySignature)
        eocd.appendLittleEndian(UInt16(0))                    // disk number
        eocd.appendLittleEndian(UInt16(0))                    // cd start disk
        eocd.appendLittleEndian(UInt16(central.count))        // entries on disk
        eocd.appendLittleEndian(UInt16(central.count))        // total entries
        eocd.appendLittleEndian(UInt32(centralSize))
        eocd.appendLittleEndian(UInt32(centralOffset))
        eocd.appendLittleEndian(UInt16(0))                    // comment length
        try writeAll(eocd)

        try output.synchronize()
        try output.close()
        closed = true
        finalized = true
    }

    /// 中途失败：尽力关闭输出，不写中央目录（残留文件由调用方删除）。
    func abort() {
        guard !closed else { return }
        if deflateActive {
            deflateEnd(&deflateStream)
            deflateActive = false
        }
        try? output.close()
        closed = true
    }

    var isFinalized: Bool { finalized }

    // MARK: - 内部

    private func ensureOpen() throws {
        guard !closed, !finalized else {
            throw PortableBackupPackageError.malformedArchive("归档已关闭。")
        }
    }

    /// 容忍短写：循环直到 data 全部写出；返回 0 字节视为停滞报错。
    private func writeAll(_ data: Data) throws {
        var written = 0
        while written < data.count {
            let n = try output.write(data.subdata(in: written..<data.count))
            guard n > 0 else {
                throw PortableBackupPackageError.malformedArchive(
                    "ZIP 输出写入没有进展。"
                )
            }
            written += n
        }
        position += UInt64(data.count)
    }

    /// raw deflate 流式喂入（windowBits = -15，与 ZipArchive 同参数）。
    /// 返回本段输入产生的压缩字节数。
    private func deflateWrite(_ data: Data) throws -> UInt64 {
        var produced: UInt64 = 0
        var failure: Error?
        data.withUnsafeBytes { input in
            guard let baseAddress = input.baseAddress, failure == nil else { return }
            deflateStream.next_in = UnsafeMutablePointer(
                mutating: baseAddress.assumingMemoryBound(to: Bytef.self)
            )
            deflateStream.avail_in = uInt(input.count)
            repeat {
                var chunkProduced = 0
                var status: Int32 = Z_OK
                deflateBuffer.withUnsafeMutableBytes { buffer in
                    guard let outBase = buffer.baseAddress else { return }
                    deflateStream.next_out = outBase.assumingMemoryBound(to: Bytef.self)
                    deflateStream.avail_out = uInt(buffer.count)
                    status = deflate(&deflateStream, Z_NO_FLUSH)
                    chunkProduced = buffer.count - Int(deflateStream.avail_out)
                }
                guard status == Z_OK else {
                    failure = PortableBackupPackageError.malformedArchive(
                        "deflate 写入失败（\(status)）。"
                    )
                    return
                }
                if chunkProduced > 0 {
                    do {
                        try writeAll(deflateBuffer.prefix(chunkProduced))
                        produced += UInt64(chunkProduced)
                    } catch {
                        failure = error
                        return
                    }
                }
            } while deflateStream.avail_in > 0 || deflateStream.avail_out == 0
        }
        if let failure { throw failure }
        return produced
    }

    /// Z_FINISH 排空 deflate 流并释放 z_stream。返回尾部压缩字节数。
    private func deflateFinish() throws -> UInt64 {
        var produced: UInt64 = 0
        var failure: Error?
        var finished = false
        while !finished, failure == nil {
            var chunkProduced = 0
            var status: Int32 = Z_OK
            deflateBuffer.withUnsafeMutableBytes { buffer in
                guard let outBase = buffer.baseAddress else { return }
                deflateStream.next_out = outBase.assumingMemoryBound(to: Bytef.self)
                deflateStream.avail_out = uInt(buffer.count)
                status = deflate(&deflateStream, Z_FINISH)
                chunkProduced = buffer.count - Int(deflateStream.avail_out)
            }
            switch status {
            case Z_STREAM_END:
                finished = true
            case Z_OK:
                break
            default:
                failure = PortableBackupPackageError.malformedArchive(
                    "deflate 结束失败（\(status)）。"
                )
            }
            if chunkProduced > 0, failure == nil {
                do {
                    try writeAll(deflateBuffer.prefix(chunkProduced))
                    produced += UInt64(chunkProduced)
                } catch {
                    failure = error
                }
            }
        }
        deflateEnd(&deflateStream)
        deflateActive = false
        if let failure { throw failure }
        return produced
    }

    private static func incrementalCRC32(_ seed: UInt32, of data: Data) -> UInt32 {
        var value = uLong(seed)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            // uInt 上限切片喂入（chunk 通常 256KiB，防御性切片）。
            var offset = 0
            while offset < buffer.count {
                let length = min(buffer.count - offset, Int(UInt32.max))
                value = zlib.crc32(
                    value,
                    base.advanced(by: offset).assumingMemoryBound(to: Bytef.self),
                    uInt(length)
                )
                offset += length
            }
        }
        return UInt32(truncatingIfNeeded: value)
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
