import Foundation
import GRDB
import OboeDomain

public enum OboeDatabaseLifecycleError: Error, Equatable, Sendable {
    case operationInProgress
    case invalidRestorationSource(String)
    case interruptedRestorationMarker(String)
    case restorationRollbackFailed(
        snapshotURL: URL,
        restorationError: String,
        rollbackError: String
    )
    case migrationRollbackFailed(
        snapshotURL: URL,
        migrationError: String,
        rollbackError: String
    )
}

extension OboeDatabaseLifecycleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "另一个数据库操作仍在进行，请稍后重试。"
        case let .invalidRestorationSource(reason):
            "恢复来源不是可用的 Oboe 数据库：\(reason)"
        case let .interruptedRestorationMarker(reason):
            "无法处理上次中断的恢复：\(reason)"
        case let .restorationRollbackFailed(snapshotURL, restorationError, rollbackError):
            "恢复失败且自动回滚未完成。恢复错误：\(restorationError)；回滚错误：\(rollbackError)。回滚快照保留在 \(snapshotURL.path)。"
        case let .migrationRollbackFailed(snapshotURL, migrationError, rollbackError):
            "数据库迁移失败且自动回滚未完成。迁移错误：\(migrationError)；回滚错误：\(rollbackError)。回滚快照保留在 \(snapshotURL.path)。"
        }
    }
}

enum DatabaseRestorationStage: Sendable {
    case rollbackSnapshotCreated
    case currentDatabaseClosed
    case candidateInstalled
    case replacementValidated
}

