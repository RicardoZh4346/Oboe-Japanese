import Foundation
import XCTest
@testable import OboeDomain

/// T06: the repair service and recoverable draft lifecycle — user input is
/// persisted before requests, failures return to `editing`, late or
/// superseded responses can never overwrite current state, and nothing here
/// writes a Note or Card.
final class AIRepairServiceTests: XCTestCase {

    // MARK: - Draft preparation

    func testPreviewNoteSnapshotResolvesCurrentNoteContent() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        let snapshot = try await env.service.previewNoteSnapshot(draftID: draftID)
        XCTAssertEqual(snapshot.kind, .vocabulary)
        XCTAssertEqual(snapshot.headword, "受ける")
        XCTAssertEqual(snapshot.reading, "うける")
        XCTAssertEqual(snapshot.meaningZH, "接受；遭受")
        XCTAssertEqual(snapshot.examples.first?.japanese, "試験を受ける")
    }

    func testPrepareDraftSnapshotsTargetAndReusesExisting() async throws {
        let env = try await makeEnvironment()
        let (draftID, envelope) = try await env.service.prepareDraft(
            cardID: env.cardID,
            userComment: "例句总是记不住"
        )
        XCTAssertEqual(envelope.targetNoteID, env.noteID)
        XCTAssertEqual(envelope.targetCardID, env.cardID)
        XCTAssertEqual(envelope.expectedContentVersion, 3)
        XCTAssertTrue(envelope.targetCardEnabled)
        XCTAssertEqual(
            envelope.affectedTemplateKinds,
            [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        XCTAssertEqual(envelope.userComment, "例句总是记不住")
        XCTAssertEqual(envelope.phase, .editing)

        // Re-entering returns the same draft with the user's input intact.
        let persisted = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(persisted, envelope)
        let again = try await env.service.prepareDraft(cardID: env.cardID)
        XCTAssertEqual(again.id, draftID)
        XCTAssertEqual(again.envelope.userComment, "例句总是记不住")
    }

    func testUpdateUserCommentPersistsBeforeAnyRequest() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        try await env.service.updateUserComment(draftID: draftID, comment: "意思太多分不清")
        let stored = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.userComment, "意思太多分不清")
    }

    func testPrepareDraftMarksMissingTargetAsBlocked() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        env.adaptiveRepository.records = []
        let reopened = try await env.service.prepareDraft(cardID: env.cardID)
        XCTAssertEqual(reopened.id, draftID)
        XCTAssertTrue(reopened.envelope.adoptionBlocked)
        do {
            _ = try await env.service.analyze(
                draftID: draftID,
                defaultTimeZoneID: "Asia/Shanghai"
            )
            XCTFail("expected targetUnavailable")
        } catch {
            XCTAssertEqual(error as? AIRepairServiceError, .targetUnavailable)
        }
    }

    // MARK: - Happy path

    func testAnalyzeSendsWhitelistContextAndStoresSuggestedResponse() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(
            cardID: env.cardID,
            userComment: "两个意思记混"
        )
        await env.client.setResult(.success(Self.validResponseJSON))

        let updated = try await env.service.analyze(
            draftID: draftID,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(updated.phase, .suggested)
        XCTAssertEqual(updated.requestGeneration, 2)
        XCTAssertEqual(updated.response?.suggestions.count, 2)
        XCTAssertEqual(updated.response?.problemTypes, [.tooManyMeanings])

        let captured = await env.client.lastContext
        XCTAssertEqual(captured?.note.headword, "受ける")
        XCTAssertEqual(captured?.note.meaningZH, "接受；遭受")
        XCTAssertEqual(captured?.direction, .vocabularyJapaneseToChinese)
        XCTAssertEqual(captured?.reviewSummary.lifetimeLapses, 6)
        XCTAssertEqual(captured?.userComment, "两个意思记混")

        let persisted = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(persisted?.phase, .suggested)
        XCTAssertEqual(persisted?.response, updated.response)
    }

    // MARK: - Failures return to editing without touching the Note

    func testDisabledAIAndMissingCredentialRevertToEditing() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)

        env.configurationRepository.setEnabled(false)
        await assertAnalyzeFails(env, draftID: draftID, equals: AIConnectionError.aiDisabled)
        var phase = try await env.store.fetchDraft(id: draftID)?.phase
        XCTAssertEqual(phase, .editing)

        env.configurationRepository.setEnabled(true)
        await env.credentialStore.setCredential(nil)
        await assertAnalyzeFails(env, draftID: draftID, equals: AIConnectionError.credentialMissing)
        phase = try await env.store.fetchDraft(id: draftID)?.phase
        XCTAssertEqual(phase, .editing)
        let callCount = await env.client.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testTransportErrorAndInvalidOutputRevertToEditing() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)

        await env.client.setResult(.failure(AIConnectionError.timedOut))
        await assertAnalyzeFails(env, draftID: draftID, equals: AIConnectionError.timedOut)
        var draft = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(draft?.phase, .editing)

        await env.client.setResult(.success("not json at all"))
        do {
            _ = try await env.service.analyze(draftID: draftID, defaultTimeZoneID: "Asia/Shanghai")
            XCTFail("expected decode failure")
        } catch {
            XCTAssertEqual(error as? AIRepairError, .invalidJSON)
        }
        draft = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(draft?.phase, .editing)
        XCTAssertNil(draft?.response)
    }

    func testCancelledRequestRevertsToEditing() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        await env.client.setResult(.failure(AIConnectionError.cancelled))
        await assertAnalyzeFails(env, draftID: draftID, equals: AIConnectionError.cancelled)
        let draft = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(draft?.phase, .editing)
    }

    // MARK: - Stale and superseded responses

    func testNewerAnalyzeSupersedesInFlightRequest() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)

        // First request blocks until released; a second analyze completes first.
        await env.client.setResult(.success(Self.validResponseJSON))
        await env.client.setBlockFirstCall(true)
        async let first: Void = {
            do {
                _ = try await env.service.analyze(
                    draftID: draftID,
                    defaultTimeZoneID: "Asia/Shanghai"
                )
                XCTFail("older request should be stale")
            } catch {
                XCTAssertEqual(error as? AIRepairServiceError, .staleResponse)
            }
        }()
        await env.client.waitForCallCount(1)
        let newer = try await env.service.analyze(
            draftID: draftID,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(newer.phase, .suggested)
        XCTAssertEqual(newer.requestGeneration, 3)
        await env.client.releaseBlockedCalls()
        await first

        let persisted = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(persisted?.phase, .suggested)
        XCTAssertEqual(persisted?.requestGeneration, 3)
    }

    func testDiscardedDraftMidRequestDiscardsResponse() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        await env.client.setResult(.success(Self.validResponseJSON))
        await env.client.setBlockFirstCall(true)

        async let analysis = env.service.analyze(
            draftID: draftID,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        await env.client.waitForCallCount(1)
        // Restore/discard semantics: the row disappears before the response lands.
        try await env.service.discardDraft(id: draftID)
        await env.client.releaseBlockedCalls()
        do {
            _ = try await analysis
            XCTFail("expected staleResponse")
        } catch {
            XCTAssertEqual(error as? AIRepairServiceError, .staleResponse)
        }
        let gone = try await env.store.fetchDraft(id: draftID)
        XCTAssertNil(gone)
    }

    func testUserCancelMakesInFlightResponseStale() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        await env.client.setResult(.success(Self.validResponseJSON))
        await env.client.setBlockFirstCall(true)

        async let analysis = env.service.analyze(
            draftID: draftID,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        await env.client.waitForCallCount(1)
        await env.service.cancelAnalysis()
        await env.client.releaseBlockedCalls()
        do {
            _ = try await analysis
            XCTFail("expected staleResponse")
        } catch {
            XCTAssertEqual(error as? AIRepairServiceError, .staleResponse)
        }
        // The cancelled attempt reverts to the retryable phase.
        let draft = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(draft?.phase, .editing)
        XCTAssertNil(draft?.response)
    }

    // MARK: - Phase guards, restore sweep, receipts

    func testCommittedAndCommittingDraftsAreNotAnalyzable() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        let fetchedCommitting = try await env.store.fetchDraft(id: draftID)
        var committing = try XCTUnwrap(fetchedCommitting)
        committing.phase = .committing
        try await env.store.saveDraft(
            id: draftID,
            envelope: committing,
            provenance: AIRepairDraftProvenance(providerID: nil, modelID: nil, promptVersion: nil),
            updatedAt: Date()
        )
        await assertAnalyzeFails(
            env,
            draftID: draftID,
            equals: AIRepairServiceError.draftNotAnalyzable(.committing)
        )
    }

    func testRestoreSweepRevertsAnalyzingAndBlocksMissingTargets() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        let fetchedAnalyzing = try await env.store.fetchDraft(id: draftID)
        var analyzing = try XCTUnwrap(fetchedAnalyzing)
        analyzing.phase = .analyzing
        try await env.store.saveDraft(
            id: draftID,
            envelope: analyzing,
            provenance: AIRepairDraftProvenance(providerID: nil, modelID: nil, promptVersion: nil),
            updatedAt: Date()
        )

        // A second draft whose target was deleted becomes non-adoptable.
        let orphanCardID = UUID()
        let orphan = AIRepairDraftEnvelope(
            targetNoteID: UUID(),
            targetCardID: orphanCardID,
            expectedContentVersion: 1,
            targetCardEnabled: true,
            affectedTemplateKinds: [.vocabularyJapaneseToChinese],
            userComment: "保留说明",
            phase: .editing
        )
        let orphanID = UUID()
        try await env.store.saveDraft(
            id: orphanID,
            envelope: orphan,
            provenance: AIRepairDraftProvenance(providerID: nil, modelID: nil, promptVersion: nil),
            updatedAt: Date()
        )

        try await env.service.restoreDraftsForLaunch()

        let reverted = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(reverted?.phase, .editing)
        XCTAssertFalse(reverted?.adoptionBlocked ?? true)

        let blocked = try await env.store.fetchDraft(id: orphanID)
        XCTAssertTrue(blocked?.adoptionBlocked ?? false)
        XCTAssertEqual(blocked?.userComment, "保留说明")
    }

    func testCommittedReceiptLookupAndDiscard() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        let operationID = UUID()
        let fetchedCommitted = try await env.store.fetchDraft(id: draftID)
        var committed = try XCTUnwrap(fetchedCommitted)
        committed.operationID = operationID
        committed.phase = .committed
        committed.commitReceipt = AIRepairCommitReceipt(
            operationID: operationID,
            payloadHash: String(repeating: "b", count: 64),
            createdNoteIDs: [UUID()],
            createdCardIDs: [UUID()],
            originalCardDisposition: .pause
        )
        try await env.store.saveDraft(
            id: draftID,
            envelope: committed,
            provenance: AIRepairDraftProvenance(providerID: nil, modelID: nil, promptVersion: nil),
            updatedAt: Date()
        )
        let receipt = try await env.service.committedReceipt(for: operationID)
        XCTAssertEqual(receipt?.originalCardDisposition, .pause)
        let missing = try await env.service.committedReceipt(for: UUID())
        XCTAssertNil(missing)

        try await env.service.discardDraft(id: draftID)
        let gone = try await env.store.fetchDraft(id: draftID)
        XCTAssertNil(gone)
    }

    // MARK: - Commit (T08)

    /// prepareDraft → analyze → `.suggested`; the shared starting point for
    /// every commit test.
    private func makeSuggestedEnvironment() async throws -> (env: Environment, draftID: UUID) {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        await env.client.setResult(.success(Self.validResponseJSON))
        _ = try await env.service.analyze(
            draftID: draftID,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        return (env, draftID)
    }

    func testCommitAppliesMergedContentAndStoresReceipt() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()

        let receipt = try await env.service.commitInPlaceRepair(
            draftID: draftID,
            suggestionIndex: 0
        )

        let calls = await env.commitStore.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.draftID, draftID)
        XCTAssertEqual(calls.first?.expectedContentVersion, 3)
        guard case let .vocabulary(content)? = calls.first?.content else {
            return XCTFail("expected vocabulary content")
        }
        XCTAssertEqual(content.meaningZH, "参加考试", "补丁字段必须进入提交内容")
        XCTAssertEqual(content.headword, "受ける", "未补丁字段保持原值")
        XCTAssertEqual(receipt.originalCardDisposition, .keep)
        XCTAssertEqual(receipt.payloadHash.count, 64)

        let stored = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.phase, .committed)
        XCTAssertEqual(stored?.commitReceipt, receipt)
        XCTAssertEqual(stored?.operationID, receipt.operationID)
    }

    func testCommitReplaysSamePayloadIdempotently() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        let first = try await env.service.commitInPlaceRepair(
            draftID: draftID,
            suggestionIndex: 0
        )
        // 重复提交同一 payload：返回既有回执，不再写笔记。
        let replay = try await env.service.commitInPlaceRepair(
            draftID: draftID,
            suggestionIndex: 0
        )
        XCTAssertEqual(replay, first)
        let calls = await env.commitStore.calls
        XCTAssertEqual(calls.count, 1, "幂等回放不得再次提交")
    }

    func testCommitRejectsDifferentPayloadAfterCommit() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        // 构造一份已提交草稿：operationID 相同方向但回执 payloadHash 与
        // 当前建议不同 —— 同一 operationID 的不同 payload 必须冲突。
        let fetched = try await env.store.fetchDraft(id: draftID)
        var committed = try XCTUnwrap(fetched)
        committed.operationID = UUID()
        committed.phase = .committed
        committed.commitReceipt = AIRepairCommitReceipt(
            operationID: committed.operationID ?? UUID(),
            payloadHash: String(repeating: "f", count: 64),
            originalCardDisposition: .keep
        )
        try await env.store.saveDraft(
            id: draftID,
            envelope: committed,
            provenance: AIRepairDraftProvenance(
                providerID: nil,
                modelID: nil,
                promptVersion: nil
            ),
            updatedAt: Date()
        )

        await XCTAssertThrowsErrorAsync(
            try await env.service.commitInPlaceRepair(
                draftID: draftID,
                suggestionIndex: 0
            )
        ) { error in
            XCTAssertEqual(error as? AIRepairCommitError, .operationConflict)
        }
    }

    func testCommitRefusesOverwriteWhenNoteChangedDuringPreview() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        // 预览期间的手工编辑令 contentVersion 前进。
        try await bumpNoteContentVersion(in: env)

        await XCTAssertThrowsErrorAsync(
            try await env.service.commitInPlaceRepair(
                draftID: draftID,
                suggestionIndex: 0
            )
        ) { error in
            XCTAssertEqual(error as? AIRepairCommitError, .contentConflict)
        }
        let calls = await env.commitStore.calls
        XCTAssertTrue(calls.isEmpty, "冲突必须零写入")
        let stored = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.phase, .suggested, "冲突后草稿停在可重试状态")
    }

    func testCommitFailureRevertsToPreviewingAndKeepsOperationID() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        await env.commitStore.setError(StubCommitFailure())

        await XCTAssertThrowsErrorAsync(
            try await env.service.commitInPlaceRepair(
                draftID: draftID,
                suggestionIndex: 0
            )
        )
        let afterFailure = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(afterFailure?.phase, .previewing)
        let operationID = try XCTUnwrap(afterFailure?.operationID)

        // 重试沿用同一 operationID（稳定重试）。
        await env.commitStore.setError(nil)
        let receipt = try await env.service.commitInPlaceRepair(
            draftID: draftID,
            suggestionIndex: 0
        )
        XCTAssertEqual(receipt.operationID, operationID)
        let calls = await env.commitStore.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testCommitRejectsSplitSuggestionAndNonCommittablePhases() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        await XCTAssertThrowsErrorAsync(
            try await env.service.commitInPlaceRepair(
                draftID: draftID,
                suggestionIndex: 1
            )
        ) { error in
            XCTAssertEqual(error as? AIRepairCommitError, .splitRequiresSplitCommit)
        }

        let env2 = try await makeEnvironment()
        let (editingID, _) = try await env2.service.prepareDraft(cardID: env2.cardID)
        await XCTAssertThrowsErrorAsync(
            try await env2.service.commitInPlaceRepair(
                draftID: editingID,
                suggestionIndex: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? AIRepairCommitError,
                .notCommittable(.editing)
            )
        }
    }

    func testUpdateEditedCandidateAndCommitUsesIt() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        let edited = AIRepairSuggestion(
            type: .rewriteMeaning,
            title: "手动调整释义",
            reason: "用户编辑",
            replacement: AIRepairFieldPatch(meaningZH: "收下；接受")
        )
        try await env.service.updateEditedCandidate(
            draftID: draftID,
            candidate: edited
        )
        let stored = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.editedCandidate, edited)

        // 不声明采用编辑候选 → 仍用原建议；声明后 → 用编辑候选。
        let receipt = try await env.service.commitInPlaceRepair(
            draftID: draftID,
            suggestionIndex: 0,
            adoptingEditedCandidate: true
        )
        let calls = await env.commitStore.calls
        guard case let .vocabulary(content) = calls.last?.content else {
            return XCTFail("expected vocabulary content")
        }
        XCTAssertEqual(content.meaningZH, "收下；接受")
        XCTAssertEqual(receipt.payloadHash.count, 64)

        // 非法候选被拒绝且不进入草稿。
        let invalid = AIRepairSuggestion(
            type: .rewriteMeaning,
            title: "",
            reason: "",
            replacement: nil
        )
        await XCTAssertThrowsErrorAsync(
            try await env.service.updateEditedCandidate(
                draftID: draftID,
                candidate: invalid
            )
        )
    }

    func testMarkPreviewingRoundTrip() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        try await env.service.markPreviewing(draftID: draftID)
        var stored = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.phase, .previewing)
        // previewing 可重新分析（用户选择改跑新一轮）。
        await env.client.setResult(.success(Self.validResponseJSON))
        let reanalyzed = try await env.service.analyze(
            draftID: draftID,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(reanalyzed.phase, .suggested)
        stored = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.phase, .suggested)
    }

    // MARK: - Split commit (T09)

    private let splitDirections: [[CardTemplateKind]] = [
        [.vocabularyJapaneseToChinese],
        [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
    ]

    func testSplitCommitCreatesCommitsAndReceiptWithStableIDs() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()

        let receipt = try await env.service.commitSplitRepair(
            draftID: draftID,
            suggestionIndex: 1,
            deckID: env.deckID,
            directions: splitDirections,
            originalCardDisposition: .pause
        )

        let calls = await env.commitStore.splitCalls
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.draftID, draftID)
        XCTAssertEqual(call.expectedContentVersion, 3)
        XCTAssertEqual(call.disposition, .pause)
        XCTAssertEqual(call.commits.count, 2)
        for commit in call.commits {
            XCTAssertEqual(commit.deckID, env.deckID)
        }
        guard case let .vocabulary(first)? = call.commits.first?.content else {
            return XCTFail("expected vocabulary content")
        }
        XCTAssertEqual(first.headword, "試験を受ける")
        XCTAssertEqual(first.meaningZH, "参加考试")
        XCTAssertEqual(
            call.commits[0].cards.map(\.templateKind),
            [.vocabularyJapaneseToChinese]
        )
        XCTAssertEqual(
            call.commits[1].cards.map(\.templateKind),
            [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        XCTAssertEqual(receipt.createdNoteIDs, call.commits.map(\.noteID))
        XCTAssertEqual(
            receipt.createdCardIDs,
            call.commits.flatMap { $0.cards.map(\.id) }
        )
        XCTAssertEqual(receipt.originalCardDisposition, .pause)
        XCTAssertEqual(receipt.payloadHash.count, 64)

        let stored = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.phase, .committed)
        XCTAssertEqual(stored?.commitReceipt, receipt)
    }

    func testSplitCommitIDsStableAcrossRetries() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        await env.commitStore.setError(StubCommitFailure())

        await XCTAssertThrowsErrorAsync(
            try await env.service.commitSplitRepair(
                draftID: draftID,
                suggestionIndex: 1,
                deckID: env.deckID,
                directions: splitDirections,
                originalCardDisposition: .delete
            )
        )
        let failed = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(failed?.phase, .previewing)
        let operationID = try XCTUnwrap(failed?.operationID)

        await env.commitStore.setError(nil)
        let receipt = try await env.service.commitSplitRepair(
            draftID: draftID,
            suggestionIndex: 1,
            deckID: env.deckID,
            directions: splitDirections,
            originalCardDisposition: .delete
        )
        let calls = await env.commitStore.splitCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(
            calls[0].commits.map(\.noteID),
            calls[1].commits.map(\.noteID),
            "同一操作重试必须复用相同 Note ID"
        )
        XCTAssertEqual(
            calls[0].commits.flatMap { $0.cards.map(\.id) },
            calls[1].commits.flatMap { $0.cards.map(\.id) },
            "同一操作重试必须复用相同 Card ID"
        )
        XCTAssertEqual(receipt.operationID, operationID)
        XCTAssertEqual(receipt.createdNoteIDs, calls[1].commits.map(\.noteID))
    }

    func testSplitCommitReplaysCommittedReceipt() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        let first = try await env.service.commitSplitRepair(
            draftID: draftID,
            suggestionIndex: 1,
            deckID: env.deckID,
            directions: splitDirections,
            originalCardDisposition: .keep
        )
        // 重复确认/提交后响应丢失：同 payload 直接回放回执，零写入。
        let replay = try await env.service.commitSplitRepair(
            draftID: draftID,
            suggestionIndex: 1,
            deckID: env.deckID,
            directions: splitDirections,
            originalCardDisposition: .keep
        )
        XCTAssertEqual(replay, first)
        let calls = await env.commitStore.splitCalls
        XCTAssertEqual(calls.count, 1, "幂等回放不得再次提交")
    }

    func testSplitCommitRejectsDifferentPayloadAfterCommit() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        _ = try await env.service.commitSplitRepair(
            draftID: draftID,
            suggestionIndex: 1,
            deckID: env.deckID,
            directions: splitDirections,
            originalCardDisposition: .keep
        )
        // 同 operationID 换 payload（不同处置）→ 冲突。
        await XCTAssertThrowsErrorAsync(
            try await env.service.commitSplitRepair(
                draftID: draftID,
                suggestionIndex: 1,
                deckID: env.deckID,
                directions: splitDirections,
                originalCardDisposition: .delete
            )
        ) { error in
            XCTAssertEqual(error as? AIRepairCommitError, .operationConflict)
        }
    }

    func testSplitCommitRefusesWhenNoteChangedDuringPreview() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        try await bumpNoteContentVersion(in: env)
        await XCTAssertThrowsErrorAsync(
            try await env.service.commitSplitRepair(
                draftID: draftID,
                suggestionIndex: 1,
                deckID: env.deckID,
                directions: splitDirections,
                originalCardDisposition: .pause
            )
        ) { error in
            XCTAssertEqual(error as? AIRepairCommitError, .contentConflict)
        }
        let calls = await env.commitStore.splitCalls
        XCTAssertTrue(calls.isEmpty, "冲突必须零写入")
    }

    /// 用户在预览期间改动待提交方向 → 方向快照失配 → 拒绝并要求重新预览。
    func testSplitCommitRefusesWhenDirectionsChangedDuringPreview() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        await env.contentCardRepository.setDirections([
            CardDirectionState(
                cardID: env.cardID,
                templateKind: .vocabularyJapaneseToChinese,
                isEnabled: true
            )
        ])
        await XCTAssertThrowsErrorAsync(
            try await env.service.commitSplitRepair(
                draftID: draftID,
                suggestionIndex: 1,
                deckID: env.deckID,
                directions: splitDirections,
                originalCardDisposition: .pause
            )
        ) { error in
            XCTAssertEqual(error as? AIRepairCommitError, .contentConflict)
        }
        let calls = await env.commitStore.splitCalls
        XCTAssertTrue(calls.isEmpty, "方向失配必须零写入")
    }

    func testSplitCommitRejectsInvalidDirectionPlans() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        // 空方向
        await XCTAssertThrowsErrorAsync(
            try await env.service.commitSplitRepair(
                draftID: draftID,
                suggestionIndex: 1,
                deckID: env.deckID,
                directions: [[], [.vocabularyJapaneseToChinese]],
                originalCardDisposition: .keep
            )
        ) { error in
            guard case .invalidSplitPlan = error as? AIRepairCommitError else {
                return XCTFail("expected invalidSplitPlan, got \(error)")
            }
        }
        // 不适用模板（语法方向给词汇候选）
        await XCTAssertThrowsErrorAsync(
            try await env.service.commitSplitRepair(
                draftID: draftID,
                suggestionIndex: 1,
                deckID: env.deckID,
                directions: [
                    [.vocabularyJapaneseToChinese],
                    [.grammarFormToExplanation]
                ],
                originalCardDisposition: .keep
            )
        ) { error in
            guard case .invalidSplitPlan = error as? AIRepairCommitError else {
                return XCTFail("expected invalidSplitPlan, got \(error)")
            }
        }
        // 数量不匹配
        await XCTAssertThrowsErrorAsync(
            try await env.service.commitSplitRepair(
                draftID: draftID,
                suggestionIndex: 1,
                deckID: env.deckID,
                directions: [[.vocabularyJapaneseToChinese]],
                originalCardDisposition: .keep
            )
        ) { error in
            guard case .invalidSplitPlan = error as? AIRepairCommitError else {
                return XCTFail("expected invalidSplitPlan, got \(error)")
            }
        }
        let calls = await env.commitStore.splitCalls
        XCTAssertTrue(calls.isEmpty, "非法方案必须零写入")
    }

    /// 混合合法/非法候选：任一候选不过校验则整个提交零写入。
    func testSplitCommitWithMixedInvalidCandidateWritesNothing() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        let fetchedDraft = try await env.store.fetchDraft(id: draftID)
        var draft = try XCTUnwrap(fetchedDraft)
        draft.response = AIRepairResponse(
            problemTypes: [.tooManyMeanings],
            summary: "拆分",
            suggestions: [
                AIRepairSuggestion(
                    type: .splitCard,
                    title: "拆分",
                    reason: "测试",
                    splitNotes: [
                        AIRepairNoteCandidate(
                            kind: .vocabulary,
                            headword: "合法",
                            meaningZH: "合法释义"
                        ),
                        AIRepairNoteCandidate(
                            kind: .vocabulary,
                            headword: "非法",
                            meaningZH: ""
                        )
                    ]
                )
            ]
        )
        try await env.store.saveDraft(
            id: draftID,
            envelope: draft,
            provenance: AIRepairDraftProvenance(
                providerID: nil,
                modelID: nil,
                promptVersion: nil
            ),
            updatedAt: Date()
        )
        await XCTAssertThrowsErrorAsync(
            try await env.service.commitSplitRepair(
                draftID: draftID,
                suggestionIndex: 0,
                deckID: env.deckID,
                directions: [
                    [.vocabularyJapaneseToChinese],
                    [.vocabularyJapaneseToChinese]
                ],
                originalCardDisposition: .keep
            )
        )
        let calls = await env.commitStore.splitCalls
        XCTAssertTrue(calls.isEmpty, "非法候选必须零写入")
        let stored = try await env.store.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.phase, .suggested, "校验失败不得推进相位")
    }

    func testSplitCommitRejectsNonSplitSuggestion() async throws {
        let (env, draftID) = try await makeSuggestedEnvironment()
        await XCTAssertThrowsErrorAsync(
            try await env.service.commitSplitRepair(
                draftID: draftID,
                suggestionIndex: 0,
                deckID: env.deckID,
                directions: [[.vocabularyJapaneseToChinese]],
                originalCardDisposition: .keep
            )
        ) { error in
            XCTAssertEqual(error as? AIRepairCommitError, .notSplitSuggestion)
        }
    }

    func testTargetDeckIDResolvesTargetNoteDeck() async throws {
        let env = try await makeEnvironment()
        let (draftID, _) = try await env.service.prepareDraft(cardID: env.cardID)
        let deckID = try await env.service.targetDeckID(draftID: draftID)
        XCTAssertEqual(deckID, env.deckID)
    }

    // MARK: - Environment

    private struct Environment {
        let service: AIRepairService
        let store: InMemoryAIRepairDraftStore
        let commitStore: StubAIRepairCommitStore
        let client: StubAIRepairClient
        let configurationRepository: StubAIConfigurationRepository
        let credentialStore: StubCredentialStore
        let adaptiveRepository: StubAdaptiveRepository
        let vocabularyRepository: StubVocabularyRepository
        let contentCardRepository: StubContentCardRepository
        let noteID: UUID
        let cardID: UUID
        let deckID: UUID
    }

    private func makeEnvironment() async throws -> Environment {
        let noteID = UUID()
        let cardID = UUID()
        let deckID = UUID()

        let adaptiveRepository = StubAdaptiveRepository()
        adaptiveRepository.records = [
            AdaptiveCardRecord(
                evidence: AdaptiveCardEvidence(
                    cardID: cardID,
                    noteID: noteID,
                    deckID: deckID,
                    templateKind: .vocabularyJapaneseToChinese,
                    isEnabled: true,
                    scheduling: SchedulingCard(
                        dueAt: Date().addingTimeInterval(86_400),
                        stability: 5,
                        difficulty: 6,
                        repetitions: 9,
                        lapses: 6,
                        state: .review
                    ),
                    firstStudiedAt: Date().addingTimeInterval(-90 * 86_400),
                    samples: []
                ),
                headword: "受ける",
                noteContentVersion: 3
            )
        ]

        let vocabularyRepository = StubVocabularyRepository()
        await vocabularyRepository.setNote(VocabularyNote(
            id: noteID,
            deckID: deckID,
            headword: "受ける",
            reading: "うける",
            meaningZH: "接受；遭受",
            partOfSpeech: "动词",
            jlpt: .n3,
            notes: "原注释",
            contentVersion: 3,
            createdAt: Date(),
            updatedAt: Date(),
            examples: [
                VocabularyExample(
                    id: UUID(),
                    japanese: "試験を受ける",
                    translationZH: "参加考试",
                    sortOrder: 0
                )
            ]
        ))

        let contentCardRepository = StubContentCardRepository(directions: [
            CardDirectionState(
                cardID: cardID,
                templateKind: .vocabularyJapaneseToChinese,
                isEnabled: true
            ),
            CardDirectionState(
                cardID: UUID(),
                templateKind: .vocabularyChineseToJapanese,
                isEnabled: true
            )
        ])

        let store = InMemoryAIRepairDraftStore()
        let commitStore = StubAIRepairCommitStore(draftStore: store)
        let client = StubAIRepairClient()
        let configurationRepository = StubAIConfigurationRepository()
        let credentialStore = StubCredentialStore()
        let service = AIRepairService(
            draftStore: store,
            commitStore: commitStore,
            configurationRepository: configurationRepository,
            credentialStore: credentialStore,
            client: client,
            vocabularyRepository: vocabularyRepository,
            grammarRepository: StubGrammarRepository(),
            contentCardRepository: contentCardRepository,
            adaptiveCardService: AdaptiveCardService(repository: adaptiveRepository),
            clock: { Date() }
        )
        return Environment(
            service: service,
            store: store,
            commitStore: commitStore,
            client: client,
            configurationRepository: configurationRepository,
            credentialStore: credentialStore,
            adaptiveRepository: adaptiveRepository,
            vocabularyRepository: vocabularyRepository,
            contentCardRepository: contentCardRepository,
            noteID: noteID,
            cardID: cardID,
            deckID: deckID
        )
    }

    private func assertAnalyzeFails(
        _ env: Environment,
        draftID: UUID,
        equals expected: some Error & Equatable,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await env.service.analyze(
                draftID: draftID,
                defaultTimeZoneID: "Asia/Shanghai"
            )
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AIConnectionError, expected as? AIConnectionError, file: file, line: line)
            if let serviceError = error as? AIRepairServiceError,
               let expected = expected as? AIRepairServiceError {
                XCTAssertEqual(serviceError, expected, file: file, line: line)
            }
        }
    }

    private static let validResponseJSON = """
    {
      "schemaVersion": 1,
      "problemTypes": ["too_many_meanings"],
      "summary": "释义覆盖多个语境。",
      "suggestions": [
        {
          "type": "rewrite_meaning",
          "title": "精简释义",
          "reason": "聚焦核心含义",
          "replacement": {"meaningZH": "参加考试"},
          "clearFields": null,
          "splitNotes": null
        },
        {
          "type": "split_card",
          "title": "按语境拆分",
          "reason": "分别记忆",
          "replacement": null,
          "clearFields": null,
          "splitNotes": [
            {"kind": "vocabulary", "headword": "試験を受ける", "reading": "しけんをうける",
             "meaningZH": "参加考试", "partOfSpeech": null, "jlpt": null,
             "usage": null, "connection": null, "notes": null, "examples": null},
            {"kind": "vocabulary", "headword": "影響を受ける", "reading": "えいきょうをうける",
             "meaningZH": "受到影响", "partOfSpeech": null, "jlpt": null,
             "usage": null, "connection": null, "notes": null, "examples": null}
          ]
        }
      ]
    }
    """
}

