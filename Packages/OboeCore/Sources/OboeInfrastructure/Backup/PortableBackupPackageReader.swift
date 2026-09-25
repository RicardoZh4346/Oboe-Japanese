import CryptoKit
import Foundation
import OboeDomain

/// v7 包解压校验后的落地结果。目录布局：
///
///     <directory>/
///         manifest.json
///         records.ndjson
///         checksums.json
///         attachments/<id>.<ext>   ← 与附件存储根目录同构，可直接用于 swap
///
/// 校验不通过时 extractAndValidate 抛错，目录残留由调用方清理——
/// 校验失败的产物对上层不可见。
public struct ExtractedBackupPackage: Equatable, Sendable {
    public let directoryURL: URL
    public let manifestURL: URL
    public let recordsURL: URL
    public let checksumsURL: URL
    /// 附件落地目录：内容直接就是新的附件根（平铺 `<id>.<ext>`）。
    public let attachmentsDirectoryURL: URL
    public let manifest: PortableBackupPackageManifest
    public let exportedAt: Date
    public let attachmentDescriptors: [AttachmentDescriptor]

    public init(
        directoryURL: URL,
        manifestURL: URL,
        recordsURL: URL,
        checksumsURL: URL,
        attachmentsDirectoryURL: URL,
        manifest: PortableBackupPackageManifest,
        exportedAt: Date,
        attachmentDescriptors: [AttachmentDescriptor]
    ) {
        self.directoryURL = directoryURL
        self.manifestURL = manifestURL
        self.recordsURL = recordsURL
        self.checksumsURL = checksumsURL
        self.attachmentsDirectoryURL = attachmentsDirectoryURL
        self.manifest = manifest
        self.exportedAt = exportedAt
        self.attachmentDescriptors = attachmentDescriptors
    }
}

/// 便携备份 v7 包的读取与校验器（设计 §11.2/§11.3 的 Prepare 阶段；
/// v0.6.0 §8.3 流式化：不再 `Data(contentsOf:)` 读全包）。
///
/// 信任顺序：ZIP magic → 文件尾窗口定位 EOCD → 受限中央目录
/// （限额/路径/加密/符号链接/ZIP64/多卷）→ 本地头一致性 + 数据区重叠 →
/// manifest（格式契约 + descriptor 字段级校验）→ 白名单 → checksums →
/// 逐条目流式解压到 staging 文件（边解压边累计字节、SHA-256、CRC32，
/// 超限立即中断）→ MIME 魔数（ImageIO UTI，文件 URL 后端不解码整像素）、
/// 像素尺寸。任何一步失败立即抛错。
public struct PortableBackupPackageReader: Sendable {
    public let limits: PortableBackupPackageLimits

    public init(limits: PortableBackupPackageLimits = PortableBackupPackageLimits()) {
        self.limits = limits
    }

    /// ZIP magic 探测——识别容器只看内容，不看扩展名。
    /// 本地文件头 PK\x03\x04 或空归档 EOCD PK\x05\x06 都算 ZIP。
    public static func isPackage(fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else {
            return false
        }
        return head == Data([0x50, 0x4B, 0x03, 0x04])
            || head == Data([0x50, 0x4B, 0x05, 0x06])
    }

    /// 只解 manifest.json——供恢复预览在不解压附件的情况下读取摘要。
    public func readManifest(fileURL: URL) throws -> PortableBackupPackageManifest {
        let indexed = try loadAndIndexArchive(fileURL: fileURL)
        defer { indexed.close() }
        return indexed.manifest
    }

