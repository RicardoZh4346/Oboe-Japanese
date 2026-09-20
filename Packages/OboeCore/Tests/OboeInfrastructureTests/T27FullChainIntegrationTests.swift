import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T27: the full P0 chain on one real database — 复习失败 → 易错 → AI
/// 拆卡提交（预览采纳的持久化边界）→ 新卡学习 → 备份导出 → 恢复准备 →
/// 恢复库上重算。Every leg reads through the same services the app uses,
/// so a regression in scheduling, adaptive evidence, split atomicity or
/// the backup contract breaks the chain instead of a mocked surrogate.
final class T27FullChainIntegrationTests: XCTestCase {
    private var fixture: AdaptiveDatabaseFixture!
    private let now = AdaptiveDatabaseFixture.baseDate
    private let timeZoneID = AdaptiveDatabaseFixture.timeZoneID

    override func setUp() async throws {
        fixture = try await AdaptiveDatabaseFixture.make()
    }

    override func tearDown() {
        fixture?.remove()
        fixture = nil
    }

    func testFailureToLeechToSplitToLearnToBackupRestoreChain() async throws {
        let repository = GRDBAdaptiveRepository(database: fixture.database)
        let service = AdaptiveCardService(repository: repository)

        // ── 1) 复习失败 → 易错 ──────────────────────────────────────
        // The previously-fresh ja→zh card fails six due reviews — the
        // same evidence shape the real submission path writes.
        let failingCard = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        try await fixture.updateScheduling(
            cardID: failingCard,
            state: .review,
            dueAt: now.addingTimeInterval(86_400),
            stability: 1.0, difficulty: 9.0, repetitions: 15, lapses: 6,
            firstStudiedAt: now.addingTimeInterval(-40 * 86_400),
            stateVersion: 15
        )
        for index in 0..<6 {
            let reviewedAt = now.addingTimeInterval(TimeInterval(-(index + 1)) * 86_400)
            try await fixture.insertReviewLog(
                cardKey: failingCard, cardID: failingCard,
                noteID: fixture.freshNote.noteID, deckID: fixture.deckAID,
                rating: .again,
                reviewedAt: reviewedAt,
                previousSnapshot: fixture.snapshot(
                    state: .review,
                    dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 3.0, difficulty: 8.8, repetitions: 9 + index,
                    lapses: 5, stateVersion: index * 2
                ),
                nextSnapshot: fixture.snapshot(
                    state: .relearning,
                    dueAt: reviewedAt.addingTimeInterval(600_000),
                    stability: 1.0, difficulty: 9.0, repetitions: 10 + index,
                    lapses: 6, stateVersion: index * 2 + 1
                )
            )
        }
        var snapshot = try await service.snapshot(scope: .all, at: now)
        let leechIDs = Set(snapshot.items(matching: .leech).map(\.cardID))
        XCTAssertTrue(leechIDs.contains(failingCard), "连续到期 Again 必须进入易错集")
        XCTAssertEqual(snapshot.leechCount, 2, "failingCard + 夹具自带 lapsedCard")

        // ── 2) AI 建议 → 预览 → 拆卡提交 ────────────────────────────
        // The commit path is the durable boundary of the preview→adopt
        // flow: guards run inside one write, then new notes/cards, the
        // original-card disposition and the committed-draft receipt.
        let commitRepo = GRDBAIRepairCommitRepository(database: fixture.database)
        let drafts = GRDBAIRepairDraftRepository(database: fixture.database)
        let kinds: [CardTemplateKind] = [
            .vocabularyJapaneseToChinese, .vocabularyChineseToJapanese
        ]
        let draftID = UUID()
        try await drafts.saveDraft(
            id: draftID,
            envelope: AIRepairDraftEnvelope(
                targetNoteID: fixture.freshNote.noteID,
                targetCardID: failingCard,
                expectedContentVersion: 1,
                targetCardEnabled: true,
                affectedTemplateKinds: kinds,
                operationID: UUID(),
                phase: .committing
            ),
            provenance: Self.provenance,
            updatedAt: now
        )
        let commits = (0..<2).map { index in
            AIRepairSplitNoteCommit(
                noteID: UUID(),
                exampleID: UUID(),
                deckID: fixture.deckAID,
                content: .vocabulary(ValidatedVocabularyContent(
                    headword: "拆分\(index + 1)",
                    reading: "よみ\(index + 1)",
                    meaningZH: "释义\(index + 1)",
                    partOfSpeech: nil,
                    jlpt: nil,
                    example: VocabularyExampleContent(
                        japanese: "例文\(index + 1)です。",
                        translationZH: nil
                    ),
                    notes: nil
                )),
                cards: [
                    NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese),
                    NewCardSeed(id: UUID(), templateKind: .vocabularyChineseToJapanese)
                ],
                schedulerProfileID: UUID(),
                createdAt: now
            )
        }
        let operationID = UUID()
        try await commitRepo.commitSplitRepair(
            draftID: draftID,
            envelope: AIRepairDraftEnvelope(
                targetNoteID: fixture.freshNote.noteID,
                targetCardID: failingCard,
                expectedContentVersion: 1,
                targetCardEnabled: true,
                affectedTemplateKinds: kinds,
                operationID: operationID,
                phase: .committed,
                commitReceipt: AIRepairCommitReceipt(
                    operationID: operationID,
                    payloadHash: String(repeating: "a", count: 64),
                    createdNoteIDs: commits.map(\.noteID),
                    createdCardIDs: commits.flatMap { $0.cards.map(\.id) },
                    originalCardDisposition: .pause
                )
            ),
            provenance: Self.provenance,
            commits: commits,
            originalCardDisposition: .pause,
            updatedAt: now
        )