public actor OboeDatabaseLifecycle {
    public let databaseURL: URL
    public let snapshotService: DatabaseSnapshotService

    private let migrator: DatabaseMigrator
    private let restorationFaultInjector: @Sendable (DatabaseRestorationStage) throws -> Void
    private var openDatabase: OboeDatabase?
    private var openingTask: Task<OboeDatabase, Error>?
    private var isReplacingDatabase = false
    private var isDatabaseOperationActive = false
    private var databaseOperationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(databaseURL: URL, snapshotDirectoryURL: URL) {
        self.databaseURL = databaseURL
        snapshotService = DatabaseSnapshotService(directoryURL: snapshotDirectoryURL)
        migrator = OboeDatabaseSchema.makeMigrator()
        restorationFaultInjector = { _ in }
    }

    init(
        databaseURL: URL,
        snapshotService: DatabaseSnapshotService,
        migrator: DatabaseMigrator,
        restorationFaultInjector: @escaping @Sendable (DatabaseRestorationStage) throws -> Void = { _ in }
    ) {
        self.databaseURL = databaseURL
        self.snapshotService = snapshotService
        self.migrator = migrator
        self.restorationFaultInjector = restorationFaultInjector
    }

    @discardableResult
    public func open() async throws -> OboeDatabase {
        guard !isReplacingDatabase else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        if let openDatabase {
            return openDatabase
        }
        if let openingTask {
            let database = try await openingTask.value
            openDatabase = database
            self.openingTask = nil
            return database
        }

        let task = Task { [databaseURL, snapshotService, migrator] in
            try await Self.recoverInterruptedRestorationIfNeeded(
                databaseURL: databaseURL,
                snapshotService: snapshotService
            )
            return try await Self.openDatabase(
                at: databaseURL,
                snapshotService: snapshotService,
                migrator: migrator
            )
        }
        openingTask = task

        do {
            let database = try await task.value
            openDatabase = database
            openingTask = nil
            return database
        } catch {
            openingTask = nil
            throw error
        }
    }

    public func currentDatabase() -> OboeDatabase? {
        guard !isReplacingDatabase else {
            return nil
        }
        return openDatabase
    }

    public func close() throws {
        guard openingTask == nil, !isReplacingDatabase, !isDatabaseOperationActive else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        guard let openDatabase else {
            return
        }
        try openDatabase.close()
        self.openDatabase = nil
    }

    @discardableResult
    public func reopen() async throws -> OboeDatabase {
        try close()
        return try await open()
    }

    @discardableResult
    public func createDailySnapshotIfNeeded(
        hasChanges: Bool,
        at createdAt: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> DatabaseSnapshot? {
        await acquireDatabaseOperation()
        defer { releaseDatabaseOperation() }

        let current = try await open()
        return try await snapshotService.createDailySnapshotIfNeeded(
            from: current.pool,
            hasChanges: hasChanges,
            at: createdAt,
            calendar: calendar
        )
    }

    @discardableResult
    public func replaceDatabase(
        with sourceURL: URL,
        beforeCommit: @escaping @Sendable (OboeDatabase) async throws -> Void = { _ in }
    ) async throws -> OboeDatabase {
        guard openingTask == nil, !isReplacingDatabase else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        await acquireDatabaseOperation()
        defer { releaseDatabaseOperation() }

        guard openingTask == nil, !isReplacingDatabase else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        let current = try await open()
        isReplacingDatabase = true
        defer { isReplacingDatabase = false }

        let validation = try await snapshotService.validateSnapshot(at: sourceURL)
        guard validation.appliedMigrationIdentifiers.contains(
            OboeDatabaseSchema.migrationIdentifiers[0]
        ) else {
            throw OboeDatabaseLifecycleError.invalidRestorationSource(
                "缺少基础 schema 迁移标识。"
            )
        }

        // Both files are fully materialized while the current pool remains open.
        // A disk-space failure therefore cannot strand the active database.
        let rollbackSnapshot = try await snapshotService.createSnapshot(
            from: current.pool,
            reason: .restoration
        )
        let token = UUID().uuidString.lowercased()
        let directoryURL = databaseURL.deletingLastPathComponent()
        let candidateURL = directoryURL.appendingPathComponent(
            ".restore-candidate-\(token).sqlite"
        )
        let originalURL = directoryURL.appendingPathComponent(
            ".restore-original-\(token).sqlite"
        )
        do {
            let source = try await snapshotService.openValidatedSnapshot(at: sourceURL)
            defer { try? source.close() }
            let candidate = try DatabaseQueue(path: candidateURL.path)
            do {
                try source.backup(to: candidate)
                try await candidate.writeWithoutTransaction { db in
                    try db.execute(sql: "PRAGMA journal_mode = DELETE")
                }
                try candidate.close()
            } catch {
                try? candidate.close()
                throw error
            }
            _ = try await snapshotService.validateSnapshot(at: candidateURL)
        } catch {
            Self.removeDatabaseFiles(at: candidateURL)
            throw error
        }

        let deviceAISettings = try await Self.readDeviceAISettings(from: current.pool)
        let marker = RestorationMarker(
            version: 1,
            rollbackSnapshotFilename: rollbackSnapshot.url.lastPathComponent,
            candidateFilename: candidateURL.lastPathComponent,
            originalFilename: originalURL.lastPathComponent,
            phase: .rollbackReady
        )
        let markerURL = Self.restorationMarkerURL(for: databaseURL)

        do {
            try Self.writeMarker(marker, to: markerURL)
            try restorationFaultInjector(.rollbackSnapshotCreated)
            try current.close()
            openDatabase = nil
            try restorationFaultInjector(.currentDatabaseClosed)

            Self.removeSidecarFiles(at: databaseURL)
            try FileManager.default.moveItem(at: databaseURL, to: originalURL)
            try FileManager.default.moveItem(at: candidateURL, to: databaseURL)
            try Self.writeMarker(marker.withPhase(.candidateInstalled), to: markerURL)
            try restorationFaultInjector(.candidateInstalled)

            let replacement = try await Self.openDatabase(
                at: databaseURL,
                snapshotService: snapshotService,
                migrator: migrator
            )
            openDatabase = replacement
            try await Self.finishRestoration(
                database: replacement,
                deviceAISettings: deviceAISettings
            )
            try await beforeCommit(replacement)
            try restorationFaultInjector(.replacementValidated)

            Self.removeDatabaseFiles(at: originalURL)
            try? FileManager.default.removeItem(at: markerURL)
            return replacement
        } catch {
            let restorationError = error
            try? openDatabase?.close()
            openDatabase = nil
            do {
                try await Self.installRollbackSnapshot(
                    rollbackSnapshot.url,
                    at: databaseURL,
                    snapshotService: snapshotService
                )
                let restored = try await Self.openDatabase(
                    at: databaseURL,
                    snapshotService: snapshotService,
                    migrator: migrator
                )
                openDatabase = restored
                Self.removeDatabaseFiles(at: candidateURL)
                Self.removeDatabaseFiles(at: originalURL)
                try? FileManager.default.removeItem(at: markerURL)
            } catch {
                let rollbackError = error
                throw OboeDatabaseLifecycleError.restorationRollbackFailed(
                    snapshotURL: rollbackSnapshot.url,
                    restorationError: String(describing: restorationError),
                    rollbackError: String(describing: rollbackError)
                )
            }
            throw restorationError
        }
    }

    private func acquireDatabaseOperation() async {
        guard isDatabaseOperationActive else {
            isDatabaseOperationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            databaseOperationWaiters.append(continuation)
        }
    }

    private func releaseDatabaseOperation() {
        guard !databaseOperationWaiters.isEmpty else {
            isDatabaseOperationActive = false
            return
        }
        let next = databaseOperationWaiters.removeFirst()
        next.resume()
    }

    private static func openDatabase(
        at databaseURL: URL,
        snapshotService: DatabaseSnapshotService,
        migrator: DatabaseMigrator
    ) async throws -> OboeDatabase {
        let existedBeforeOpen = try hasExistingDatabaseFile(at: databaseURL)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try OboeDatabase.openPool(path: databaseURL.path)
        var preMigrationSnapshot: DatabaseSnapshot?

        do {
            let needsMigration = try await pool.read { db in
                try !migrator.hasCompletedMigrations(db)
            }
            if existedBeforeOpen && needsMigration {
                preMigrationSnapshot = try await snapshotService.createSnapshot(
                    from: pool,
                    reason: .migration
                )
            }

            try migrator.migrate(pool)
            return OboeDatabase(pool: pool)
        } catch {
            let openingError = error
            if let preMigrationSnapshot {
                do {
                    try await snapshotService.restorePreMigrationSnapshot(
                        at: preMigrationSnapshot.url,
                        to: pool
                    )
                } catch {
                    let rollbackError = error
                    try? pool.close()
                    throw OboeDatabaseLifecycleError.migrationRollbackFailed(
                        snapshotURL: preMigrationSnapshot.url,
                        migrationError: String(describing: openingError),
                        rollbackError: String(describing: rollbackError)
                    )
                }
            }
            try? pool.close()
            throw openingError
        }
    }

    private static func recoverInterruptedRestorationIfNeeded(
        databaseURL: URL,
        snapshotService: DatabaseSnapshotService
    ) async throws {
        let markerURL = restorationMarkerURL(for: databaseURL)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            return
        }
        let marker: RestorationMarker
        do {
            marker = try JSONDecoder().decode(
                RestorationMarker.self,
                from: Data(contentsOf: markerURL)
            )
            try marker.validateFilenames()
        } catch {
            throw OboeDatabaseLifecycleError.interruptedRestorationMarker(
                String(describing: error)
            )
        }
        let rollbackURL = snapshotService.directoryURL.appendingPathComponent(
            marker.rollbackSnapshotFilename
        )
        try await installRollbackSnapshot(
            rollbackURL,
            at: databaseURL,
            snapshotService: snapshotService
        )
        let directoryURL = databaseURL.deletingLastPathComponent()
        removeDatabaseFiles(
            at: directoryURL.appendingPathComponent(marker.candidateFilename)
        )
        removeDatabaseFiles(
            at: directoryURL.appendingPathComponent(marker.originalFilename)
        )
        try? FileManager.default.removeItem(at: markerURL)
    }

    private static func installRollbackSnapshot(
        _ snapshotURL: URL,
        at databaseURL: URL,
        snapshotService: DatabaseSnapshotService
    ) async throws {
        _ = try await snapshotService.validateSnapshot(at: snapshotURL)
        let pendingURL = databaseURL.deletingLastPathComponent().appendingPathComponent(
            ".rollback-install-\(UUID().uuidString.lowercased()).sqlite"
        )
        do {
            try FileManager.default.copyItem(at: snapshotURL, to: pendingURL)
            _ = try await snapshotService.validateSnapshot(at: pendingURL)
            removeDatabaseFiles(at: databaseURL)
            try FileManager.default.moveItem(at: pendingURL, to: databaseURL)
        } catch {
            removeDatabaseFiles(at: pendingURL)
            throw error
        }
    }

    private static func finishRestoration(
        database: OboeDatabase,
        deviceAISettings: DeviceAISettings?
    ) async throws {
        try await database.pool.write { db in
            if let deviceAISettings {
                try db.execute(
                    sql: """
                        UPDATE app_settings
                        SET ai_enabled = ?, ai_provider_id = ?, ai_service_name = ?,
                            ai_base_url = ?, ai_model_id = ?, ai_credential_id = ?,
                            ai_response_format_mode = ?
                        WHERE id = 1
                        """,
                    arguments: [
                        deviceAISettings.isEnabled,
                        deviceAISettings.providerID,
                        deviceAISettings.serviceName,
                        deviceAISettings.baseURL,
                        deviceAISettings.modelID,
                        deviceAISettings.credentialID,
                        deviceAISettings.responseFormatMode
                    ]
                )
            }

            try db.execute(sql: "DELETE FROM search_documents")
            let notes = try Row.fetchAll(
                db,
                sql: "SELECT id, headword, reading, meaning_zh FROM notes"
            )
            for note in notes {
                let noteID: String = note["id"]
                let headword: String = note["headword"]
                let reading: String? = note["reading"]
                let meaning: String = note["meaning_zh"]
                try db.execute(
                    sql: """
                        INSERT INTO search_documents(
                            note_id, normalized_headword, normalized_reading, normalized_meaning
                        ) VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        noteID,
                        SearchTextNormalizer.normalize(headword),
                        SearchTextNormalizer.normalize(reading ?? ""),
                        SearchTextNormalizer.normalize(meaning)
                    ]
                )
            }

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
        }
    }

    private static func readDeviceAISettings(
        from database: any DatabaseReader
    ) async throws -> DeviceAISettings? {
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT ai_enabled, ai_provider_id, ai_service_name, ai_base_url,
                           ai_model_id, ai_credential_id, ai_response_format_mode
                    FROM app_settings WHERE id = 1
                    """
            ) else {
                return nil
            }
            return DeviceAISettings(
                isEnabled: row["ai_enabled"],
                providerID: row["ai_provider_id"],
                serviceName: row["ai_service_name"],
                baseURL: row["ai_base_url"],
                modelID: row["ai_model_id"],
                credentialID: row["ai_credential_id"],
                responseFormatMode: row["ai_response_format_mode"]
            )
        }
    }

    private static func restorationMarkerURL(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(
            ".oboe-restoration-state.json"
        )
    }

    private static func writeMarker(_ marker: RestorationMarker, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: url, options: .atomic)
    }

    private static func removeSidecarFiles(at databaseURL: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
    }

    private static func removeDatabaseFiles(at databaseURL: URL) {
        try? FileManager.default.removeItem(at: databaseURL)
        removeSidecarFiles(at: databaseURL)
    }

    private static func hasExistingDatabaseFile(at databaseURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return false
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0
    }
}

private struct DeviceAISettings: Sendable {
    let isEnabled: Bool
    let providerID: String?
    let serviceName: String?
    let baseURL: String?
    let modelID: String?
    let credentialID: String?
    let responseFormatMode: String
}

private struct RestorationMarker: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case rollbackReady
        case candidateInstalled
    }

    let version: Int
    let rollbackSnapshotFilename: String
    let candidateFilename: String
    let originalFilename: String
    let phase: Phase

    func withPhase(_ phase: Phase) -> Self {
        Self(
            version: version,
            rollbackSnapshotFilename: rollbackSnapshotFilename,
            candidateFilename: candidateFilename,
            originalFilename: originalFilename,
            phase: phase
        )
    }

    func validateFilenames() throws {
        guard version == 1,
              Self.isSafeFilename(rollbackSnapshotFilename),
              Self.isSafeFilename(candidateFilename),
              Self.isSafeFilename(originalFilename) else {
            throw OboeDatabaseLifecycleError.interruptedRestorationMarker(
                "标记版本或文件名无效。"
            )
        }
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename == URL(fileURLWithPath: filename).lastPathComponent
            && !filename.contains("/")
            && !filename.contains("\\")
    }
}