    /// 解压 + 全量校验到 destinationURL。目录不存在则创建。
    /// 校验顺序保证：结构 → manifest → checksums → 逐条附件。
    @discardableResult
    public func extractAndValidate(
        fileURL: URL,
        to destinationURL: URL
    ) throws -> ExtractedBackupPackage {
        let indexed = try loadAndIndexArchive(fileURL: fileURL)
        defer { indexed.close() }
        let manifest = indexed.manifest
        let exportedAt = try Self.manifestExportedAt(manifest)
        let descriptors = manifest.attachments

        let fileManager = FileManager.default
        let attachmentsURL = destinationURL.appendingPathComponent(
            PortableBackupPackageFormat.attachmentsDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: attachmentsURL,
            withIntermediateDirectories: true
        )

        // checksums.json：键集合必须恰好是 records.ndjson + 每个声明附件。
        let checksums = try extractChecksums(from: indexed)
        let expectedFiles = Set(descriptors.map(\.relativePath))
            .union([PortableBackupPackageFormat.recordsEntryName])
        guard Set(checksums.files.keys) == expectedFiles else {
            throw PortableBackupPackageError.invalidChecksums(
                "files 清单与实际包内容不一致。"
            )
        }
        for (name, digest) in checksums.files {
            guard PortableBackupPackageFormat.isLowercaseSHA256Hex(digest) else {
                throw PortableBackupPackageError.invalidChecksums(
                    "\(name) 的摘要不是小写十六进制。"
                )
            }
        }

        // records.ndjson：流式解压落盘（≤200 MiB，边解压边算 SHA-256）→
        // 与 checksums 比对。记录级校验交给现有 NDJSON 导入管线。
        let recordsURL = destinationURL.appendingPathComponent(
            PortableBackupPackageFormat.recordsEntryName
        )
        let recordsResult = try indexed.extractToFile(
            named: PortableBackupPackageFormat.recordsEntryName,
            to: recordsURL,
            byteLimit: limits.maximumRecordsBytes
        )
        guard recordsResult.sha256
                == checksums.files[PortableBackupPackageFormat.recordsEntryName] else {
            throw PortableBackupPackageError.checksumMismatch(
                file: PortableBackupPackageFormat.recordsEntryName
            )
        }

        // 附件：manifest 声明的每个 descriptor 都必须有对应条目，
        // 字节数/SHA-256/MIME 魔数/像素全部一致才算通过。
        for descriptor in descriptors {
            let fileName = String(descriptor.relativePath.dropFirst(
                PortableBackupPackageFormat.attachmentsDirectoryName.count + 1
            ))
            let destination = attachmentsURL.appendingPathComponent(fileName)
            let result = try indexed.extractToFile(
                named: descriptor.relativePath,
                to: destination,
                byteLimit: limits.maximumEntryBytes
            )
            guard result.byteCount == Int64(descriptor.byteCount) else {
                throw PortableBackupPackageError.attachmentSizeMismatch(
                    id: descriptor.id,
                    expected: Int64(descriptor.byteCount),
                    actual: result.byteCount
                )
            }
            guard result.sha256 == descriptor.sha256,
                  result.sha256 == checksums.files[descriptor.relativePath] else {
                throw PortableBackupPackageError.attachmentChecksumMismatch(
                    id: descriptor.id
                )
            }
            // 文件 URL 嗅探：CGImageSource 文件后端只读 metadata，不解码整像素。
            guard let inspection = AttachmentContentSniffer.inspect(
                fileURL: destination
            ) else {
                throw PortableBackupPackageError.attachmentTypeMismatch(
                    id: descriptor.id,
                    declared: descriptor.mimeType,
                    actual: "无法识别"
                )
            }
            guard inspection.mimeType == descriptor.mimeType else {
                throw PortableBackupPackageError.attachmentTypeMismatch(
                    id: descriptor.id,
                    declared: descriptor.mimeType,
                    actual: inspection.mimeType
                )
            }
            if let declaredWidth = descriptor.pixelWidth,
               let declaredHeight = descriptor.pixelHeight {
                guard declaredWidth == inspection.pixelWidth,
                      declaredHeight == inspection.pixelHeight else {
                    throw PortableBackupPackageError.attachmentPixelMismatch(
                        id: descriptor.id
                    )
                }
            }
        }

        // manifest/checksums 原文一并落盘，便于审计与上游排障。
        let manifestURL = destinationURL.appendingPathComponent(
            PortableBackupPackageFormat.manifestEntryName
        )
        let checksumsURL = destinationURL.appendingPathComponent(
            PortableBackupPackageFormat.checksumsEntryName
        )
        try indexed.rawManifestData.write(to: manifestURL, options: .atomic)
        try indexed.rawChecksumsData.write(to: checksumsURL, options: .atomic)

        return ExtractedBackupPackage(
            directoryURL: destinationURL,
            manifestURL: manifestURL,
            recordsURL: recordsURL,
            checksumsURL: checksumsURL,
            attachmentsDirectoryURL: attachmentsURL,
            manifest: manifest,
            exportedAt: exportedAt,
            attachmentDescriptors: descriptors
        )
    }

