import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBInboxContextTests: XCTestCase {
    func testBeginProcessingCreatesContextSnapshotAndMarksItem() async throws {
        try await withHarness { repository, service, _ in
            let item = Self.makeItem(text: "元のテキスト")
            try await repository.insertItem(item)

            let context = try await service.beginProcessing(
                itemID: item.id,
                mode: .manualEdit
            )
            XCTAssertEqual(context.inboxItemID, item.id)
            XCTAssertEqual(context.contentRevision, 1)
            XCTAssertEqual(context.inputText, "元のテキスト")
            XCTAssertEqual(context.mode, .manualEdit)
            XCTAssertNil(context.draftID)
            XCTAssertNil(context.resumePayloadJSON)

            let reloaded = try await repository.fetchItem(id: item.id)
            XCTAssertEqual(reloaded?.status, .processing)

            // updatedAt is stored at millisecond precision; compare the rest fieldwise.
            let fetched = try await repository.fetchProcessingContext(inboxItemID: item.id)
            XCTAssertEqual(fetched?.id, context.id)
            XCTAssertEqual(fetched?.inboxItemID, item.id)
            XCTAssertEqual(fetched?.inputText, "元のテキスト")
            XCTAssertEqual(fetched?.contentRevision, 1)
            XCTAssertEqual(fetched?.mode, .manualEdit)
            let fetchedByID = try await repository.fetchProcessingContext(id: context.id)
            XCTAssertEqual(fetchedByID?.id, context.id)
            XCTAssertEqual(fetchedByID?.inboxItemID, item.id)

            // Re-entering is idempotent: same context id, no new row.
            let again = try await service.beginProcessing(itemID: item.id, mode: .manualEdit)
            XCTAssertEqual(again.id, context.id)
        }
    }

    func testInterleavedItemsKeepIsolatedResumeState() async throws {
        try await withHarness { repository, service, _ in
            let itemA = Self.makeItem(text: "項目A")
            let itemB = Self.makeItem(text: "項目B")
            try await repository.insertItem(itemA)
            try await repository.insertItem(itemB)

            let contextA = try await service.beginProcessing(itemID: itemA.id, mode: .manualEdit)
            let contextB = try await service.beginProcessing(
                itemID: itemB.id,
                mode: .sentenceAnalysis
            )
            XCTAssertNotEqual(contextA.id, contextB.id)

            let deckA = UUID()
            let deckB = UUID()
            _ = try await service.saveResumePayload(
                inboxItemID: itemA.id,
                payload: CaptureResumePayload(
                    selection: CaptureTextSelection(utf16Offset: 0, utf16Length: 3),
                    targetDeckID: deckA,
                    vocabularyDirections: [.chineseToJapanese]
                )
            )
            _ = try await service.saveResumePayload(
                inboxItemID: itemB.id,
                payload: CaptureResumePayload(
                    targetDeckID: deckB,
                    selectedAnalysisItemIDs: [UUID()],
                    analysisContentRevision: 1
                )
            )

            let sessionA = try await service.resumeSession(inboxItemID: itemA.id)
            let sessionB = try await service.resumeSession(inboxItemID: itemB.id)
            XCTAssertEqual(sessionA?.context.mode, .manualEdit)
            XCTAssertEqual(sessionA?.payload?.targetDeckID, deckA)
            XCTAssertEqual(sessionA?.payload?.vocabularyDirections, [.chineseToJapanese])
            XCTAssertEqual(sessionB?.context.mode, .sentenceAnalysis)
            XCTAssertEqual(sessionB?.payload?.targetDeckID, deckB)
            XCTAssertEqual(sessionB?.payload?.selectedAnalysisItemIDs.count, 1)
        }
    }

    func testCaptureDraftsExcludedFromLatestButFetchableByID() async throws {
        try await withHarness { repository, service, database in
            let vocabulary = GRDBVocabularyRepository(database: database)
            let grammar = GRDBGrammarRepository(database: database)
            let sentenceAnalysis = GRDBSentenceAnalysisDraftRepository(database: database)

            let vocabularyDraft = VocabularyDraft(
                id: UUID(),
                deckID: nil,
                formData: VocabularyFormData(headword: "集める", meaningZH: "收集"),
                updatedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            let grammarDraft = GrammarDraft(
                id: UUID(),
                deckID: nil,
                formData: GrammarFormData(grammarForm: "Vてしまう", meaningZH: "完成/遗憾"),
                updatedAt: Date(timeIntervalSince1970: 1_768_000_100)
            )
            let sentenceDraft = SentenceAnalysisDraft(
                id: UUID(),
                sentence: "雨が降った。",
                result: nil,
                providerID: nil,
                modelID: nil,
                promptVersion: nil,
                updatedAt: Date(timeIntervalSince1970: 1_768_000_200)
            )
            try await vocabulary.saveVocabularyDraft(vocabularyDraft)
            try await grammar.saveGrammarDraft(grammarDraft)
            try await sentenceAnalysis.saveSentenceAnalysisDraft(sentenceDraft)

            // Before any capture context claims them, latest queries return them.
            let latestVocabulary = try await vocabulary.fetchLatestVocabularyDraft()?.id
            let latestGrammar = try await grammar.fetchLatestGrammarDraft()?.id
            let latestSentence = try await sentenceAnalysis.fetchLatestSentenceAnalysisDraft()?.id
            XCTAssertEqual(latestVocabulary, vocabularyDraft.id)
            XCTAssertEqual(latestGrammar, grammarDraft.id)
            XCTAssertEqual(latestSentence, sentenceDraft.id)

            let item = Self.makeItem()
            try await repository.insertItem(item)
            let context = try await service.beginProcessing(
                itemID: item.id,
                mode: .vocabularyGeneration
            )
            _ = try await service.attachDraft(inboxItemID: item.id, draftID: vocabularyDraft.id)

            // The claimed vocabulary draft is hidden from the normal Add page but
            // remains loadable by ID for the capture session.
            let hiddenVocabulary = try await vocabulary.fetchLatestVocabularyDraft()
            let claimedVocabulary = try await vocabulary.fetchVocabularyDraft(
                id: vocabularyDraft.id
            )
            let grammarLatest = try await grammar.fetchLatestGrammarDraft()?.id
            let sentenceLatest = try await sentenceAnalysis.fetchLatestSentenceAnalysisDraft()?.id
            XCTAssertNil(hiddenVocabulary)
            XCTAssertEqual(claimedVocabulary?.formData.headword, "集める")
            // Other kinds are unaffected.
            XCTAssertEqual(grammarLatest, grammarDraft.id)
            XCTAssertEqual(sentenceLatest, sentenceDraft.id)

            // Claiming a grammar draft only hides that row.
            let item2 = Self.makeItem()
            try await repository.insertItem(item2)
            _ = try await service.beginProcessing(itemID: item2.id, mode: .grammarGeneration)
            _ = try await service.attachDraft(inboxItemID: item2.id, draftID: grammarDraft.id)
            let hiddenGrammar = try await grammar.fetchLatestGrammarDraft()
            let claimedGrammar = try await grammar.fetchGrammarDraft(id: grammarDraft.id)
            let sentenceLatestAfter = try await sentenceAnalysis.fetchLatestSentenceAnalysisDraft()?.id
            XCTAssertNil(hiddenGrammar)
            XCTAssertNotNil(claimedGrammar)
            XCTAssertEqual(sentenceLatestAfter, sentenceDraft.id)
            XCTAssertEqual(context.draftID, nil)
        }
    }

    func testConcurrentDraftAndPayloadUpdatesDoNotClobberEachOther() async throws {
        try await withHarness { repository, service, database in
            let item = Self.makeItem(text: "并发更新")
            try await repository.insertItem(item)
            _ = try await service.beginProcessing(
                itemID: item.id,
                mode: .vocabularyGeneration
            )
            let vocabulary = GRDBVocabularyRepository(database: database)
            let draft = VocabularyDraft(
                id: UUID(),
                deckID: nil,
                formData: VocabularyFormData(headword: "更新", meaningZH: "update"),
                updatedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await vocabulary.saveVocabularyDraft(draft)
            let draftID = draft.id
            let payload = CaptureResumePayload(
                targetDeckID: nil,
                pendingOperationID: nil
            )
            // Column-scoped writers must not clobber each other's fields in
            // either order (draft attach and payload persist run concurrently
            // from the editor).
            _ = try await service.attachDraft(
                inboxItemID: item.id,
                draftID: draftID
            )
            _ = try await service.saveResumePayload(
                inboxItemID: item.id,
                payload: payload
            )
            var context = try await repository.fetchProcessingContext(
                inboxItemID: item.id
            )
            XCTAssertEqual(context?.draftID, draftID)
            XCTAssertNotNil(context?.resumePayloadJSON)

            _ = try await service.saveResumePayload(
                inboxItemID: item.id,
                payload: payload
            )
            _ = try await service.attachDraft(
                inboxItemID: item.id,
                draftID: draftID
            )
            context = try await repository.fetchProcessingContext(
                inboxItemID: item.id
            )
            XCTAssertEqual(context?.draftID, draftID)
            XCTAssertNotNil(context?.resumePayloadJSON)
        }
    }

    func testSourceRevisionInvalidatesAnalysisButKeepsUserChoices() async throws {
        try await withHarness { repository, service, _ in
            let item = Self.makeItem(text: "最初の文章")
            try await repository.insertItem(item)
            _ = try await service.beginProcessing(itemID: item.id, mode: .sentenceAnalysis)

            let itemID = UUID()
            let deckID = UUID()
            _ = try await service.saveResumePayload(
                inboxItemID: item.id,
                payload: CaptureResumePayload(
                    selection: CaptureTextSelection(utf16Offset: 0, utf16Length: 3),
                    targetDeckID: deckID,
                    selectedAnalysisItemIDs: [itemID],
                    editedCardDrafts: [
                        SentenceAnalysisCardDraft(
                            id: itemID,
                            kind: .vocabulary,
                            headword: "最初",
                            meaningZH: "最初"
                        )
                    ],
                    analysisContentRevision: 1
                )
            )

            // User revises the source text: revision bumps.
            _ = try await service.updateText(
                id: item.id,
                expectedRevision: 1,
                text: "書き換えた文章"
            )

            let staleSession = try await service.resumeSession(inboxItemID: item.id)
            XCTAssertEqual(staleSession?.item.contentRevision, 2)
            XCTAssertTrue(staleSession?.isSourceRevised ?? false)
            XCTAssertTrue(staleSession?.isAnalysisStale ?? false)
            let staleResume = staleSession?.resumablePayload
            XCTAssertEqual(staleResume?.targetDeckID, deckID)
            XCTAssertEqual(staleResume?.selectedAnalysisItemIDs, [])
            XCTAssertEqual(staleResume?.editedCardDrafts, [])

            // Re-entering refreshes the snapshot; the old analysis stays stale.
            _ = try await service.beginProcessing(itemID: item.id, mode: .sentenceAnalysis)
            let session = try await service.resumeSession(inboxItemID: item.id)
            XCTAssertEqual(session?.context.contentRevision, 2)
            XCTAssertEqual(session?.context.inputText, "書き換えた文章")
            XCTAssertFalse(session?.isSourceRevised ?? true)
            XCTAssertTrue(session?.isAnalysisStale ?? false)
            XCTAssertEqual(session?.resumablePayload?.targetDeckID, deckID)
        }
    }

    func testResumeSessionRejectsInvalidPayloadButKeepsContext() async throws {
        try await withHarness { repository, service, database in
            let item = Self.makeItem()
            try await repository.insertItem(item)
            let context = try await service.beginProcessing(itemID: item.id, mode: .manualEdit)

            // Bypass the service to store a schema-valid but version-invalid payload.
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE inbox_processing_contexts
                        SET resume_payload_json = '{"version":99}'
                        WHERE id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(context.id)]
                )
            }

            await assertThrowsPayloadError(
                { try await service.resumeSession(inboxItemID: item.id) },
                equals: .unsupportedVersion(99)
            )
            let contextAfter = try await repository.fetchProcessingContext(inboxItemID: item.id)
            XCTAssertEqual(contextAfter?.resumePayloadJSON, "{\"version\":99}")

            // Out-of-bounds selection against the snapshot text is a field error.
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE inbox_processing_contexts
                        SET resume_payload_json =
                            '{"version":1,"selection":{"utf16Offset":0,"utf16Length":99999}}'
                        WHERE id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(context.id)]
                )
            }
            await assertThrowsPayloadError(
                { try await service.resumeSession(inboxItemID: item.id) },
                equals: .invalidField("selection")
            )
        }
    }

    func testDeletedLinkedDraftLeavesContextIntact() async throws {
        try await withHarness { repository, service, database in
            let vocabulary = GRDBVocabularyRepository(database: database)
            let item = Self.makeItem()
            try await repository.insertItem(item)
            _ = try await service.beginProcessing(itemID: item.id, mode: .vocabularyGeneration)

            let draft = VocabularyDraft(
                id: UUID(),
                deckID: nil,
                formData: VocabularyFormData(headword: "消える", meaningZH: "消失"),
                updatedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await vocabulary.saveVocabularyDraft(draft)
            _ = try await service.attachDraft(inboxItemID: item.id, draftID: draft.id)

            // Deleting the draft clears the link via SET NULL; the context survives.
            try await vocabulary.deleteVocabularyDraft(id: draft.id)
            let context = try await repository.fetchProcessingContext(inboxItemID: item.id)
            let deletedDraft = try await vocabulary.fetchVocabularyDraft(id: draft.id)
            XCTAssertNotNil(context)
            XCTAssertNil(context?.draftID)
            XCTAssertNil(deletedDraft)
        }
    }

    func testDeletedTargetDeckDoesNotCorruptSession() async throws {
        try await withHarness { repository, service, database in
            let item = Self.makeItem()
            try await repository.insertItem(item)
            _ = try await service.beginProcessing(itemID: item.id, mode: .manualEdit)

            let deckID = UUID()
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                        VALUES (?, '将被删除', 0, 1, 1)
                        """,
                    arguments: [DatabaseValueCodec.encode(deckID)]
                )
            }
            _ = try await service.saveResumePayload(
                inboxItemID: item.id,
                payload: CaptureResumePayload(targetDeckID: deckID)
            )
            try await database.pool.write { db in
                try db.execute(sql: "DELETE FROM decks WHERE id = ?", arguments: [DatabaseValueCodec.encode(deckID)])
            }

            let session = try await service.resumeSession(inboxItemID: item.id)
            // The payload still decodes; deck existence is resolved by the editor UI.
            XCTAssertEqual(session?.payload?.targetDeckID, deckID)
        }
    }

    func testDeletingItemCascadesContext() async throws {
        try await withHarness { repository, service, _ in
            let item = Self.makeItem()
            try await repository.insertItem(item)
            let context = try await service.beginProcessing(itemID: item.id, mode: .manualEdit)

            try await service.delete(id: item.id)
            let byItem = try await repository.fetchProcessingContext(inboxItemID: item.id)
            let byID = try await repository.fetchProcessingContext(id: context.id)
            XCTAssertNil(byItem)
            XCTAssertNil(byID)
        }
    }

    func testDeleteProcessingContextKeepsItem() async throws {
        try await withHarness { repository, service, _ in
            let item = Self.makeItem()
            try await repository.insertItem(item)
            _ = try await service.beginProcessing(itemID: item.id, mode: .manualEdit)

            try await service.deleteProcessingContext(inboxItemID: item.id)
            let contextAfter = try await repository.fetchProcessingContext(inboxItemID: item.id)
            let itemAfter = try await repository.fetchItem(id: item.id)
            XCTAssertNil(contextAfter)
            XCTAssertEqual(itemAfter?.status, .processing)
        }
    }
}

private extension GRDBInboxContextTests {
    static func makeItem(
        id: UUID = UUID(),
        text: String = "そんなわけないでしょう。",
        createdAt: Date = Date(timeIntervalSince1970: 1_768_000_000)
    ) -> InboxItem {
        InboxItem(
            id: id,
            text: text,
            sourceType: .manual,
            status: .unprocessed,
            contentRevision: 1,
            sourceApp: nil,
            sourceURL: nil,
            imageReference: nil,
            createdAt: createdAt,
            updatedAt: createdAt,
            processedAt: nil,
            archivedAt: nil,
            statusBeforeArchive: nil
        )
    }

    func withHarness(
        _ body: (GRDBInboxRepository, InboxService, OboeDatabase) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBInboxContextTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try OboeDatabase(
            path: directory.appendingPathComponent("oboe.sqlite").path
        )
        let repository = GRDBInboxRepository(database: database)
        try await body(repository, InboxService(repository: repository), database)
    }

    func assertThrowsPayloadError(
        _ body: () async throws -> Any?,
        equals expected: CaptureResumePayloadError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("预期抛出错误，但调用成功返回", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CaptureResumePayloadError, expected, file: file, line: line)
        }
    }
}
