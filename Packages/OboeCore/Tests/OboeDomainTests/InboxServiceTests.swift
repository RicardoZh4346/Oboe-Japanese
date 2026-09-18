import Foundation
import XCTest
@testable import OboeDomain

final class InboxServiceTests: XCTestCase {
    func testCaptureValidatesTextAndStoresUnprocessedItem() async throws {
        let repository = FakeInboxRepository()
        let fixedNow = Date(timeIntervalSince1970: 1_768_000_000)
        let fixedID = UUID()
        let service = InboxService(
            repository: repository,
            now: { fixedNow },
            makeID: { fixedID }
        )

        do {
            _ = try await service.capture(text: "  \n", sourceType: .manual)
            XCTFail("预期空文本被拒绝")
        } catch {
            XCTAssertEqual(error as? InboxTextValidationError, .empty)
        }
        XCTAssertEqual(repository.items.count, 0)

        let item = try await service.capture(
            text: "  そんなわけないでしょう。\n",
            sourceType: .paste,
            sourceApp: "  Safari  ",
            sourceURL: "   "
        )
        XCTAssertEqual(item.id, fixedID)
        XCTAssertEqual(item.status, .unprocessed)
        XCTAssertEqual(item.contentRevision, 1)
        XCTAssertEqual(item.text, "  そんなわけないでしょう。\n")
        XCTAssertEqual(item.sourceApp, "Safari")
        XCTAssertNil(item.sourceURL)
        XCTAssertEqual(item.createdAt, fixedNow)
        XCTAssertEqual(item.updatedAt, fixedNow)
        XCTAssertEqual(repository.items.count, 1)
    }

    func testCaptureRejectsOverLimitText() async throws {
        let repository = FakeInboxRepository()
        let service = InboxService(repository: repository)
        let oversized = String(
            repeating: "あ",
            count: InboxText.maximumCharacterCount + 1
        )
        do {
            _ = try await service.capture(text: oversized, sourceType: .ocr)
            XCTFail("预期超长文本被拒绝")
        } catch {
            XCTAssertEqual(
                error as? InboxTextValidationError,
                .tooLong(maximumCharacters: InboxText.maximumCharacterCount)
            )
        }
        XCTAssertEqual(repository.items.count, 0)
    }

    func testFetchPageNormalizesQueryAndSkipsEmpty() async throws {
        let repository = FakeInboxRepository()
        let service = InboxService(repository: repository)

        _ = try await service.fetchPage(query: "  パン ")
        XCTAssertEqual(repository.lastNormalizedQuery, "ぱん")

        _ = try await service.fetchPage(query: "   ")
        XCTAssertNil(repository.lastNormalizedQuery)

        _ = try await service.fetchPage(query: nil)
        XCTAssertNil(repository.lastNormalizedQuery)
    }

    func testUpdateTextValidatesBeforeRepositoryCall() async throws {
        let repository = FakeInboxRepository()
        let service = InboxService(repository: repository)
        let item = try await service.capture(text: "原文", sourceType: .manual)

        do {
            _ = try await service.updateText(
                id: item.id,
                expectedRevision: 1,
                text: "   "
            )
            XCTFail("预期空文本被拒绝")
        } catch {
            XCTAssertEqual(error as? InboxTextValidationError, .empty)
        }
        XCTAssertEqual(repository.updateTextCallCount, 0)
    }

    func testBeginProcessingMarksItemAndSnapshotsContext() async throws {
        let repository = FakeInboxRepository()
        let fixedNow = Date(timeIntervalSince1970: 1_768_000_000)
        let service = InboxService(
            repository: repository,
            now: { fixedNow }
        )
        let item = try await service.capture(text: "原文", sourceType: .manual)

        let context = try await service.beginProcessing(itemID: item.id, mode: .manualEdit)
        XCTAssertEqual(context.inboxItemID, item.id)
        XCTAssertEqual(context.inputText, "原文")
        XCTAssertEqual(context.contentRevision, 1)
        XCTAssertEqual(context.payloadVersion, CaptureResumePayloadFormat.currentVersion)
        XCTAssertEqual(repository.items[0].status, .processing)

        let again = try await service.beginProcessing(itemID: item.id, mode: .manualEdit)
        XCTAssertEqual(again.id, context.id)
        XCTAssertEqual(repository.contexts.count, 1)
    }