    // MARK: - 归档装载与条目级校验

    /// ZIP 已解析、条目级安全检查已通过的中间形态。
    /// 持有打开的文件句柄，用完必须 close。
    private final class IndexedArchive {
        let reader: StreamingZipReader
        let entriesByName: [String: StreamingZipReader.Entry]
        var manifest: PortableBackupPackageManifest
        var rawManifestData: Data
        var rawChecksumsData: Data

        init(
            reader: StreamingZipReader,
            entriesByName: [String: StreamingZipReader.Entry],
            manifest: PortableBackupPackageManifest,
            rawManifestData: Data,
            rawChecksumsData: Data
        ) {
            self.reader = reader
            self.entriesByName = entriesByName
            self.manifest = manifest
            self.rawManifestData = rawManifestData
            self.rawChecksumsData = rawChecksumsData
        }

        func entry(named name: String) throws -> StreamingZipReader.Entry {
            guard let entry = entriesByName[name] else {
                throw PortableBackupPackageError.missingEntry(name)
            }
            return entry
        }

        func extractToData(named name: String, byteLimit: Int64) throws -> Data {
            try reader.extractToData(entry(named: name), byteLimit: byteLimit)
        }

        func extractToFile(
            named name: String,
            to destinationURL: URL,
            byteLimit: Int64
        ) throws -> StreamingZipReader.FileResult {
            try reader.extractToFile(
                entry(named: name),
                to: destinationURL,
                byteLimit: byteLimit
            )
        }

        func close() {
            reader.close()
        }
    }

    /// 单条目解压上限按条目类型分派（§8.3）：manifest/checksums →
    /// maximumManifestBytes，records → maximumRecordsBytes，
    /// 附件及其它 → maximumEntryBytes。修复旧版通用 128 MiB 把
    /// records 卡死的问题；白名单外条目仍按附件档受限。
    static func uncompressedByteLimit(
        forEntryName name: String,
        limits: PortableBackupPackageLimits
    ) -> Int64 {
        switch name {
        case PortableBackupPackageFormat.manifestEntryName,
             PortableBackupPackageFormat.checksumsEntryName:
            return Int64(limits.maximumManifestBytes)
        case PortableBackupPackageFormat.recordsEntryName:
            return limits.maximumRecordsBytes
        default:
            return limits.maximumEntryBytes
        }
    }

    private func loadAndIndexArchive(fileURL: URL) throws -> IndexedArchive {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= limits.maximumPackageBytes else {
            throw PortableBackupPackageError.packageTooLarge(
                actual: size,
                limit: limits.maximumPackageBytes
            )
        }
        guard size > 0 else {
            throw PortableBackupPackageError.notAPackage
        }
        guard Self.isPackage(fileURL: fileURL) else {
            throw PortableBackupPackageError.notAPackage
        }
        let reader = try StreamingZipReader(fileURL: fileURL)
        do {
            return try indexValidatedArchive(reader)
        } catch {
            reader.close()
            throw error
        }
    }