extension AIRepairServiceTests {
    /// Simulates a manual edit landing between preview and commit —
    /// `contentVersion` moves so the guarded commit must refuse.
    private func bumpNoteContentVersion(in env: Environment) async throws {
        let fetched = try await env.vocabularyRepository.fetchVocabulary(id: env.noteID)
        let current = try XCTUnwrap(fetched)
        await env.vocabularyRepository.setNote(VocabularyNote(
            id: current.id,
            deckID: current.deckID,
            headword: current.headword,
            reading: current.reading,
            meaningZH: current.meaningZH,
            partOfSpeech: current.partOfSpeech,
            jlpt: current.jlpt,
            notes: current.notes,
            contentVersion: current.contentVersion + 1,
            createdAt: current.createdAt,
            updatedAt: Date(),
            examples: current.examples
        ))
    }
}

private struct StubCommitFailure: Error {}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown")
    } catch {
        errorHandler(error)
    }
}

// MARK: - Stubs

/// Simulates the atomic commit transaction for domain tests: records the
/// intended write, honours a forced failure, and persists the committed
/// envelope back through the shared draft store (the note side has no real
/// table here — the GRDB tests cover the guarded update itself).
private actor StubAIRepairCommitStore: AIRepairCommitStore {
    struct Call: Equatable, Sendable {
        let draftID: UUID
        let expectedContentVersion: Int
        let content: AIRepairValidatedContent
    }

    struct SplitCall: Equatable, Sendable {
        let draftID: UUID
        let expectedContentVersion: Int
        let commits: [AIRepairSplitNoteCommit]
        let disposition: AIRepairOriginalCardDisposition
    }

    private let draftStore: InMemoryAIRepairDraftStore
    private(set) var calls: [Call] = []
    private(set) var splitCalls: [SplitCall] = []
    private var error: Error?

    init(draftStore: InMemoryAIRepairDraftStore) {
        self.draftStore = draftStore
    }

    func setError(_ error: Error?) {
        self.error = error
    }

    func commitInPlaceRepair(
        draftID: UUID,
        envelope: AIRepairDraftEnvelope,
        provenance: AIRepairDraftProvenance,
        content: AIRepairValidatedContent,
        newExampleID: UUID,
        updatedAt: Date
    ) async throws {
        calls.append(Call(
            draftID: draftID,
            expectedContentVersion: envelope.expectedContentVersion,
            content: content
        ))
        if let error { throw error }
        try await draftStore.saveDraft(
            id: draftID,
            envelope: envelope,
            provenance: provenance,
            updatedAt: updatedAt
        )
    }

    func commitSplitRepair(
        draftID: UUID,
        envelope: AIRepairDraftEnvelope,
        provenance: AIRepairDraftProvenance,
        commits: [AIRepairSplitNoteCommit],
        originalCardDisposition: AIRepairOriginalCardDisposition,
        updatedAt: Date
    ) async throws {
        splitCalls.append(SplitCall(
            draftID: draftID,
            expectedContentVersion: envelope.expectedContentVersion,
            commits: commits,
            disposition: originalCardDisposition
        ))
        if let error { throw error }
        try await draftStore.saveDraft(
            id: draftID,
            envelope: envelope,
            provenance: provenance,
            updatedAt: updatedAt
        )
    }
}

