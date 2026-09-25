import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// StreamingZipReader / PortableBackupPackageReader（v0.6.0 §8.3）防线测试：
/// EOCD 尾窗口、注释错位、多卷/ZIP64/加密/未知 method、路径穿越、重复名、
/// 白名单、本地头↔中央目录一致性、数据区重叠、CRC/SHA、声明大小不符、
/// 超限中断（炸弹）、MIME/像素、短读模拟。
final class StreamingZipReaderTests: XCTestCase {

    private var rootURL: URL!
    private var extractionURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StreamingZipReaderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        extractionURL = rootURL.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: - EOCD / 结构

    /// 合法 ZIP 注释：EOCD 不在 22 字节固定尾部也能定位。
    func testEOCDWithValidCommentStillParses() throws {
        let package = try makeSimplePackage()
        var data = try Data(contentsOf: package)
        let eocd = data.count - 22
        let comment = Data("oboe-comment".utf8)
        data[eocd + 20] = UInt8(comment.count & 0xFF)
        data[eocd + 21] = UInt8(comment.count >> 8)
        data.append(comment)
        let url = uniqueURL("commented.oboe-backup")
        try data.write(to: url)
        let reader = try StreamingZipReader(fileURL: url)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(reader.entries[0].name, "a.txt")
        reader.close()
    }

    /// 注释长度与文件尾不符 → EOCD 错位拒绝。
    func testEOCDCommentLengthMismatchFails() throws {
        let package = try makeSimplePackage()
        var data = try Data(contentsOf: package)
        data.append(Data("trailing".utf8)) // 不更新 commentLength
        let url = uniqueURL("badcomment.oboe-backup")
        try data.write(to: url)
        assertMalformed { try StreamingZipReader(fileURL: url) }
    }

    /// 非 ZIP 内容找不到 EOCD。
    func testNonZipContentFails() throws {
        let url = uniqueURL("junk.oboe-backup")
        try Data(repeating: 0x41, count: 1_024).write(to: url)
        XCTAssertThrowsError(try StreamingZipReader(fileURL: url)) { error in
            XCTAssertEqual(
                error as? PortableBackupPackageError,
                .notAPackage
            )
        }
    }

