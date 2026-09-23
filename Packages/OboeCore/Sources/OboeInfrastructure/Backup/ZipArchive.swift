import Foundation
import zlib

/// 最小 ZIP 读写器（设计 §11.2 依赖降级方案）。
///
/// 环境里无法解析 ZIPFoundation（离线且本地 SwiftPM 缓存没有副本），
/// 所以按方案允许的回退路径实现：只支持单卷、store/deflate、无 ZIP64。
/// 读出端自己做全部安全校验（路径穿越、符号链接、加密、大小、CRC），
/// 不依赖系统归档实现，行为在各 Apple 平台一致。
///
/// 压缩用系统 zlib 的 raw deflate（windowBits = -15），与 ZIP 规范一致。
enum ZipArchive {

    /// ZIP 条目压缩方式（只接受这两种，其余一律拒绝）。
    enum Method: UInt16, Sendable {
        case store = 0
        case deflate = 8
    }

    // MARK: - 常量

    private static let localHeaderSignature: UInt32 = 0x04034B50
    private static let centralDirectorySignature: UInt32 = 0x02014B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054B50
    private static let endOfCentralDirectoryMinimumSize = 22
    private static let centralDirectoryEntryFixedSize = 46
    private static let localHeaderFixedSize = 30
    /// 通用标志位：bit0 加密、bit11 UTF-8 文件名。
    private static let flagEncrypted: UInt16 = 0x0001
    private static let flagUTF8Names: UInt16 = 0x0800
    /// UNIX mode 文件类型位（external attributes 高 16 位）。
    private static let unixFileTypeMask: UInt32 = 0xF000
    private static let unixRegularFile: UInt32 = 0x8000

    // MARK: - 写入

    struct WriteEntry: Sendable {
        var name: String
        var data: Data
        var method: Method = .deflate
        /// DOS 位打包日期/时间；默认 1980-01-01 00:00:00 保持输出确定性。
        var dosDate: UInt16 = 0x21
        var dosTime: UInt16 = 0
        /// UNIX mode 放在高 16 位；普通文件默认 0o100644。
        var externalAttributes: UInt32 = UInt32(0o100644) << 16
    }

    /// 把 Date（按 UTC 解释）转成 DOS 日期/时间位段。越界年份钳到合法域。
    static func dosDateTime(from date: Date) -> (date: UInt16, time: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = min(max((components.year ?? 1980), 1980), 2107)
        let dosDate = UInt16(year - 1980) << 9
            | UInt16(components.month ?? 1) << 5
            | UInt16(components.day ?? 1)
        let dosTime = UInt16(components.hour ?? 0) << 11
            | UInt16(components.minute ?? 0) << 5
            | UInt16((components.second ?? 0) / 2)
        return (dosDate, dosTime)
    }

    /// 序列化整个归档到内存再一次性写盘——备份包体积有上限，
    /// 内存序列化保证写入是原子的（先写临时文件再 rename 由调用方负责）。
    static func archive(entries: [WriteEntry]) throws -> Data {
        guard entries.count <= 0xFFFF else {
            throw PortableBackupPackageError.tooManyEntries(
                actual: entries.count,
                limit: 0xFFFF
            )
        }
        var output = Data()
        var centralDirectory = Data()
        centralDirectory.reserveCapacity(entries.count * 64)

        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8),
                  nameData.count <= 0xFFFF else {
                throw PortableBackupPackageError.invalidEntryName(entry.name)
            }
            let payload: Data
            switch entry.method {
            case .store:
                payload = entry.data
            case .deflate:
                payload = try deflateRaw(entry.data)
            }
            guard payload.count <= Int(UInt32.max),
                  entry.data.count <= Int(UInt32.max) else {
                throw PortableBackupPackageError.entryTooLarge(
                    name: entry.name,
                    actual: Int64(entry.data.count),
                    limit: Int64(UInt32.max)
                )
            }
            let checksum = crc32(of: entry.data)
            let localOffset = output.count
            guard localOffset <= Int(UInt32.max) else {
                throw PortableBackupPackageError.malformedArchive("归档超过 4GiB 上限。")
            }

            // 本地文件头：sizes/CRC 直接写死，不用 data descriptor。
            output.appendLittleEndian(Self.localHeaderSignature)
            output.appendLittleEndian(UInt16(20))               // version needed
            output.appendLittleEndian(Self.flagUTF8Names)       // flags
            output.appendLittleEndian(entry.method.rawValue)
            output.appendLittleEndian(entry.dosTime)
            output.appendLittleEndian(entry.dosDate)
            output.appendLittleEndian(checksum)
            output.appendLittleEndian(UInt32(payload.count))
            output.appendLittleEndian(UInt32(entry.data.count))
            output.appendLittleEndian(UInt16(nameData.count))
            output.appendLittleEndian(UInt16(0))                // extra length
            output.append(nameData)
            output.append(payload)

