import Foundation
import XCTest
@testable import Oboe
import OboeDomain
import OboeInfrastructure

/// S09 专项学习驱动测试：真实容器 + GRDB 持久层，验证冻结队列推进、
/// practice 提交/撤销、scheduled 正式提交来源与完成/重开状态。
@MainActor
final class CustomStudyReviewDriverTests: XCTestCase {

    private final class Fixture {
        let baseURL: URL
        let database: OboeDatabase
        let container: AppFeatureContainer
        let deckID: UUID

        init(
            baseURL: URL,
            database: OboeDatabase,
            container: AppFeatureContainer,
            deckID: UUID
        ) {
            self.baseURL = baseURL
            self.database = database
            self.container = container
            self.deckID = deckID
        }

        func remove() {
            try? database.close()
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    // MARK: - fixture

    /// 真实 OB 库 + 容器：两张 `japaneseToChinese` 词汇卡进同一牌组。
    private func makeFixture() async throws -> Fixture {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-study-driver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: baseURL, withIntermediateDirectories: true
        )
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: baseURL.appendingPathComponent("oboe.sqlite"),
            snapshotDirectoryURL: baseURL.appendingPathComponent(
                "Snapshots", isDirectory: true
            )
        )
        let database = try await lifecycle.open()
        guard let built = AppFeatureContainerFactory.makeServices(
            database: database,
            generation: 1,
            baseURL: baseURL,
            bootstrap: AppBootstrapEnvironment(),
            adaptiveInvalidationCenter: AdaptiveInvalidationCenter()
        ) else {
            throw XCTSkip("容器构建失败（内置词库缺失时跳过）。")
        }
        let container = built.container
        let deck = try await container.decks.deckService.createDeck(named: "专项测试")
        for (headword, reading) in [("食べる", "たべる"), ("飲む", "のむ")] {
            _ = try await container.decks.contentCardService.commitVocabulary(
                draftID: nil,
                deckID: deck.id,
                formData: VocabularyFormData(
                    headword: headword,
                    reading: reading,
                    meaningZH: "测试"
                ),
                directions: Set<VocabularyCardDirection>([.japaneseToChinese])
            )
        }
        return Fixture(
            baseURL: baseURL,
            database: database,
            container: container,
            deckID: deck.id
        )
    }

    private func makeSession(
        in fixture: Fixture,
        mode: CustomStudyMode
    ) async throws -> CustomStudySession {
        let repository = fixture.container.shared.customStudyRepository
        let service = fixture.container.shared.customStudyService
        let filter = CustomStudyFilter(deckIDs: [fixture.deckID])
        let cardIDs = try await repository.buildQueue(
            filter: filter,
            context: CustomStudyQueueContext(now: Date())
        )
        let queue = CustomStudyQueue.ordered(
            cardIDs: cardIDs,
            order: filter.order,
            randomSeed: filter.randomSeed,
            generatedAt: Date()
        )
        let session = try service.makeSession(
            filter: filter,
            queue: queue,
            mode: mode,
            now: Date()
        )
        try await repository.createSession(session)
        return session
    }

    private func makeModel(
        fixture: Fixture,
        session: CustomStudySession
    ) -> ReviewViewModel {
        let container = fixture.container
        return ReviewViewModel(
            service: container.today.studyService,
            historyService: container.today.historyService,
            speechPreferencesService: container.today.speechPreferencesService,
            adaptiveCardService: container.today.adaptiveCardService,
            adaptivePreferencesService: container.today.adaptivePreferencesService,
            speechService: container.shared.speechService,
            customStudyRepository: container.shared.customStudyRepository,
            customStudyService: container.shared.customStudyService,
            scope: StudyScope(
                deckID: fixture.deckID,
                title: "专项学习",
                queueSource: .customStudy(
                    sessionID: session.id,
                    mode: session.mode
                )
            )
        )
    }

    // MARK: - 队列推进

    func testPracticeLoadPresentsFrozenCard() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let session = try await makeSession(in: fixture, mode: .practiceOnly)
        XCTAssertEqual(session.queue.cardIDs.count, 2)
        let model = makeModel(fixture: fixture, session: session)

        await model.refresh()