    func testBeginProcessingRejectsArchivedProcessedAndMissingItems() async throws {
        let repository = FakeInboxRepository()
        let service = InboxService(repository: repository)
        let archived = try await service.capture(text: "归档", sourceType: .manual)
        try await service.archive(ids: [archived.id])

        do {
            _ = try await service.beginProcessing(itemID: archived.id, mode: .manualEdit)
            XCTFail("预期归档条目被拒绝")
        } catch {
            XCTAssertEqual(error as? InboxError, .itemArchived)
        }

        do {
            _ = try await service.beginProcessing(itemID: UUID(), mode: .manualEdit)
            XCTFail("预期缺失条目被拒绝")
        } catch {
            XCTAssertEqual(error as? InboxError, .itemNotFound)
        }
    }

    func testSaveResumePayloadAndResumeSessionRoundTrip() async throws {
        let repository = FakeInboxRepository()
        let service = InboxService(repository: repository)
        let item = try await service.capture(text: "分析対象", sourceType: .manual)
        let context = try await service.beginProcessing(
            itemID: item.id,
            mode: .sentenceAnalysis
        )

        do {
            _ = try await service.resumeSession(inboxItemID: item.id)
        } catch {
            XCTFail("预期会话可恢复：\(error)")
        }

        let deckID = UUID()
        let updated = try await service.saveResumePayload(
            inboxItemID: item.id,
            payload: CaptureResumePayload(
                targetDeckID: deckID,
                vocabularyDirections: [.chineseToJapanese],
                analysisContentRevision: 1
            )
        )
        XCTAssertEqual(updated.id, context.id)
        XCTAssertNotNil(updated.resumePayloadJSON)

        let session = try await service.resumeSession(inboxItemID: item.id)
        XCTAssertEqual(session?.item.id, item.id)
        XCTAssertEqual(session?.context.id, context.id)
        XCTAssertEqual(session?.payload?.targetDeckID, deckID)
        XCTAssertFalse(session?.isSourceRevised ?? true)
        XCTAssertFalse(session?.isAnalysisStale ?? true)
    }

    func testResumeSessionThrowsOnInvalidPersistedPayload() async throws {
        let repository = FakeInboxRepository()
        let service = InboxService(repository: repository)
        let item = try await service.capture(text: "原文", sourceType: .manual)
        let context = try await service.beginProcessing(itemID: item.id, mode: .manualEdit)

        // Fake repo stores the JSON verbatim to emulate a corrupted row.
        try await repository.upsertProcessingContext(
            InboxProcessingContext(
                id: context.id,
                inboxItemID: item.id,
                contentRevision: 1,
                inputText: "原文",
                mode: .manualEdit,
                draftID: nil,
                payloadVersion: 1,
                resumePayloadJSON: "not-json",
                updatedAt: context.updatedAt
            )
        )

        do {
            _ = try await service.resumeSession(inboxItemID: item.id)
            XCTFail("预期非法 payload 抛出错误")
        } catch {
            XCTAssertEqual(error as? CaptureResumePayloadError, .invalidJSON)
        }
    }

    func testResumeSessionReturnsNilWithoutItemOrContext() async throws {
        let repository = FakeInboxRepository()
        let service = InboxService(repository: repository)
        let missing = try await service.resumeSession(inboxItemID: UUID())
        XCTAssertNil(missing)

        let item = try await service.capture(text: "原文", sourceType: .manual)
        let noContext = try await service.resumeSession(inboxItemID: item.id)
        XCTAssertNil(noContext)
    }

    func testArchiveAndDeleteDelegateToRepository() async throws {
        let repository = FakeInboxRepository()
        let fixedNow = Date(timeIntervalSince1970: 1_768_000_000)
        let service = InboxService(repository: repository, now: { fixedNow })
        let item = try await service.capture(text: "収集", sourceType: .manual)

        try await service.archive(ids: [item.id])
        XCTAssertEqual(repository.lastArchiveDate, fixedNow)
        XCTAssertEqual(repository.items[0].status, .archived)
        XCTAssertEqual(repository.items[0].statusBeforeArchive, .unprocessed)

        try await service.delete(id: item.id)
        XCTAssertEqual(repository.items.count, 0)

        do {
            try await service.delete(id: item.id)
            XCTFail("预期删除缺失条目抛出错误")
        } catch {
            XCTAssertEqual(error as? InboxError, .itemNotFound)
        }
    }

