import Foundation
import GRDB
import OboeDomain

public struct PortableBackupPackageExport: Equatable, Sendable {
    public let url: URL
    public let exportedAt: Date
    public let recordCounts: [String: Int]
    /// 写入 manifest 的附件 descriptor（按 id 排序）。
    public let attachments: [AttachmentDescriptor]
    /// inbox_items 引用了但文件已缺失、未随包分发的资源 id。
    /// 恢复端对这些引用按既有惯例降级为 NULL，不阻断恢复。
    public let unresolvedAttachmentIDs: [String]

    public init(
        url: URL,
        exportedAt: Date,
        recordCounts: [String: Int],
        attachments: [AttachmentDescriptor],
        unresolvedAttachmentIDs: [String]
    ) {
        self.url = url
        self.exportedAt = exportedAt
        self.recordCounts = recordCounts
        self.attachments = attachments
        self.unresolvedAttachmentIDs = unresolvedAttachmentIDs
    }
}

/// 便携备份 v7 导出器（设计 §11.2 / v0.6.0 §8.2）：`.oboe-backup` 扩展名不变，
/// 内部为 ZIP 容器——`manifest.json` + `records.ndjson`（完整 v6 流）
/// + `attachments/<id>.<ext>` + `checksums.json`。
///
/// S04 流式化：不再聚合完整 records/ZIP/附件 Data。records.ndjson 先落到
/// staging 文件（沿用 `writeBackupRecords` 的一致性快照读法），再以
/// 256 KiB chunk 流式写入 `StreamingZipWriter` 并增量计算 SHA-256；
/// 附件经 `attachmentFileProvider` 逐文件提供 URL，先嗅探元数据再按 id
/// 排序写入——内存复杂度 O(chunk + 有界元数据)。
///
/// 附件元数据的唯一事实源是文件字节本身：sha256/大小/MIME/像素都从文件
/// 内容实时计算，`attachments` 表不参与导出，manifest、checksums 与包内
/// 文件不可能互相漂移。
public actor PortableBackupPackageExporter {
    public static let formatVersion = PortableBackupPackageFormat.formatVersion
    public static let fileExtension = PortableBackupFormat.fileExtension

    /// 附件文件提供者：受控资源 id → 本地文件 URL。
    /// S05 的 staged lease 会实现同一契约提供暂存文件；本步只做协议预留，
    /// 默认实现直接映射 `InboxImageStore` 的存储文件。抛出或文件缺失时
    /// 该 id 记入 unresolved（与旧版缺文件语义一致），导出继续。
    public typealias AttachmentFileProvider = @Sendable (String) throws -> URL

    private let database: OboeDatabase
    private let workingDirectoryURL: URL
    private let attachmentFileProvider: AttachmentFileProvider
    private let snapshotCreatedHook: (@Sendable () async throws -> Void)?

    public init(
        database: OboeDatabase,
        imageStore: InboxImageStore,
        workingDirectoryURL: URL
    ) {
        self.database = database
        self.workingDirectoryURL = workingDirectoryURL
        attachmentFileProvider = { resourceID in
            try imageStore.fileURL(for: resourceID)
        }
        snapshotCreatedHook = nil
    }

    init(
        database: OboeDatabase,
        imageStore: InboxImageStore,
        workingDirectoryURL: URL,
        attachmentFileProvider: AttachmentFileProvider? = nil,
        snapshotCreatedHook: (@Sendable () async throws -> Void)?
    ) {
        self.database = database
        self.workingDirectoryURL = workingDirectoryURL
        self.attachmentFileProvider = attachmentFileProvider ?? { resourceID in
            try imageStore.fileURL(for: resourceID)
        }
        self.snapshotCreatedHook = snapshotCreatedHook
    }

    public func export(
        appVersion: String,
        at exportedAt: Date = Date()
    ) async throws -> PortableBackupPackageExport {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: workingDirectoryURL,
            withIntermediateDirectories: true
        )

        // 与 v6 导出同一个一致性快照机制：所有行与附件清单都读自同一瞬间。
        let snapshotDirectory = workingDirectoryURL.appendingPathComponent(
            ".export-snapshots",
            isDirectory: true
        )
        let snapshotService = DatabaseSnapshotService(directoryURL: snapshotDirectory)
        let snapshot = try await snapshotService.createSnapshot(
            from: database.pool,
            reason: .export,
            at: exportedAt
        )
        defer {
            try? fileManager.removeItem(at: snapshot.url)
        }

        if let snapshotCreatedHook {
            try await snapshotCreatedHook()
        }

        let stagingURL = workingDirectoryURL.appendingPathComponent(
            ".packaging-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let pendingURL = workingDirectoryURL.appendingPathComponent(
            ".pending-\(UUID().uuidString.lowercased()).\(Self.fileExtension)"
        )
        let finalURL = uniqueExportURL(at: exportedAt)

        do {
            try Task.checkCancellation()
            let result = try writePackage(
                from: snapshot.url,
                stagingURL: stagingURL,
                to: pendingURL,
                appVersion: appVersion,
                exportedAt: exportedAt
            )
            // 成功才从 .pending 临时名转正——中间失败不留有效名残件。
            try fileManager.moveItem(at: pendingURL, to: finalURL)
            try? fileManager.removeItem(at: stagingURL)
            return PortableBackupPackageExport(
                url: finalURL,
                exportedAt: exportedAt,
                recordCounts: result.recordCounts,
                attachments: result.attachments,
                unresolvedAttachmentIDs: result.unresolvedAttachmentIDs
            )
        } catch {
            try? fileManager.removeItem(at: pendingURL)
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    public func removeExport(at url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL
                == workingDirectoryURL.standardizedFileURL else {
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 打包

    private struct PackageResult {
        let recordCounts: [String: Int]
        let attachments: [AttachmentDescriptor]
        let unresolvedAttachmentIDs: [String]
    }

    /// 两阶段打包（§8.2）：
    /// 1. 快照内写 records.ndjson 到 staging → 流式入包算 sha256；
    ///    附件逐文件嗅探元数据、按 id 顺序流式入包（store，已压缩内容不再压）。
    /// 2. 全部 descriptor/digest 已知后写 manifest → checksums → 中央目录。
    ///
    /// 包内条目顺序：records → attachments → manifest → checksums
    /// （manifest 依赖 records/附件摘要；reader 按名字索引，不依赖顺序）。
    private func writePackage(
        from snapshotURL: URL,
        stagingURL: URL,
        to pendingURL: URL,
        appVersion: String,
        exportedAt: Date
    ) throws -> PackageResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let recordsURL = stagingURL.appendingPathComponent(
            PortableBackupPackageFormat.recordsEntryName
        )

        // records.ndjson：与独立 v6 导出逐字节同构的记录流。
        // writeBackupRecords 走 FileHandle 写入，目标文件必须先存在。
        fileManager.createFile(atPath: recordsURL.path, contents: nil)
        let recordCounts = try PortableBackupExporter.writeBackupRecords(
            from: snapshotURL,
            to: recordsURL,
            appVersion: appVersion,
            exportedAt: exportedAt
        )

        // 附件清单：从同一快照读 inbox_items 的引用集合，保证记录流与
        // 附件集一致——导出进行中新增的引用不会混进包里。
        let referencedIDs = try referencedAttachmentIDs(in: snapshotURL)

        let writer = try StreamingZipWriter(fileURL: pendingURL)
        var attachments: [AttachmentDescriptor] = []
        var unresolved: [String] = []
        var checksumFiles: [String: String] = [:]
        do {
            try Task.checkCancellation()
            let dosDateTime = ZipArchive.dosDateTime(from: exportedAt)

            // records.ndjson：staging 文件按 chunk 流式入包，增量算 sha256。
            try writer.beginEntry(
                name: PortableBackupPackageFormat.recordsEntryName,
                method: .deflate,
                dosDate: dosDateTime.date,
                dosTime: dosDateTime.time
            )
            try streamFile(at: recordsURL, into: writer)
            let recordsResult = try writer.finishEntry()
            checksumFiles[PortableBackupPackageFormat.recordsEntryName] =
                recordsResult.sha256

            // 附件：逐文件 provider → 嗅探 → 排序写入。字节只经手一个 chunk，
            // 不再聚合 [(AttachmentDescriptor, Data)]。
            for resourceID in referencedIDs {
                try Task.checkCancellation()
                guard let fileURL = try? attachmentFileProvider(resourceID),
                      fileManager.fileExists(atPath: fileURL.path),
                      let inspection = AttachmentContentSniffer.inspect(
                        fileURL: fileURL
                      ),
                      let ext = AttachmentContentSniffer.canonicalExtension(
                        forMimeType: inspection.mimeType
                      ) else {
                    unresolved.append(resourceID)
                    continue
                }
                let relativePath = PortableBackupPackageFormat.canonicalRelativePath(
                    id: resourceID,
                    fileExtension: ext
                )
                try writer.beginEntry(
                    name: relativePath,
                    method: .store,
                    dosDate: dosDateTime.date,
                    dosTime: dosDateTime.time
                )
                try streamFile(at: fileURL, into: writer)
                let result = try writer.finishEntry()
                let descriptor = AttachmentDescriptor(
                    id: resourceID,
                    relativePath: relativePath,
                    mimeType: inspection.mimeType,
                    byteCount: Int(result.uncompressedSize),
                    sha256: result.sha256,
                    pixelWidth: inspection.pixelWidth,
                    pixelHeight: inspection.pixelHeight
                )
                attachments.append(descriptor)
                checksumFiles[relativePath] = result.sha256
            }

            // 所有 descriptor/digest 已知后才写 manifest 与 checksums。
            let manifest = PortableBackupPackageManifest(
                format: PortableBackupFormat.identifier,
                formatVersion: Self.formatVersion,
                container: PortableBackupPackageFormat.container,
                appVersion: appVersion,
                exportedAt: PortableBackupPackageFormat.iso8601String(
                    from: exportedAt
                ),
                encoding: "utf-8",
                lineEnding: "lf",
                checksumAlgorithm: PortableBackupFormat.checksumAlgorithm,
                recordFormatVersion: PortableBackupPackageFormat.recordsFormatVersion,
                recordOrder: PortableBackupFormatV7.recordTypes,
                counts: recordCounts,
                excludedScopes: PortableBackupPackageFormat.excludedScopes,
                attachments: attachments
            )
            try writer.beginEntry(
                name: PortableBackupPackageFormat.manifestEntryName,
                method: .deflate,
                dosDate: dosDateTime.date,
                dosTime: dosDateTime.time
            )
            try writer.write(manifest.encoded())
            _ = try writer.finishEntry()

            let checksums = PortableBackupChecksums(
                algorithm: PortableBackupFormat.checksumAlgorithm,
                files: checksumFiles
            )
            try writer.beginEntry(
                name: PortableBackupPackageFormat.checksumsEntryName,
                method: .deflate,
                dosDate: dosDateTime.date,
                dosTime: dosDateTime.time
            )
            try writer.write(checksums.encoded())
            _ = try writer.finishEntry()

            try writer.finalizeArchive()
        } catch {
            writer.abort()
            throw error
        }
        return PackageResult(
            recordCounts: recordCounts,
            attachments: attachments,
            unresolvedAttachmentIDs: unresolved
        )
    }

    /// 文件 → ZIP 条目流式搬运：256 KiB chunk，逐块检查取消。
    private func streamFile(at url: URL, into writer: StreamingZipWriter) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            try Task.checkCancellation()
            // autoreleasepool：FileHandle.read 返回 autoreleased NSData，
            // 紧循环里不排水会把累计读量顶进 RSS。
            guard let chunk = try autoreleasepool(invoking: {
                try handle.read(upToCount: StreamingZipWriter.chunkSize)
            }), !chunk.isEmpty else {
                return
            }
            try writer.write(chunk)
        }
    }

    private func referencedAttachmentIDs(in snapshotURL: URL) throws -> [String] {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "Oboe package export attachments"
        let snapshot = try DatabaseQueue(path: snapshotURL.path, configuration: configuration)
        defer { try? snapshot.close() }
        return try snapshot.read { db in
            // D09（设计 §6.3）：导出清单用统一引用集合——
            // inbox_items ∪ source_contexts；v15 之前的快照没有
            // source_contexts 表，探测后按旧集合退化为 inbox 单列。
            let hasSourceContexts = try db.tableExists("source_contexts")
            let sql = hasSourceContexts
                ? """
                    SELECT DISTINCT image_reference FROM (
                        SELECT image_reference FROM inbox_items
                        UNION
                        SELECT image_reference FROM source_contexts
                    )
                    WHERE image_reference IS NOT NULL
                      AND image_reference <> ''
                    ORDER BY image_reference
                    """
                : """
                    SELECT DISTINCT image_reference
                    FROM inbox_items
                    WHERE image_reference IS NOT NULL
                    ORDER BY image_reference
                    """
            return try String.fetchAll(db, sql: sql)
        }
    }

    private func uniqueExportURL(at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = "Oboe-\(formatter.string(from: date))"
        var candidate = workingDirectoryURL.appendingPathComponent(
            "\(prefix).\(Self.fileExtension)"
        )
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = workingDirectoryURL.appendingPathComponent(
                "\(prefix)-\(suffix).\(Self.fileExtension)"
            )
            suffix += 1
        }
        return candidate
    }
}
