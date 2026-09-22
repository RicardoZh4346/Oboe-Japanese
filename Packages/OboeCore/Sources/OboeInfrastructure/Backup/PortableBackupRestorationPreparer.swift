import CoreFoundation
import CryptoKit
import Foundation
import GRDB
import OboeDomain

public struct PortableBackupPreparationLimits: Equatable, Sendable {
    public let maximumFileBytes: Int64
    public let maximumLineBytes: Int
    public let maximumRecordCount: Int
    public let maximumStringBytes: Int

    public init(
        maximumFileBytes: Int64 = 200 * 1_024 * 1_024,
        maximumLineBytes: Int = 1_024 * 1_024,
        maximumRecordCount: Int = 1_000_000,
        maximumStringBytes: Int = 512 * 1_024
    ) {
        precondition(maximumFileBytes > 0)
        precondition(maximumLineBytes > 0)
        precondition(maximumRecordCount > 0)
        precondition(maximumStringBytes > 0)
        self.maximumFileBytes = maximumFileBytes
        self.maximumLineBytes = maximumLineBytes
        self.maximumRecordCount = maximumRecordCount
        self.maximumStringBytes = maximumStringBytes
    }
}

public struct PortableBackupDataSummary: Equatable, Sendable {
    public let recordCounts: [String: Int]
    public let processingInboxItemCount: Int

    public init(
        recordCounts: [String: Int],
        processingInboxItemCount: Int = 0
    ) {
        self.recordCounts = recordCounts
        self.processingInboxItemCount = processingInboxItemCount
    }

    public var deckCount: Int { recordCounts["deck", default: 0] }
    public var noteCount: Int { recordCounts["note", default: 0] }
    public var cardCount: Int { recordCounts["card", default: 0] }
    public var reviewCount: Int { recordCounts["review", default: 0] }
    public var draftCount: Int { recordCounts["draft", default: 0] }
    public var inboxItemCount: Int { recordCounts["inboxItem", default: 0] }
    public var processingContextCount: Int {
        recordCounts["inboxProcessingContext", default: 0]
    }
    public var captureImportReceiptCount: Int {
        recordCounts["captureImportReceipt", default: 0]
    }
    public var inboxCommitReceiptCount: Int {
        recordCounts["inboxCommitReceipt", default: 0]
    }
}

public struct PreparedRestoration: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let temporaryDatabaseURL: URL
    public let sourceFilename: String
    public let sourceFormatVersion: Int
    public let preparedFormatVersion: Int
    public let sourceAppVersion: String
    public let exportedAt: Date
    public let backup: PortableBackupDataSummary
    public let current: PortableBackupDataSummary
    public let excludedScopes: [String]

    public init(
        id: UUID,
        temporaryDatabaseURL: URL,
        sourceFilename: String,
        sourceFormatVersion: Int,
        preparedFormatVersion: Int,
        sourceAppVersion: String,
        exportedAt: Date,
        backup: PortableBackupDataSummary,
        current: PortableBackupDataSummary,
        excludedScopes: [String] = []
    ) {
        self.id = id
        self.temporaryDatabaseURL = temporaryDatabaseURL
        self.sourceFilename = sourceFilename
        self.sourceFormatVersion = sourceFormatVersion
        self.preparedFormatVersion = preparedFormatVersion
        self.sourceAppVersion = sourceAppVersion
        self.exportedAt = exportedAt
        self.backup = backup
        self.current = current
        self.excludedScopes = excludedScopes
    }

    /// Only the v3 contract carries Inbox records — restoring a v1/v2 backup
    /// means the Inbox becomes empty, which the preview must state clearly.
    public var restoresInboxData: Bool {
        sourceFormatVersion >= 3
    }
}

public enum PortableBackupPreparationError: Error, Equatable, Sendable {
    case fileTooLarge(actual: Int64, limit: Int64)
    case emptyFile
    case lineTooLarge(line: Int, limit: Int)
    case missingFinalLineFeed
    case invalidLineEnding(line: Int)
    case invalidUTF8(line: Int)
    case invalidJSON(line: Int)
    case invalidManifest(String)
    case unsupportedFormatVersion(Int)
    case futureFormatVersion(Int)
    case tooManyRecords(declared: Int, limit: Int)
    case unexpectedRecordType(line: Int, type: String)
    case invalidRecordOrder(line: Int, type: String)
    case invalidRecord(line: Int, reason: String)
    case missingFooter
    case trailingContentAfterFooter
    case countMismatch(type: String, expected: Int, actual: Int)
    case invalidChecksum
    case unsupportedAlgorithmVersion(String)
    case databaseValidation(String)
}

extension PortableBackupPreparationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .fileTooLarge(actual, limit):
            "备份文件过大（\(actual) 字节，上限 \(limit) 字节）。"
        case .emptyFile:
            "备份文件为空。"
        case let .lineTooLarge(line, limit):
            "备份第 \(line) 行超过 \(limit) 字节上限。"
        case .missingFinalLineFeed:
            "备份没有使用规定的 LF 文件结尾。"
        case let .invalidLineEnding(line):
            "备份第 \(line) 行不是规定的 LF 行尾。"
        case let .invalidUTF8(line):
            "备份第 \(line) 行不是有效 UTF-8。"
        case let .invalidJSON(line):
            "备份第 \(line) 行不是有效 JSON 对象。"
        case let .invalidManifest(reason):
            "备份 manifest 无效：\(reason)"
        case let .unsupportedFormatVersion(version):
            "不支持备份格式版本 \(version)。"
        case let .futureFormatVersion(version):
            "备份格式版本 \(version) 比当前应用新，请升级 Oboe。"
        case let .tooManyRecords(declared, limit):
            "备份声明 \(declared) 条记录，超过 \(limit) 条上限。"
        case let .unexpectedRecordType(line, type):
            "备份第 \(line) 行包含未知记录类型 \(type)。"
        case let .invalidRecordOrder(line, type):
            "备份第 \(line) 行的 \(type) 记录顺序无效。"
        case let .invalidRecord(line, reason):
            "备份第 \(line) 行无效：\(reason)"
        case .missingFooter:
            "备份缺少校验尾行。"
        case .trailingContentAfterFooter:
            "备份校验尾行之后仍有内容。"
        case let .countMismatch(type, expected, actual):
            "备份 \(type) 数量不符（声明 \(expected)，实际 \(actual)）。"
        case .invalidChecksum:
            "备份 SHA-256 校验失败，文件可能已损坏。"
        case let .unsupportedAlgorithmVersion(version):
            "不支持调度算法版本 \(version)。"
        case let .databaseValidation(reason):
            "临时恢复库校验失败：\(reason)"
        }
    }
}

