import CryptoKit
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

/// 便携备份 v7 导出器（设计 §11.2）：`.oboe-backup` 扩展名不变，
/// 内部升级为 ZIP 容器——`manifest.json` + `records.ndjson`（完整 v6 流）
/// + `attachments/<id>.<ext>` + `checksums.json`。
///
/// 附件元数据的唯一事实源是文件字节本身：sha256/大小/MIME/像素都从
/// `InboxImageStore` 读出的内容实时计算，`attachments` 表不参与导出，
/// 这样 manifest、checksums 与包内文件不可能互相漂移。
public actor PortableBackupPackageExporter {
    public static let formatVersion = PortableBackupPackageFormat.formatVersion
    public static let fileExtension = PortableBackupFormat.fileExtension

    private let database: OboeDatabase
    private let imageStore: InboxImageStore
    private let workingDirectoryURL: URL
    private let snapshotCreatedHook: (@Sendable () async throws -> Void)?

    public init(
        database: OboeDatabase,
        imageStore: InboxImageStore,
        workingDirectoryURL: URL
    ) {
        self.database = database
        self.imageStore = imageStore
        self.workingDirectoryURL = workingDirectoryURL
        snapshotCreatedHook = nil
    }

    init(
        database: OboeDatabase,
        imageStore: InboxImageStore,
        workingDirectoryURL: URL,
        snapshotCreatedHook: (@Sendable () async throws -> Void)?
    ) {
        self.database = database
        self.imageStore = imageStore
        self.workingDirectoryURL = workingDirectoryURL
        self.snapshotCreatedHook = snapshotCreatedHook
    }

    public func export(
        appVersion: String,
        at exportedAt: Date = Date()
    ) async throws -> PortableBackupPackageExport {
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
            let result = try writePackage(
                from: snapshot.url,
                stagingURL: stagingURL,
                appVersion: appVersion,
                exportedAt: exportedAt
            )
            try result.archive.write(to: pendingURL, options: .atomic)
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
        let archive: Data
        let recordCounts: [String: Int]
        let attachments: [AttachmentDescriptor]
        let unresolvedAttachmentIDs: [String]
    }

    private func writePackage(
        from snapshotURL: URL,
        stagingURL: URL,
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
        var attachments: [AttachmentDescriptor] = []
        var unresolved: [String] = []
        var attachmentPayloads: [(descriptor: AttachmentDescriptor, data: Data)] = []
        for resourceID in referencedIDs {
            guard let payload = try attachmentPayload(for: resourceID) else {
                unresolved.append(resourceID)
                continue
            }
            attachments.append(payload.descriptor)
            attachmentPayloads.append(payload)
        }

        let manifest = PortableBackupPackageManifest(
            format: PortableBackupFormat.identifier,
            formatVersion: Self.formatVersion,
            container: PortableBackupPackageFormat.container,
            appVersion: appVersion,
            exportedAt: PortableBackupPackageFormat.iso8601String(from: exportedAt),
            encoding: "utf-8",
            lineEnding: "lf",
            checksumAlgorithm: PortableBackupFormat.checksumAlgorithm,
            recordFormatVersion: PortableBackupPackageFormat.recordsFormatVersion,
            recordOrder: PortableBackupFormatV6.recordTypes,
            counts: recordCounts,
            excludedScopes: PortableBackupPackageFormat.excludedScopes,
            attachments: attachments
        )
        let manifestData = try manifest.encoded()

        let recordsData = try Data(contentsOf: recordsURL)
        var checksumFiles: [String: String] = [
            PortableBackupPackageFormat.recordsEntryName: Self.sha256Hex(of: recordsData)
        ]
        for payload in attachmentPayloads {
            checksumFiles[payload.descriptor.relativePath] = payload.descriptor.sha256
        }
        let checksums = PortableBackupChecksums(
            algorithm: PortableBackupFormat.checksumAlgorithm,
            files: checksumFiles
        )
        let checksumsData = try checksums.encoded()

        // 固定条目顺序：manifest → records → attachments（按 id 排序）→ checksums。
        let dosDateTime = ZipArchive.dosDateTime(from: exportedAt)
        var entries = [
            ZipArchive.WriteEntry(
                name: PortableBackupPackageFormat.manifestEntryName,
                data: manifestData,
                dosDate: dosDateTime.date,
                dosTime: dosDateTime.time
            ),
            ZipArchive.WriteEntry(
                name: PortableBackupPackageFormat.recordsEntryName,
                data: recordsData,
                dosDate: dosDateTime.date,
                dosTime: dosDateTime.time
            )
        ]
        for payload in attachmentPayloads.sorted(by: { $0.descriptor.id < $1.descriptor.id }) {
            entries.append(ZipArchive.WriteEntry(
                name: payload.descriptor.relativePath,
                data: payload.data,
                dosDate: dosDateTime.date,
                dosTime: dosDateTime.time
            ))
        }
        entries.append(ZipArchive.WriteEntry(
            name: PortableBackupPackageFormat.checksumsEntryName,
            data: checksumsData,
            dosDate: dosDateTime.date,
            dosTime: dosDateTime.time
        ))
        let archive = try ZipArchive.archive(entries: entries)
        return PackageResult(
            archive: archive,
            recordCounts: recordCounts,
            attachments: attachments,
            unresolvedAttachmentIDs: unresolved
        )
    }

    /// 附件字节 → descriptor + 数据。文件缺失或内容不再是受支持图片时
    /// 返回 nil（调用方记入 unresolved，导出继续）。
    private func attachmentPayload(
        for resourceID: String
    ) throws -> (descriptor: AttachmentDescriptor, data: Data)? {
        let data: Data
        do {
            data = try imageStore.loadPreviewData(for: resourceID)
        } catch {
            return nil
        }
        guard let inspection = AttachmentContentSniffer.inspect(data),
              let ext = AttachmentContentSniffer.canonicalExtension(
                forMimeType: inspection.mimeType
              ) else {
            return nil
        }
        let descriptor = AttachmentDescriptor(
            id: resourceID,
            relativePath: PortableBackupPackageFormat.canonicalRelativePath(
                id: resourceID,
                fileExtension: ext
            ),
            mimeType: inspection.mimeType,
            byteCount: data.count,
            sha256: Self.sha256Hex(of: data),
            pixelWidth: inspection.pixelWidth,
            pixelHeight: inspection.pixelHeight
        )
        return (descriptor, data)
    }

    private func referencedAttachmentIDs(in snapshotURL: URL) throws -> [String] {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "Oboe package export attachments"
        let snapshot = try DatabaseQueue(path: snapshotURL.path, configuration: configuration)
        defer { try? snapshot.close() }
        return try snapshot.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT image_reference
                    FROM inbox_items
                    WHERE image_reference IS NOT NULL
                    ORDER BY image_reference
                    """
            )
        }
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