        // Original card suspended → leaves the enabled-leech filter; the
        // split cards join the analysed set as unstarted New cards.
        snapshot = try await service.snapshot(scope: .all, at: now)
        XCTAssertEqual(snapshot.leechCount, 1, "暂停的原卡退出易错筛选")
        let suspendedIDs = Set(snapshot.items(matching: .suspended).map(\.cardID))
        XCTAssertTrue(suspendedIDs.contains(failingCard))
        let analysedIDs = Set(snapshot.items.map(\.cardID))
        for card in commits.flatMap(\.cards) {
            XCTAssertTrue(analysedIDs.contains(card.id), "拆卡新卡必须进入分析集")
        }

        // ── 3) 新卡学习 ─────────────────────────────────────────────
        // A split card takes its first study and a Good due review —
        // it stays enabled + normal, never inheriting the leech state.
        let learningCard = commits[0].cards[0].id
        let learningNote = commits[0].noteID
        let learnedAt = now.addingTimeInterval(-86_400)
        try await fixture.insertReviewLog(
            cardKey: learningCard, cardID: learningCard,
            noteID: learningNote, deckID: fixture.deckAID,
            rating: .good,
            reviewedAt: learnedAt,
            previousSnapshot: fixture.snapshot(
                state: .new,
                dueAt: learnedAt,
                stability: 0, difficulty: 0, repetitions: 0,
                lapses: 0, stateVersion: 0
            ),
            nextSnapshot: fixture.snapshot(
                state: .learning,
                dueAt: learnedAt.addingTimeInterval(600),
                stability: 1.0, difficulty: 5.0, repetitions: 1,
                lapses: 0, stateVersion: 1
            ),
            wasFirstStudy: true
        )
        try await fixture.updateScheduling(
            cardID: learningCard,
            state: .learning,
            dueAt: learnedAt.addingTimeInterval(600),
            stability: 1.0, difficulty: 5.0, repetitions: 1, lapses: 0,
            firstStudiedAt: learnedAt,
            stateVersion: 1
        )
        snapshot = try await service.snapshot(scope: .all, at: now)
        let learningItem = try XCTUnwrap(
            snapshot.items.first { $0.cardID == learningCard }
        )
        XCTAssertEqual(learningItem.assessment.status, .normal)
        XCTAssertTrue(learningItem.isEnabled)
        XCTAssertEqual(snapshot.leechCount, 1)