public actor PortableBackupRestorationPreparer {
    private let currentDatabase: OboeDatabase
    private let workingDirectoryURL: URL
    private let limits: PortableBackupPreparationLimits
    private let inboxImageResourceExists: @Sendable (String) -> Bool

    public init(
        currentDatabase: OboeDatabase,
        workingDirectoryURL: URL,
        limits: PortableBackupPreparationLimits = PortableBackupPreparationLimits(),
        inboxImageResourceExists: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.currentDatabase = currentDatabase
        self.workingDirectoryURL = workingDirectoryURL
        self.limits = limits
        self.inboxImageResourceExists = inboxImageResourceExists
    }

    public func prepare(fileURL: URL) async throws -> PreparedRestoration {
        try Task.checkCancellation()
        let size = try Self.fileSize(at: fileURL)
        guard size <= limits.maximumFileBytes else {
            throw PortableBackupPreparationError.fileTooLarge(
                actual: size,
                limit: limits.maximumFileBytes
            )
        }
        guard size > 0 else {
            throw PortableBackupPreparationError.emptyFile
        }

        try FileManager.default.createDirectory(
            at: workingDirectoryURL,
            withIntermediateDirectories: true
        )
        try removeAbandonedPreparationFiles()

        let preparationID = UUID()
        let pendingURL = workingDirectoryURL.appendingPathComponent(
            ".preparing-\(preparationID.uuidString.lowercased()).sqlite"
        )
        let preparedURL = workingDirectoryURL.appendingPathComponent(
            "prepared-\(preparationID.uuidString.lowercased()).sqlite"
        )
        let temporaryDatabase = try OboeDatabase(path: pendingURL.path)

        do {
            let manifest = try await temporaryDatabase.pool.write { db in
                let manifest = try Self.parseAndImport(
                    fileURL: fileURL,
                    into: db,
                    limits: limits
                )
                // v1–v5 备份没有 noteDeck 记录：导入后按 home deck 合成
                // 每个 Note 的初始 membership（设计 §9）。v6 文件必须自带
                // 完整成员关系，由 validateNoteDeckData 严格校验。
                if manifest.sourceFormatVersion < 6 {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO note_decks(note_id, deck_id, added_at_ms)
                        SELECT id, deck_id, created_at_ms FROM notes
                        """)
                }
                try Self.finalizeImportedInboxData(
                    in: db,
                    resourceExists: inboxImageResourceExists
                )
                try Self.finalizeImportedDraftData(in: db)
                // v12：旧备份可能只含部分方向卡——恢复的库已越过迁移点，
                // 这里重跑同一补齐逻辑，保证词汇词条三方向齐全。
                try OboeDatabaseSchema.fillVocabularyDirections(db)
                return manifest
            }
            try Task.checkCancellation()
            let backupSummary = try await temporaryDatabase.pool.read { db in
                try Self.validateAndSummarizeImportedDatabase(db)
            }
            let currentSummary = try await currentDatabase.pool.read { db in
                try Self.summarizeDatabase(db)
            }
            let preparedDatabase = try DatabaseQueue(path: preparedURL.path)
            do {
                try temporaryDatabase.pool.backup(to: preparedDatabase)
                try await preparedDatabase.writeWithoutTransaction { db in
                    try db.execute(sql: "PRAGMA journal_mode = DELETE")
                }
                _ = try await preparedDatabase.read { db in
                    try Self.validateAndSummarizeImportedDatabase(db)
                }
                try preparedDatabase.close()
                try Task.checkCancellation()
            } catch {
                try? preparedDatabase.close()
                throw error
            }
            try temporaryDatabase.close()
            Self.removeDatabaseFiles(at: pendingURL)

            return PreparedRestoration(
                id: preparationID,
                temporaryDatabaseURL: preparedURL,
                sourceFilename: fileURL.lastPathComponent,
                sourceFormatVersion: manifest.sourceFormatVersion,
                preparedFormatVersion: PortableBackupFormat.currentVersion,
                sourceAppVersion: manifest.appVersion,
                exportedAt: manifest.exportedAt,
                backup: backupSummary,
                current: currentSummary,
                excludedScopes: manifest.excludedScopes
            )
        } catch {
            try? temporaryDatabase.close()
            Self.removeDatabaseFiles(at: pendingURL)
            Self.removeDatabaseFiles(at: preparedURL)
            throw error
        }
    }

    public func discard(_ preparation: PreparedRestoration) throws {
        guard preparation.temporaryDatabaseURL.deletingLastPathComponent().standardizedFileURL
                == workingDirectoryURL.standardizedFileURL,
              preparation.temporaryDatabaseURL.lastPathComponent.hasPrefix("prepared-") else {
            return
        }
        Self.removeDatabaseFiles(at: preparation.temporaryDatabaseURL)
    }

    private func removeAbandonedPreparationFiles() throws {
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: workingDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.lastPathComponent.hasPrefix("prepared-") {
            Self.removeDatabaseFiles(at: url)
        }
        // `.skipsHiddenFiles` intentionally omits in-progress files, so scan the
        // names explicitly as well to clean up a preparation interrupted by exit.
        let allURLs = try fileManager.contentsOfDirectory(
            at: workingDirectoryURL,
            includingPropertiesForKeys: nil
        )
        for url in allURLs where url.lastPathComponent.hasPrefix(".preparing-") {
            Self.removeDatabaseFiles(at: url)
        }
    }
}

private extension PortableBackupRestorationPreparer {
    struct ParsedManifest: Sendable {
        let sourceFormatVersion: Int
        let appVersion: String
        let exportedAt: Date
        let counts: [String: Int]
        let excludedScopes: [String]
    }

    struct ColumnMetadata: Sendable {
        enum Storage: Sendable {
            case integer
            case real
            case text
        }

        let storage: Storage
        let isRequired: Bool
    }

    struct BoundedLineReader {
        private let handle: FileHandle
        private let maximumLineBytes: Int
        private var buffer = Data()
        private var reachedEnd = false

        init(url: URL, maximumLineBytes: Int) throws {
            handle = try FileHandle(forReadingFrom: url)
            self.maximumLineBytes = maximumLineBytes
        }

        func close() {
            try? handle.close()
        }

        mutating func nextLine(lineNumber: Int) throws -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let end = buffer.index(after: newline)
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(..<end)
                    guard line.count <= maximumLineBytes else {
                        throw PortableBackupPreparationError.lineTooLarge(
                            line: lineNumber,
                            limit: maximumLineBytes
                        )
                    }
                    return line
                }
                if reachedEnd {
                    guard buffer.isEmpty else {
                        throw PortableBackupPreparationError.missingFinalLineFeed
                    }
                    return nil
                }
                let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
                if chunk.isEmpty {
                    reachedEnd = true
                } else {
                    buffer.append(chunk)
                    guard buffer.firstIndex(of: 0x0A) != nil
                            || buffer.count <= maximumLineBytes else {
                        throw PortableBackupPreparationError.lineTooLarge(
                            line: lineNumber,
                            limit: maximumLineBytes
                        )
                    }
                }
            }
        }
    }

    static let manifestKeys: Set<String> = [
        "recordType", "format", "formatVersion", "appVersion", "exportedAt",
        "encoding", "lineEnding", "checksumAlgorithm", "recordOrder", "counts"
    ]
    static let manifestKeysV3: Set<String> = manifestKeys.union(["excludedScopes"])
    static let footerKeys: Set<String> = ["recordType", "checksumAlgorithm", "checksum"]
    static let uuidColumns: Set<String> = [
        "decks.id", "notes.id", "notes.deck_id", "examples.id", "examples.note_id",
        "tags.id", "note_tags.note_id", "note_tags.tag_id", "scheduler_profiles.id",
        "cards.id", "cards.note_id", "cards.profile_id", "study_days.id",
        "daily_tasks.study_day_id", "daily_tasks.card_id", "review_logs.id",
        "review_logs.event_id", "review_logs.card_id", "review_logs.card_key",
        "review_logs.note_id", "review_logs.deck_id_at_review", "review_logs.study_day_id",
        "review_logs.profile_id", "drafts.id",
        "inbox_items.id",
        "inbox_processing_contexts.id", "inbox_processing_contexts.inbox_item_id",
        "inbox_processing_contexts.draft_id",
        "capture_import_receipts.capture_id", "capture_import_receipts.inbox_item_id",
        "inbox_commit_receipts.operation_id", "inbox_commit_receipts.processing_context_id",
        "note_decks.note_id", "note_decks.deck_id"
    ]

    static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func parseAndImport(
        fileURL: URL,
        into db: Database,
        limits: PortableBackupPreparationLimits
    ) throws -> ParsedManifest {
        var reader = try BoundedLineReader(
            url: fileURL,
            maximumLineBytes: limits.maximumLineBytes
        )
        defer { reader.close() }
        var lineNumber = 1
        guard let manifestLine = try reader.nextLine(lineNumber: lineNumber) else {
            throw PortableBackupPreparationError.emptyFile
        }
        let manifestObject = try jsonObject(from: manifestLine, lineNumber: lineNumber)
        let manifest = try parseManifest(manifestObject, limits: limits)
        let sourceSpecifications: [PortableBackupTableSpecification]
        switch manifest.sourceFormatVersion {
        case 1: sourceSpecifications = PortableBackupFormatV1.tableSpecifications
        case 2: sourceSpecifications = PortableBackupFormatV2.tableSpecifications
        case 3: sourceSpecifications = PortableBackupFormatV3.tableSpecifications
        case 4: sourceSpecifications = PortableBackupFormatV4.tableSpecifications
        case 5: sourceSpecifications = PortableBackupFormatV5.tableSpecifications
        case 6: sourceSpecifications = PortableBackupFormatV6.tableSpecifications
        default:
            throw PortableBackupPreparationError.unsupportedFormatVersion(
                manifest.sourceFormatVersion
            )
        }
        let sourceRecordTypes = sourceSpecifications.map(\.recordType)
        let sourceSpecificationByType = Dictionary(
            uniqueKeysWithValues: sourceSpecifications.map { ($0.recordType, $0) }
        )
        var hasher = SHA256()
        hasher.update(data: manifestLine)

        let metadata = try loadColumnMetadata(in: db)
        var actualCounts = Dictionary(
            uniqueKeysWithValues: sourceRecordTypes.map { ($0, 0) }
        )
        var lastRecordIndex = -1
        var actualTotal = 0

        while true {
            try Task.checkCancellation()
            lineNumber += 1
            guard let line = try reader.nextLine(lineNumber: lineNumber) else {
                throw PortableBackupPreparationError.missingFooter
            }
            let object = try jsonObject(from: line, lineNumber: lineNumber)
            let recordType = try requiredString(
                object["recordType"],
                field: "recordType",
                context: "第 \(lineNumber) 行"
            )
            if recordType == "footer" {
                guard try reader.nextLine(lineNumber: lineNumber + 1) == nil else {
                    throw PortableBackupPreparationError.trailingContentAfterFooter
                }
                try validateFooter(object, checksum: hasher.finalize())
                for type in sourceRecordTypes {
                    let expected = manifest.counts[type, default: 0]
                    let actual = actualCounts[type, default: 0]
                    guard expected == actual else {
                        throw PortableBackupPreparationError.countMismatch(
                            type: type,
                            expected: expected,
                            actual: actual
                        )
                    }
                }
                return manifest
            }

            guard let sourceSpecification = sourceSpecificationByType[recordType],
                  let currentSpecification = PortableBackupFormatV6.specificationByRecordType[recordType],
                  let recordIndex = sourceRecordTypes.firstIndex(of: recordType) else {
                throw PortableBackupPreparationError.unexpectedRecordType(
                    line: lineNumber,
                    type: recordType
                )
            }
            guard recordIndex >= lastRecordIndex else {
                throw PortableBackupPreparationError.invalidRecordOrder(
                    line: lineNumber,
                    type: recordType
                )
            }
            lastRecordIndex = recordIndex
            actualTotal += 1
            guard actualTotal <= limits.maximumRecordCount else {
                throw PortableBackupPreparationError.tooManyRecords(
                    declared: actualTotal,
                    limit: limits.maximumRecordCount
                )
            }

            hasher.update(data: line)
            guard Set(object.keys) == Set(sourceSpecification.columns).union(["recordType"]) else {
                throw PortableBackupPreparationError.invalidRecord(
                    line: lineNumber,
                    reason: "\(recordType) 字段集合不符合 v\(manifest.sourceFormatVersion)。"
                )
            }
            let migratedObject = try migrateRecordToCurrentFormat(
                object,
                sourceVersion: manifest.sourceFormatVersion
            )
            do {
                try insert(
                    migratedObject,
                    specification: currentSpecification,
                    sourceFormatVersion: manifest.sourceFormatVersion,
                    metadata: metadata[currentSpecification.tableName, default: [:]],
                    lineNumber: lineNumber,
                    limits: limits,
                    in: db
                )
            } catch let error as PortableBackupPreparationError {
                throw error
            } catch {
                throw PortableBackupPreparationError.invalidRecord(
                    line: lineNumber,
                    reason: String(describing: error)
                )
            }
            actualCounts[recordType, default: 0] += 1
        }
    }

    static func parseManifest(
        _ object: [String: Any],
        limits: PortableBackupPreparationLimits
    ) throws -> ParsedManifest {
        // A higher-than-current format is rejected on version alone — its field
        // contract is unknown by definition. At or below currentVersion the key
        // set must match the declared version exactly (v3+ adds excludedScopes).
        if let peeked = object["formatVersion"] as? Int,
           peeked > PortableBackupFormat.currentVersion {
            throw PortableBackupPreparationError.futureFormatVersion(peeked)
        }
        let expectedKeys = (object["formatVersion"] as? Int ?? 0) >= 3
            ? manifestKeysV3
            : manifestKeys
        guard Set(object.keys) == expectedKeys else {
            throw PortableBackupPreparationError.invalidManifest("字段集合不符合清单契约。")
        }
        guard try requiredString(object["recordType"], field: "recordType", context: "manifest")
                == "manifest",
              try requiredString(object["format"], field: "format", context: "manifest")
                == PortableBackupFormat.identifier,
              try requiredString(object["encoding"], field: "encoding", context: "manifest")
                == "utf-8",
              try requiredString(object["lineEnding"], field: "lineEnding", context: "manifest")
                == "lf",
              try requiredString(
                object["checksumAlgorithm"],
                field: "checksumAlgorithm",
                context: "manifest"
              ) == PortableBackupFormat.checksumAlgorithm else {
            throw PortableBackupPreparationError.invalidManifest("格式标识或编码约定不受支持。")
        }

        let version = try requiredInteger(
            object["formatVersion"],
            field: "formatVersion",
            context: "manifest"
        )
        try validateMigrationPath(from: version)
        let appVersion = try requiredString(
            object["appVersion"],
            field: "appVersion",
            context: "manifest"
        )
        try validateStringLength(appVersion, field: "appVersion", limits: limits)
        let exportedAtString = try requiredString(
            object["exportedAt"],
            field: "exportedAt",
            context: "manifest"
        )
        try validateStringLength(exportedAtString, field: "exportedAt", limits: limits)
        guard let exportedAt = iso8601Date(from: exportedAtString) else {
            throw PortableBackupPreparationError.invalidManifest("exportedAt 不是有效 UTC ISO 8601。")
        }
        let expectedRecordTypes: [String]
        switch version {
        case 1: expectedRecordTypes = PortableBackupFormatV1.recordTypes
        case 2: expectedRecordTypes = PortableBackupFormatV2.recordTypes
        case 3: expectedRecordTypes = PortableBackupFormatV3.recordTypes
        case 4: expectedRecordTypes = PortableBackupFormatV4.recordTypes
        case 5: expectedRecordTypes = PortableBackupFormatV5.recordTypes
        case 6: expectedRecordTypes = PortableBackupFormatV6.recordTypes
        default:
            throw PortableBackupPreparationError.unsupportedFormatVersion(version)
        }
        guard let recordOrder = object["recordOrder"] as? [String],
              recordOrder == expectedRecordTypes else {
            throw PortableBackupPreparationError.invalidManifest("recordOrder 不符合 v\(version)。")
        }
        guard let rawCounts = object["counts"] as? [String: Any],
              Set(rawCounts.keys) == Set(expectedRecordTypes) else {
            throw PortableBackupPreparationError.invalidManifest("counts 未完整列出 v\(version) 记录类型。")
        }
        var counts: [String: Int] = [:]
        var total = 0
        for type in expectedRecordTypes {
            let count = try requiredInteger(rawCounts[type], field: type, context: "counts")
            guard count >= 0 else {
                throw PortableBackupPreparationError.invalidManifest("\(type) 数量不能为负。")
            }
            let (newTotal, overflow) = total.addingReportingOverflow(count)
            guard !overflow else {
                throw PortableBackupPreparationError.invalidManifest("记录总数溢出。")
            }
            total = newTotal
            counts[type] = count
        }
        guard total <= limits.maximumRecordCount else {
            throw PortableBackupPreparationError.tooManyRecords(
                declared: total,
                limit: limits.maximumRecordCount
            )
        }
        var excludedScopes: [String] = []
        if version >= 3 {
            guard let scopes = object["excludedScopes"] as? [String],
                  scopes.allSatisfy({ !$0.isEmpty }) else {
                throw PortableBackupPreparationError.invalidManifest(
                    "excludedScopes 必须是非空字符串数组。"
                )
            }
            excludedScopes = scopes
        }
        return ParsedManifest(
            sourceFormatVersion: version,
            appVersion: appVersion,
            exportedAt: exportedAt,
            counts: counts,
            excludedScopes: excludedScopes
        )
    }

    static func validateMigrationPath(from version: Int) throws {
        if version > PortableBackupFormat.currentVersion {
            throw PortableBackupPreparationError.futureFormatVersion(version)
        }
        guard version >= 1 else {
            throw PortableBackupPreparationError.unsupportedFormatVersion(version)
        }
    }

    static func migrateRecordToCurrentFormat(
        _ object: [String: Any],
        sourceVersion: Int
    ) throws -> [String: Any] {
        try validateMigrationPath(from: sourceVersion)
        var migrated = object
        if sourceVersion == 1, migrated["recordType"] as? String == "note" {
            migrated["source_ref"] = NSNull()
        }
        if sourceVersion < 6, migrated["recordType"] as? String == "note" {
            // v1–v5 备份没有音调列；v6 起 `pitch_accent` 是必填字段位。
            migrated["pitch_accent"] = NSNull()
        }
        if sourceVersion < 5, migrated["recordType"] as? String == "settings" {
            migrated["primary_deck_id"] = NSNull()
        }
        if sourceVersion < 4, migrated["recordType"] as? String == "settings" {
            // v1–v3 backups predate the Adaptive toggles: fill the current
            // `AdaptivePreferences.defaults`（v0.5.5 起 ON/ON/ON/ON）so the row
            // satisfies the current settings contract. v4+ 记录保留原值。
            let defaults = AdaptivePreferences.defaults
            migrated["typed_answer_zh_ja"] = defaults.typedAnswerChineseToJapanese ? 1 : 0
            migrated["auto_play_listening_audio"] = defaults.autoPlayListeningAudio ? 1 : 0
            migrated["typed_answer_listening"] = defaults.typedAnswerListening ? 1 : 0
            migrated["leech_reminders_enabled"] = defaults.leechRemindersEnabled ? 1 : 0
        }
        return migrated
    }

    static func validateFooter(_ object: [String: Any], checksum: SHA256.Digest) throws {
        guard Set(object.keys) == footerKeys,
              try requiredString(object["recordType"], field: "recordType", context: "footer")
                == "footer",
              try requiredString(
                object["checksumAlgorithm"],
                field: "checksumAlgorithm",
                context: "footer"
              ) == PortableBackupFormat.checksumAlgorithm else {
            throw PortableBackupPreparationError.invalidChecksum
        }
        let expected = checksum.map { String(format: "%02x", $0) }.joined()
        let actual = try requiredString(object["checksum"], field: "checksum", context: "footer")
        guard actual.count == 64, actual == expected else {
            throw PortableBackupPreparationError.invalidChecksum
        }
    }

    static func jsonObject(from line: Data, lineNumber: Int) throws -> [String: Any] {
        guard line.last == 0x0A else {
            throw PortableBackupPreparationError.missingFinalLineFeed
        }
        let payload = line.dropLast()
        guard payload.last != 0x0D else {
            throw PortableBackupPreparationError.invalidLineEnding(line: lineNumber)
        }
        guard String(data: payload, encoding: .utf8) != nil else {
            throw PortableBackupPreparationError.invalidUTF8(line: lineNumber)
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(payload))
                    as? [String: Any] else {
                throw PortableBackupPreparationError.invalidJSON(line: lineNumber)
            }
            return object
        } catch let error as PortableBackupPreparationError {
            throw error
        } catch {
            throw PortableBackupPreparationError.invalidJSON(line: lineNumber)
        }
    }

    static func loadColumnMetadata(
        in db: Database
    ) throws -> [String: [String: ColumnMetadata]] {
        var result: [String: [String: ColumnMetadata]] = [:]
        for specification in PortableBackupFormatV6.tableSpecifications {
            let rows = try Row.fetchAll(
                db,
                sql: "PRAGMA table_info(\(specification.tableName))"
            )
            var columns: [String: ColumnMetadata] = [:]
            for row in rows {
                let name: String = row["name"]
                let declaredType: String = row["type"]
                let storage: ColumnMetadata.Storage
                switch declaredType.uppercased() {
                case "INTEGER": storage = .integer
                case "REAL": storage = .real
                case "TEXT": storage = .text
                default:
                    throw PortableBackupPreparationError.databaseValidation(
                        "无法识别 \(specification.tableName).\(name) 的字段类型。"
                    )
                }
                columns[name] = ColumnMetadata(
                    storage: storage,
                    isRequired: (row["notnull"] as Int) == 1
                )
            }
            result[specification.tableName] = columns
        }
        return result
    }

    static func insert(
        _ object: [String: Any],
        specification: PortableBackupTableSpecification,
        sourceFormatVersion: Int,
        metadata: [String: ColumnMetadata],
        lineNumber: Int,
        limits: PortableBackupPreparationLimits,
        in db: Database
    ) throws {
        let expectedKeys = Set(specification.columns).union(["recordType"])
        guard Set(object.keys) == expectedKeys else {
            throw PortableBackupPreparationError.invalidRecord(
                line: lineNumber,
                reason: "\(specification.recordType) 字段集合不符合 v\(sourceFormatVersion)。"
            )
        }
        var values: [DatabaseValue] = []
        values.reserveCapacity(specification.columns.count)
        for column in specification.columns {
            guard let columnMetadata = metadata[column] else {
                throw PortableBackupPreparationError.databaseValidation(
                    "临时库缺少 \(specification.tableName).\(column)。"
                )
            }
            let value = try databaseValue(
                object[column] ?? NSNull(),
                table: specification.tableName,
                column: column,
                metadata: columnMetadata,
                lineNumber: lineNumber,
                limits: limits
            )
            values.append(value)
        }

        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
        try db.execute(
            sql: "INSERT INTO \(specification.tableName) "
                + "(\(specification.columns.joined(separator: ", "))) VALUES (\(placeholders))",
            arguments: StatementArguments(values)
        )
    }

    static func databaseValue(
        _ rawValue: Any,
        table: String,
        column: String,
        metadata: ColumnMetadata,
        lineNumber: Int,
        limits: PortableBackupPreparationLimits
    ) throws -> DatabaseValue {
        if rawValue is NSNull {
            guard !metadata.isRequired else {
                throw PortableBackupPreparationError.invalidRecord(
                    line: lineNumber,
                    reason: "\(column) 不能为空。"
                )
            }
            return .null
        }

        switch metadata.storage {
        case .text:
            guard let value = rawValue as? String else {
                throw typeError(lineNumber: lineNumber, column: column, expected: "字符串")
            }
            try validateStringLength(value, field: column, limits: limits, line: lineNumber)
            if uuidColumns.contains("\(table).\(column)") {
                guard let uuid = UUID(uuidString: value),
                      uuid.uuidString.lowercased() == value else {
                    throw PortableBackupPreparationError.invalidRecord(
                        line: lineNumber,
                        reason: "\(column) 不是规范小写 UUID。"
                    )
                }
            }
            return value.databaseValue
        case .integer:
            let value = try jsonInteger(rawValue, lineNumber: lineNumber, field: column)
            return value.databaseValue
        case .real:
            guard let number = rawValue as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else {
                throw typeError(lineNumber: lineNumber, column: column, expected: "有限数字")
            }
            return number.doubleValue.databaseValue
        }
    }

    static func validateAndSummarizeImportedDatabase(
        _ db: Database
    ) throws -> PortableBackupDataSummary {
        let quickCheck = try String.fetchAll(db, sql: "PRAGMA quick_check")
        guard quickCheck == ["ok"] else {
            throw PortableBackupPreparationError.databaseValidation(
                "SQLite quick_check: \(quickCheck.joined(separator: ", "))"
            )
        }
        let foreignKeyViolations = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"
        ) ?? 0
        guard foreignKeyViolations == 0 else {
            throw PortableBackupPreparationError.databaseValidation(
                "存在 \(foreignKeyViolations) 个外键错误。"
            )
        }
        try validateTimeZones(in: db)
        try validateScheduling(in: db)
        try validateInboxData(in: db)
        try validateDraftData(in: db)
        try validateCardTemplates(in: db)
        try validateNoteDeckData(in: db)
        return try summarizeDatabase(db)
    }

    /// v6 invariants (设计 §9): every note has at least one membership and
    /// its home deck (`notes.deck_id`) is among them; `pitch_accent` is
    /// NULL or consistent with the reading's mora count. FK/PK violations
    /// (dangling or duplicate noteDeck rows) are already caught by
    /// `pragma_foreign_key_check` and the insert itself.
    static func validateNoteDeckData(in db: Database) throws {
        let withoutMembership = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM notes n
                WHERE NOT EXISTS (
                    SELECT 1 FROM note_decks nd WHERE nd.note_id = n.id
                )
                """
        ) ?? 0
        guard withoutMembership == 0 else {
            throw PortableBackupPreparationError.databaseValidation(
                "存在 \(withoutMembership) 条没有牌组成员关系的笔记。"
            )
        }
        let homeMissing = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM notes n
                WHERE NOT EXISTS (
                    SELECT 1 FROM note_decks nd
                    WHERE nd.note_id = n.id AND nd.deck_id = n.deck_id
                )
                """
        ) ?? 0
        guard homeMissing == 0 else {
            throw PortableBackupPreparationError.databaseValidation(
                "存在 \(homeMissing) 条笔记的归属牌组不在其成员关系中。"
            )
        }
        let pitchRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, reading, pitch_accent FROM notes
                WHERE pitch_accent IS NOT NULL
                """
        )
        for row in pitchRows {
            let id: String = row["id"]
            let reading: String? = row["reading"]
            let pitch: Int = row["pitch_accent"]
            guard pitch >= 0,
                  PitchAccent(rawValue: pitch)?.isConsistent(withReading: reading) == true else {
                throw PortableBackupPreparationError.databaseValidation(
                    "笔记 \(id) 的音调值与读音不匹配或越界。"
                )
            }
        }
    }

    /// v3 Inbox records carry semantic payloads the column-level checks cannot
    /// see: resume-JSON must decode against the current payload contract, the
    /// context payload version must be understood, and commit-receipt digests
    /// must be canonical SHA-256 hex. Historical note IDs inside result_json
    /// may legitimately reference deleted notes — intentionally unchecked.
    static func validateInboxData(in db: Database) throws {
        let contextRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, payload_version, resume_payload_json
                FROM inbox_processing_contexts
                """
        )
        for row in contextRows {
            let contextID: String = row["id"]
            let payloadVersion: Int = row["payload_version"]
            guard payloadVersion == CaptureResumePayloadFormat.currentVersion else {
                throw PortableBackupPreparationError.databaseValidation(
                    "处理上下文 \(contextID) 的续编版本 \(payloadVersion) 未知。"
                )
            }
            if let resumeJSON: String = row["resume_payload_json"] {
                guard (try? CaptureResumePayloadCodec.decode(resumeJSON)) != nil else {
                    throw PortableBackupPreparationError.databaseValidation(
                        "处理上下文 \(contextID) 的续编数据无法解码。"
                    )
                }
            }
        }
        let receiptHashes = try Row.fetchAll(
            db,
            sql: "SELECT operation_id, payload_hash FROM inbox_commit_receipts"
        )
        for row in receiptHashes {
            let hash: String = row["payload_hash"]
            guard isLowercaseSHA256Hex(hash) else {
                let operationID: String = row["operation_id"]
                throw PortableBackupPreparationError.databaseValidation(
                    "提交回执 \(operationID) 的摘要格式无效。"
                )
            }
        }
    }

    /// ai_repair drafts carry a strict v1 envelope (设计 §10.2): every
    /// envelope must decode and satisfy phase/receipt consistency or the whole
    /// backup is rejected. Then, for uncommitted drafts only, the target
    /// Note/Card pair must still resolve — a committed receipt is allowed to
    /// reference objects the user deleted afterwards, so those are skipped.
    /// An unresolvable target degrades the draft to `adoptionBlocked` inside
    /// the import transaction rather than failing the restore.
    static func finalizeImportedDraftData(in db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, payload_version, payload_json
                FROM drafts WHERE draft_kind = ?
                """,
            arguments: [AIRepairDraftFormat.draftKind]
        )
        for row in rows {
            let draftID: String = row["id"]
            let payloadVersion: Int = row["payload_version"]
            guard payloadVersion == AIRepairDraftFormat.currentPayloadVersion else {
                throw PortableBackupPreparationError.databaseValidation(
                    "修卡草稿 \(draftID) 的 payload 版本 \(payloadVersion) 未知。"
                )
            }
            let payloadJSON: String = row["payload_json"]
            let envelope: AIRepairDraftEnvelope
            do {
                envelope = try AIRepairDraftCodec.decode(payloadJSON)
            } catch {
                throw PortableBackupPreparationError.databaseValidation(
                    "修卡草稿 \(draftID) 的封套无法解码或语义无效。"
                )
            }
            guard envelope.phase != .committed, !envelope.adoptionBlocked else {
                continue
            }
            let targetExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM cards
                        JOIN notes ON notes.id = cards.note_id
                        WHERE cards.id = ? AND notes.id = ?
                    )
                    """,
                arguments: [
                    DatabaseValueCodec.encode(envelope.targetCardID),
                    DatabaseValueCodec.encode(envelope.targetNoteID)
                ]
            ) ?? false
            guard !targetExists else { continue }
            var blocked = envelope
            blocked.adoptionBlocked = true
            try db.execute(
                sql: "UPDATE drafts SET payload_json = ? WHERE id = ?",
                arguments: [try AIRepairDraftCodec.encode(blocked), draftID]
            )
        }
    }

    /// The template↔kind invariant (设计 §10.2): grammar cards only exist on
    /// grammar notes and every vocabulary template — including
    /// `vocabulary_listening` — only on vocabulary notes. Raw enum values are
    /// already fenced by the table CHECKs at insert; this catches pairs the
    /// CHECKs cannot see.
    static func validateCardTemplates(in db: Database) throws {
        let mismatched = try Row.fetchOne(
            db,
            sql: """
                SELECT cards.id AS card_id
                FROM cards
                JOIN notes ON notes.id = cards.note_id
                WHERE (cards.template_kind = 'grammar_form_explanation')
                      != (notes.kind = 'grammar')
                LIMIT 1
                """
        )
        if let mismatched {
            let cardID: String = mismatched["card_id"]
            throw PortableBackupPreparationError.databaseValidation(
                "卡片 \(cardID) 的模板与 Note 类型不一致。"
            )
        }
    }

    /// Post-import semantic check re-run on the prepared copy: every ai_repair
    /// draft must still decode against the v1 contract (finalizeImportedDraftData
    /// already rewrote unresolvable targets inside the transaction).
    static func validateDraftData(in db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, payload_version, payload_json
                FROM drafts WHERE draft_kind = ?
                """,
            arguments: [AIRepairDraftFormat.draftKind]
        )
        for row in rows {
            let draftID: String = row["id"]
            let payloadVersion: Int = row["payload_version"]
            guard payloadVersion == AIRepairDraftFormat.currentPayloadVersion else {
                throw PortableBackupPreparationError.databaseValidation(
                    "修卡草稿 \(draftID) 的 payload 版本 \(payloadVersion) 未知。"
                )
            }
            let payloadJSON: String = row["payload_json"]
            guard (try? AIRepairDraftCodec.decode(payloadJSON)) != nil else {
                throw PortableBackupPreparationError.databaseValidation(
                    "修卡草稿 \(draftID) 的封套无法解码或语义无效。"
                )
            }
        }
    }

    /// Runs inside the import transaction: a malformed attachment reference is
    /// a contract violation (reject), while a well-formed but unresolvable
    /// resource ID degrades to NULL so the restored item keeps its text.
    static func finalizeImportedInboxData(
        in db: Database,
        resourceExists: (String) -> Bool
    ) throws {
        let references = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT image_reference
                FROM inbox_items
                WHERE image_reference IS NOT NULL
                """
        )
        for reference in references {
            guard isControlledInboxResourceID(reference) else {
                throw PortableBackupPreparationError.databaseValidation(
                    "inbox_items.image_reference 不是受控资源 ID。"
                )
            }
            guard !resourceExists(reference) else { continue }
            try db.execute(
                sql: """
                    UPDATE inbox_items
                    SET image_reference = NULL
                    WHERE image_reference = ?
                    """,
                arguments: [reference]
            )
        }
    }

    /// Attachment references are opaque resource IDs, never filesystem paths —
    /// reject anything that could traverse or address the local file system.
    static func isControlledInboxResourceID(_ value: String) -> Bool {
        guard value.count <= 128, !value.isEmpty else { return false }
        return value.allSatisfy { character in
            ("a"..."z").contains(character)
                || ("A"..."Z").contains(character)
                || ("0"..."9").contains(character)
                || character == "-"
                || character == "_"
        }
    }

    static func isLowercaseSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character)
        }
    }

    static func validateTimeZones(in db: Database) throws {
        let settingsZones = try String.fetchAll(db, sql: "SELECT learning_time_zone_id FROM app_settings")
        let studyDayRows = try Row.fetchAll(
            db,
            sql: "SELECT local_date, time_zone_id FROM study_days"
        )
        guard settingsZones.allSatisfy({ TimeZone(identifier: $0) != nil }) else {
            throw PortableBackupPreparationError.databaseValidation("学习时区无效。")
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        for row in studyDayRows {
            let localDate: String = row["local_date"]
            let timeZoneID: String = row["time_zone_id"]
            guard localDate.count == 10,
                  formatter.date(from: localDate) != nil,
                  TimeZone(identifier: timeZoneID) != nil else {
                throw PortableBackupPreparationError.databaseValidation("学习日日期或时区无效。")
            }
        }
    }

    static func validateScheduling(in db: Database) throws {
        let profileRows = try Row.fetchAll(
            db,
            sql: "SELECT id, algorithm_version, parameters_json FROM scheduler_profiles"
        )
        for row in profileRows {
            let algorithmVersion: String = row["algorithm_version"]
            guard algorithmVersion == SwiftFSRSReviewScheduler.algorithmVersion else {
                throw PortableBackupPreparationError.unsupportedAlgorithmVersion(algorithmVersion)
            }
            let parametersJSON: String = row["parameters_json"]
            guard let parameters = try? JSONDecoder().decode(
                [Double].self,
                from: Data(parametersJSON.utf8)
            ), parameters.count == 21, parameters.allSatisfy(\.isFinite) else {
                throw PortableBackupPreparationError.databaseValidation("FSRS 参数必须是 21 个有限数字。")
            }
        }

        let invalidCard = try Row.fetchOne(
            db,
            sql: """
                SELECT cards.algorithm_version AS card_algorithm,
                       scheduler_profiles.algorithm_version AS profile_algorithm
                FROM cards
                JOIN scheduler_profiles ON scheduler_profiles.id = cards.profile_id
                WHERE cards.algorithm_version != ?
                   OR cards.algorithm_version != scheduler_profiles.algorithm_version
                LIMIT 1
                """,
            arguments: [SwiftFSRSReviewScheduler.algorithmVersion]
        )
        if let invalidCard {
            let version: String = invalidCard["card_algorithm"]
            throw PortableBackupPreparationError.unsupportedAlgorithmVersion(version)
        }

        let reviewRows = try Row.fetchAll(
            db,
            sql: """
                SELECT review_logs.profile_id, review_logs.algorithm_version,
                       review_logs.previous_state_json, review_logs.next_state_json,
                       scheduler_profiles.algorithm_version AS profile_algorithm
                FROM review_logs
                JOIN scheduler_profiles ON scheduler_profiles.id = review_logs.profile_id
                """
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        for row in reviewRows {
            let algorithmVersion: String = row["algorithm_version"]
            let profileAlgorithm: String = row["profile_algorithm"]
            guard algorithmVersion == SwiftFSRSReviewScheduler.algorithmVersion,
                  algorithmVersion == profileAlgorithm else {
                throw PortableBackupPreparationError.unsupportedAlgorithmVersion(algorithmVersion)
            }
            let profileID = try DatabaseValueCodec.decodeUUID(row["profile_id"])
            let previousJSON: String = row["previous_state_json"]
            let nextJSON: String = row["next_state_json"]
            guard let previous = try? decoder.decode(
                ReviewSchedulingSnapshot.self,
                from: Data(previousJSON.utf8)
            ), let next = try? decoder.decode(
                ReviewSchedulingSnapshot.self,
                from: Data(nextJSON.utf8)
            ) else {
                throw PortableBackupPreparationError.databaseValidation("评分调度快照无法解码。")
            }
            guard isValid(snapshot: previous, profileID: profileID),
                  isValid(snapshot: next, profileID: profileID),
                  previous.stateVersion < Int.max,
                  next.stateVersion == previous.stateVersion + 1 else {
                throw PortableBackupPreparationError.databaseValidation("评分调度快照状态无效。")
            }
        }
    }

    static func isValid(snapshot: ReviewSchedulingSnapshot, profileID: UUID) -> Bool {
        let card = snapshot.scheduling
        return snapshot.schemaVersion == ReviewSchedulingSnapshot.currentSchemaVersion
            && snapshot.algorithmVersion == SwiftFSRSReviewScheduler.algorithmVersion
            && snapshot.profileID == profileID
            && snapshot.stateVersion >= 0
            && card.dueAt.timeIntervalSince1970.isFinite
            && (card.lastReviewAt?.timeIntervalSince1970.isFinite ?? true)
            && (snapshot.firstStudiedAt?.timeIntervalSince1970.isFinite ?? true)
            && card.stability.isFinite && card.stability >= 0
            && card.difficulty.isFinite && card.difficulty >= 0 && card.difficulty <= 10
            && card.elapsedDays.isFinite && card.elapsedDays >= 0
            && card.scheduledDays.isFinite && card.scheduledDays >= 0
            && card.learningStep >= 0
            && card.repetitions >= 0
            && card.lapses >= 0
    }

    static func summarizeDatabase(_ db: Database) throws -> PortableBackupDataSummary {
        var counts: [String: Int] = [:]
        for specification in PortableBackupFormatV6.tableSpecifications {
            counts[specification.recordType] = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(specification.tableName)"
            ) ?? 0
        }
        let processingCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM inbox_items WHERE status = 'processing'"
        ) ?? 0
        return PortableBackupDataSummary(
            recordCounts: counts,
            processingInboxItemCount: processingCount
        )
    }

    static func requiredString(
        _ rawValue: Any?,
        field: String,
        context: String
    ) throws -> String {
        guard let value = rawValue as? String else {
            throw PortableBackupPreparationError.invalidManifest(
                "\(context) 的 \(field) 必须是字符串。"
            )
        }
        return value
    }

    static func requiredInteger(
        _ rawValue: Any?,
        field: String,
        context: String
    ) throws -> Int {
        let value = try jsonInteger(rawValue, lineNumber: 1, field: field)
        guard value >= Int64(Int.min), value <= Int64(Int.max) else {
            throw PortableBackupPreparationError.invalidManifest("\(context) 的 \(field) 超出范围。")
        }
        return Int(value)
    }

    static func jsonInteger(
        _ rawValue: Any?,
        lineNumber: Int,
        field: String
    ) throws -> Int64 {
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int64(number.stringValue) else {
            throw typeError(lineNumber: lineNumber, column: field, expected: "整数")
        }
        return value
    }

    static func typeError(
        lineNumber: Int,
        column: String,
        expected: String
    ) -> PortableBackupPreparationError {
        .invalidRecord(
            line: lineNumber,
            reason: "\(column) 必须是\(expected)。"
        )
    }

    static func validateStringLength(
        _ value: String,
        field: String,
        limits: PortableBackupPreparationLimits,
        line: Int = 1
    ) throws {
        guard value.utf8.count <= limits.maximumStringBytes else {
            throw PortableBackupPreparationError.invalidRecord(
                line: line,
                reason: "\(field) 超过 \(limits.maximumStringBytes) 字节上限。"
            )
        }
    }

    static func iso8601Date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)
    }

    static func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
