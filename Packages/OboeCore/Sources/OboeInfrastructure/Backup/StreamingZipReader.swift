import CryptoKit
import Foundation
import zlib

/// StreamingZipReader 的读入端抽象：定长、可随机访问的字节源。
/// `read` 允许短读（返回的字节数可少于请求数），reader 负责循环补齐；
/// 返回空 Data 表示已到源末尾。文件实现是 FileHandle，
/// 测试可注入短读/截断/损坏替身。
protocol StreamingZipByteSource: AnyObject {
    var sizeInBytes: Int64 { get }
    /// 从 offset 起返回最多 maximumCount 字节；offset 越界应返回空 Data。
    func read(at offset: Int64, maximumCount: Int) throws -> Data
    func close()
}

/// FileHandle 字节源。
final class FileHandleZipByteSource: StreamingZipByteSource {
    private let handle: FileHandle
    let sizeInBytes: Int64

    init(fileURL: URL) throws {
        handle = try FileHandle(forReadingFrom: fileURL)
        sizeInBytes = Int64(try handle.seekToEnd())
    }

    func read(at offset: Int64, maximumCount: Int) throws -> Data {
        guard offset >= 0, maximumCount > 0, offset < sizeInBytes else {
            return Data()
        }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: maximumCount) ?? Data()
    }

    func close() {
        try? handle.close()
    }
}

/// 流式 ZIP 读取器（设计 §8.3）：不再把整包读进内存。
///
/// 文件尾 64KiB+22 窗口定位 EOCD → 逐条读中央目录元数据 →
/// `validateLocalHeaders()` 逐条核对本地头并做数据区重叠检查 →
/// `extractToData` / `extractToFile` 按 offset 流式解压，边解压边
/// 累计大小/CRC32/SHA-256，超限立即中断，不预分配声明的巨大 size。
final class StreamingZipReader {
    struct Entry: Sendable, Equatable {
        let name: String
        /// 中央目录里的原始文件名字节（用于与本地头逐字节比对）。
        let nameData: Data
        let method: ZipArchive.Method
        let compressedSize: Int64
        let uncompressedSize: Int64
        let crc32: UInt32
        let localHeaderOffset: Int64
        let flags: UInt16
        let externalAttributes: UInt32
        /// 本地头校验后填充：压缩数据区在文件内的起点。
        var dataStart: Int64 = -1

        var isDirectory: Bool { name.hasSuffix("/") }

        /// UNIX mode 指示的非常规文件（符号链接、FIFO、设备、目录位……）。
        /// mode 全 0（非 UNIX 创建器）按普通文件处理。
        var isNonRegularFile: Bool {
            let type = (externalAttributes >> 16) & 0xF000
            return type != 0 && type != 0x8000
        }
    }

    /// 流式解压到文件的结果。
    struct FileResult: Sendable, Equatable {
        /// 实际解压字节数（已核对等于中央目录声明值）。
        let byteCount: Int64
        /// 解压内容的 SHA-256（小写十六进制），边解压边算。
        let sha256: String
    }

    private static let localHeaderSignature: UInt32 = 0x04034B50
    private static let centralDirectorySignature: UInt32 = 0x02014B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054B50
    private static let endOfCentralDirectoryMinimumSize: Int64 = 22
    private static let centralDirectoryEntryFixedSize = 46
    private static let localHeaderFixedSize = 30
    private static let flagEncrypted: UInt16 = 0x0001
    private static let streamChunkSize = 256 * 1_024

    private let source: any StreamingZipByteSource
    private let fileSize: Int64
    /// 中央目录起点——所有条目的（本地头+数据）区域必须落在它之前。
    private let centralDirectoryOffset: Int64
    private(set) var entries: [Entry]
    private var validatedLocals = false
    private var closed = false

    init(fileURL: URL) throws {
        let byteSource = try FileHandleZipByteSource(fileURL: fileURL)
        source = byteSource
        fileSize = byteSource.sizeInBytes
        let parsed = try Self.parseCentralDirectory(source: source, fileSize: fileSize)
        entries = parsed.entries
        centralDirectoryOffset = parsed.offset
    }

    /// 注入型字节源（测试短读/截断/损坏场景）。
    init(source: any StreamingZipByteSource) throws {
        self.source = source
        fileSize = source.sizeInBytes
        let parsed = try Self.parseCentralDirectory(source: source, fileSize: fileSize)
        entries = parsed.entries
        centralDirectoryOffset = parsed.offset
    }

    deinit {
        if !closed {
            source.close()
        }
    }

