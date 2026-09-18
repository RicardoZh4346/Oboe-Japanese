import Foundation
import GRDB
import OboeDomain

public struct GRDBInboxRepository: InboxRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func insertItem(_ item: InboxItem) async throws {
        guard item.status == .unprocessed,
              item.contentRevision >= 1,
              item.processedAt == nil,
              item.archivedAt == nil,
              item.statusBeforeArchive == nil else {
            throw InboxError.invalidNewItemStatus(item.status)
        }
        try await pool.write { db in
            try Self.insertItem(item, in: db)
        }
    }

    public func insertImportedItem(
        _ item: InboxItem,
        receipt: CaptureImportReceipt
    ) async throws -> CaptureImportResult {
        guard item.status == .unprocessed,
              item.contentRevision >= 1,
              item.processedAt == nil,
              item.archivedAt == nil,
              item.statusBeforeArchive == nil else {
            throw InboxError.invalidNewItemStatus(item.status)
        }
        guard receipt.inboxItemID == item.id else {
            throw InboxError.receiptDoesNotMatchItem
        }
        return try await pool.write { db in
            if let existing = try Self.fetchImportReceiptRow(
                captureID: receipt.captureID,
                in: db
            ) {
                let existingHash: String = existing["payload_hash"]
                guard existingHash == receipt.payloadHash else {
                    throw InboxError.captureConflict(captureID: receipt.captureID)
                }
                let linkedItemID: String? = existing["inbox_item_id"]
                return .alreadyImported(
                    inboxItemID: try linkedItemID.map(DatabaseValueCodec.decodeUUID)
                )
            }
            try Self.insertItem(item, in: db)
            try Self.insertImportReceipt(receipt, in: db)
            return .imported(item)
        }
    }

    public func fetchItem(id: UUID) async throws -> InboxItem? {
        try await pool.read { db in
            try Self.fetchItemRow(id: id, in: db).map(Self.decodeItem)
        }
    }

    public func fetchPage(
        status: InboxStatus,
        normalizedQuery: String?,
        cursor: InboxPageCursor?,
        limit: Int
    ) async throws -> InboxPage {
        guard limit > 0 else {
            return InboxPage(items: [], nextCursor: nil)
        }
        return try await pool.read { db in
            var clauses = ["status = ?"]
            var arguments: [DatabaseValueConvertible?] = [status.rawValue]
            if let normalizedQuery, !normalizedQuery.isEmpty {
                clauses.append("oboe_normalize_search(text) LIKE ? ESCAPE '\\'")
                arguments.append("%\(Self.likeEscaped(normalizedQuery))%")
            }
            if let cursor {
                clauses.append("(created_at_ms < ? OR (created_at_ms = ? AND id < ?))")
                arguments.append(cursor.createdAtMilliseconds)
                arguments.append(cursor.createdAtMilliseconds)
                arguments.append(DatabaseValueCodec.encode(cursor.id))
            }
            arguments.append(limit + 1)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, text, source_type, status, content_revision,
                           source_app, source_url, image_reference,
                           created_at_ms, updated_at_ms, processed_at_ms,
                           archived_at_ms, status_before_archive
                    FROM inbox_items
                    WHERE \(clauses.joined(separator: " AND "))
                    ORDER BY created_at_ms DESC, id DESC
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments)
            )
            let items = try rows.prefix(limit).map(Self.decodeItem)
            var nextCursor: InboxPageCursor?
            if rows.count > limit {
                let cursorRow = rows[limit - 1]
                let cursorID: String = cursorRow["id"]
                nextCursor = InboxPageCursor(
                    createdAtMilliseconds: cursorRow["created_at_ms"],
                    id: try DatabaseValueCodec.decodeUUID(cursorID)
                )
            }
            return InboxPage(items: items, nextCursor: nextCursor)
        }
    }

    public func fetchUnprocessedCount() async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM inbox_items WHERE status = 'unprocessed'"
            ) ?? 0
        }
    }

    public func observeUnprocessedCount() -> AsyncThrowingStream<Int, Error> {
        let observation = ValueObservation.tracking { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM inbox_items WHERE status = 'unprocessed'"
            ) ?? 0
        }
        let values = observation.values(
            in: pool,
            bufferingPolicy: .bufferingNewest(1)
        )
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await count in values {
                        guard !Task.isCancelled else {
                            break
                        }
                        continuation.yield(count)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func updateItemText(
        id: UUID,
        expectedRevision: Int,
        text: String,
        at date: Date
    ) async throws -> InboxItem {
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            guard let row = try Self.fetchItemRow(id: id, in: db) else {
                throw InboxError.itemNotFound
            }
            let statusValue: String = row["status"]
            guard let status = InboxStatus(rawValue: statusValue) else {
                throw InboxError.invalidPersistedValue(field: "status")
            }
            guard status != .archived else {
                throw InboxError.itemArchived
            }
            let currentRevision: Int = row["content_revision"]
            guard currentRevision == expectedRevision else {
                throw InboxError.revisionConflict(
                    expected: expectedRevision,
                    actual: currentRevision
                )
            }
            let nextStatus = status == .processed ? InboxStatus.unprocessed : status
            try db.execute(
                sql: """
                    UPDATE inbox_items
                    SET text = ?, content_revision = ?, status = ?, updated_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    text,
                    currentRevision + 1,
                    nextStatus.rawValue,
                    updatedAtMilliseconds,
                    DatabaseValueCodec.encode(id)
                ]
            )
            guard let updated = try Self.fetchItemRow(id: id, in: db) else {
                throw InboxError.itemNotFound
            }
            return try Self.decodeItem(updated)
        }
    }

    public func archiveItems(ids: [UUID], at date: Date) async throws {
        let archivedAtMilliseconds = try DatabaseValueCodec.encode(date)
        try await pool.write { db in
            for id in ids {
                try db.execute(
                    sql: """
                        UPDATE inbox_items
                        SET status = 'archived',
                            archived_at_ms = ?,
                            status_before_archive = status,
                            updated_at_ms = ?
                        WHERE id = ? AND status != 'archived'
                        """,
                    arguments: [
                        archivedAtMilliseconds,
                        archivedAtMilliseconds,
                        DatabaseValueCodec.encode(id)
                    ]
                )
            }
        }
    }

    public func unarchiveItem(id: UUID, at date: Date) async throws -> InboxItem {
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            guard let row = try Self.fetchItemRow(id: id, in: db) else {
                throw InboxError.itemNotFound
            }
            let statusValue: String = row["status"]
            guard statusValue == InboxStatus.archived.rawValue else {
                throw InboxError.itemNotArchived
            }
            let restoredStatus: String = row["status_before_archive"]
            try db.execute(
                sql: """
                    UPDATE inbox_items
                    SET status = ?, archived_at_ms = NULL,
                        status_before_archive = NULL, updated_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    restoredStatus,
                    updatedAtMilliseconds,
                    DatabaseValueCodec.encode(id)
                ]
            )
            guard let updated = try Self.fetchItemRow(id: id, in: db) else {
                throw InboxError.itemNotFound
            }
            return try Self.decodeItem(updated)
        }
    }

    public func fetchImageReferences() async throws -> Set<String> {
        try await pool.read { db in
            Set(
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT image_reference
                        FROM inbox_items
                        WHERE image_reference IS NOT NULL
                        """
                )
            )
        }
    }

    public func deleteItem(id: UUID) async throws {
        try await pool.write { db in
            let draftIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT draft_id FROM inbox_processing_contexts
                    WHERE inbox_item_id = ? AND draft_id IS NOT NULL
                    """,
                arguments: [DatabaseValueCodec.encode(id)]
            )
            try db.execute(
                sql: "DELETE FROM inbox_items WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            )
            guard db.changesCount == 1 else {
                throw InboxError.itemNotFound
            }
            for draftID in draftIDs {
                try db.execute(
                    sql: """
                        DELETE FROM drafts
                        WHERE id = ? AND NOT EXISTS (
                            SELECT 1 FROM inbox_processing_contexts
                            WHERE draft_id = drafts.id
                        )
                        """,
                    arguments: [draftID]
                )
            }
        }
    }

    public func markItemProcessing(id: UUID, at date: Date) async throws -> InboxItem {
        try await pool.write { db in
            try Self.transition(
                id: id,
                expected: .unprocessed,
                to: .processing,
                at: date,
                in: db
            )
        }
    }

    public func markItemUnprocessed(id: UUID, at date: Date) async throws -> InboxItem {
        try await pool.write { db in
            try Self.transition(
                id: id,
                expected: .processing,
                to: .unprocessed,
                at: date,
                in: db
            )
        }
    }

    public func markItemProcessed(id: UUID, at date: Date) async throws -> InboxItem {
        try await pool.write { db in
            try Self.transition(
                id: id,
                expected: .processing,
                to: .processed,
                at: date,
                in: db
            )
        }
    }

    public func fetchImportReceipt(captureID: UUID) async throws -> CaptureImportReceipt? {
        try await pool.read { db in
            try Self.fetchImportReceiptRow(captureID: captureID, in: db)
                .map(Self.decodeImportReceipt)
        }
    }

    public func fetchCommitReceipt(operationID: UUID) async throws -> InboxCommitReceipt? {
        try await pool.read { db in
            try Self.fetchCommitReceiptRow(operationID: operationID, in: db)
                .map(Self.decodeCommitReceipt)
        }
    }

    public func fetchProcessingContext(inboxItemID: UUID) async throws -> InboxProcessingContext? {
        try await pool.read { db in
            try Self.fetchContextRow(inboxItemID: inboxItemID, in: db)
                .map(Self.decodeContext)
        }
    }

    public func fetchProcessingContext(id: UUID) async throws -> InboxProcessingContext? {
        try await pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, inbox_item_id, content_revision, input_text, mode,
                           draft_id, payload_version, resume_payload_json, updated_at_ms
                    FROM inbox_processing_contexts
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(id)]
            ).map(Self.decodeContext)
        }
    }

    public func upsertProcessingContext(_ context: InboxProcessingContext) async throws {
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(context.updatedAt)
        try await pool.write { db in
            guard try Self.fetchItemRow(id: context.inboxItemID, in: db) != nil else {
                throw InboxError.itemNotFound
            }
            try db.execute(
                sql: """
                    INSERT INTO inbox_processing_contexts(
                        id, inbox_item_id, content_revision, input_text, mode,
                        draft_id, payload_version, resume_payload_json, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        content_revision = excluded.content_revision,
                        input_text = excluded.input_text,
                        mode = excluded.mode,
                        draft_id = excluded.draft_id,
                        payload_version = excluded.payload_version,
                        resume_payload_json = excluded.resume_payload_json,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    DatabaseValueCodec.encode(context.id),
                    DatabaseValueCodec.encode(context.inboxItemID),
                    context.contentRevision,
                    context.inputText,
                    context.mode.rawValue,
                    context.draftID.map(DatabaseValueCodec.encode),
                    context.payloadVersion,
                    context.resumePayloadJSON,
                    updatedAtMilliseconds
                ]
            )
        }
    }

    public func updateProcessingContextDraft(
        inboxItemID: UUID,
        draftID: UUID?,
        updatedAt: Date
    ) async throws -> InboxProcessingContext? {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE inbox_processing_contexts
                    SET draft_id = ?, updated_at_ms = ?
                    WHERE inbox_item_id = ?
                    """,
                arguments: [
                    draftID.map(DatabaseValueCodec.encode),
                    try DatabaseValueCodec.encode(updatedAt),
                    DatabaseValueCodec.encode(inboxItemID)
                ]
            )
            return try Self.fetchContextRow(inboxItemID: inboxItemID, in: db)
                .map(Self.decodeContext)
        }
    }

    public func updateProcessingContextPayload(
        inboxItemID: UUID,
        payloadVersion: Int,
        resumePayloadJSON: String?,
        updatedAt: Date
    ) async throws -> InboxProcessingContext? {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE inbox_processing_contexts
                    SET payload_version = ?, resume_payload_json = ?, updated_at_ms = ?
                    WHERE inbox_item_id = ?
                    """,
                arguments: [
                    payloadVersion,
                    resumePayloadJSON,
                    try DatabaseValueCodec.encode(updatedAt),
                    DatabaseValueCodec.encode(inboxItemID)
                ]
            )
            return try Self.fetchContextRow(inboxItemID: inboxItemID, in: db)
                .map(Self.decodeContext)
        }
    }

    public func updateProcessingContextModeAndSnapshot(
        inboxItemID: UUID,
        mode: CaptureProcessingMode,
        contentRevision: Int,
        inputText: String,
        updatedAt: Date
    ) async throws -> InboxProcessingContext? {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE inbox_processing_contexts
                    SET mode = ?, content_revision = ?, input_text = ?, updated_at_ms = ?
                    WHERE inbox_item_id = ?
                    """,
                arguments: [
                    mode.rawValue,
                    contentRevision,
                    inputText,
                    try DatabaseValueCodec.encode(updatedAt),
                    DatabaseValueCodec.encode(inboxItemID)
                ]
            )
            return try Self.fetchContextRow(inboxItemID: inboxItemID, in: db)
                .map(Self.decodeContext)
        }
    }

    public func deleteProcessingContext(inboxItemID: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM inbox_processing_contexts WHERE inbox_item_id = ?",
                arguments: [DatabaseValueCodec.encode(inboxItemID)]
            )
        }
    }

    static func insertItem(_ item: InboxItem, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO inbox_items(
                    id, text, source_type, status, content_revision,
                    source_app, source_url, image_reference,
                    created_at_ms, updated_at_ms, processed_at_ms,
                    archived_at_ms, status_before_archive
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(item.id),
                item.text,
                item.sourceType.rawValue,
                item.status.rawValue,
                item.contentRevision,
                item.sourceApp,
                item.sourceURL,
                item.imageReference,
                DatabaseValueCodec.encode(item.createdAt),
                DatabaseValueCodec.encode(item.updatedAt),
                item.processedAt.map(DatabaseValueCodec.encode),
                item.archivedAt.map(DatabaseValueCodec.encode),
                item.statusBeforeArchive?.rawValue
            ]
        )
    }

    static func insertImportReceipt(
        _ receipt: CaptureImportReceipt,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO capture_import_receipts(
                    capture_id, payload_hash, inbox_item_id, imported_at_ms
                ) VALUES (?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(receipt.captureID),
                receipt.payloadHash,
                receipt.inboxItemID.map(DatabaseValueCodec.encode),
                DatabaseValueCodec.encode(receipt.importedAt)
            ]
        )
    }

    static func insertCommitReceipt(
        _ receipt: InboxCommitReceipt,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO inbox_commit_receipts(
                    operation_id, processing_context_id, payload_hash,
                    result_json, committed_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(receipt.operationID),
                receipt.processingContextID.map(DatabaseValueCodec.encode),
                receipt.payloadHash,
                receipt.resultJSON,
                DatabaseValueCodec.encode(receipt.committedAt)
            ]
        )
    }

    static func transition(
        id: UUID,
        expected: InboxStatus,
        to newStatus: InboxStatus,
        at date: Date,
        in db: Database
    ) throws -> InboxItem {
        guard let row = try fetchItemRow(id: id, in: db) else {
            throw InboxError.itemNotFound
        }
        let statusValue: String = row["status"]
        guard let status = InboxStatus(rawValue: statusValue) else {
            throw InboxError.invalidPersistedValue(field: "status")
        }
        guard status == expected else {
            throw InboxError.invalidStatusTransition(from: status, to: newStatus)
        }
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(date)
        switch newStatus {
        case .processing, .unprocessed:
            try db.execute(
                sql: "UPDATE inbox_items SET status = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [
                    newStatus.rawValue,
                    updatedAtMilliseconds,
                    DatabaseValueCodec.encode(id)
                ]
            )
        case .processed:
            try db.execute(
                sql: """
                    UPDATE inbox_items
                    SET status = 'processed', processed_at_ms = ?, updated_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    updatedAtMilliseconds,
                    updatedAtMilliseconds,
                    DatabaseValueCodec.encode(id)
                ]
            )
        case .archived:
            throw InboxError.invalidStatusTransition(from: status, to: newStatus)
        }
        guard let updated = try fetchItemRow(id: id, in: db) else {
            throw InboxError.itemNotFound
        }
        return try decodeItem(updated)
    }

    static func fetchItemRow(id: UUID, in db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, text, source_type, status, content_revision,
                       source_app, source_url, image_reference,
                       created_at_ms, updated_at_ms, processed_at_ms,
                       archived_at_ms, status_before_archive
                FROM inbox_items
                WHERE id = ?
                """,
            arguments: [DatabaseValueCodec.encode(id)]
        )
    }

    static func fetchContextRow(inboxItemID: UUID, in db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, inbox_item_id, content_revision, input_text, mode,
                       draft_id, payload_version, resume_payload_json, updated_at_ms
                FROM inbox_processing_contexts
                WHERE inbox_item_id = ?
                ORDER BY updated_at_ms DESC, id
                LIMIT 1
                """,
            arguments: [DatabaseValueCodec.encode(inboxItemID)]
        )
    }

    static func fetchImportReceiptRow(captureID: UUID, in db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT capture_id, payload_hash, inbox_item_id, imported_at_ms
                FROM capture_import_receipts
                WHERE capture_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(captureID)]
        )
    }

    static func fetchCommitReceiptRow(operationID: UUID, in db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT operation_id, processing_context_id, payload_hash,
                       result_json, committed_at_ms
                FROM inbox_commit_receipts
                WHERE operation_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(operationID)]
        )
    }

    static func decodeItem(_ row: Row) throws -> InboxItem {
        let idValue: String = row["id"]
        let sourceTypeValue: String = row["source_type"]
        let statusValue: String = row["status"]
        let statusBeforeArchiveValue: String? = row["status_before_archive"]
        guard let sourceType = InboxSourceType(rawValue: sourceTypeValue) else {
            throw InboxError.invalidPersistedValue(field: "source_type")
        }
        guard let status = InboxStatus(rawValue: statusValue) else {
            throw InboxError.invalidPersistedValue(field: "status")
        }
        let statusBeforeArchive = try statusBeforeArchiveValue.map { value in
            guard let decoded = InboxStatus(rawValue: value) else {
                throw InboxError.invalidPersistedValue(field: "status_before_archive")
            }
            return decoded
        }
        let createdAtMilliseconds: Int64 = row["created_at_ms"]
        let updatedAtMilliseconds: Int64 = row["updated_at_ms"]
        let processedAtMilliseconds: Int64? = row["processed_at_ms"]
        let archivedAtMilliseconds: Int64? = row["archived_at_ms"]
        return InboxItem(
            id: try DatabaseValueCodec.decodeUUID(idValue),
            text: row["text"],
            sourceType: sourceType,
            status: status,
            contentRevision: row["content_revision"],
            sourceApp: row["source_app"],
            sourceURL: row["source_url"],
            imageReference: row["image_reference"],
            createdAt: DatabaseValueCodec.decodeDate(milliseconds: createdAtMilliseconds),
            updatedAt: DatabaseValueCodec.decodeDate(milliseconds: updatedAtMilliseconds),
            processedAt: processedAtMilliseconds.map {
                DatabaseValueCodec.decodeDate(milliseconds: $0)
            },
            archivedAt: archivedAtMilliseconds.map {
                DatabaseValueCodec.decodeDate(milliseconds: $0)
            },
            statusBeforeArchive: statusBeforeArchive
        )
    }

    static func decodeImportReceipt(_ row: Row) throws -> CaptureImportReceipt {
        let captureIDValue: String = row["capture_id"]
        let inboxItemIDValue: String? = row["inbox_item_id"]
        let importedAtMilliseconds: Int64 = row["imported_at_ms"]
        return try CaptureImportReceipt(
            captureID: DatabaseValueCodec.decodeUUID(captureIDValue),
            payloadHash: row["payload_hash"],
            inboxItemID: inboxItemIDValue.map(DatabaseValueCodec.decodeUUID),
            importedAt: DatabaseValueCodec.decodeDate(milliseconds: importedAtMilliseconds)
        )
    }

    static func decodeContext(_ row: Row) throws -> InboxProcessingContext {
        let idValue: String = row["id"]
        let inboxItemIDValue: String = row["inbox_item_id"]
        let modeValue: String = row["mode"]
        let draftIDValue: String? = row["draft_id"]
        guard let mode = CaptureProcessingMode(rawValue: modeValue) else {
            throw InboxError.invalidPersistedValue(field: "mode")
        }
        let updatedAtMilliseconds: Int64 = row["updated_at_ms"]
        return try InboxProcessingContext(
            id: DatabaseValueCodec.decodeUUID(idValue),
            inboxItemID: DatabaseValueCodec.decodeUUID(inboxItemIDValue),
            contentRevision: row["content_revision"],
            inputText: row["input_text"],
            mode: mode,
            draftID: draftIDValue.map(DatabaseValueCodec.decodeUUID),
            payloadVersion: row["payload_version"],
            resumePayloadJSON: row["resume_payload_json"],
            updatedAt: DatabaseValueCodec.decodeDate(milliseconds: updatedAtMilliseconds)
        )
    }

    static func decodeCommitReceipt(_ row: Row) throws -> InboxCommitReceipt {
        let operationIDValue: String = row["operation_id"]
        let contextIDValue: String? = row["processing_context_id"]
        let committedAtMilliseconds: Int64 = row["committed_at_ms"]
        return try InboxCommitReceipt(
            operationID: DatabaseValueCodec.decodeUUID(operationIDValue),
            processingContextID: contextIDValue.map(DatabaseValueCodec.decodeUUID),
            payloadHash: row["payload_hash"],
            resultJSON: row["result_json"],
            committedAt: DatabaseValueCodec.decodeDate(milliseconds: committedAtMilliseconds)
        )
    }

    private static func likeEscaped(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
