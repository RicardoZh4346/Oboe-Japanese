import Foundation
import GRDB
import XCTest
@testable import Oboe
import OboeDomain
import OboeInfrastructure

/// v0.7.5 S16 Too Easy 驱动测试：真实容器 + GRDB 持久层。
/// 覆盖：应用/清除、CAS 冲突、typed 撤销（不复活驱逐卡）、撤销窗口
/// 过期、custom 会话 sibling 驱逐、听力卡音频停止、歧义拒绝、
/// 跨窗口 flag 命中后的惰性跳卡。
@MainActor
final class TooEasyReviewDriverTests: XCTestCase {

    /// 记录 stop 次数的语音桩件——Too Easy 应用路径必须先停音频
    /// 再驱逐（听力卡题面播放不得越过驱逐继续）。
    @MainActor
    private final class RecordingSpeechService: SpeechService {
        var availability: JapaneseSpeechAvailability =
            .available(voiceName: "stub")
        var stopCount = 0
        func speakWithEvents(
            _ texts: [String],
            onEvent: @escaping SpeechEventHandler
        ) -> UUID { UUID() }
        func stop() { stopCount += 1 }
    }

    private final class Fixture {
        let baseURL: URL
        let database: OboeDatabase
        let container: AppFeatureContainer
        let deckID: UUID
        /// note → 该 note 名下卡的 id（按 note_id 查 cards 表）。
        var cardIDsByNote: [UUID: [UUID]] = [:]
        /// note → 提交时绑定的 unit id。
        var unitIDByNote: [UUID: UUID] = [:]

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

        var learningUnits: any LearningUnitFlagProviding {
            container.shared.learningUnits!
        }
        var learningUnitRepository: GRDBLearningUnitRepository {
            GRDBLearningUnitRepository(database: database)
        }

        func cardID(ofNote noteID: UUID, template templateKind: CardTemplateKind? = nil) -> UUID? {
            cardIDsByNote[noteID]?.first
        }

        func unitID(ofNote noteID: UUID) -> UUID? {
            unitIDByNote[noteID]
        }

        func remove() {
            try? database.close()
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    // MARK: - fixture

    /// 真实库 + 容器。`words` 按 (headword, reading, directions) 建词汇
    /// Note——commitVocabulary 同事务自动建 localNote unit + link。
    private func makeFixture(
        words: [(String, String, Set<VocabularyCardDirection>)] = [
            ("食べる", "たべる", [.japaneseToChinese]),
            ("飲む", "のむ", [.japaneseToChinese]),
            ("見る", "みる", [.japaneseToChinese])
        ]
    ) async throws -> Fixture {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("too-easy-\(UUID().uuidString)")
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
            adaptiveInvalidationCenter: AdaptiveInvalidationCenter(),
            generationSource: DatabaseGenerationSource()
        ) else {
            throw XCTSkip("容器构建失败（内置词库缺失时跳过）。")
        }
        let container = built.container
        let deck = try await container.decks.deckService.createDeck(
            named: "太简单测试"
        )
        let fixture = Fixture(
            baseURL: baseURL,
            database: database,
            container: container,
            deckID: deck.id
        )
        let units = fixture.learningUnits
        for (headword, reading, directions) in words {
            let result = try await container.decks.contentCardService
                .commitVocabulary(
                    draftID: nil,
                    deckID: deck.id,
                    formData: VocabularyFormData(
                        headword: headword,
                        reading: reading,
                        meaningZH: "测试"
                    ),
                    directions: directions
                )
            let noteID = result.noteID
            fixture.unitIDByNote[noteID] = try await units
                .fetchLink(noteID: noteID)?.unitID
            fixture.cardIDsByNote[noteID] = try await database.pool.read {
                db in
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM cards WHERE note_id = ? ORDER BY id",
                    arguments: [DatabaseValueCodec.encode(noteID)]
                ).map { try DatabaseValueCodec.decodeUUID($0) }
            }
        }
        return fixture
    }

    /// 把 `noteID` 重绑到 `unitID`（legacySecondary）——制造「同 unit
    /// 多 Note」的 sibling 场景（D02：换绑走显式 unlink+link）。
    private func rebindNote(
        _ noteID: UUID, to unitID: UUID, in fixture: Fixture
    ) async throws {
        try await fixture.database.pool.write { db in
            if let link = try GRDBLearningUnitRepository.fetchLink(
                noteID: noteID, in: db
            ) {
                try GRDBLearningUnitRepository.unlinkNote(
                    unitID: link.unitID, noteID: noteID, in: db
                )
            }
            try GRDBLearningUnitRepository.linkNote(
                unitID: unitID,
                noteID: noteID,
                role: .legacySecondary,
                origin: .manual,
                atMilliseconds: try DatabaseValueCodec.encode(Date()),
                in: db
            )
        }
        fixture.unitIDByNote[noteID] = unitID
    }