    private func indexValidatedArchive(
        _ reader: StreamingZipReader
    ) throws -> IndexedArchive {
        guard reader.entries.count <= limits.maximumEntryCount else {
            throw PortableBackupPackageError.tooManyEntries(
                actual: reader.entries.count,
                limit: limits.maximumEntryCount
            )
        }

        // 条目级检查：路径、非常规文件、按类型分派的单条目上限、解压总量。
        var totalUncompressed: Int64 = 0
        var entriesByName: [String: StreamingZipReader.Entry] = [:]
        for entry in reader.entries {
            try Self.validateEntryPath(entry.name)
            entriesByName[entry.name] = entry
            // 目录标记条目是惰性的（不解压、不落地），允许存在以兼容
            // 其他工具产出的包；文件条目才要求常规文件。
            if entry.isDirectory { continue }
            guard !entry.isNonRegularFile else {
                throw PortableBackupPackageError.nonRegularFileEntry(entry.name)
            }
            let entryLimit = Self.uncompressedByteLimit(
                forEntryName: entry.name,
                limits: limits
            )
            guard entry.uncompressedSize <= entryLimit else {
                throw PortableBackupPackageError.entryTooLarge(
                    name: entry.name,
                    actual: entry.uncompressedSize,
                    limit: entryLimit
                )
            }
            let (sum, overflow) = totalUncompressed.addingReportingOverflow(
                entry.uncompressedSize
            )
            guard !overflow else {
                throw PortableBackupPackageError.totalUncompressedTooLarge(
                    actual: Int64.max,
                    limit: limits.maximumTotalUncompressedBytes
                )
            }
            totalUncompressed = sum
        }
        guard totalUncompressed <= limits.maximumTotalUncompressedBytes else {
            throw PortableBackupPackageError.totalUncompressedTooLarge(
                actual: totalUncompressed,
                limit: limits.maximumTotalUncompressedBytes
            )
        }

        // 本地头一致性（名称/flags/method/CRC/sizes）+ 数据区重叠，
        // 在解出任何内容前完成全部结构性核对。
        try reader.validateLocalHeaders()
        // 校验后的条目带 dataStart——按名索引重建一次。
        entriesByName = Dictionary(
            uniqueKeysWithValues: reader.entries.map { ($0.name, $0) }
        )

        let indexed = IndexedArchive(
            reader: reader,
            entriesByName: entriesByName,
            manifest: PortableBackupPackageManifest(
                format: "", formatVersion: 0, container: "", appVersion: "",
                exportedAt: "", encoding: "", lineEnding: "",
                checksumAlgorithm: "", recordFormatVersion: 0,
                recordOrder: [], counts: [:], excludedScopes: [], attachments: []
            ),
            rawManifestData: Data(),
            rawChecksumsData: Data()
        )
        // manifest.json 先解出来（带自己的体积上限），才有完整白名单。
        let manifestEntry = try indexed.extractToData(
            named: PortableBackupPackageFormat.manifestEntryName,
            byteLimit: Int64(limits.maximumManifestBytes)
        )
        guard manifestEntry.count <= limits.maximumManifestBytes else {
            throw PortableBackupPackageError.entryTooLarge(
                name: PortableBackupPackageFormat.manifestEntryName,
                actual: Int64(manifestEntry.count),
                limit: Int64(limits.maximumManifestBytes)
            )
        }
        let manifest = try Self.parseManifest(manifestEntry, limits: limits)

        // 白名单：固定三件套 + manifest 声明的附件路径；目录条目跳过。
        var allowed = Set(manifest.attachments.map(\.relativePath))
        allowed.insert(PortableBackupPackageFormat.manifestEntryName)
        allowed.insert(PortableBackupPackageFormat.recordsEntryName)
        allowed.insert(PortableBackupPackageFormat.checksumsEntryName)
        for entry in reader.entries where !entry.isDirectory {
            guard allowed.contains(entry.name) else {
                throw PortableBackupPackageError.unexpectedEntry(entry.name)
            }
        }
        // manifest 声明的附件在 ZIP 里必须真实存在。
        for descriptor in manifest.attachments {
            guard entriesByName[descriptor.relativePath] != nil else {
                throw PortableBackupPackageError.attachmentMissing(id: descriptor.id)
            }
        }
        let checksumsData = try indexed.extractToData(
            named: PortableBackupPackageFormat.checksumsEntryName,
            byteLimit: Int64(limits.maximumManifestBytes)
        )
        guard checksumsData.count <= limits.maximumManifestBytes else {
            throw PortableBackupPackageError.entryTooLarge(
                name: PortableBackupPackageFormat.checksumsEntryName,
                actual: Int64(checksumsData.count),
                limit: Int64(limits.maximumManifestBytes)
            )
        }
        indexed.manifest = manifest
        indexed.rawManifestData = manifestEntry
        indexed.rawChecksumsData = checksumsData
        return indexed
    }