    func testDeleteNotifiesAttachmentCleanupAndFetchImageReferences() async throws {
        let repository = FakeInboxRepository()
        let collector = ReferenceCollector()
        let service = InboxService(
            repository: repository,
            onItemDeleted: { reference in
                await collector.record(reference)
            }
        )
        let withImage = try await service.capture(
            text: "带图",
            sourceType: .ocr,
            imageReference: "img-001"
        )
        let withoutImage = try await service.capture(
            text: "无图",
            sourceType: .manual
        )

        let references = try await service.fetchImageReferences()
        XCTAssertEqual(references, ["img-001"])

        try await service.delete(id: withoutImage.id)
        var collected = await collector.references()
        XCTAssertEqual(collected, [])

        try await service.delete(id: withImage.id)
        collected = await collector.references()
        XCTAssertEqual(collected, ["img-001"])
        let remaining = try await service.fetchImageReferences()
        XCTAssertEqual(remaining, [])
    }
}

/// @Sendable cleanup closures cannot capture mutable state — collect through
/// a small actor instead.
private actor ReferenceCollector {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func references() -> [String] {
        values
    }
}

private final class FakeInboxRepository: InboxRepository, @unchecked Sendable {
    var items: [InboxItem] = []
    var lastNormalizedQuery: String?
    var lastArchiveDate: Date?
    var updateTextCallCount = 0

    func insertItem(_ item: InboxItem) async throws {
        items.append(item)
    }

    func insertImportedItem(
        _ item: InboxItem,
        receipt: CaptureImportReceipt
    ) async throws -> CaptureImportResult {
        items.append(item)
        return .imported(item)
    }

    func fetchItem(id: UUID) async throws -> InboxItem? {
        items.first { $0.id == id }
    }

    func fetchPage(
        status: InboxStatus,
        normalizedQuery: String?,
        cursor: InboxPageCursor?,
        limit: Int
    ) async throws -> InboxPage {
        lastNormalizedQuery = normalizedQuery
        return InboxPage(
            items: items.filter { $0.status == status },
            nextCursor: nil
        )
    }

    func fetchUnprocessedCount() async throws -> Int {
        items.filter { $0.status == .unprocessed }.count
    }

    func fetchImageReferences() async throws -> Set<String> {
        Set(items.compactMap(\.imageReference))
    }