            // 中央目录条目。
            centralDirectory.appendLittleEndian(Self.centralDirectorySignature)
            centralDirectory.appendLittleEndian(UInt16(20))     // version made by
            centralDirectory.appendLittleEndian(UInt16(20))     // version needed
            centralDirectory.appendLittleEndian(Self.flagUTF8Names)
            centralDirectory.appendLittleEndian(entry.method.rawValue)
            centralDirectory.appendLittleEndian(entry.dosTime)
            centralDirectory.appendLittleEndian(entry.dosDate)
            centralDirectory.appendLittleEndian(checksum)
            centralDirectory.appendLittleEndian(UInt32(payload.count))
            centralDirectory.appendLittleEndian(UInt32(entry.data.count))
            centralDirectory.appendLittleEndian(UInt16(nameData.count))
            centralDirectory.appendLittleEndian(UInt16(0))      // extra
            centralDirectory.appendLittleEndian(UInt16(0))      // comment
            centralDirectory.appendLittleEndian(UInt16(0))      // disk start
            centralDirectory.appendLittleEndian(UInt16(0))      // internal attrs
            centralDirectory.appendLittleEndian(entry.externalAttributes)
            centralDirectory.appendLittleEndian(UInt32(localOffset))
            centralDirectory.append(nameData)
        }

        let centralOffset = output.count
        guard centralOffset <= Int(UInt32.max),
              centralDirectory.count <= Int(UInt32.max) else {
            throw PortableBackupPackageError.malformedArchive("归档超过 4GiB 上限。")
        }
        output.append(centralDirectory)

        // EOCD。
        output.appendLittleEndian(Self.endOfCentralDirectorySignature)
        output.appendLittleEndian(UInt16(0))                    // disk number
        output.appendLittleEndian(UInt16(0))                    // cd start disk
        output.appendLittleEndian(UInt16(entries.count))        // entries on disk
        output.appendLittleEndian(UInt16(entries.count))        // total entries
        output.appendLittleEndian(UInt32(centralDirectory.count))
        output.appendLittleEndian(UInt32(centralOffset))
        output.appendLittleEndian(UInt16(0))                    // comment length
        return output
    }

    // MARK: - 读取

    /// 中央目录里解析出的条目元数据。解压内容前先拿它做全部限额/安全检查。
    struct ReadEntry: Sendable, Equatable {
        let name: String
        let method: Method
        let compressedSize: Int
        let uncompressedSize: Int
        let crc32: UInt32
        let localHeaderOffset: Int
        let flags: UInt16
        let externalAttributes: UInt32

        var isDirectory: Bool { name.hasSuffix("/") }

        /// UNIX mode 指示的非常规文件（符号链接、FIFO、设备、目录位……）。
        /// mode 全 0（非 UNIX 创建器）按普通文件处理。
        var isNonRegularFile: Bool {
            let type = (externalAttributes >> 16) & ZipArchive.unixFileTypeMask
            return type != 0 && type != ZipArchive.unixRegularFile
        }
    }

    struct Reader {
        let data: Data
        let entries: [ReadEntry]

        init(data: Data) throws {
            self.data = data
            entries = try Self.parseCentralDirectory(in: data)
        }

        /// 解压单个条目：边界、方式、解压后大小、CRC32 全部校验。
        func extract(_ entry: ReadEntry) throws -> Data {
            guard entry.localHeaderOffset >= 0,
                  entry.localHeaderOffset + ZipArchive.localHeaderFixedSize <= data.count else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的本地头越界。"
                )
            }
            let localEnd = entry.localHeaderOffset + ZipArchive.localHeaderFixedSize
            let local = data.subdata(in: entry.localHeaderOffset..<localEnd)
            guard local.littleEndianUInt32(at: 0) == ZipArchive.localHeaderSignature else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的本地头签名无效。"
                )
            }
            let localMethod = local.littleEndianUInt16(at: 8)
            guard localMethod == entry.method.rawValue else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的本地头与中央目录压缩方式不一致。"
                )
            }
            let localNameLength = Int(local.littleEndianUInt16(at: 26))
            let localExtraLength = Int(local.littleEndianUInt16(at: 28))
            let dataStart = entry.localHeaderOffset + ZipArchive.localHeaderFixedSize
                + localNameLength + localExtraLength
            guard dataStart >= 0, dataStart <= data.count,
                  entry.compressedSize >= 0,
                  dataStart + entry.compressedSize <= data.count else {
                throw PortableBackupPackageError.malformedArchive(
                    "\(entry.name) 的数据区越界。"
                )
            }
            let payload = data.subdata(in: dataStart..<(dataStart + entry.compressedSize))
            let content: Data
            switch entry.method {
            case .store:
                content = payload
            case .deflate:
                content = try inflateRaw(payload, uncompressedSize: entry.uncompressedSize)
            }
            guard content.count == entry.uncompressedSize else {
                throw PortableBackupPackageError.sizeMismatch(
                    name: entry.name,
                    expected: entry.uncompressedSize,
                    actual: content.count
                )
            }
            guard crc32(of: content) == entry.crc32 else {
                throw PortableBackupPackageError.crcMismatch(name: entry.name)
            }
            return content
        }

        /// 定位 EOCD（文件尾 64KiB+22 窗口内倒扫签名）并解析中央目录。
        /// 多卷、ZIP64、加密条目在这里就全部拒绝。
        private static func parseCentralDirectory(in data: Data) throws -> [ReadEntry] {
            guard data.count >= endOfCentralDirectoryMinimumSize else {
                throw PortableBackupPackageError.notAPackage
            }
            let windowStart = max(
                0,
                data.count - (endOfCentralDirectoryMinimumSize + 0xFFFF)
            )
            var eocdOffset: Int?
            var cursor = data.count - endOfCentralDirectoryMinimumSize
            while cursor >= windowStart {
                if data.littleEndianUInt32(at: cursor) == endOfCentralDirectorySignature {
                    eocdOffset = cursor
                    break
                }
                cursor -= 1
            }
            guard let eocd = eocdOffset else {
                throw PortableBackupPackageError.notAPackage
            }
            let commentLength = Int(data.littleEndianUInt16(at: eocd + 20))
            guard eocd + endOfCentralDirectoryMinimumSize + commentLength == data.count else {
                throw PortableBackupPackageError.malformedArchive("EOCD 不在文件末尾。")
            }
            let diskNumber = data.littleEndianUInt16(at: eocd + 4)
            let cdStartDisk = data.littleEndianUInt16(at: eocd + 6)
            let entriesOnDisk = data.littleEndianUInt16(at: eocd + 8)
            let totalEntries = data.littleEndianUInt16(at: eocd + 10)
            let cdSize = data.littleEndianUInt32(at: eocd + 12)
            let cdOffset = data.littleEndianUInt32(at: eocd + 16)
            guard diskNumber == 0, cdStartDisk == 0, entriesOnDisk == totalEntries else {
                throw PortableBackupPackageError.malformedArchive("不支持多卷 ZIP。")
            }
            // 0xFFFF/0xFFFFFFFF 哨兵值意味着 ZIP64——本实现不支持。
            guard totalEntries != 0xFFFF,
                  cdSize != 0xFFFFFFFF, cdOffset != 0xFFFFFFFF else {
                throw PortableBackupPackageError.malformedArchive("不支持 ZIP64。")
            }
            let cdRange = Int(cdOffset)..<(Int(cdOffset) + Int(cdSize))
            guard cdOffset <= Int32.max, cdSize <= Int32.max,
                  cdRange.upperBound <= eocd, cdRange.lowerBound >= 0 else {
                throw PortableBackupPackageError.malformedArchive("中央目录越界。")
            }

            var result: [ReadEntry] = []
            result.reserveCapacity(Int(totalEntries))
            var seenNames = Set<String>()
            var offset = Int(cdOffset)
            for _ in 0..<Int(totalEntries) {
                guard offset + centralDirectoryEntryFixedSize <= cdRange.upperBound else {
                    throw PortableBackupPackageError.malformedArchive("中央目录条目截断。")
                }
                guard data.littleEndianUInt32(at: offset) == centralDirectorySignature else {
                    throw PortableBackupPackageError.malformedArchive("中央目录签名无效。")
                }
                let flags = data.littleEndianUInt16(at: offset + 8)
                let methodRaw = data.littleEndianUInt16(at: offset + 10)
                let crc = data.littleEndianUInt32(at: offset + 16)
                let compressedSize = data.littleEndianUInt32(at: offset + 20)
                let uncompressedSize = data.littleEndianUInt32(at: offset + 24)
                let nameLength = Int(data.littleEndianUInt16(at: offset + 28))
                let extraLength = Int(data.littleEndianUInt16(at: offset + 30))
                let commentLength = Int(data.littleEndianUInt16(at: offset + 32))
                let diskStart = data.littleEndianUInt16(at: offset + 34)
                let externalAttributes = data.littleEndianUInt32(at: offset + 38)
                let localHeaderOffset = data.littleEndianUInt32(at: offset + 42)
                let entryEnd = offset + centralDirectoryEntryFixedSize
                    + nameLength + extraLength + commentLength
                guard entryEnd <= cdRange.upperBound,
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
                guard let method = Method(rawValue: methodRaw) else {
                    throw PortableBackupPackageError.unsupportedCompressionMethod(methodRaw)
                }
                let nameStart = offset + centralDirectoryEntryFixedSize
                let nameBytes = data.subdata(in: nameStart..<(nameStart + nameLength))
                guard let name = String(data: nameBytes, encoding: .utf8),
                      name.utf8.count == nameBytes.count else {
                    throw PortableBackupPackageError.invalidEntryName("<二进制文件名>")
                }
                guard seenNames.insert(name).inserted else {
                    throw PortableBackupPackageError.duplicateEntry(name)
                }
                result.append(ReadEntry(
                    name: name,
                    method: method,
                    compressedSize: Int(compressedSize),
                    uncompressedSize: Int(uncompressedSize),
                    crc32: crc,
                    localHeaderOffset: Int(localHeaderOffset),
                    flags: flags,
                    externalAttributes: externalAttributes
                ))
                offset = entryEnd
            }
            guard offset == cdRange.upperBound else {
                throw PortableBackupPackageError.malformedArchive("中央目录长度不符。")
            }
            return result
        }
    }

    // MARK: - zlib 桥接（raw deflate / inflate）

    static func crc32(of data: Data) -> UInt32 {
        var value = UInt32(zlib.crc32(0, nil, 0))
        if !data.isEmpty {
            value = data.withUnsafeBytes { buffer in
                UInt32(zlib.crc32(
                    uLong(value),
                    buffer.baseAddress?.assumingMemoryBound(to: Bytef.self),
                    uInt(buffer.count)
                ))
            }
        }
        return value
    }

    /// raw deflate（windowBits = -15）：ZIP 用的就是无 zlib 头的流。
    static func deflateRaw(_ data: Data) throws -> Data {
        // avail_in 是 uInt：>4GiB 的输入会被截断，提前拒绝而不是静默写错。
        guard data.count <= Int(UInt32.max) else {
            throw PortableBackupPackageError.entryTooLarge(
                name: "<内存>",
                actual: Int64(data.count),
                limit: Int64(UInt32.max)
            )
        }
        var stream = z_stream()
        guard deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw PortableBackupPackageError.malformedArchive("deflate 初始化失败。")
        }
        defer { deflateEnd(&stream) }
        let bound = Int(deflateBound(&stream, uLong(data.count)))
        var output = Data(count: max(bound, 64))
        var produced = 0
        var finished = false
        data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(
                    mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self)
                )
                stream.avail_in = uInt(input.count)
                stream.next_out = buffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(buffer.count)
                finished = deflate(&stream, Z_FINISH) == Z_STREAM_END
                produced = buffer.count - Int(stream.avail_out)
            }
        }
        guard finished else {
            throw PortableBackupPackageError.malformedArchive("deflate 未正常结束。")
        }
        output.count = produced
        return output
    }

    /// raw inflate：输出缓冲恰好等于申报的解压大小——声明值与真实数据
    /// 不符（爆炸或截断）都会在这里变成错误而不是越界写。
    static func inflateRaw(_ data: Data, uncompressedSize: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(
            &stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw PortableBackupPackageError.malformedArchive("inflate 初始化失败。")
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: uncompressedSize + 1)
        var produced = 0
        var streamEnded = false
        var failure: PortableBackupPackageError?
        data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(
                    mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self)
                )
                stream.avail_in = uInt(input.count)
                stream.next_out = buffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(buffer.count)
                while failure == nil {
                    switch inflate(&stream, Z_NO_FLUSH) {
                    case Z_STREAM_END:
                        streamEnded = true
                        produced = buffer.count - Int(stream.avail_out)
                        return
                    case Z_OK, Z_BUF_ERROR:
                        if stream.avail_in == 0 || stream.avail_out == 0 {
                            failure = .malformedArchive("deflate 流与声明大小不符。")
                            return
                        }
                    default:
                        failure = .malformedArchive("deflate 流损坏。")
                        return
                    }
                }
            }
        }
        if let failure { throw failure }
        guard streamEnded, produced == uncompressedSize else {
            throw PortableBackupPackageError.malformedArchive("deflate 流与声明大小不符。")
        }
        output.count = produced
        return output
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