private actor InMemoryAIRepairDraftStore: AIRepairDraftStore {
    private var drafts: [UUID: AIRepairDraftEnvelope] = [:]

    func saveDraft(
        id: UUID,
        envelope: AIRepairDraftEnvelope,
        provenance: AIRepairDraftProvenance,
        updatedAt: Date
    ) async throws {
        drafts[id] = envelope
    }

    func fetchDraft(id: UUID) async throws -> AIRepairDraftEnvelope? {
        drafts[id]
    }

    func fetchAllDrafts() async throws -> [(id: UUID, envelope: AIRepairDraftEnvelope)] {
        drafts.map { (id: $0.key, envelope: $0.value) }
    }

    func deleteDraft(id: UUID) async throws {
        drafts[id] = nil
    }
}

private actor StubAIRepairClient: AIRepairClient {
    private var result: Result<String, Error> = .failure(AIConnectionError.connectionFailed)
    private var blockFirstCall = false
    private(set) var callCount = 0
    private(set) var lastContext: AIRepairRequestContext?
    private var continuations: [CheckedContinuation<String, Error>] = []

    func analyze(
        context: AIRepairRequestContext,
        configuration: AIConfiguration,
        credential: String
    ) async throws -> String {
        callCount += 1
        lastContext = context
        if blockFirstCall, callCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        }
        return try result.get()
    }

    func setResult(_ result: Result<String, Error>) {
        self.result = result
    }

    func setBlockFirstCall(_ value: Bool) {
        blockFirstCall = value
    }

    func waitForCallCount(_ count: Int) async {
        while callCount < count {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func releaseBlockedCalls() {
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume(with: result)
        }
    }
}

