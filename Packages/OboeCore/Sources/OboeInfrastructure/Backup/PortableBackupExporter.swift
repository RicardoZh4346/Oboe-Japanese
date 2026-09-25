import CryptoKit
import Foundation
import GRDB

public struct PortableBackupExport: Equatable, Sendable {
    public let url: URL
    public let exportedAt: Date
    public let recordCounts: [String: Int]

    public init(url: URL, exportedAt: Date, recordCounts: [String: Int]) {
        self.url = url
        self.exportedAt = exportedAt
        self.recordCounts = recordCounts
    }
}

public enum PortableBackupExportError: Error, Equatable, Sendable {
    case unsupportedDatabaseValue(table: String, column: String)
}

/// Writes Oboe's public, versioned NDJSON backup format.
///
/// The exporter first creates a consistent SQLite snapshot. All rows are then
/// read from that snapshot and written one line at a time, so live reviews can
/// continue without mixing database states or loading the full history in memory.
public actor PortableBackupExporter {
    public static let formatVersion = PortableBackupFormat.currentVersion
    public static let fileExtension = PortableBackupFormat.fileExtension

    private let database: OboeDatabase
    private let workingDirectoryURL: URL
    private let snapshotCreatedHook: (@Sendable () async throws -> Void)?

    public init(database: OboeDatabase, workingDirectoryURL: URL) {
        self.database = database
        self.workingDirectoryURL = workingDirectoryURL
        snapshotCreatedHook = nil
    }

    init(
        database: OboeDatabase,
        workingDirectoryURL: URL,
        snapshotCreatedHook: (@Sendable () async throws -> Void)?
    ) {
        self.database = database
        self.workingDirectoryURL = workingDirectoryURL
        self.snapshotCreatedHook = snapshotCreatedHook
    }

    public func export(
        appVersion: String,
        at exportedAt: Date = Date()
    ) async throws -> PortableBackupExport {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: workingDirectoryURL,
            withIntermediateDirectories: true
        )

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

        let pendingURL = workingDirectoryURL.appendingPathComponent(
            ".pending-\(UUID().uuidString.lowercased()).\(Self.fileExtension)"
        )
        let finalURL = uniqueExportURL(at: exportedAt)
        fileManager.createFile(atPath: pendingURL.path, contents: nil)

        do {
            let result = try Self.writeBackupRecords(
                from: snapshot.url,
                to: pendingURL,
                appVersion: appVersion,
                exportedAt: exportedAt
            )
            try fileManager.moveItem(at: pendingURL, to: finalURL)
            return PortableBackupExport(
                url: finalURL,
                exportedAt: exportedAt,
                recordCounts: result
            )
        } catch {
            try? fileManager.removeItem(at: pendingURL)
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

    /// 把一致的快照库写成完整 v6 NDJSON 流（manifest 行 + 记录行 + footer）。
    /// 提为 static 供 v7 包导出复用——`records.ndjson` 与该文件逐字节同构。
    static func writeBackupRecords(
        from snapshotURL: URL,
        to outputURL: URL,
        appVersion: String,
        exportedAt: Date
    ) throws -> [String: Int] {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        configuration.label = "Oboe portable backup export"
        let snapshot = try DatabaseQueue(path: snapshotURL.path, configuration: configuration)
        defer { try? snapshot.close() }

        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        return try snapshot.read { db in
            var counts: [String: Int] = [:]
            for specification in PortableBackupFormatV7.tableSpecifications {
                let countSQL: String
                if let selectSQL = specification.selectSQL {
                    countSQL = "SELECT COUNT(*) FROM (\(selectSQL))"
                } else {
                    countSQL = "SELECT COUNT(*) FROM \(specification.tableName)"
                }
                counts[specification.recordType] = try Int.fetchOne(db, sql: countSQL) ?? 0
            }

            var hasher = SHA256()
            let manifest: [String: Any] = [
                "recordType": "manifest",
                "format": PortableBackupFormat.identifier,
                "formatVersion": PortableBackupFormat.currentVersion,
                "appVersion": appVersion,
                "exportedAt": Self.iso8601String(from: exportedAt),
                "encoding": "utf-8",
                "lineEnding": "lf",
                "checksumAlgorithm": PortableBackupFormat.checksumAlgorithm,
                "recordOrder": PortableBackupFormatV7.recordTypes,
                "counts": counts,
                "excludedScopes": PortableBackupFormat.excludedScopes
            ]
            try Self.writeHashedLine(manifest, to: handle, hasher: &hasher)

            for specification in PortableBackupFormatV7.tableSpecifications {
                let sql: String
                if let selectSQL = specification.selectSQL {
                    sql = "\(selectSQL) ORDER BY \(specification.orderBy)"
                } else {
                    sql = "SELECT \(specification.columns.joined(separator: ", ")) "
                        + "FROM \(specification.tableName) ORDER BY \(specification.orderBy)"
                }
                let cursor = try Row.fetchCursor(db, sql: sql)
                while let row = try cursor.next() {
                    var object: [String: Any] = ["recordType": specification.recordType]
                    for column in specification.columns {
                        let value: DatabaseValue = row[column]
                        object[column] = try Self.jsonValue(
                            value,
                            table: specification.tableName,
                            column: column
                        )
                    }
                    try Self.writeHashedLine(object, to: handle, hasher: &hasher)
                }
            }

            let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            try Self.writeLine(
                [
                    "recordType": "footer",
                    "checksumAlgorithm": PortableBackupFormat.checksumAlgorithm,
                    "checksum": checksum
                ],
                to: handle
            )
            try handle.synchronize()
            return counts
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

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func writeHashedLine(
        _ object: [String: Any],
        to handle: FileHandle,
        hasher: inout SHA256
    ) throws {
        let data = try lineData(object)
        try handle.write(contentsOf: data)
        hasher.update(data: data)
    }

    private static func writeLine(
        _ object: [String: Any],
        to handle: FileHandle
    ) throws {
        try handle.write(contentsOf: lineData(object))
    }

    private static func lineData(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private static func jsonValue(
        _ value: DatabaseValue,
        table: String,
        column: String
    ) throws -> Any {
        switch value.storage {
        case .null:
            return NSNull()
        case let .int64(value):
            return value
        case let .double(value):
            return value
        case let .string(value):
            return value
        case let .blob(value):
            // The v1 schema has no binary export fields. Rejecting an unexpected
            // blob prevents an undocumented, lossy representation from escaping.
            _ = value
            throw PortableBackupExportError.unsupportedDatabaseValue(
                table: table,
                column: column
            )
        }
    }
}
