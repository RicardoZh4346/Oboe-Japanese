import Foundation

public struct InboxPageCursor: Equatable, Sendable {
    public let createdAtMilliseconds: Int64
    public let id: UUID

    public init(createdAtMilliseconds: Int64, id: UUID) {
        self.createdAtMilliseconds = createdAtMilliseconds
        self.id = id
    }
}

public struct InboxPage: Equatable, Sendable {
    public let items: [InboxItem]
    public let nextCursor: InboxPageCursor?

    public init(items: [InboxItem], nextCursor: InboxPageCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum CaptureImportResult: Equatable, Sendable {
    case imported(InboxItem)
    case alreadyImported(inboxItemID: UUID?)
}

public enum InboxError: Error, Equatable, Sendable {
    case itemNotFound
    case revisionConflict(expected: Int, actual: Int)
    case itemArchived
    case itemNotArchived
    case invalidStatusTransition(from: InboxStatus, to: InboxStatus)
    case captureConflict(captureID: UUID)
    case receiptDoesNotMatchItem
    case processingContextNotFound
    case invalidPersistedValue(field: String)
    case invalidNewItemStatus(InboxStatus)
    case commitPayloadConflict(operationID: UUID)
}

public protocol InboxRepository: Sendable {
    func insertItem(_ item: InboxItem) async throws
    func insertImportedItem(
        _ item: InboxItem,
        receipt: CaptureImportReceipt
    ) async throws -> CaptureImportResult
    func fetchItem(id: UUID) async throws -> InboxItem?
    func fetchPage(
        status: InboxStatus,
        normalizedQuery: String?,
        cursor: InboxPageCursor?,
        limit: Int
    ) async throws -> InboxPage
    func fetchUnprocessedCount() async throws -> Int
    func observeUnprocessedCount() -> AsyncThrowingStream<Int, Error>
    /// Distinct attachment resource IDs referenced by inbox items — the keep
    /// set for controlled-storage cleanup sweeps.
    func fetchImageReferences() async throws -> Set<String>
    func updateItemText(
        id: UUID,
        expectedRevision: Int,
        text: String,
        at date: Date
    ) async throws -> InboxItem
    func archiveItems(ids: [UUID], at date: Date) async throws
    func unarchiveItem(id: UUID, at date: Date) async throws -> InboxItem
    func deleteItem(id: UUID) async throws
    func markItemProcessing(id: UUID, at date: Date) async throws -> InboxItem
    func markItemUnprocessed(id: UUID, at date: Date) async throws -> InboxItem
    func markItemProcessed(id: UUID, at date: Date) async throws -> InboxItem
    func fetchProcessingContext(inboxItemID: UUID) async throws -> InboxProcessingContext?
    func fetchProcessingContext(id: UUID) async throws -> InboxProcessingContext?
    func upsertProcessingContext(_ context: InboxProcessingContext) async throws
    /// Column-scoped updates that never clobber unrelated columns when called
    /// concurrently (draft attach and payload persist race otherwise).
    func updateProcessingContextDraft(
        inboxItemID: UUID,
        draftID: UUID?,
        updatedAt: Date
    ) async throws -> InboxProcessingContext?
    func updateProcessingContextPayload(
        inboxItemID: UUID,
        payloadVersion: Int,
        resumePayloadJSON: String?,
        updatedAt: Date
    ) async throws -> InboxProcessingContext?
    func updateProcessingContextModeAndSnapshot(
        inboxItemID: UUID,
        mode: CaptureProcessingMode,
        contentRevision: Int,
        inputText: String,
        updatedAt: Date
    ) async throws -> InboxProcessingContext?
    func deleteProcessingContext(inboxItemID: UUID) async throws
    func fetchImportReceipt(captureID: UUID) async throws -> CaptureImportReceipt?
    func fetchCommitReceipt(operationID: UUID) async throws -> InboxCommitReceipt?
}

public struct InboxService: Sendable {
    public static let pageSize = 50

    private let repository: any InboxRepository
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    /// Called with a deleted item's attachment resource ID after the row is
    /// gone — the app layer wires controlled-storage cleanup here so every
    /// delete path (detail, swipe, batch) releases the image file.
    private let onItemDeleted: (@Sendable (String) async -> Void)?

    public init(
        repository: any InboxRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() },
        onItemDeleted: (@Sendable (String) async -> Void)? = nil
    ) {
        self.repository = repository
        self.now = now
        self.makeID = makeID
        self.onItemDeleted = onItemDeleted
    }

    public func capture(
        text: String,
        sourceType: InboxSourceType,
        sourceApp: String? = nil,
        sourceURL: String? = nil,
        imageReference: String? = nil
    ) async throws -> InboxItem {
        let validatedText = try InboxText(validating: text)
        let timestamp = now()
        let item = InboxItem(
            id: makeID(),
            text: validatedText.value,
            sourceType: sourceType,
            status: .unprocessed,
            contentRevision: 1,
            sourceApp: Self.normalizedOptional(sourceApp),
            sourceURL: Self.normalizedOptional(sourceURL),
            imageReference: imageReference,
            createdAt: timestamp,
            updatedAt: timestamp,
            processedAt: nil,
            archivedAt: nil,
            statusBeforeArchive: nil
        )
        try await repository.insertItem(item)
        return item
    }

    /// Shared-queue import: the item reuses the envelope's captureID so a
    /// retried publish maps onto the same row, and the payload digest comes
    /// from the producer-side contract. The repository performs the
    /// receipt-check → item-insert → receipt-insert atomically.
    public func importCapture(
        captureID: UUID,
        text: String,
        sourceType: InboxSourceType,
        sourceApp: String?,
        sourceURL: String?,
        payloadHash: String,
        capturedAt: Date
    ) async throws -> CaptureImportResult {
        let validatedText = try InboxText(validating: text)
        let timestamp = now()
        let item = InboxItem(
            id: captureID,
            text: validatedText.value,
            sourceType: sourceType,
            status: .unprocessed,
            contentRevision: 1,
            sourceApp: Self.normalizedOptional(sourceApp),
            sourceURL: Self.normalizedOptional(sourceURL),
            imageReference: nil,
            createdAt: capturedAt,
            updatedAt: timestamp,
            processedAt: nil,
            archivedAt: nil,
            statusBeforeArchive: nil
        )
        return try await repository.insertImportedItem(
            item,
            receipt: CaptureImportReceipt(
                captureID: captureID,
                payloadHash: payloadHash,
                inboxItemID: item.id,
                importedAt: timestamp
            )
        )
    }

    public func fetchItem(id: UUID) async throws -> InboxItem? {
        try await repository.fetchItem(id: id)
    }

    public func fetchPage(
        status: InboxStatus = .unprocessed,
        query: String? = nil,
        cursor: InboxPageCursor? = nil,
        limit: Int = InboxService.pageSize
    ) async throws -> InboxPage {
        let normalizedQuery = query
            .map(SearchTextNormalizer.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
        return try await repository.fetchPage(
            status: status,
            normalizedQuery: normalizedQuery,
            cursor: cursor,
            limit: limit
        )
    }

    public func fetchUnprocessedCount() async throws -> Int {
        try await repository.fetchUnprocessedCount()
    }

    public func observeUnprocessedCount() -> AsyncThrowingStream<Int, Error> {
        repository.observeUnprocessedCount()
    }

    public func updateText(
        id: UUID,
        expectedRevision: Int,
        text: String
    ) async throws -> InboxItem {
        let validatedText = try InboxText(validating: text)
        return try await repository.updateItemText(
            id: id,
            expectedRevision: expectedRevision,
            text: validatedText.value,
            at: now()
        )
    }

    public func archive(ids: [UUID]) async throws {
        try await repository.archiveItems(ids: ids, at: now())
    }

    public func unarchive(id: UUID) async throws -> InboxItem {
        try await repository.unarchiveItem(id: id, at: now())
    }

    /// Deletes the row first; the attachment cleanup callback runs only
    /// after the repository confirms removal, so a failed delete never
    /// orphans text that still references its image.
    public func delete(id: UUID) async throws {
        let reference = try await repository.fetchItem(id: id)?.imageReference
        try await repository.deleteItem(id: id)
        if let reference {
            await onItemDeleted?(reference)
        }
    }

    public func fetchImageReferences() async throws -> Set<String> {
        try await repository.fetchImageReferences()
    }

    public func fetchProcessingContext(
        inboxItemID: UUID
    ) async throws -> InboxProcessingContext? {
        try await repository.fetchProcessingContext(inboxItemID: inboxItemID)
    }

    /// Ensures the item is in processing state and a context exists holding a
    /// snapshot of the current revision and text. Re-entering refreshes the
    /// snapshot and mode while preserving the linked draft and resume payload.
    @discardableResult
    public func beginProcessing(
        itemID: UUID,
        mode: CaptureProcessingMode
    ) async throws -> InboxProcessingContext {
        guard let item = try await repository.fetchItem(id: itemID) else {
            throw InboxError.itemNotFound
        }
        switch item.status {
        case .archived:
            throw InboxError.itemArchived
        case .processed:
            throw InboxError.invalidStatusTransition(from: .processed, to: .processing)
        case .unprocessed:
            _ = try await repository.markItemProcessing(id: itemID, at: now())
        case .processing:
            break
        }
        if let existing = try await repository.fetchProcessingContext(inboxItemID: itemID) {
            guard existing.contentRevision != item.contentRevision
                    || existing.inputText != item.text
                    || existing.mode != mode else {
                return existing
            }
            let refreshed = try await repository.updateProcessingContextModeAndSnapshot(
                inboxItemID: itemID,
                mode: mode,
                contentRevision: item.contentRevision,
                inputText: item.text,
                updatedAt: now()
            )
            guard let refreshed else {
                throw InboxError.processingContextNotFound
            }
            return refreshed
        }
        let context = InboxProcessingContext(
            id: makeID(),
            inboxItemID: itemID,
            contentRevision: item.contentRevision,
            inputText: item.text,
            mode: mode,
            draftID: nil,
            payloadVersion: CaptureResumePayloadFormat.currentVersion,
            resumePayloadJSON: nil,
            updatedAt: now()
        )
        try await repository.upsertProcessingContext(context)
        return context
    }

    /// Links (or clears) the working draft on the item's processing context.
    @discardableResult
    public func attachDraft(
        inboxItemID: UUID,
        draftID: UUID?
    ) async throws -> InboxProcessingContext {
        guard let updated = try await repository.updateProcessingContextDraft(
            inboxItemID: inboxItemID,
            draftID: draftID,
            updatedAt: now()
        ) else {
            throw InboxError.processingContextNotFound
        }
        return updated
    }

    /// Validates and persists the resume payload. `nil` clears it.
    @discardableResult
    public func saveResumePayload(
        inboxItemID: UUID,
        payload: CaptureResumePayload?
    ) async throws -> InboxProcessingContext {
        // Encode first so invalid payloads never reach the write path.
        let json = try payload.map(CaptureResumePayloadCodec.encode)
        guard let updated = try await repository.updateProcessingContextPayload(
            inboxItemID: inboxItemID,
            payloadVersion: CaptureResumePayloadFormat.currentVersion,
            resumePayloadJSON: json,
            updatedAt: now()
        ) else {
            throw InboxError.processingContextNotFound
        }
        return updated
    }

    /// Loads the item's processing context with the resume payload decoded and
    /// staleness flags resolved. Returns nil when the item or its context does
    /// not exist. Throws `CaptureResumePayloadError` when the persisted payload
    /// fails version, field, or size validation; the stored row is left intact.
    public func resumeSession(
        inboxItemID: UUID
    ) async throws -> CaptureProcessingSession? {
        guard let item = try await repository.fetchItem(id: inboxItemID),
              let context = try await repository.fetchProcessingContext(
                  inboxItemID: inboxItemID
              ) else {
            return nil
        }
        var payload: CaptureResumePayload?
        if let json = context.resumePayloadJSON {
            payload = try CaptureResumePayloadCodec.decode(json)
            if let selection = payload?.selection {
                try CaptureResumePayloadCodec.validateSelection(
                    selection,
                    within: context.inputText
                )
            }
        }
        return CaptureProcessingSession(item: item, context: context, payload: payload)
    }

    public func deleteProcessingContext(inboxItemID: UUID) async throws {
        try await repository.deleteProcessingContext(inboxItemID: inboxItemID)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