private final class StubAIConfigurationRepository: AIConfigurationRepository, @unchecked Sendable {
    var configuration = AIConfiguration(
        isEnabled: true,
        serviceKind: .custom,
        serviceName: "Fixture",
        baseURL: URL(string: "https://fixture.example/v1")!,
        modelID: "fixture-model",
        responseFormatMode: .jsonObject,
        credentialReference: AICredentialReference(
            id: UUID(),
            serviceKind: .custom,
            host: "fixture.example"
        )
    )

    func loadOrCreateAIConfiguration(defaultTimeZoneID: String) async throws -> AIConfiguration {
        configuration
    }

    func saveAIConfiguration(_ configuration: AIConfiguration) async throws {
        self.configuration = configuration
    }

    func setEnabled(_ enabled: Bool) {
        configuration = AIConfiguration(
            isEnabled: enabled,
            serviceKind: configuration.serviceKind,
            serviceName: configuration.serviceName,
            baseURL: configuration.baseURL,
            modelID: configuration.modelID,
            responseFormatMode: configuration.responseFormatMode,
            credentialReference: configuration.credentialReference
        )
    }
}

private actor StubCredentialStore: AICredentialStore {
    private var credential: String? = "fixture-key"
    func readCredential(for reference: AICredentialReference) async throws -> String? {
        credential
    }

    func saveCredential(_ credential: String, for reference: AICredentialReference) async throws {
        self.credential = credential
    }

    func deleteCredential(for reference: AICredentialReference) async throws {
        credential = nil
    }

    func setCredential(_ value: String?) {
        credential = value
    }
}