    func observeUnprocessedCount() -> AsyncThrowingStream<Int, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func updateItemText(
        id: UUID,
        expectedRevision: Int,
        text: String,
        at date: Date
    ) async throws -> InboxItem {
        updateTextCallCount += 1
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw InboxError.itemNotFound
        }
        let item = items[index]
        let updated = InboxItem(
            id: item.id,
            text: text,
            sourceType: item.sourceType,
            status: item.status,
            contentRevision: item.contentRevision + 1,
            sourceApp: item.sourceApp,
            sourceURL: item.sourceURL,
            imageReference: item.imageReference,
            createdAt: item.createdAt,
            updatedAt: date,
            processedAt: item.processedAt,
            archivedAt: item.archivedAt,
            statusBeforeArchive: item.statusBeforeArchive
        )
        items[index] = updated
        return updated
    }

    func archiveItems(ids: [UUID], at date: Date) async throws {
        lastArchiveDate = date
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }),
                  items[index].status != .archived else {
                continue
            }
            let item = items[index]
            items[index] = InboxItem(
                id: item.id,
                text: item.text,
                sourceType: item.sourceType,
                status: .archived,
                contentRevision: item.contentRevision,
                sourceApp: item.sourceApp,
                sourceURL: item.sourceURL,
                imageReference: item.imageReference,
                createdAt: item.createdAt,
                updatedAt: date,
                processedAt: item.processedAt,
                archivedAt: date,
                statusBeforeArchive: item.status
            )
        }
    }

    func unarchiveItem(id: UUID, at date: Date) async throws -> InboxItem {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw InboxError.itemNotFound
        }
        let item = items[index]
        guard item.status == .archived else {
            throw InboxError.itemNotArchived
        }
        let restored = InboxItem(
            id: item.id,
            text: item.text,
            sourceType: item.sourceType,
            status: item.statusBeforeArchive ?? .unprocessed,
            contentRevision: item.contentRevision,
            sourceApp: item.sourceApp,
            sourceURL: item.sourceURL,
            imageReference: item.imageReference,
            createdAt: item.createdAt,
            updatedAt: date,
            processedAt: item.processedAt,
            archivedAt: nil,
            statusBeforeArchive: nil
        )
        items[index] = restored
        return restored
    }

    func deleteItem(id: UUID) async throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw InboxError.itemNotFound
        }
        items.remove(at: index)
    }

    func markItemProcessing(id: UUID, at date: Date) async throws -> InboxItem {
        try transition(id: id, expected: .unprocessed, to: .processing, at: date)
    }

    func markItemUnprocessed(id: UUID, at date: Date) async throws -> InboxItem {
        try transition(id: id, expected: .processing, to: .unprocessed, at: date)
    }

    func markItemProcessed(id: UUID, at date: Date) async throws -> InboxItem {
        try transition(id: id, expected: .processing, to: .processed, at: date)
    }

    var contexts: [InboxProcessingContext] = []

    func fetchProcessingContext(inboxItemID: UUID) async throws -> InboxProcessingContext? {
        contexts.first { $0.inboxItemID == inboxItemID }
    }

    func fetchProcessingContext(id: UUID) async throws -> InboxProcessingContext? {
        contexts.first { $0.id == id }
    }

    func upsertProcessingContext(_ context: InboxProcessingContext) async throws {
        if let index = contexts.firstIndex(where: { $0.id == context.id }) {
            contexts[index] = context
        } else {
            contexts.append(context)
        }
    }

    func updateProcessingContextDraft(
        inboxItemID: UUID,
        draftID: UUID?,
        updatedAt: Date
    ) async throws -> InboxProcessingContext? {
        guard let index = contexts.firstIndex(where: { $0.inboxItemID == inboxItemID }) else {
            return nil
        }
        let existing = contexts[index]
        let updated = InboxProcessingContext(
            id: existing.id,
            inboxItemID: existing.inboxItemID,
            contentRevision: existing.contentRevision,
            inputText: existing.inputText,
            mode: existing.mode,
            draftID: draftID,
            payloadVersion: existing.payloadVersion,
            resumePayloadJSON: existing.resumePayloadJSON,
            updatedAt: updatedAt
        )
        contexts[index] = updated
        return updated
    }

    func updateProcessingContextPayload(
        inboxItemID: UUID,
        payloadVersion: Int,
        resumePayloadJSON: String?,
        updatedAt: Date
    ) async throws -> InboxProcessingContext? {
        guard let index = contexts.firstIndex(where: { $0.inboxItemID == inboxItemID }) else {
            return nil
        }
        let existing = contexts[index]
        let updated = InboxProcessingContext(
            id: existing.id,
            inboxItemID: existing.inboxItemID,
            contentRevision: existing.contentRevision,
            inputText: existing.inputText,
            mode: existing.mode,
            draftID: existing.draftID,
            payloadVersion: payloadVersion,
            resumePayloadJSON: resumePayloadJSON,
            updatedAt: updatedAt
        )
        contexts[index] = updated
        return updated
    }

    func updateProcessingContextModeAndSnapshot(
        inboxItemID: UUID,
        mode: CaptureProcessingMode,
        contentRevision: Int,
        inputText: String,
        updatedAt: Date
    ) async throws -> InboxProcessingContext? {
        guard let index = contexts.firstIndex(where: { $0.inboxItemID == inboxItemID }) else {
            return nil
        }
        let existing = contexts[index]
        let updated = InboxProcessingContext(
            id: existing.id,
            inboxItemID: existing.inboxItemID,
            contentRevision: contentRevision,
            inputText: inputText,
            mode: mode,
            draftID: existing.draftID,
            payloadVersion: existing.payloadVersion,
            resumePayloadJSON: existing.resumePayloadJSON,
            updatedAt: updatedAt
        )
        contexts[index] = updated
        return updated
    }

    func deleteProcessingContext(inboxItemID: UUID) async throws {
        contexts.removeAll { $0.inboxItemID == inboxItemID }
    }

    func fetchImportReceipt(captureID: UUID) async throws -> CaptureImportReceipt? {
        nil
    }

    func fetchCommitReceipt(operationID: UUID) async throws -> InboxCommitReceipt? {
        nil
    }

    private func transition(
        id: UUID,
        expected: InboxStatus,
        to newStatus: InboxStatus,
        at date: Date
    ) throws -> InboxItem {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw InboxError.itemNotFound
        }
        let item = items[index]
        guard item.status == expected else {
            throw InboxError.invalidStatusTransition(from: item.status, to: newStatus)
        }
        let updated = InboxItem(
            id: item.id,
            text: item.text,
            sourceType: item.sourceType,
            status: newStatus,
            contentRevision: item.contentRevision,
            sourceApp: item.sourceApp,
            sourceURL: item.sourceURL,
            imageReference: item.imageReference,
            createdAt: item.createdAt,
            updatedAt: date,
            processedAt: newStatus == .processed ? date : item.processedAt,
            archivedAt: item.archivedAt,
            statusBeforeArchive: item.statusBeforeArchive
        )
        items[index] = updated
        return updated
    }
}
