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

/// 便携备份 v7 包的读取与校验器（设计 §11.2/§11.3 的 Prepare 阶段）。
///
/// 信任顺序：ZIP magic → 中央目录（限额/路径/加密/符号链接）→ manifest
/// （格式契约 + descriptor 字段级校验）→ checksums → 逐字节 SHA-256、
/// 大小、MIME 魔数（ImageIO UTI）、像素尺寸。任何一步失败立即抛错。
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
        try loadAndIndexArchive(fileURL: fileURL).manifest
    }

    /// 解压 + 全量校验到 destinationURL。目录不存在则创建。
    /// 校验顺序保证：读入字节 → 结构 → manifest → checksums → 逐条附件。
    @discardableResult
    public func extractAndValidate(
        fileURL: URL,
        to destinationURL: URL
    ) throws -> ExtractedBackupPackage {
        let indexed = try loadAndIndexArchive(fileURL: fileURL)
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

        // records.ndjson：大小上限 → SHA-256 → 落盘。记录级校验交给
        // 现有 NDJSON 导入管线（与 v1–v6 同一套契约检查）。
        let recordsData = try indexed.extract(
            named: PortableBackupPackageFormat.recordsEntryName
        )
        guard Int64(recordsData.count) <= limits.maximumRecordsBytes else {
            throw PortableBackupPackageError.entryTooLarge(
                name: PortableBackupPackageFormat.recordsEntryName,
                actual: Int64(recordsData.count),
                limit: limits.maximumRecordsBytes
            )
        }
        guard Self.sha256Hex(of: recordsData)
                == checksums.files[PortableBackupPackageFormat.recordsEntryName] else {
            throw PortableBackupPackageError.checksumMismatch(
                file: PortableBackupPackageFormat.recordsEntryName
            )
        }
        let recordsURL = destinationURL.appendingPathComponent(
            PortableBackupPackageFormat.recordsEntryName
        )
        try recordsData.write(to: recordsURL, options: .atomic)

        // 附件：manifest 声明的每个 descriptor 都必须有对应条目，
        // 字节数/SHA-256/MIME 魔数/像素全部一致才落盘。
        for descriptor in descriptors {
            let entryData = try indexed.extract(named: descriptor.relativePath)
            guard entryData.count == descriptor.byteCount else {
                throw PortableBackupPackageError.attachmentSizeMismatch(
                    id: descriptor.id,
                    expected: Int64(descriptor.byteCount),
                    actual: Int64(entryData.count)
                )
            }
            let digest = Self.sha256Hex(of: entryData)
            guard digest == descriptor.sha256,
                  digest == checksums.files[descriptor.relativePath] else {
                throw PortableBackupPackageError.attachmentChecksumMismatch(
                    id: descriptor.id
                )
            }
            guard let inspection = AttachmentContentSniffer.inspect(entryData) else {
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
            let fileName = String(descriptor.relativePath.dropFirst(
                PortableBackupPackageFormat.attachmentsDirectoryName.count + 1
            ))
            try entryData.write(
                to: attachmentsURL.appendingPathComponent(fileName),
                options: .atomic
            )
        }

        // manifest/checksums 原文一并落盘，便于审计与上游排障。
        let manifestURL = destinationURL.appendingPathComponent(
            PortableBackupPackageFormat.manifestEntryName
        )
        let checksumsURL = destinationURL.appendingPathComponent(
            PortableBackupPackageFormat.checksumsEntryName
        )
        try indexed.extract(named: PortableBackupPackageFormat.manifestEntryName)
            .write(to: manifestURL, options: .atomic)
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
    private struct IndexedArchive {
        let reader: ZipArchive.Reader
        let entriesByName: [String: ZipArchive.ReadEntry]
        let manifest: PortableBackupPackageManifest
        let rawChecksumsData: Data

        func extract(named name: String) throws -> Data {
            guard let entry = entriesByName[name] else {
                throw PortableBackupPackageError.missingEntry(name)
            }
            return try reader.extract(entry)
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
        let data = try Data(contentsOf: fileURL)
        guard Self.isPackage(fileURL: fileURL) else {
            throw PortableBackupPackageError.notAPackage
        }
        let reader = try ZipArchive.Reader(data: data)
        guard reader.entries.count <= limits.maximumEntryCount else {
            throw PortableBackupPackageError.tooManyEntries(
                actual: reader.entries.count,
                limit: limits.maximumEntryCount
            )
        }

        // 条目级检查：路径、非常规文件、单条目与解压总量上限。
        var totalUncompressed: Int64 = 0
        var entriesByName: [String: ZipArchive.ReadEntry] = [:]
        for entry in reader.entries {
            try Self.validateEntryPath(entry.name)
            entriesByName[entry.name] = entry
            // 目录标记条目是惰性的（不解压、不落地），允许存在以兼容
            // 其他工具产出的包；文件条目才要求常规文件。
            if entry.isDirectory { continue }
            guard !entry.isNonRegularFile else {
                throw PortableBackupPackageError.nonRegularFileEntry(entry.name)
            }
            guard Int64(entry.uncompressedSize) <= limits.maximumEntryBytes else {
                throw PortableBackupPackageError.entryTooLarge(
                    name: entry.name,
                    actual: Int64(entry.uncompressedSize),
                    limit: limits.maximumEntryBytes
                )
            }
            let (sum, overflow) = totalUncompressed.addingReportingOverflow(
                Int64(entry.uncompressedSize)
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

        let indexed = IndexedArchive(
            reader: reader,
            entriesByName: entriesByName,
            manifest: PortableBackupPackageManifest(
                format: "", formatVersion: 0, container: "", appVersion: "",
                exportedAt: "", encoding: "", lineEnding: "",
                checksumAlgorithm: "", recordFormatVersion: 0,
                recordOrder: [], counts: [:], excludedScopes: [], attachments: []
            ),
            rawChecksumsData: Data()
        )
        // manifest.json 先解出来（带自己的体积上限），才有完整白名单。
        let manifestEntry = try indexed.extract(
            named: PortableBackupPackageFormat.manifestEntryName
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
        let checksumsData = try indexed.extract(
            named: PortableBackupPackageFormat.checksumsEntryName
        )
        guard checksumsData.count <= limits.maximumManifestBytes else {
            throw PortableBackupPackageError.entryTooLarge(
                name: PortableBackupPackageFormat.checksumsEntryName,
                actual: Int64(checksumsData.count),
                limit: Int64(limits.maximumManifestBytes)
            )
        }
        return IndexedArchive(
            reader: reader,
            entriesByName: entriesByName,
            manifest: manifest,
            rawChecksumsData: checksumsData
        )
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
        guard recordFormatVersion == PortableBackupPackageFormat.recordsFormatVersion else {
            throw PortableBackupPackageError.invalidManifest(
                "内嵌记录流版本 \(recordFormatVersion) 不受支持。"
            )
        }
        guard let recordOrder = object["recordOrder"] as? [String],
              recordOrder == PortableBackupFormatV6.recordTypes else {
            throw PortableBackupPackageError.invalidManifest("recordOrder 不符合 v6 契约。")
        }
        guard let rawCounts = object["counts"] as? [String: Any],
              Set(rawCounts.keys) == Set(PortableBackupFormatV6.recordTypes) else {
            throw PortableBackupPackageError.invalidManifest("counts 未完整列出 v6 记录类型。")
        }
        var counts: [String: Int] = [:]
        for type in PortableBackupFormatV6.recordTypes {
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