private actor StubVocabularyRepository: VocabularyRepository {
    private var note: VocabularyNote?

    func setNote(_ note: VocabularyNote?) {
        self.note = note
    }

    func commitNewVocabulary(_ request: NewVocabularyCommitRequest) async throws -> VocabularyNote {
        fatalError("unused")
    }

    func fetchVocabularySummaries(deckID: UUID) async throws -> [VocabularyNoteSummary] { [] }

    func fetchVocabulary(id: UUID) async throws -> VocabularyNote? {
        note?.id == id ? note : nil
    }

    func saveVocabularyDraft(_ draft: VocabularyDraft) async throws {}
    func fetchLatestVocabularyDraft() async throws -> VocabularyDraft? { nil }
    func fetchVocabularyDraft(id: UUID) async throws -> VocabularyDraft? { nil }
    func deleteVocabularyDraft(id: UUID) async throws {}

    func updateVocabulary(
        id: UUID,
        content: ValidatedVocabularyContent,
        newExampleID: UUID,
        at date: Date
    ) async throws -> VocabularyNote? { nil }
}

private actor StubGrammarRepository: GrammarRepository {
    var note: GrammarNote?

    func fetchGrammar(id: UUID) async throws -> GrammarNote? {
        note?.id == id ? note : nil
    }

    func saveGrammarDraft(_ draft: GrammarDraft) async throws {}
    func fetchLatestGrammarDraft() async throws -> GrammarDraft? { nil }
    func fetchGrammarDraft(id: UUID) async throws -> GrammarDraft? { nil }
    func deleteGrammarDraft(id: UUID) async throws {}

    func updateGrammar(
        id: UUID,
        content: ValidatedGrammarContent,
        newExampleID: UUID,
        at date: Date
    ) async throws -> GrammarNote? { nil }
}

private actor StubContentCardRepository: ContentCardRepository {
    var directions: [CardDirectionState]

    init(directions: [CardDirectionState]) {
        self.directions = directions
    }

    func setDirections(_ directions: [CardDirectionState]) {
        self.directions = directions
    }

    func commitVocabulary(
        _ commit: VocabularyContentCommit,
        capture: CaptureCommitContext?
    ) async throws -> ContentCommitResult {
        fatalError("unused")
    }

    func commitGrammar(
        _ commit: GrammarContentCommit,
        capture: CaptureCommitContext?
    ) async throws -> ContentCommitResult {
        fatalError("unused")
    }

    func fetchCardDirections(noteID: UUID) async throws -> [CardDirectionState] {
        directions
    }

    func replaceEnabledCardDirections(
        _ replacement: CardDirectionReplacement
    ) async throws -> [CardDirectionState] {
        directions
    }

    func setCardEnabled(
        cardID: UUID,
        isEnabled: Bool,
        at updatedAt: Date
    ) async throws -> CardDirectionState {
        directions[0]
    }

    func deleteCard(cardID: UUID) async throws {}
}