        // ── 4) 备份 → 恢复 → 重算一致 ──────────────────────────────
        let sourceTrend = try await AdaptiveTrendService(
            repository: repository
        ).report(at: now, learningTimeZoneID: timeZoneID)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-T27Chain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let export = try await PortableBackupExporter(
            database: fixture.database,
            workingDirectoryURL: root.appendingPathComponent("exports", isDirectory: true)
        ).export(appVersion: "test", at: now)
        let current = try OboeDatabase(path: root.appendingPathComponent("current.sqlite").path)
        let prepared = try await PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: root.appendingPathComponent("preparations", isDirectory: true)
        ).prepare(fileURL: export.url)
        defer {
            Task { try? await PortableBackupRestorationPreparer(
                currentDatabase: current,
                workingDirectoryURL: root.appendingPathComponent("preparations", isDirectory: true)
            ).discard(prepared) }
            try? current.close()
        }

        let restored = try OboeDatabase(path: prepared.temporaryDatabaseURL.path)
        defer { try? restored.close() }
        let restoredRepository = GRDBAdaptiveRepository(database: restored)
        let restoredSnapshot = try await AdaptiveCardService(
            repository: restoredRepository
        ).snapshot(scope: .all, at: now)
        let restoredTrend = try await AdaptiveTrendService(
            repository: restoredRepository
        ).report(at: now, learningTimeZoneID: timeZoneID)

        // v12：恢复会补齐词汇笔记缺失的方向卡——恢复集是原分析集的超集，
        // 多出的只能是补齐的未学 New 卡（normal、无学习记录）。
        let sourceCardIDs = Set(snapshot.items.map(\.cardID))
        XCTAssertTrue(
            Set(restoredSnapshot.items.map(\.cardID)).isSuperset(of: sourceCardIDs)
        )
        for item in restoredSnapshot.items where !sourceCardIDs.contains(item.cardID) {
            XCTAssertEqual(item.assessment.status, .normal, "补齐方向卡必须是普通未学新卡")
            XCTAssertNil(item.lastReviewedAt)
        }
        XCTAssertEqual(restoredSnapshot.leechCount, snapshot.leechCount)
        XCTAssertEqual(
            Set(restoredSnapshot.items(matching: .suspended).map(\.cardID)),
            Set(snapshot.items(matching: .suspended).map(\.cardID))
        )
        for item in snapshot.items {
            let restoredItem = restoredSnapshot.items.first { $0.cardID == item.cardID }
            XCTAssertEqual(
                restoredItem?.assessment.status, item.assessment.status,
                "恢复后卡 \(item.cardID) 状态必须一致"
            )
        }
        XCTAssertGreaterThanOrEqual(
            restoredTrend.analyzedCardCount, sourceTrend.analyzedCardCount
        )
        XCTAssertEqual(restoredTrend.weekStartLeechCount, sourceTrend.weekStartLeechCount)
        XCTAssertEqual(restoredTrend.currentLeechCount, sourceTrend.currentLeechCount)
        XCTAssertEqual(restoredTrend.weekLeechCount, sourceTrend.weekLeechCount)
        XCTAssertEqual(restoredTrend.newlyAppearedCount, sourceTrend.newlyAppearedCount)
        XCTAssertEqual(restoredTrend.stillLeechCount, sourceTrend.stillLeechCount)
        XCTAssertEqual(restoredTrend.recoveredStableCount, sourceTrend.recoveredStableCount)
        XCTAssertEqual(restoredTrend.improvedCount, sourceTrend.improvedCount)
        XCTAssertEqual(restoredTrend.suspendedCount, sourceTrend.suspendedCount)

        // The committed draft + receipt ride the backup too.
        let draftCount = try await restored.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM drafts WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(draftID)]
            ) ?? 0
        }
        XCTAssertEqual(draftCount, 1, "已提交草稿与回执必须随备份恢复")
    }

    private static var provenance: AIRepairDraftProvenance {
        AIRepairDraftProvenance(
            providerID: "custom",
            modelID: "chain-fixture",
            promptVersion: "oboe-ai-repair-v1"
        )
    }
}