        XCTAssertNotNil(model.card)
        XCTAssertEqual(
            model.card?.content.cardID,
            session.queue.cardIDs.first
        )
        XCTAssertNil(model.plan)
        XCTAssertNil(model.currentItem)
        XCTAssertFalse(model.customIsFinished)
        XCTAssertTrue(model.isCustomSession)
        XCTAssertFalse(model.showsIntervals)
    }

    // MARK: - practice 提交

    func testPracticeSubmitRecordsAttemptWithoutReviewLog() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let session = try await makeSession(in: fixture, mode: .practiceOnly)
        let model = makeModel(fixture: fixture, session: session)
        await model.refresh()
        let firstCardID = try XCTUnwrap(model.card?.content.cardID)

        model.revealAnswer()
        await model.submit(.good)

        let repository = fixture.container.shared.customStudyRepository
        let attempts = try await repository.fetchAttempts(sessionID: session.id)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.rating, .good)
        XCTAssertEqual(attempts.first?.cardKey, firstCardID)
        XCTAssertNil(attempts.first?.undoneAt)
        // practice 不登记正式来源（不写 review_logs 的旁证）。
        let eventID = try XCTUnwrap(attempts.first?.eventID)
        let origin = try await repository.fetchScheduledOrigin(eventID: eventID)
        XCTAssertNil(origin)
        // 推进到第二张卡。
        XCTAssertEqual(
            model.card?.content.cardID,
            session.queue.cardIDs.last
        )
        XCTAssertTrue(model.canUndo)
    }

    func testPracticeUndoRestoresCardToQueueHead() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let session = try await makeSession(in: fixture, mode: .practiceOnly)
        let model = makeModel(fixture: fixture, session: session)
        await model.refresh()
        let firstCardID = try XCTUnwrap(model.card?.content.cardID)
        model.revealAnswer()
        await model.submit(.again)

        await model.undoLastSubmission()

        let repository = fixture.container.shared.customStudyRepository
        let attempts = try await repository.fetchAttempts(sessionID: session.id)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertNotNil(attempts.first?.undoneAt)
        XCTAssertEqual(model.card?.content.cardID, firstCardID)
        XCTAssertFalse(model.canUndo)
    }

    func testQueueExhaustionFinishesSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let session = try await makeSession(in: fixture, mode: .practiceOnly)
        let model = makeModel(fixture: fixture, session: session)

        for _ in 0 ..< 2 {
            await model.refresh()
            model.revealAnswer()
            await model.submit(.good)
        }

        XCTAssertTrue(model.customIsFinished)
        XCTAssertNil(model.card)
        let repository = fixture.container.shared.customStudyRepository
        let persisted = try await repository.fetchSession(id: session.id)
        XCTAssertEqual(persisted?.status, .finished)
    }

    // MARK: - scheduled 提交

    func testScheduledSubmitWritesReviewLogAndOrigin() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let session = try await makeSession(in: fixture, mode: .scheduled)
        let model = makeModel(fixture: fixture, session: session)
        await model.refresh()
        XCTAssertNotNil(model.card)

        model.revealAnswer()
        await model.submit(.good)

        let repository = fixture.container.shared.customStudyRepository
        // scheduled 不走 practice_attempts。
        let attempts = try await repository.fetchAttempts(sessionID: session.id)
        XCTAssertTrue(attempts.isEmpty)
        // 正式提交 + 来源登记（review_logs.event_id → session）。
        let eventID = try XCTUnwrap(model.lastSubmission?.eventID)
        let origin = try await repository.fetchScheduledOrigin(eventID: eventID)
        XCTAssertEqual(origin?.sessionID, session.id)
        XCTAssertEqual(origin?.submissionKind, .customScheduled)
        XCTAssertTrue(model.showsIntervals)
    }

    // MARK: - 重开

    func testRestartCreatesFreshSessionWithNewID() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let session = try await makeSession(in: fixture, mode: .practiceOnly)
        let model = makeModel(fixture: fixture, session: session)
        for _ in 0 ..< 2 {
            await model.refresh()
            model.revealAnswer()
            await model.submit(.good)
        }
        XCTAssertTrue(model.customIsFinished)

        await model.restartCustomSession()

        XCTAssertFalse(model.customIsFinished)
        XCTAssertNotNil(model.card)
        XCTAssertEqual(model.customPresentedCount, 0)
        let repository = fixture.container.shared.customStudyRepository
        let active = try await repository.fetchActiveSession()
        XCTAssertNotEqual(active?.id, session.id)
        // 旧会话已是终态 .finished——createSession 只打断仍 active 的，
        // 不复写已完成的终态（原子启动语义，持久层契约）。
        let old = try await repository.fetchSession(id: session.id)
        XCTAssertEqual(old?.status, .finished)
    }
}