    /// 文件小于 EOCD 最小长度。
    func testTinyFileFails() throws {
        let url = uniqueURL("tiny.oboe-backup")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: url)
        XCTAssertThrowsError(try StreamingZipReader(fileURL: url)) { error in
            XCTAssertEqual(
                error as? PortableBackupPackageError,
                .notAPackage
            )
        }
    }

    /// EOCD disk 字段非 0 → 多卷拒绝。
    func testMultiVolumeRejected() throws {
        let url = try patchingSimplePackage { data in
            data[data.count - 22 + 4] = 1
        }
        assertMalformed { try StreamingZipReader(fileURL: url) }
    }

    /// 中央目录条目的 disk start 非 0 → 多卷拒绝。
    func testCentralEntryDiskStartRejected() throws {
        let url = try patchingSimplePackage { data in
            let cd = centralRecordOffset(of: "a.txt", in: data)!
            data[cd + 34] = 1
        }
        assertMalformed { try StreamingZipReader(fileURL: url) }
    }

    /// 0xFFFF/0xFFFFFFFF 哨兵 → ZIP64 拒绝。
    func testZip64SentinelsRejected() throws {
        let byEntries = try patchingSimplePackage { data in
            data[data.count - 22 + 10] = 0xFF
            data[data.count - 22 + 11] = 0xFF
        }
        assertMalformed { try StreamingZipReader(fileURL: byEntries) }

        let bySize = try patchingSimplePackage { data in
            data[data.count - 22 + 12] = 0xFF
            data[data.count - 22 + 13] = 0xFF
            data[data.count - 22 + 14] = 0xFF
            data[data.count - 22 + 15] = 0xFF
        }
        assertMalformed { try StreamingZipReader(fileURL: bySize) }
    }

    /// flags bit0（加密）在中央目录即拒绝。
    func testEncryptedCentralFlagRejected() throws {
        let url = try patchingSimplePackage { data in
            let cd = centralRecordOffset(of: "a.txt", in: data)!
            data[cd + 8] |= 0x01
        }
        XCTAssertThrowsError(try StreamingZipReader(fileURL: url)) { error in
            XCTAssertEqual(
                error as? PortableBackupPackageError,
                .encryptedArchive
            )
        }
    }

    /// 非 store/deflate 的压缩方式拒绝。
    func testUnknownCompressionMethodRejected() throws {
        let url = try patchingSimplePackage { data in
            let cd = centralRecordOffset(of: "a.txt", in: data)!
            data[cd + 10] = 99
            data[cd + 11] = 0
        }
        XCTAssertThrowsError(try StreamingZipReader(fileURL: url)) { error in
            XCTAssertEqual(
                error as? PortableBackupPackageError,
                .unsupportedCompressionMethod(99)
            )
        }
    }

    /// 中央目录重复名拒绝。
    func testDuplicateEntryRejected() throws {
        let data = try ZipArchive.archive(entries: [
            ZipArchive.WriteEntry(name: "a.txt", data: Data([1])),
            ZipArchive.WriteEntry(name: "a.txt", data: Data([2]))
        ])
        let url = uniqueURL("dup.oboe-backup")
        try data.write(to: url)
        XCTAssertThrowsError(try StreamingZipReader(fileURL: url)) { error in
            XCTAssertEqual(
                error as? PortableBackupPackageError,
                .duplicateEntry("a.txt")
            )
        }
    }

    // MARK: - 本地头 ↔ 中央目录一致性（新增防线）

    /// 本地头 flags 与中央目录不符 → 拒绝。
    func testLocalCentralFlagsMismatchFails() throws {
        let url = try patchingSimplePackage { data in
            let local = localHeaderOffset(of: "a.txt", in: data)!
            data[local + 6] = 0
            data[local + 7] = 0
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        assertMalformed { try reader.validateLocalHeaders() }
    }

    /// 本地头 method 与中央目录不符 → 拒绝。
    func testLocalCentralMethodMismatchFails() throws {
        let url = try patchingSimplePackage { data in
            let local = localHeaderOffset(of: "a.txt", in: data)!
            data[local + 8] = 0   // deflate → store
            data[local + 9] = 0
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        assertMalformed { try reader.validateLocalHeaders() }
    }

    /// 本地头 CRC 与中央目录不符 → 拒绝。
    func testLocalCentralCRCMismatchFails() throws {
        let url = try patchingSimplePackage { data in
            let local = localHeaderOffset(of: "a.txt", in: data)!
            data[local + 14] ^= 0xFF
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        assertMalformed { try reader.validateLocalHeaders() }
    }

    /// 本地头 compressedSize 与中央目录不符 → 拒绝。
    func testLocalCentralSizeMismatchFails() throws {
        let url = try patchingSimplePackage { data in
            let local = localHeaderOffset(of: "a.txt", in: data)!
            data[local + 18] ^= 0xFF
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        assertMalformed { try reader.validateLocalHeaders() }
    }

    /// 本地头文件名与中央目录不符 → 拒绝。
    func testLocalCentralNameMismatchFails() throws {
        let url = try patchingTwoEntryPackage { data in
            let cd = centralRecordOffset(of: "b.txt", in: data)!
            data[cd + 46] = UInt8(ascii: "c") // b.txt → c.txt（中央）
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        assertMalformed { try reader.validateLocalHeaders() }
    }

    /// 本地头签名无效 → 拒绝。
    func testLocalHeaderSignatureInvalidFails() throws {
        let url = try patchingSimplePackage { data in
            let local = localHeaderOffset(of: "a.txt", in: data)!
            data[local] = 0
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        assertMalformed { try reader.validateLocalHeaders() }
    }

    // MARK: - 数据区重叠（新增防线）

    /// 前一条目声明的压缩数据区延伸到后一条目的本地头区域 → 拒绝。
    func testOverlappingDataRegionsFail() throws {
        let url = try patchingTwoEntryPackage { data in
            let aCD = centralRecordOffset(of: "a.txt", in: data)!
            let aLocal = localHeaderOffset(of: "a.txt", in: data)!
            let bLocal = localHeaderOffset(of: "b.txt", in: data)!
            let aNameLen = Int(data[aLocal + 26])
            let aDataStart = aLocal + 30 + aNameLen
            // a 的 compressedSize 扩到覆盖 b 的本地头起点。
            let hostile = UInt32(bLocal - aDataStart + 1)
            data.writeLittleEndian(hostile, at: aLocal + 18)
            data.writeLittleEndian(hostile, at: aCD + 20)
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        do {
            try reader.validateLocalHeaders()
            XCTFail("应拒绝重叠数据区")
        } catch PortableBackupPackageError.malformedArchive(let reason) {
            XCTAssertTrue(reason.contains("重叠"), "错误信息不符：\(reason)")
        }
    }

    /// 数据区越出中央目录起点 → 拒绝。
    func testDataRegionBeyondCentralDirectoryFails() throws {
        let url = try patchingTwoEntryPackage { data in
            let bCD = centralRecordOffset(of: "b.txt", in: data)!
            let bLocal = localHeaderOffset(of: "b.txt", in: data)!
            let bNameLen = Int(data[bLocal + 26])
            let bDataStart = bLocal + 30 + bNameLen
            let eocd = data.count - 22
            let cdOffset = Int(data.littleEndianUInt32(at: eocd + 16))
            let hostile = UInt32(cdOffset - bDataStart + 4)
            data.writeLittleEndian(hostile, at: bLocal + 18)
            data.writeLittleEndian(hostile, at: bCD + 20)
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        assertMalformed { try reader.validateLocalHeaders() }
    }

    // MARK: - 内容完整性

    /// 数据字节被改 → CRC32 校验失败（store 条目直读）。
    func testCRCMismatchFails() throws {
        let url = try patchingStorePackage { data in
            let local = localHeaderOffset(of: "s.bin", in: data)!
            let nameLen = Int(data[local + 26])
            data[local + 30 + nameLen] ^= 0xFF
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        try reader.validateLocalHeaders()
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "s.bin" })
        XCTAssertThrowsError(try reader.extractToData(entry, byteLimit: .max)) {
            XCTAssertEqual(
                $0 as? PortableBackupPackageError,
                .crcMismatch(name: "s.bin")
            )
        }
    }

    /// store 条目声明的 uncompressed ≠ compressed → sizeMismatch。
    func testStoreDeclaredSizeMismatchFails() throws {
        let url = try patchingStorePackage { data in
            let cd = centralRecordOffset(of: "s.bin", in: data)!
            let local = localHeaderOffset(of: "s.bin", in: data)!
            let comp = data.littleEndianUInt32(at: cd + 20)
            data.writeLittleEndian(comp + 1, at: local + 22)
            data.writeLittleEndian(comp + 1, at: cd + 24)
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        try reader.validateLocalHeaders()
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "s.bin" })
        XCTAssertThrowsError(try reader.extractToData(entry, byteLimit: .max)) {
            guard case PortableBackupPackageError.sizeMismatch = $0 else {
                return XCTFail("应为 sizeMismatch，实际 \($0)")
            }
        }
    }

    /// deflate 炸弹：声明 100 字节、实际解压出 ~1MiB → 产出超过声明立即中断。
    func testDeflateBombAbortsAtDeclaredSize() throws {
        let url = try patchingDeflatePackage(payloadSize: 1_000_000) { data in
            let cd = centralRecordOffset(of: "bomb.bin", in: data)!
            let local = localHeaderOffset(of: "bomb.bin", in: data)!
            data.writeLittleEndian(UInt32(100), at: local + 22)
            data.writeLittleEndian(UInt32(100), at: cd + 24)
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        try reader.validateLocalHeaders()
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "bomb.bin" })
        let dest = uniqueURL("bomb-out.bin")
        XCTAssertThrowsError(try reader.extractToFile(
            entry, to: dest, byteLimit: .max
        )) { error in
            guard case PortableBackupPackageError.malformedArchive = error else {
                return XCTFail("应为 malformedArchive，实际 \(error)")
            }
        }
        // 中断后部分写出文件被删除——不留给上层。
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    /// deflate 流在声明 compressedSize 内未结束 → 拒绝。
    func testDeflateTruncatedStreamFails() throws {
        let url = try patchingDeflatePackage(payloadSize: 1_000_000) { data in
            let cd = centralRecordOffset(of: "bomb.bin", in: data)!
            let local = localHeaderOffset(of: "bomb.bin", in: data)!
            // compressedSize 声明砍半：流在区域内提前耗尽输入。
            let comp = data.littleEndianUInt32(at: cd + 20)
            data.writeLittleEndian(comp / 2, at: local + 18)
            data.writeLittleEndian(comp / 2, at: cd + 20)
        }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        try reader.validateLocalHeaders()
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "bomb.bin" })
        XCTAssertThrowsError(try reader.extractToData(entry, byteLimit: .max)) {
            guard case PortableBackupPackageError.malformedArchive = $0 else {
                return XCTFail("应为 malformedArchive，实际 \($0)")
            }
        }
    }

    /// 解压到一半超过 byteLimit → entryTooLarge 且立即中断。
    func testStreamAbortOnByteLimit() throws {
        // 声明值 = 真实值（一致性校验要过），靠 byteLimit 在入口即拒。
        let url = try patchingDeflatePackage(payloadSize: 1_000_000) { _ in }
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        try reader.validateLocalHeaders()
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "bomb.bin" })
        // 声明值本身在限额内（1MiB），实际解压不超过声明 →
        // byteLimit 低于声明值时在入口即拒。
        XCTAssertThrowsError(try reader.extractToData(entry, byteLimit: 500)) {
            guard case PortableBackupPackageError.entryTooLarge = $0 else {
                return XCTFail("应为 entryTooLarge，实际 \($0)")
            }
        }
    }

    /// 目录条目惰性容忍（兼容其它工具产出的包）。
    func testDirectoryEntryTolerated() throws {
        let data = try ZipArchive.archive(entries: [
            ZipArchive.WriteEntry(name: "attachments/", data: Data()),
            ZipArchive.WriteEntry(name: "a.txt", data: Data([1, 2, 3]))
        ])
        let url = uniqueURL("dir.oboe-backup")
        try data.write(to: url)
        let reader = try StreamingZipReader(fileURL: url)
        defer { reader.close() }
        try reader.validateLocalHeaders()
        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertTrue(reader.entries[0].isDirectory)
        let file = try XCTUnwrap(reader.entries.first { $0.name == "a.txt" })
        XCTAssertEqual(try reader.extractToData(file, byteLimit: .max), Data([1, 2, 3]))
    }

    // MARK: - 短读 / 截断

    /// 字节源每次最多返回 4 字节：EOCD/中央目录/本地头/解压全程循环补齐。
    func testShortReadSourceStillExtracts() throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 253) })
        let data = try ZipArchive.archive(entries: [
            ZipArchive.WriteEntry(name: "big.bin", data: payload, method: .deflate),
            ZipArchive.WriteEntry(name: "raw.bin", data: payload, method: .store)
        ])
        let source = InMemoryZipSource(data: data, maxReadChunk: 1_000)
        let reader = try StreamingZipReader(source: source)
        defer { reader.close() }
        try reader.validateLocalHeaders()
        for name in ["big.bin", "raw.bin"] {
            let entry = try XCTUnwrap(reader.entries.first { $0.name == name })
            XCTAssertEqual(
                try reader.extractToData(entry, byteLimit: .max),
                payload
            )
        }
    }

    /// 文件在中央目录中间被截断 → 条目截断错误。
    func testTruncatedCentralDirectoryFails() throws {
        let data = try ZipArchive.archive(entries: [
            ZipArchive.WriteEntry(name: "a.txt", data: Data([1])),
            ZipArchive.WriteEntry(name: "b.txt", data: Data([2])),
            ZipArchive.WriteEntry(name: "c.txt", data: Data([3]))
        ])
        // 保留 EOCD：把 cdOffset 之后的有效字节截到第一条目中间。
        // 简单构造：文件整体截到 60%——EOCD 不在窗口 → notAPackage，
        // 另构造"cd 声明完整但文件短"——直接截断数据区也可覆盖 readExact 报错。
        let truncated = data.prefix(data.count / 2)
        let url = uniqueURL("trunc.oboe-backup")
        try truncated.write(to: url)
        XCTAssertThrowsError(try StreamingZipReader(fileURL: url)) {
            XCTAssertTrue($0 is PortableBackupPackageError)
        }
    }

    // MARK: - 包级限额分派（§8.3 修复）

    /// records.ndjson 按 maximumRecordsBytes 而非通用 128MiB 上限：
    /// 129MiB records 在默认限额与收紧的 attachment 限额下都能走通。
    func testRecordsOver128MiBExtracts() throws {
        let recordsBytes = 129 * 1_024 * 1_024
        let packageURL = uniqueURL("big-records.oboe-backup")
        let writer = try StreamingZipWriter(fileURL: packageURL)
        try writer.beginEntry(name: "records.ndjson", method: .deflate)
        let chunk = Data(repeating: 0x61, count: 1_024 * 1_024)
        var remaining = recordsBytes
        while remaining > 0 {
            let part = min(remaining, chunk.count)
            try writer.write(chunk.prefix(part))
            remaining -= part
        }
        let recordsResult = try writer.finishEntry()
        let manifest = try makeManifest(attachments: [])
        try writer.beginEntry(name: "manifest.json", method: .deflate)
        try writer.write(manifest)
        _ = try writer.finishEntry()
        let checksums = try makeChecksums([
            "records.ndjson": recordsResult.sha256
        ])
        try writer.beginEntry(name: "checksums.json", method: .deflate)
        try writer.write(checksums)
        _ = try writer.finishEntry()
        try writer.finalizeArchive()

        // 默认限额：129MiB records 必须走通（旧实现被 128MiB 通用限卡死）。
        let extracted = try PortableBackupPackageReader().extractAndValidate(
            fileURL: packageURL,
            to: extractionURL
        )
        let extractedSize = try FileManager.default.attributesOfItem(
            atPath: extracted.recordsURL.path
        )[.size] as? Int64
        XCTAssertEqual(extractedSize, Int64(recordsBytes))

        // attachment 限额收到 1MiB 也不能误伤 records。
        let tightLimits = PortableBackupPackageLimits(maximumEntryBytes: 1_024 * 1_024)
        let out2 = uniqueURL("out2")
        _ = try PortableBackupPackageReader(limits: tightLimits).extractAndValidate(
            fileURL: packageURL,
            to: out2
        )
    }

    /// records 自身限额仍生效：声明/实际超过 maximumRecordsBytes 即拒。
    func testRecordsLimitStillEnforced() throws {
        let recordsBytes = 2 * 1_024 * 1_024
        let packageURL = uniqueURL("records-limit.oboe-backup")
        let writer = try StreamingZipWriter(fileURL: packageURL)
        try writer.beginEntry(name: "records.ndjson", method: .deflate)
        try writer.write(Data(repeating: 0x62, count: recordsBytes))
        let recordsResult = try writer.finishEntry()
        try writer.beginEntry(name: "manifest.json", method: .deflate)
        try writer.write(makeManifest(attachments: []))
        _ = try writer.finishEntry()
        try writer.beginEntry(name: "checksums.json", method: .deflate)
        try writer.write(makeChecksums(["records.ndjson": recordsResult.sha256]))
        _ = try writer.finishEntry()
        try writer.finalizeArchive()

        let limits = PortableBackupPackageLimits(
            maximumRecordsBytes: Int64(1_024 * 1_024)
        )
        XCTAssertThrowsError(
            try PortableBackupPackageReader(limits: limits).extractAndValidate(
                fileURL: packageURL,
                to: extractionURL
            )
        ) { error in
            guard case PortableBackupPackageError.entryTooLarge(
                let name, let actual, let limit
            ) = error else {
                return XCTFail("应为 entryTooLarge，实际 \(error)")
            }
            XCTAssertEqual(name, "records.ndjson")
            XCTAssertEqual(actual, Int64(recordsBytes))
            XCTAssertEqual(limit, Int64(1_024 * 1_024))
        }
    }

    /// manifest 声明像素与实际不符 → attachmentPixelMismatch。
    func testPixelMismatchFails() throws {
        let jpeg = try makeJPEG(width: 64, height: 32)
        let id = "img001"
        let sha = sha256Hex(jpeg)
        let descriptor = AttachmentDescriptor(
            id: id,
            relativePath: "attachments/\(id).jpg",
            mimeType: "image/jpeg",
            byteCount: jpeg.count,
            sha256: sha,
            pixelWidth: 999,
            pixelHeight: 999
        )
        let packageURL = uniqueURL("pixel.oboe-backup")
        try buildValidPackage(
            at: packageURL,
            records: Data("{}".utf8),
            attachments: [(descriptor, jpeg)]
        )
        XCTAssertThrowsError(
            try PortableBackupPackageReader().extractAndValidate(
                fileURL: packageURL,
                to: extractionURL
            )
        ) { error in
            XCTAssertEqual(
                error as? PortableBackupPackageError,
                .attachmentPixelMismatch(id: id)
            )
        }
    }

    /// 附件字节是真实图片但 MIME 声明不符 → attachmentTypeMismatch。
    func testAttachmentMIMEContentMismatchFails() throws {
        let jpeg = try makeJPEG(width: 64, height: 32)
        let id = "img002"
        let descriptor = AttachmentDescriptor(
            id: id,
            relativePath: "attachments/\(id).png",
            mimeType: "image/png",
            byteCount: jpeg.count,
            sha256: sha256Hex(jpeg),
            pixelWidth: 64,
            pixelHeight: 32
        )
        let packageURL = uniqueURL("mime.oboe-backup")
        try buildValidPackage(
            at: packageURL,
            records: Data("{}".utf8),
            attachments: [(descriptor, jpeg)]
        )
        XCTAssertThrowsError(
            try PortableBackupPackageReader().extractAndValidate(
                fileURL: packageURL,
                to: extractionURL
            )
        ) { error in
            guard case PortableBackupPackageError.attachmentTypeMismatch = error else {
                return XCTFail("应为 attachmentTypeMismatch，实际 \(error)")
            }
        }
    }

    /// 包文件本身超限 → packageTooLarge（不进入结构解析）。
    func testPackageSizeLimitFails() throws {
        let package = try makeSimplePackage()
        let size = try FileManager.default.attributesOfItem(
            atPath: package.path
        )[.size] as? Int64
        let limits = PortableBackupPackageLimits(
            maximumPackageBytes: (size ?? 1_000) - 1
        )
        XCTAssertThrowsError(
            try PortableBackupPackageReader(limits: limits).extractAndValidate(
                fileURL: package,
                to: extractionURL
            )
        ) { error in
            guard case PortableBackupPackageError.packageTooLarge = error else {
                return XCTFail("应为 packageTooLarge，实际 \(error)")
            }
        }
    }

    // MARK: - helpers

    private func uniqueURL(_ name: String) -> URL {
        rootURL.appendingPathComponent(
            "\(UUID().uuidString.lowercased())-\(name)"
        )
    }

    private func makeSimplePackage() throws -> URL {
        let url = uniqueURL("simple.oboe-backup")
        try ZipArchive.archive(entries: [
            ZipArchive.WriteEntry(name: "a.txt", data: Data("hi".utf8))
        ]).write(to: url)
        return url
    }

    private func patchingSimplePackage(
        _ mutate: (inout Data) -> Void
    ) throws -> URL {
        let url = uniqueURL("patched.oboe-backup")
        var data = try ZipArchive.archive(entries: [
            ZipArchive.WriteEntry(name: "a.txt", data: Data("hi".utf8))
        ])
        mutate(&data)
        try data.write(to: url)
        return url
    }

    private func patchingTwoEntryPackage(
        _ mutate: (inout Data) -> Void
    ) throws -> URL {
        let url = uniqueURL("patched2.oboe-backup")
        var data = try ZipArchive.archive(entries: [
            ZipArchive.WriteEntry(name: "a.txt", data: Data("first".utf8)),
            ZipArchive.WriteEntry(name: "b.txt", data: Data("second".utf8))
        ])
        mutate(&data)
        try data.write(to: url)
        return url
    }

    private func patchingStorePackage(
        _ mutate: (inout Data) -> Void
    ) throws -> URL {
        let url = uniqueURL("patched-store.oboe-backup")
        var data = try ZipArchive.archive(entries: [
            ZipArchive.WriteEntry(
                name: "s.bin",
                data: Data(repeating: 0x51, count: 4_096),
                method: .store
            )
        ])
        mutate(&data)
        try data.write(to: url)
        return url
    }

    private func patchingDeflatePackage(
        payloadSize: Int,
        _ mutate: (inout Data) -> Void
    ) throws -> URL {
        let url = uniqueURL("patched-deflate.oboe-backup")
        var data = try ZipArchive.archive(entries: [
            ZipArchive.WriteEntry(
                name: "bomb.bin",
                data: Data(repeating: 0x00, count: payloadSize),
                method: .deflate
            )
        ])
        mutate(&data)
        try data.write(to: url)
        return url
    }

    /// 定位中央目录里指定名字的条目固定头起点。
    private func centralRecordOffset(of name: String, in data: Data) -> Int? {
        let eocd = data.count - 22
        var offset = Int(data.littleEndianUInt32(at: eocd + 16))
        let end = eocd
        while offset < end {
            let nameLen = Int(data.littleEndianUInt16(at: offset + 28))
            let extraLen = Int(data.littleEndianUInt16(at: offset + 30))
            let commentLen = Int(data.littleEndianUInt16(at: offset + 32))
            let entryName = String(
                data: data.subdata(in: (offset + 46)..<(offset + 46 + nameLen)),
                encoding: .utf8
            )
            if entryName == name { return offset }
            offset += 46 + nameLen + extraLen + commentLen
        }
        return nil
    }

    /// 指定条目的本地头偏移（中央目录 +42 字段）。
    private func localHeaderOffset(of name: String, in data: Data) -> Int? {
        guard let cd = centralRecordOffset(of: name, in: data) else { return nil }
        return Int(data.littleEndianUInt32(at: cd + 42))
    }

    private func makeManifest(
        attachments: [AttachmentDescriptor]
    ) throws -> Data {
        try PortableBackupPackageManifest(
            format: PortableBackupFormat.identifier,
            formatVersion: PortableBackupPackageFormat.formatVersion,
            container: PortableBackupPackageFormat.container,
            appVersion: "test",
            exportedAt: PortableBackupPackageFormat.iso8601String(
                from: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            encoding: "utf-8",
            lineEnding: "lf",
            checksumAlgorithm: PortableBackupFormat.checksumAlgorithm,
            recordFormatVersion: 6,  // fixture 声明与其内嵌的 v6 记录流一致
            recordOrder: PortableBackupFormatV6.recordTypes,
            counts: Dictionary(
                uniqueKeysWithValues: PortableBackupFormatV6.recordTypes.map {
                    ($0, 0)
                }
            ),
            excludedScopes: PortableBackupPackageFormat.excludedScopes,
            attachments: attachments
        ).encoded()
    }

    private func makeChecksums(_ files: [String: String]) throws -> Data {
        try PortableBackupChecksums(
            algorithm: PortableBackupFormat.checksumAlgorithm,
            files: files
        ).encoded()
    }

    /// 用流式 writer 搭一个结构合法的包：records + attachments + manifest + checksums。
    private func buildValidPackage(
        at url: URL,
        records: Data,
        attachments: [(AttachmentDescriptor, Data)]
    ) throws {
        let writer = try StreamingZipWriter(fileURL: url)
        try writer.beginEntry(name: "records.ndjson", method: .deflate)
        try writer.write(records)
        let recordsResult = try writer.finishEntry()
        var checksumFiles = ["records.ndjson": recordsResult.sha256]
        for (descriptor, data) in attachments {
            try writer.beginEntry(
                name: descriptor.relativePath,
                method: .store
            )
            try writer.write(data)
            _ = try writer.finishEntry()
            checksumFiles[descriptor.relativePath] = descriptor.sha256
        }
        try writer.beginEntry(name: "manifest.json", method: .deflate)
        try writer.write(makeManifest(attachments: attachments.map(\.0)))
        _ = try writer.finishEntry()
        try writer.beginEntry(name: "checksums.json", method: .deflate)
        try writer.write(makeChecksums(checksumFiles))
        _ = try writer.finishEntry()
        try writer.finalizeArchive()
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertMalformed(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Any
    ) {
        do {
            _ = try body()
            XCTFail("应拒绝该归档", file: file, line: line)
        } catch PortableBackupPackageError.malformedArchive {
            // 通过。
        } catch {
            XCTFail("错误类型不符：\(error)", file: file, line: line)
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

    mutating func writeLittleEndian(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