    // MARK: - manifest / checksums 解析

    private static let manifestKeys: Set<String> = [
        "format", "formatVersion", "container", "appVersion", "exportedAt",
        "encoding", "lineEnding", "checksumAlgorithm", "recordFormatVersion",
        "recordOrder", "counts", "excludedScopes", "attachments"
    ]

    static func parseManifest(
        _ data: Data,
        limits: PortableBackupPackageLimits
    ) throws -> PortableBackupPackageManifest {
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw PortableBackupPackageError.invalidManifest("manifest 不是 JSON 对象。")
        }
        // 版本号先探：比当前新的格式在字段契约未知的情况下直接拒绝。
        if let version = object["formatVersion"] as? Int,
           version > PortableBackupPackageFormat.formatVersion {
            throw PortableBackupPackageError.futurePackageVersion(version)
        }
        guard Set(object.keys) == manifestKeys else {
            throw PortableBackupPackageError.invalidManifest("字段集合不符合清单契约。")
        }
        guard object["format"] as? String == PortableBackupFormat.identifier,
              object["container"] as? String == PortableBackupPackageFormat.container,
              object["encoding"] as? String == "utf-8",
              object["lineEnding"] as? String == "lf",
              object["checksumAlgorithm"] as? String
                == PortableBackupFormat.checksumAlgorithm else {
            throw PortableBackupPackageError.invalidManifest("格式标识或编码约定不受支持。")
        }
        let version = try PortableBackupPackageFormat.packageInteger(
            object["formatVersion"], field: "formatVersion", context: "manifest"
        )
        guard version == PortableBackupPackageFormat.formatVersion else {
            throw PortableBackupPackageError.unsupportedPackageVersion(version)
        }
        guard let appVersion = object["appVersion"] as? String, !appVersion.isEmpty,
              let exportedAtString = object["exportedAt"] as? String,
              PortableBackupPackageFormat.iso8601Date(from: exportedAtString) != nil else {
            throw PortableBackupPackageError.invalidManifest("appVersion/exportedAt 无效。")
        }
        let recordFormatVersion = try PortableBackupPackageFormat.packageInteger(
            object["recordFormatVersion"],
            field: "recordFormatVersion",
            context: "manifest"
        )
        // 外层包格式恒为 7；内嵌记录协议 v6（旧版导出）与 v7 都可恢复。
        let expectedRecordTypes: [String]
        switch recordFormatVersion {
        case 6: expectedRecordTypes = PortableBackupFormatV6.recordTypes
        case 7: expectedRecordTypes = PortableBackupFormatV7.recordTypes
        default:
            throw PortableBackupPackageError.invalidManifest(
                "内嵌记录流版本 \(recordFormatVersion) 不受支持。"
            )
        }
        guard let recordOrder = object["recordOrder"] as? [String],
              recordOrder == expectedRecordTypes else {
            throw PortableBackupPackageError.invalidManifest(
                "recordOrder 不符合 v\(recordFormatVersion) 契约。"
            )
        }
        guard let rawCounts = object["counts"] as? [String: Any],
              Set(rawCounts.keys) == Set(expectedRecordTypes) else {
            throw PortableBackupPackageError.invalidManifest(
                "counts 未完整列出 v\(recordFormatVersion) 记录类型。"
            )
        }
        var counts: [String: Int] = [:]
        for type in expectedRecordTypes {
            let count = try PortableBackupPackageFormat.packageInteger(
                rawCounts[type], field: type, context: "counts"
            )
            guard count >= 0 else {
                throw PortableBackupPackageError.invalidManifest("\(type) 数量不能为负。")
            }
            counts[type] = count
        }
        guard let excludedScopes = object["excludedScopes"] as? [String],
              excludedScopes.allSatisfy({ !$0.isEmpty }) else {
            throw PortableBackupPackageError.invalidManifest(
                "excludedScopes 必须是非空字符串数组。"
            )
        }
        guard let rawAttachments = object["attachments"] as? [[String: Any]] else {
            throw PortableBackupPackageError.invalidManifest("attachments 必须是对象数组。")
        }
        guard rawAttachments.count <= limits.maximumAttachmentCount else {
            throw PortableBackupPackageError.tooManyAttachments(
                actual: rawAttachments.count,
                limit: limits.maximumAttachmentCount
            )
        }
        var descriptors: [AttachmentDescriptor] = []
        var seenIDs = Set<String>()
        var seenPaths = Set<String>()
        for (index, raw) in rawAttachments.enumerated() {
            let descriptor = try PortableBackupPackageFormat.validate(
                descriptor: raw,
                context: "attachments[\(index)]"
            )
            guard seenIDs.insert(descriptor.id).inserted,
                  seenPaths.insert(descriptor.relativePath).inserted else {
                throw PortableBackupPackageError.invalidManifest(
                    "附件 \(descriptor.id) 重复声明。"
                )
            }
            descriptors.append(descriptor)
        }
        return PortableBackupPackageManifest(
            format: PortableBackupFormat.identifier,
            formatVersion: version,
            container: PortableBackupPackageFormat.container,
            appVersion: appVersion,
            exportedAt: exportedAtString,
            encoding: "utf-8",
            lineEnding: "lf",
            checksumAlgorithm: PortableBackupFormat.checksumAlgorithm,
            recordFormatVersion: recordFormatVersion,
            recordOrder: recordOrder,
            counts: counts,
            excludedScopes: excludedScopes,
            attachments: descriptors
        )
    }

    private static func manifestExportedAt(
        _ manifest: PortableBackupPackageManifest
    ) throws -> Date {
        guard let date = PortableBackupPackageFormat.iso8601Date(
            from: manifest.exportedAt
        ) else {
            throw PortableBackupPackageError.invalidManifest("exportedAt 无法解析。")
        }
        return date
    }

    private func extractChecksums(
        from indexed: IndexedArchive
    ) throws -> PortableBackupChecksums {
        guard let object = try? JSONSerialization.jsonObject(
            with: indexed.rawChecksumsData
        ) as? [String: Any] else {
            throw PortableBackupPackageError.invalidChecksums("checksums 不是 JSON 对象。")
        }
        guard Set(object.keys) == ["algorithm", "files"],
              object["algorithm"] as? String
                == PortableBackupFormat.checksumAlgorithm,
              let files = object["files"] as? [String: String] else {
            throw PortableBackupPackageError.invalidChecksums("字段集合不符合契约。")
        }
        return PortableBackupChecksums(
            algorithm: PortableBackupFormat.checksumAlgorithm,
            files: files
        )
    }

    // MARK: - 条目路径与辅助

    /// 路径穿越防御：拒绝绝对路径、`..`/`.`/空分段、反斜杠、NUL。
    /// 白名单校验在更上层做；这里管 ZIP 语义的最低安全线。
    static func validateEntryPath(_ name: String) throws {
        guard !name.isEmpty,
              !name.hasPrefix("/"),
              !name.contains("\\"),
              !name.contains("\0") else {
            throw PortableBackupPackageError.invalidEntryPath(name)
        }
        var components = name.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        // 目录条目允许末尾的 "/" 标记。
        if components.last == "" { components.removeLast() }
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw PortableBackupPackageError.invalidEntryPath(name)
        }
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