    /// 指定卡序的冻结队列专项会话（`.due` 保序）。
    private func makeSession(
        in fixture: Fixture,
        cardIDs: [UUID],
        mode: CustomStudyMode = .practiceOnly
    ) async throws -> CustomStudySession {
        let repository = fixture.container.shared.customStudyRepository
        let service = fixture.container.shared.customStudyService
        let filter = CustomStudyFilter(
            deckIDs: [fixture.deckID],
            order: .due
        )
        let queue = CustomStudyQueue.ordered(
            cardIDs: cardIDs,
            order: .due,
            randomSeed: nil,
            generatedAt: Date()
        )
        let session = try service.makeSession(
            filter: filter, queue: queue, mode: mode, now: Date()
        )
        try await repository.createSession(session)
        return session
    }

    private func makeModel(
        fixture: Fixture,
        session: CustomStudySession,
        speechService: (any SpeechService)? = nil
    ) -> ReviewViewModel {
        let container = fixture.container
        return ReviewViewModel(
            service: container.today.studyService,
            historyService: container.today.historyService,
            speechPreferencesService: container.today.speechPreferencesService,
            adaptiveCardService: container.today.adaptiveCardService,
            adaptivePreferencesService: container.today.adaptivePreferencesService,
            speechService: speechService ?? container.shared.speechService,
            customStudyRepository: container.shared.customStudyRepository,
            customStudyService: container.shared.customStudyService,
            scope: StudyScope(
                deckID: fixture.deckID,
                title: "专项学习",
                queueSource: .customStudy(
                    sessionID: session.id, mode: session.mode
                )
            )
        )
    }

    // MARK: - 应用 + sibling 驱逐

    func testTooEasyEvictsSameUnitSiblingsInCustomSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let noteIDs = fixture.cardIDsByNote.keys.sorted {
            $0.uuidString < $1.uuidString
        }
        let noteA = noteIDs[0], noteB = noteIDs[1], noteC = noteIDs[2]
        let unitA = try XCTUnwrap(fixture.unitID(ofNote: noteA))
        // noteB 并入 unitA——同 unit 多 Note 的 sibling。
        try await rebindNote(noteB, to: unitA, in: fixture)
        let cardA = try XCTUnwrap(fixture.cardID(ofNote: noteA))
        let cardB = try XCTUnwrap(fixture.cardID(ofNote: noteB))
        let cardC = try XCTUnwrap(fixture.cardID(ofNote: noteC))
        let session = try await makeSession(
            in: fixture, cardIDs: [cardA, cardB, cardC]
        )
        let model = makeModel(fixture: fixture, session: session)
        await model.refresh()
        XCTAssertEqual(model.card?.content.cardID, cardA)
        XCTAssertTrue(model.canApplyTooEasy)

        await model.applyTooEasy()