    func close() {
        guard !closed else { return }
        source.close()
        closed = true
    }

    // MARK: - EOCD / 中央目录

    private static func parseCentralDirectory(
        source: any StreamingZipByteSource,
        fileSize: Int64
    ) throws -> (entries: [Entry], offset: Int64) {
        guard fileSize >= endOfCentralDirectoryMinimumSize else {
            throw PortableBackupPackageError.notAPackage
        }
        let windowStart = max(
            Int64(0),
            fileSize - (endOfCentralDirectoryMinimumSize + 0xFFFF)
        )
        let tail = try readExact(
            source: source,
            offset: windowStart,
            count: Int(fileSize - windowStart)
        )
        var eocdOffset: Int64?
        var cursor = tail.count - Int(endOfCentralDirectoryMinimumSize)
        while cursor >= 0 {
            if tail.littleEndianUInt32(at: cursor) == endOfCentralDirectorySignature {
                eocdOffset = windowStart + Int64(cursor)
                break
            }
            cursor -= 1
        }
        guard let eocd = eocdOffset else {
            throw PortableBackupPackageError.notAPackage
        }
        let e = Int(eocd - windowStart)
        let commentLength = Int64(tail.littleEndianUInt16(at: e + 20))
        guard eocd + endOfCentralDirectoryMinimumSize + commentLength == fileSize else {
            throw PortableBackupPackageError.malformedArchive("EOCD 不在文件末尾。")
        }
        let diskNumber = tail.littleEndianUInt16(at: e + 4)
        let cdStartDisk = tail.littleEndianUInt16(at: e + 6)
        let entriesOnDisk = tail.littleEndianUInt16(at: e + 8)
        let totalEntries = tail.littleEndianUInt16(at: e + 10)
        let cdSize = tail.littleEndianUInt32(at: e + 12)
        let cdOffset = tail.littleEndianUInt32(at: e + 16)
        guard diskNumber == 0, cdStartDisk == 0, entriesOnDisk == totalEntries else {
            throw PortableBackupPackageError.malformedArchive("不支持多卷 ZIP。")
        }
        // 0xFFFF/0xFFFFFFFF 哨兵值意味着 ZIP64——本实现不支持。
        guard totalEntries != 0xFFFF,
              cdSize != 0xFFFFFFFF, cdOffset != 0xFFFFFFFF else {
            throw PortableBackupPackageError.malformedArchive("不支持 ZIP64。")
        }
        let cdStart = Int64(cdOffset)
        let cdEnd = cdStart + Int64(cdSize)
        guard cdStart >= 0, cdEnd <= eocd else {
            throw PortableBackupPackageError.malformedArchive("中央目录越界。")
        }

        let cursorReader = SequentialByteReader(source: source, start: cdStart)
        var result: [Entry] = []
        result.reserveCapacity(Int(totalEntries))
        var seenNames = Set<String>()
        for _ in 0..<Int(totalEntries) {
            guard cursorReader.offset + Int64(centralDirectoryEntryFixedSize) <= cdEnd else {
                throw PortableBackupPackageError.malformedArchive("中央目录条目截断。")
            }
            let fixed = try cursorReader.read(centralDirectoryEntryFixedSize)
            guard fixed.littleEndianUInt32(at: 0) == centralDirectorySignature else {
                throw PortableBackupPackageError.malformedArchive("中央目录签名无效。")
            }
            let flags = fixed.littleEndianUInt16(at: 8)
            let methodRaw = fixed.littleEndianUInt16(at: 10)
            let crc = fixed.littleEndianUInt32(at: 16)
            let compressedSize = fixed.littleEndianUInt32(at: 20)
            let uncompressedSize = fixed.littleEndianUInt32(at: 24)
            let nameLength = Int(fixed.littleEndianUInt16(at: 28))
            let extraLength = Int(fixed.littleEndianUInt16(at: 30))
            let commentLength = Int(fixed.littleEndianUInt16(at: 32))
            let diskStart = fixed.littleEndianUInt16(at: 34)
            let externalAttributes = fixed.littleEndianUInt32(at: 38)
            let localHeaderOffset = fixed.littleEndianUInt32(at: 42)
            let entryEnd = cursorReader.offset
                + Int64(nameLength + extraLength + commentLength)
            guard entryEnd <= cdEnd,
                  compressedSize != 0xFFFFFFFF, uncompressedSize != 0xFFFFFFFF,
                  localHeaderOffset != 0xFFFFFFFF else {
                throw PortableBackupPackageError.malformedArchive(
                    "中央目录条目越界或需要 ZIP64。"
                )
            }
            guard diskStart == 0 else {
                throw PortableBackupPackageError.malformedArchive("不支持多卷 ZIP。")
            }
            guard flags & flagEncrypted == 0 else {
                throw PortableBackupPackageError.encryptedArchive
            }
            guard let method = ZipArchive.Method(rawValue: methodRaw) else {
                throw PortableBackupPackageError.unsupportedCompressionMethod(methodRaw)
            }
            let nameBytes = try cursorReader.read(nameLength)
            guard let name = String(data: nameBytes, encoding: .utf8),
                  name.utf8.count == nameBytes.count else {
                throw PortableBackupPackageError.invalidEntryName("<二进制文件名>")
            }
            guard seenNames.insert(name).inserted else {
                throw PortableBackupPackageError.duplicateEntry(name)
            }
            cursorReader.skip(Int64(extraLength + commentLength))
            result.append(Entry(
                name: name,
                nameData: nameBytes,
                method: method,
                compressedSize: Int64(compressedSize),
                uncompressedSize: Int64(uncompressedSize),
                crc32: crc,
                localHeaderOffset: Int64(localHeaderOffset),
                flags: flags,
                externalAttributes: externalAttributes
            ))
        }
        guard cursorReader.offset == cdEnd else {
            throw PortableBackupPackageError.malformedArchive("中央目录长度不符。")
        }
        return (result, cdStart)
    }

