import Foundation
import GRDB

public enum DatabaseSnapshotReason: String, Codable, Sendable {
    case daily
    case export
    case migration
    case restoration
}

public struct DatabaseSnapshot: Equatable, Sendable {
    public let url: URL
    public let reason: DatabaseSnapshotReason
    public let createdAt: Date

    public init(url: URL, reason: DatabaseSnapshotReason, createdAt: Date) {
        self.url = url
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct DatabaseSnapshotValidation: Equatable, Sendable {
    public let tableNames: Set<String>
    public let appliedMigrationIdentifiers: Set<String>

    public init(tableNames: Set<String>, appliedMigrationIdentifiers: Set<String>) {
        self.tableNames = tableNames
        self.appliedMigrationIdentifiers = appliedMigrationIdentifiers
    }
}

public enum DatabaseSnapshotError: Error, Equatable, Sendable {
    case missingSnapshot(URL)
    case integrityCheckFailed([String])
    case foreignKeyViolations(Int)
}

public actor DatabaseSnapshotService {
    public let directoryURL: URL
    public let maximumDailySnapshotCount: Int

    public init(directoryURL: URL, maximumDailySnapshotCount: Int = 3) {
        precondition(maximumDailySnapshotCount > 0)
        self.directoryURL = directoryURL
        self.maximumDailySnapshotCount = maximumDailySnapshotCount
    }

    @discardableResult
    public func createSnapshot(
        from source: any DatabaseReader,
        reason: DatabaseSnapshotReason,
        at createdAt: Date = Date()
    ) throws -> DatabaseSnapshot {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let snapshot = try makeSnapshot(reason: reason, createdAt: createdAt)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".pending-\(UUID().uuidString.lowercased()).sqlite"
        )
        let destination = try DatabaseQueue(path: temporaryURL.path)

        do {
            try source.backup(to: destination)
            try destination.writeWithoutTransaction { db in
                // DatabasePool sources use WAL. Checkpoint the copied pages into
                // the main file so a snapshot remains a self-contained file.
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            _ = try validate(destination)
            try destination.close()
            try FileManager.default.moveItem(at: temporaryURL, to: snapshot.url)
            return snapshot
        } catch {
            try? destination.close()
            removeTemporaryDatabaseFiles(at: temporaryURL)
            throw error
        }
    }

    @discardableResult
    public func createDailySnapshotIfNeeded(
        from source: any DatabaseReader,
        hasChanges: Bool,
        at createdAt: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DatabaseSnapshot? {
        guard hasChanges else {
            return nil
        }

        let existingSnapshots = try snapshots()
        guard !existingSnapshots.contains(where: {
            $0.reason == .daily && calendar.isDate($0.createdAt, inSameDayAs: createdAt)
        }) else {
            return nil
        }

        let snapshot = try createSnapshot(from: source, reason: .daily, at: createdAt)
        try pruneDailySnapshots()
        return snapshot
    }

    public func snapshots() throws -> [DatabaseSnapshot] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return []
        }

        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .compactMap(Self.parseSnapshot)
        .sorted {
            if $0.createdAt == $1.createdAt {
                return $0.url.lastPathComponent > $1.url.lastPathComponent
            }
            return $0.createdAt > $1.createdAt
        }
    }

    public func openValidatedSnapshot(at url: URL) throws -> DatabaseQueue {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DatabaseSnapshotError.missingSnapshot(url)
        }

        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        configuration.label = "Oboe snapshot validation"
        let database = try DatabaseQueue(path: url.path, configuration: configuration)

        do {
            _ = try validate(database)
            return database
        } catch {
            try? database.close()
            throw error
        }
    }

    public func validateSnapshot(at url: URL) throws -> DatabaseSnapshotValidation {
        let database = try openValidatedSnapshot(at: url)
        defer { try? database.close() }
        return try inspect(database)
    }

    func restorePreMigrationSnapshot(
        at url: URL,
        to destination: any DatabaseWriter
    ) throws {
        let snapshot = try openValidatedSnapshot(at: url)
        defer { try? snapshot.close() }
        try snapshot.backup(to: destination)
        _ = try validate(destination)
    }

    private func makeSnapshot(
        reason: DatabaseSnapshotReason,
        createdAt: Date
    ) throws -> DatabaseSnapshot {
        let milliseconds = try DatabaseValueCodec.encode(createdAt)
        let filename = "oboe-\(reason.rawValue)-\(milliseconds)-\(UUID().uuidString.lowercased()).sqlite"
        return DatabaseSnapshot(
            url: directoryURL.appendingPathComponent(filename),
            reason: reason,
            createdAt: DatabaseValueCodec.decodeDate(milliseconds: milliseconds)
        )
    }

    private func pruneDailySnapshots() throws {
        let dailySnapshots = try snapshots().filter { $0.reason == .daily }
        for snapshot in dailySnapshots.dropFirst(maximumDailySnapshotCount) {
            try FileManager.default.removeItem(at: snapshot.url)
        }
    }

    private func removeTemporaryDatabaseFiles(at databaseURL: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(
                atPath: databaseURL.path + suffix
            )
        }
    }

    private func validate(_ database: any DatabaseReader) throws -> DatabaseSnapshotValidation {
        try database.read { db in
            let quickCheck = try String.fetchAll(db, sql: "PRAGMA quick_check")
            guard quickCheck == ["ok"] else {
                throw DatabaseSnapshotError.integrityCheckFailed(quickCheck)
            }

            let foreignKeyViolations = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"
            ) ?? 0
            guard foreignKeyViolations == 0 else {
                throw DatabaseSnapshotError.foreignKeyViolations(foreignKeyViolations)
            }

            return try Self.inspect(db)
        }
    }

    private func inspect(_ database: any DatabaseReader) throws -> DatabaseSnapshotValidation {
        try database.read(Self.inspect)
    }

    private static func inspect(_ db: Database) throws -> DatabaseSnapshotValidation {
        let tableNames = Set(try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'"
        ))
        let hasMigrationTable = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'grdb_migrations')"
        ) ?? false
        let migrationIdentifiers: Set<String>
        if hasMigrationTable {
            migrationIdentifiers = Set(try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations"
            ))
        } else {
            migrationIdentifiers = []
        }
        return DatabaseSnapshotValidation(
            tableNames: tableNames,
            appliedMigrationIdentifiers: migrationIdentifiers
        )
    }

    private static func parseSnapshot(_ url: URL) -> DatabaseSnapshot? {
        guard url.pathExtension == "sqlite" else {
            return nil
        }
        let components = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard components.count >= 4,
              components[0] == "oboe",
              let reason = DatabaseSnapshotReason(rawValue: String(components[1])),
              let milliseconds = Int64(components[2]) else {
            return nil
        }
        return DatabaseSnapshot(
            url: url,
            reason: reason,
            createdAt: DatabaseValueCodec.decodeDate(milliseconds: milliseconds)
        )
    }
}