        // flag 置位 + 事件落库
        let flag = try await fixture.learningUnits.fetchFlag(unitID: unitA)
        XCTAssertEqual(flag?.tooEasy, true)
        // 当前卡与同 unit sibling 全部移出——冻结队列只剩 cardC 呈现。
        XCTAssertEqual(model.card?.content.cardID, cardC)
        XCTAssertEqual(model.customRemainingCount, 0)
        // typed Undo 锚点在；不算评分、不留提交痕迹。
        XCTAssertNotNil(model.pendingTooEasyUndo)
        XCTAssertEqual(model.completedSubmissionCount, 0)
        XCTAssertNil(model.lastSubmission)
        XCTAssertNil(model.pendingSubmission)
        let attempts = try await fixture.container.shared
            .customStudyRepository.fetchAttempts(sessionID: session.id)
        XCTAssertTrue(attempts.isEmpty)
    }

    func testTooEasyCardWithNoUnitLinkIsRejected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let noteID = fixture.cardIDsByNote.keys.first!
        // 人为解除 link——无 unit 证据的 Note 不得按词形猜 unit。
        try await fixture.database.pool.write { db in
            if let link = try GRDBLearningUnitRepository.fetchLink(
                noteID: noteID, in: db
            ) {
                try GRDBLearningUnitRepository.unlinkNote(
                    unitID: link.unitID, noteID: noteID, in: db
                )
            }
        }
        let cardID = try XCTUnwrap(fixture.cardID(ofNote: noteID))
        let session = try await makeSession(in: fixture, cardIDs: [cardID])
        let model = makeModel(fixture: fixture, session: session)
        await model.refresh()
        XCTAssertTrue(model.canApplyTooEasy)

        await model.applyTooEasy()

        XCTAssertNotNil(model.tooEasyErrorMessage)
        // 卡仍在呈现（操作被拒，不驱逐）。
        XCTAssertEqual(model.card?.content.cardID, cardID)
    }

    // MARK: - typed Undo

    func testTooEasyUndoRestoresFlagWithoutReinsertingCards() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let noteIDs = fixture.cardIDsByNote.keys.sorted {
            $0.uuidString < $1.uuidString
        }
        let noteA = noteIDs[0], noteB = noteIDs[1], noteC = noteIDs[2]
        let unitA = try XCTUnwrap(fixture.unitID(ofNote: noteA))
        try await rebindNote(noteB, to: unitA, in: fixture)
        let cardA = try XCTUnwrap(fixture.cardID(ofNote: noteA))
        let cardB = try XCTUnwrap(fixture.cardID(ofNote: noteB))
        let cardC = try XCTUnwrap(fixture.cardID(ofNote: noteC))
        let session = try await makeSession(
            in: fixture, cardIDs: [cardA, cardB, cardC]
        )
        let model = makeModel(fixture: fixture, session: session)
        await model.refresh()
        await model.applyTooEasy()
        XCTAssertEqual(model.card?.content.cardID, cardC)
        XCTAssertNotNil(model.pendingTooEasyUndo)

        await model.undoTooEasyFlag()

        // flag 还原——但本会话不回塞驱逐卡（§12.3）。
        let flag = try await fixture.learningUnits.fetchFlag(unitID: unitA)
        XCTAssertEqual(flag?.tooEasy, false)
        XCTAssertNil(model.pendingTooEasyUndo)
        XCTAssertEqual(model.card?.content.cardID, cardC)
        XCTAssertEqual(model.customRemainingCount, 0)
        XCTAssertEqual(
            model.tooEasyNoticeMessage,
            "已撤销「太简单」——这些卡从下次学习会话起恢复排期。"
        )
    }

    /// typed 栈分发：先评分（practice 栈条目）再太简单——全局撤销
    /// 先撤 flag，再撤才轮到 FSRS/练习撤销，互不串线。
    func testUndoLatestActionDispatchesTooEasyBeforeReview() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let noteIDs = fixture.cardIDsByNote.keys.sorted {
            $0.uuidString < $1.uuidString
        }
        let noteA = noteIDs[0], noteC = noteIDs[2]
        let unitA = try XCTUnwrap(fixture.unitID(ofNote: noteA))
        let cardA = try XCTUnwrap(fixture.cardID(ofNote: noteA))
        let cardC = try XCTUnwrap(fixture.cardID(ofNote: noteC))
        let session = try await makeSession(
            in: fixture, cardIDs: [cardA, cardC]
        )
        let model = makeModel(fixture: fixture, session: session)
        await model.refresh()
        // 先对 cardA 做一次练习评分（栈底 = practice review 条目）。
        model.revealAnswer()
        await model.submit(.good)
        XCTAssertEqual(model.card?.content.cardID, cardC)
        // 对 cardC 应用太简单（栈顶 = tooEasy 条目）。
        let unitC = try XCTUnwrap(fixture.unitID(ofNote: noteC))
        await model.applyTooEasy()
        XCTAssertNil(model.card)
        XCTAssertTrue(model.customIsFinished)
        let flagC = try await fixture.learningUnits.fetchFlag(unitID: unitC)
        XCTAssertEqual(flagC?.tooEasy, true)

        // 全局撤销命中栈顶 tooEasy——还原 flag，不碰 practice attempt。
        await model.undoLatestAction()
        let flagCAfter = try await fixture.learningUnits
            .fetchFlag(unitID: unitC)
        XCTAssertEqual(flagCAfter?.tooEasy, false)
        let attempts = try await fixture.container.shared
            .customStudyRepository.fetchAttempts(sessionID: session.id)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertNil(attempts.first?.undoneAt)
    }

    /// CAS 冲突：另一窗口先动了 flag → 本窗口锚点失效，撤销被拒
    /// 且不覆盖他人值。
    func testTooEasyUndoCASConflictLeavesNewerFlagUntouched() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let noteA = fixture.cardIDsByNote.keys.sorted {
            $0.uuidString < $1.uuidString
        }.first!
        let unitA = try XCTUnwrap(fixture.unitID(ofNote: noteA))
        let cardA = try XCTUnwrap(fixture.cardID(ofNote: noteA))
        let session = try await makeSession(in: fixture, cardIDs: [cardA])
        let model = makeModel(fixture: fixture, session: session)
        await model.refresh()
        await model.applyTooEasy()
        XCTAssertNotNil(model.pendingTooEasyUndo)
        let revisionAfterApply = model.pendingTooEasyUndo!.afterRevision

        // 「另一窗口」直接把 flag 改回 false——revision 前进一格。
        _ = try await fixture.learningUnits.setFlagTooEasy(
            TooEasyCommand(
                unitID: unitA,
                value: false,
                expectedFlagRevision: revisionAfterApply,
                operationID: UUID()
            ),
            at: Date()
        )

        await model.undoTooEasyFlag()

        // 撤销被拒：flag 停在另一窗口的 r+1/false；锚点失效清空。
        let flag = try await fixture.learningUnits.fetchFlag(unitID: unitA)
        XCTAssertEqual(flag?.tooEasy, false)
        XCTAssertEqual(flag?.revision, revisionAfterApply + 1)
        XCTAssertNil(model.pendingTooEasyUndo)
        XCTAssertNotNil(model.tooEasyErrorMessage)
    }

    /// 撤销窗口过期：锚点作废不执行（横幅外也挡一次）。
    func testTooEasyUndoExpiredAnchorIsRejected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let noteA = fixture.cardIDsByNote.keys.sorted {
            $0.uuidString < $1.uuidString
        }.first!
        let unitA = try XCTUnwrap(fixture.unitID(ofNote: noteA))
        let cardA = try XCTUnwrap(fixture.cardID(ofNote: noteA))
        let session = try await makeSession(in: fixture, cardIDs: [cardA])
        let model = makeModel(fixture: fixture, session: session)
        await model.refresh()
        await model.applyTooEasy()
        let pending = try XCTUnwrap(model.pendingTooEasyUndo)

        // 手工把窗口拨到过期（等价于横幅超时后的迟到点击）。
        model.tooEasy.pendingUndo = ReviewTooEasyCoordinator
            .PendingUndo(
                unitID: pending.unitID,
                eventID: pending.eventID,
                beforeValue: pending.beforeValue,
                afterRevision: pending.afterRevision,
                evictedCardID: pending.evictedCardID,
                expiresAt: Date().addingTimeInterval(-1)
            )
        await model.undoTooEasyFlag()

        let flag = try await fixture.learningUnits.fetchFlag(unitID: unitA)
        XCTAssertEqual(flag?.tooEasy, true)
        XCTAssertNil(model.pendingTooEasyUndo)
    }

    // MARK: - 听力卡音频

    func testListeningCardTooEasyStopsAudio() async throws {
        let fixture = try await makeFixture(
            words: [("聞く", "きく", [.listening]),
                    ("見る", "みる", [.japaneseToChinese])]
        )
        defer { fixture.remove() }
        let cardListening = try await fixture.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM cards WHERE template_kind = 'vocabulary_listening'"
            ).map { try DatabaseValueCodec.decodeUUID($0) }
        }
        let listeningID = try XCTUnwrap(cardListening)
        let cardOther = try XCTUnwrap(
            fixture.cardIDsByNote.values.flatMap { $0 }
                .first { $0 != listeningID }
        )
        let speech = RecordingSpeechService()
        let session = try await makeSession(
            in: fixture, cardIDs: [listeningID, cardOther]
        )
        let model = makeModel(
            fixture: fixture, session: session, speechService: speech
        )
        await model.refresh()
        XCTAssertEqual(
            model.card?.content.templateKind, .vocabularyListening
        )
        // 模拟题面播放进行中。
        model.listeningPromptRequestID = UUID()
        model.listeningPromptStatus = .playing
        let stopsBefore = speech.stopCount

        await model.applyTooEasy()

        XCTAssertGreaterThan(speech.stopCount, stopsBefore)
        XCTAssertNil(model.listeningPromptRequestID)
        XCTAssertEqual(model.listeningPromptStatus, .idle)
        XCTAssertEqual(model.card?.content.cardID, cardOther)
    }

    // MARK: - 跨窗口 flag → 本会话惰性跳卡

    /// 另一窗口置位 flag 后，本会话 preserving-refresh 立即驱逐
    /// 当前卡（不依赖观察者投递时序）。
    func testExternalFlagWriteEvictsCurrentCardOnRefresh() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let noteA = fixture.cardIDsByNote.keys.sorted {
            $0.uuidString < $1.uuidString
        }.first!
        let unitA = try XCTUnwrap(fixture.unitID(ofNote: noteA))
        let cardA = try XCTUnwrap(fixture.cardID(ofNote: noteA))
        let cardOther = try XCTUnwrap(
            fixture.cardIDsByNote.values.flatMap { $0 }
                .first { $0 != cardA }
        )
        let session = try await makeSession(
            in: fixture, cardIDs: [cardA, cardOther]
        )
        let model = makeModel(fixture: fixture, session: session)
        await model.refresh()
        XCTAssertEqual(model.card?.content.cardID, cardA)

        // 「另一窗口」写 flag——本会话未本地驱逐，但惰性复核命中。
        _ = try await fixture.learningUnits.setFlagTooEasy(
            TooEasyCommand(
                unitID: unitA,
                value: true,
                expectedFlagRevision: 0,
                operationID: UUID()
            ),
            at: Date()
        )
        await model.refresh(preservingCurrentCard: true)

        XCTAssertEqual(model.card?.content.cardID, cardOther)
    }

    /// observeChanges：同 pool 另一写方的 flag 提交产生观察 ping。
    func testObserveChangesEmitsOnCrossWindowFlagWrite() async throws {
        let fixture = try await makeFixture(
            words: [("食べる", "たべる", [.japaneseToChinese])]
        )
        defer { fixture.remove() }
        let noteID = fixture.cardIDsByNote.keys.first!
        let unitID = try XCTUnwrap(fixture.unitID(ofNote: noteID))
        guard let observing =
            fixture.learningUnits as? any LearningUnitFlagObserving
        else {
            throw XCTSkip("门面无观察能力。")
        }
        let box = StreamIteratorBox(observing.observeChanges())
        // 首个元素是观察建立时的基线——消费掉再写。
        _ = try await box.next()

        _ = try await fixture.learningUnitRepository.setFlagTooEasy(
            TooEasyCommand(
                unitID: unitID,
                value: true,
                expectedFlagRevision: 0,
                operationID: UUID()
            ),
            at: Date()
        )

        let ping = try await withThrowingTimeout(seconds: 5) {
            try await box.next()
        }
        XCTAssertNotNil(ping)
    }

    // MARK: - 操作层（LearningUnitFlagOperator）

    func testOperatorSetClearAndUndoAnchor() async throws {
        let fixture = try await makeFixture(
            words: [("食べる", "たべる", [.japaneseToChinese])]
        )
        defer { fixture.remove() }
        let noteID = fixture.cardIDsByNote.keys.first!
        let unitID = try XCTUnwrap(fixture.unitID(ofNote: noteID))
        let ops = LearningUnitFlagOperator(flags: fixture.learningUnits)

        // 三态：link 存在 → learning。
        let context = try await ops.context(forNoteID: noteID)
        XCTAssertEqual(context?.knowledgeState, .learning)
        XCTAssertEqual(context?.unit.id, unitID)

        // 置位：revision 0→1。
        let flag = try await ops.set(
            true, unitID: unitID, operationID: UUID(), at: Date()
        )
        XCTAssertTrue(flag.tooEasy)
        XCTAssertEqual(flag.revision, 1)
        // mastered 三态。
        let mastered = try await ops.context(forNoteID: noteID)
        XCTAssertEqual(mastered?.knowledgeState, .mastered)

        // 幂等 no-op：值相同不制造空转事件/revision。
        let again = try await ops.set(
            true, unitID: unitID, operationID: UUID(), at: Date()
        )
        XCTAssertEqual(again.revision, 1)

        // 锚点定位 + 撤销：回到 before（false），revision 前进。
        let anchorCandidate = try await ops.undoAnchor(unitID: unitID)
        let anchor = try XCTUnwrap(anchorCandidate)
        let restored = try await ops.undo(anchor, at: Date())
        XCTAssertFalse(restored.tooEasy)
        let undone = try await ops.context(forNoteID: noteID)
        XCTAssertEqual(undone?.knowledgeState, .learning)

        // 撤销后原锚点失效（事件已 undone）——再取应得 nil。
        let anchorAfterUndo = try await ops.undoAnchor(unitID: unitID)
        XCTAssertNil(anchorAfterUndo)

        // 详情页式清除：随时可走 set(false)（不限撤销窗口）。
        _ = try await ops.set(
            true, unitID: unitID, operationID: UUID(), at: Date()
        )
        let cleared = try await ops.set(
            false, unitID: unitID, operationID: UUID(), at: Date()
        )
        XCTAssertFalse(cleared.tooEasy)
    }

    /// CAS：陈旧 expectedRevision 直接冲突不覆盖。
    func testOperatorSetWithStaleRevisionConflicts() async throws {
        let fixture = try await makeFixture(
            words: [("食べる", "たべる", [.japaneseToChinese])]
        )
        defer { fixture.remove() }
        let noteID = fixture.cardIDsByNote.keys.first!
        let unitID = try XCTUnwrap(fixture.unitID(ofNote: noteID))
        let units = fixture.learningUnits

        _ = try await units.setFlagTooEasy(
            TooEasyCommand(
                unitID: unitID, value: true,
                expectedFlagRevision: 0, operationID: UUID()
            ),
            at: Date()
        )
        // 「另一窗口」先写入后，本窗口拿旧 revision(0) 重写 → 冲突。
        await XCTAssertThrowsErrorAsync {
            _ = try await units.setFlagTooEasy(
                TooEasyCommand(
                    unitID: unitID, value: false,
                    expectedFlagRevision: 0, operationID: UUID()
                ),
                at: Date()
            )
        } errorHandler: { error in
            guard case .flagRevisionConflict =
                error as? LearningUnitRepositoryError
            else {
                return XCTFail("期望 flagRevisionConflict，得到 \(error)")
            }
        }
        let flag = try await units.fetchFlag(unitID: unitID)
        XCTAssertEqual(flag?.tooEasy, true)
        XCTAssertEqual(flag?.revision, 1)
    }

    /// 歧义拒绝：同 lemma 多 unit ——按 Note 链接解析出多个 unit
    /// 时调用方必须拒绝合并（Inspector 上层按此结果走 ambiguous）。
    func testOperatorAmbiguousMultiUnitLookupReturnsAllUnits() async throws {
        // 两条同词形 Note——各自 localNote unit（无词典证据时
        // unit 各立门户，正是「同 lemma 多 unit」场景）。
        let fixture = try await makeFixture(
            words: [
                ("行く", "いく", [.japaneseToChinese]),
                ("行く", "いく", [.japaneseToChinese])
            ]
        )
        defer { fixture.remove() }
        let noteIDs = fixture.cardIDsByNote.keys.sorted {
            $0.uuidString < $1.uuidString
        }
        let unitA = try XCTUnwrap(fixture.unitID(ofNote: noteIDs[0]))
        let unitB = try XCTUnwrap(fixture.unitID(ofNote: noteIDs[1]))
        XCTAssertNotEqual(unitA, unitB)

        let ops = LearningUnitFlagOperator(flags: fixture.learningUnits)
        let ids = try await ops.unitIDs(linkedToNoteIDs: noteIDs)
        XCTAssertEqual(ids, [unitA, unitB])
        // 无 link 的 Note → nil（「未关联」，绝不猜）。
        let unlinked = try await ops.unit(forNoteID: UUID())
        XCTAssertNil(unlinked)
        let context = try await ops.context(forNoteID: UUID())
        XCTAssertNil(context)
    }

    // MARK: - 帮助

    private func withThrowingTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private struct TimeoutError: Error {}
}

/// `AsyncThrowingStream.Iterator` 非 Sendable——@Sendable 超时竞速
/// 闭包借箱式引用持有（测试内串行消费，无真实竞态）。
private final class StreamIteratorBox<Element>: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Element, Error>.Iterator

    init(_ stream: AsyncThrowingStream<Element, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Element? {
        try await iterator.next()
    }
}

/// `async` 断言帮助：`XCTAssertThrowsError` 不直接吃 async 闭包。
/// @MainActor 与测试类同域——闭包不跨隔离发送（strict 并发下
/// nonisolated 形参会触发 sending 诊断）。
@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    errorHandler: (Error) -> Void
) async {
    do {
        try await expression()
        XCTFail("期望抛错但未抛")
    } catch {
        errorHandler(error)
    }
}