    // MARK: - 本地头一致性 + 数据区重叠

    /// 逐条读本地文件头：签名 + 名称/flags/method/CRC/sizes 与中央目录一致，
    /// 数据区落在中央目录之前，且所有条目的（本地头+数据）区域两两不重叠。
    /// 幂等；extract 前必须执行过（extract 内部也会惰性触发一次）。
    func validateLocalHeaders() throws {
        guard !validatedLocals else { return }
        var regions: [(start: Int64, end: Int64)] = []
        regions.reserveCapacity(entries.count)
        for index in entries.indices {
            var entry = entries[index]
            let offset = entry.localHeaderOffset
            guard offset >= 0,
                  offset + Int64(Self.localHeaderFixedSize) <= centralDirectoryOffset else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的本地头越界。"
                )
            }
            let local = try Self.readExact(
                source: source,
                offset: offset,
                count: Self.localHeaderFixedSize
            )
            guard local.littleEndianUInt32(at: 0) == Self.localHeaderSignature else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的本地头签名无效。"
                )
            }
            guard local.littleEndianUInt16(at: 6) == entry.flags else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的本地头与中央目录标志位不一致。"
                )
            }
            guard local.littleEndianUInt16(at: 8) == entry.method.rawValue else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的本地头与中央目录压缩方式不一致。"
                )
            }
            guard local.littleEndianUInt32(at: 14) == entry.crc32,
                  local.littleEndianUInt32(at: 18) == UInt32(entry.compressedSize),
                  local.littleEndianUInt32(at: 22) == UInt32(entry.uncompressedSize) else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的本地头与中央目录 CRC/大小不一致。"
                )
            }
            let localNameLength = Int(local.littleEndianUInt16(at: 26))
            let localExtraLength = Int(local.littleEndianUInt16(at: 28))
            let nameStart = offset + Int64(Self.localHeaderFixedSize)
            let dataStart = nameStart + Int64(localNameLength + localExtraLength)
            guard dataStart <= centralDirectoryOffset else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的本地头越界。"
                )
            }
            let localName = try Self.readExact(
                source: source,
                offset: nameStart,
                count: localNameLength
            )
            guard localName == entry.nameData else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的本地头与中央目录文件名不一致。"
                )
            }
            let dataEnd = dataStart + entry.compressedSize
            guard dataEnd <= centralDirectoryOffset else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的数据区越界。"
                )
            }
            entry.dataStart = dataStart
            entries[index] = entry
            regions.append((start: offset, end: dataEnd))
        }
        // 数据区重叠检查：任一区间与前一区间相交即拒绝。
        regions.sort { $0.start < $1.start }
        for index in regions.indices.dropFirst() {
            guard regions[index].start >= regions[index - 1].end else {
                throw PortableBackupPackageError.malformedArchive(
                    "条目数据区重叠。"
                )
            }
        }
        validatedLocals = true
    }

    // MARK: - 流式解压

    /// 解压到内存——只用于 manifest/checksums 这类有严格小上限的条目。
    /// `byteLimit` 在上层已按条目类型分派；解压中超过立即中断。
    func extractToData(_ entry: Entry, byteLimit: Int64) throws -> Data {
        var output = Data()
        _ = try stream(entry: entry, byteLimit: byteLimit) { chunk in
            output.append(chunk)
        }
        return output
    }

    /// 解压到目标文件：FileHandle 顺序写，边解压边算 SHA-256/CRC32。
    /// 任何校验失败都会删除部分写出的目标文件再抛错。
    @discardableResult
    func extractToFile(
        _ entry: Entry,
        to destinationURL: URL,
        byteLimit: Int64
    ) throws -> FileResult {
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        do {
            var hasher = SHA256()
            let digest = try stream(entry: entry, byteLimit: byteLimit) { chunk in
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
            }
            try handle.synchronize()
            try handle.close()
            let hex = digest.sha256.map { String(format: "%02x", $0) }.joined()
            return FileResult(byteCount: digest.bytes, sha256: hex)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    /// 流式解压引擎：store 直通，deflate 走 zlib raw 流。
    /// sink 只在内容字节上调用；返回（字节数，SHA-256 摘要）。
    private func stream(
        entry: Entry,
        byteLimit: Int64,
        sink: (Data) throws -> Void
    ) throws -> (bytes: Int64, sha256: SHA256.Digest) {
        try validateLocalHeaders()
        guard entry.uncompressedSize <= byteLimit else {
            throw PortableBackupPackageError.entryTooLarge(
                name: entry.name,
                actual: entry.uncompressedSize,
                limit: byteLimit
            )
        }
        guard entry.dataStart >= 0 else {
            throw PortableBackupPackageError.malformedArchive(
                "\(entry.name) 缺少本地头位置。"
            )
        }

        var produced: Int64 = 0
        var crc: UInt32 = 0
        var hasher = SHA256()
        // emit：计数→限额/声明值中断→摘要→下沉。顺序保证超限字节不落盘。
        func emit(_ chunk: Data) throws {
            guard !chunk.isEmpty else { return }
            produced += Int64(chunk.count)
            if produced > entry.uncompressedSize {
                switch entry.method {
                case .deflate:
                    throw PortableBackupPackageError.malformedArchive(
                        "deflate 流与声明大小不符。"
                    )
                case .store:
                    throw PortableBackupPackageError.sizeMismatch(
                        name: entry.name,
                        expected: Int(entry.uncompressedSize),
                        actual: Int(produced)
                    )
                }
            }
            if produced > byteLimit {
                throw PortableBackupPackageError.entryTooLarge(
                    name: entry.name,
                    actual: produced,
                    limit: byteLimit
                )
            }
            crc = Self.incrementalCRC32(crc, of: chunk)
            hasher.update(data: chunk)
            try sink(chunk)
        }

        switch entry.method {
        case .store:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw PortableBackupPackageError.sizeMismatch(
                    name: entry.name,
                    expected: Int(entry.uncompressedSize),
                    actual: Int(entry.compressedSize)
                )
            }
            var consumed: Int64 = 0
            while consumed < entry.compressedSize {
                let request = min(
                    Int64(Self.streamChunkSize),
                    entry.compressedSize - consumed
                )
                let chunk = try Self.readExact(
                    source: source,
                    offset: entry.dataStart + consumed,
                    count: Int(request)
                )
                consumed += Int64(chunk.count)
                try emit(chunk)
            }
        case .deflate:
            var stream = z_stream()
            guard inflateInit2_(
                &stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK else {
                throw PortableBackupPackageError.malformedArchive("inflate 初始化失败。")
            }
            defer { inflateEnd(&stream) }
            // 手工管理的 zlib 工作缓冲：next_in/next_out 指针在两次 inflate
            // 调用之间必须保持有效，不能借用 Data 的临时 withUnsafeBytes 指针。
            let inputBuffer = UnsafeMutablePointer<Bytef>.allocate(
                capacity: Self.streamChunkSize
            )
            let outputBuffer = UnsafeMutablePointer<Bytef>.allocate(
                capacity: Self.streamChunkSize
            )
            defer {
                inputBuffer.deallocate()
                outputBuffer.deallocate()
            }
            var consumed: Int64 = 0
            var streamEnded = false
            while !streamEnded {
                if stream.avail_in == 0 {
                    guard consumed < entry.compressedSize else {
                        throw PortableBackupPackageError.malformedArchive(
                            "deflate 流与声明大小不符。"
                        )
                    }
                    let request = min(
                        Int64(Self.streamChunkSize),
                        entry.compressedSize - consumed
                    )
                    let chunk = try Self.readExact(
                        source: source,
                        offset: entry.dataStart + consumed,
                        count: Int(request)
                    )
                    consumed += Int64(chunk.count)
                    chunk.copyBytes(to: inputBuffer, count: chunk.count)
                    stream.next_in = inputBuffer
                    stream.avail_in = uInt(chunk.count)
                }
                let previousAvailIn = stream.avail_in
                stream.next_out = outputBuffer
                stream.avail_out = uInt(Self.streamChunkSize)
                let status = inflate(&stream, Z_NO_FLUSH)
                let chunkProduced = Self.streamChunkSize - Int(stream.avail_out)
                if chunkProduced > 0 {
                    try emit(Data(bytes: outputBuffer, count: chunkProduced))
                }
                switch status {
                case Z_STREAM_END:
                    streamEnded = true
                case Z_OK:
                    // 输入未消费且无产出 = 停滞——防恶意流死循环。
                    if chunkProduced == 0, stream.avail_in == previousAvailIn {
                        throw PortableBackupPackageError.malformedArchive(
                            "deflate 流损坏。"
                        )
                    }
                case Z_BUF_ERROR:
                    // 输入已尽 → 回圈补读；输入未动 → 流损坏。
                    if stream.avail_in > 0 {
                        throw PortableBackupPackageError.malformedArchive(
                            "deflate 流损坏。"
                        )
                    }
                default:
                    throw PortableBackupPackageError.malformedArchive(
                        "deflate 流损坏。"
                    )
                }
            }
        }

        guard produced == entry.uncompressedSize else {
            switch entry.method {
            case .deflate:
                throw PortableBackupPackageError.malformedArchive(
                    "deflate 流与声明大小不符。"
                )
            case .store:
                throw PortableBackupPackageError.sizeMismatch(
                    name: entry.name,
                    expected: Int(entry.uncompressedSize),
                    actual: Int(produced)
                )
            }
        }
        guard crc == entry.crc32 else {
            throw PortableBackupPackageError.crcMismatch(name: entry.name)
        }
        return (produced, hasher.finalize())
    }

    // MARK: - 读辅助

    /// 循环补齐短读；源在请求区间中途枯竭（返回空）视为文件截断。
    /// autoreleasepool 包住 ObjC 源的短读结果（FileHandle.read 返回
    /// autoreleased NSData），否则大条目解压会把累计读量顶进 RSS。
    private static func readExact(
        source: any StreamingZipByteSource,
        offset: Int64,
        count: Int
    ) throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        while result.count < count {
            let chunk = try autoreleasepool(invoking: {
                try source.read(
                    at: offset + Int64(result.count),
                    maximumCount: count - result.count
                )
            })
            guard !chunk.isEmpty else {
                throw PortableBackupPackageError.malformedArchive(
                    "文件在偏移 \(offset + Int64(result.count)) 处截断。"
                )
            }
            result.append(chunk)
        }
        return result
    }

    private static func incrementalCRC32(_ seed: UInt32, of data: Data) -> UInt32 {
        var value = uLong(seed)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
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

    // MARK: - 顺序游标（中央目录逐条解析用，容忍短读）

    private final class SequentialByteReader {
        private let source: any StreamingZipByteSource
        /// 已从源读到的绝对偏移（buffer 末尾）。
        private var fetchedEnd: Int64
        private var buffered = Data()

        init(source: any StreamingZipByteSource, start: Int64) {
            self.source = source
            fetchedEnd = start
        }

        /// 下一个将被消费的字节的绝对偏移。
        var offset: Int64 { fetchedEnd - Int64(buffered.count) }

        func read(_ count: Int) throws -> Data {
            if count == 0 { return Data() }
            while buffered.count < count {
                let chunk = try autoreleasepool(invoking: {
                    try source.read(
                        at: fetchedEnd,
                        maximumCount: max(count - buffered.count, 64 * 1_024)
                    )
                })
                guard !chunk.isEmpty else {
                    throw PortableBackupPackageError.malformedArchive(
                        "文件在偏移 \(fetchedEnd) 处截断。"
                    )
                }
                fetchedEnd += Int64(chunk.count)
                buffered.append(chunk)
            }
            // prefix 返回共享索引的切片（removeFirst 后 startIndex ≠ 0），
            // 必须复制重定基——下游按 0 基下标访问。
            let result = Data(buffered.prefix(count))
            buffered.removeFirst(count)
            return result
        }

        func skip(_ count: Int64) {
            var remaining = count
            if !buffered.isEmpty {
                let take = min(Int64(buffered.count), remaining)
                buffered.removeFirst(Int(take))
                remaining -= take
            }
            fetchedEnd += remaining
        }
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
