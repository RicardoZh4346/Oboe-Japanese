import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S08（角色 C）：`SchedulingEligibility` 在四条读写路径上的
/// 冻结行为矩阵（contracts §2.2/§2.3、decisions D15、技术文档 §12.2）。
///
/// 矩阵维度：
/// - 路径：TodayQueue（新/旧 daily_tasks、due、牌组过滤、剩余计数）、
///   StudyDayPlanning（新卡候选/预约释放/额度重算）、CustomStudy
///   （buildQueue/count/frozen 恢复/practice 提交复核）、
///   ReviewSubmission（commitReview 事务内迟到复核）。
/// - 内容：普通词汇卡 enabled/tooEasy 组合、Cloze/Grammar 模板、
///   迟到正式评分、practiceOnly ± includeMastered、额度与预约释放。
///
/// 核心不变量：tooEasy 是 unit 知识 flag——绝不改 `cards.is_enabled`、
/// 不动 FSRS/review_logs/firstStudiedAt；缺失 link/flag 行按 false。
final class GRDBEligibilityMatrixTests: XCTestCase {
    /// 固定「当前学习时区下午」的评测时刻（Asia/Shanghai 12:00——
    /// 在 04:00 边界内的同一学习日）。
    private let now = localDate(2027, 1, 5, 12, 0, timeZoneID: "Asia/Shanghai")

    private static let threeDirections: [CardTemplateKind] = [
        .vocabularyJapaneseToChinese,
        .vocabularyChineseToJapanese,
        .vocabularyListening,
    ]

    // MARK: - Today Queue

    /// 三个词汇方向同时出局、解除 flag 全部回到队列；`is_enabled`
    /// 全程不被 tooEasy 触碰（两维正交，§12.2 禁令）。
    func testTodayQueueDropsAllThreeDirectionsAndRestoresOnClear() async throws {
        let fixture = try await EligibilityFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        var cards: [UUID] = []
        for (offset, template) in Self.threeDirections.enumerated() {
            cards.append(
                try await fixture.addCard(
                    noteID: noteID,
                    template: template,
                    state: .new,
                    dueAt: now.addingTimeInterval(TimeInterval(offset))
                )
            )
        }
        let unitID = try await fixture.linkNewUnit(noteID: noteID)
        let queue = GRDBTodayQueueRepository(database: fixture.database)
        let build = BuildTodayPlan(
            studyDayRepository: GRDBStudyDayPlanningRepository(
                database: fixture.database
            ),
            queueRepository: queue
        )

        var plan = try await build(at: now, defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertEqual(
            Set(plan.availableNow.map(\.cardID)),
            Set(cards),
            "未标 flag 时三个方向都在新卡队列"
        )

        try await fixture.setTooEasy(unitID: unitID, value: true)
        plan = try await build(
            at: now.addingTimeInterval(60),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertTrue(
            plan.availableNow.isEmpty && plan.availableLater.isEmpty,
            "tooEasy 单元的三方向卡不得出现在今日队列"
        )
        XCTAssertEqual(plan.summary.newCount, 0)
        for cardID in cards {
            let stillEnabled = try await fixture.isEnabled(cardID: cardID)
            XCTAssertTrue(
                stillEnabled,
                "tooEasy 不得被实现成 is_enabled = 0"
            )
        }

        try await fixture.setTooEasy(unitID: unitID, value: false)
        plan = try await build(
            at: now.addingTimeInterval(120),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(
            Set(plan.availableNow.map(\.cardID)),
            Set(cards),
            "flag 解除后三方向按正常额度重排回到队列"
        )
    }

    /// due 路径：review 态卡被 flag 剔除，历史 completedCount 保留；
    /// 解除后已到期 enabled 卡自动回队（§12.2「恢复正常队列」）。
    func testTodayQueueDueCardFlaggedAndCompletedHistoryPreserved() async throws {
        let fixture = try await EligibilityFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let queue = GRDBTodayQueueRepository(database: fixture.database)
        let build = BuildTodayPlan(
            studyDayRepository: GRDBStudyDayPlanningRepository(
                database: fixture.database
            ),
            queueRepository: queue
        )
        let dayPlan = try await build(at: now, defaultTimeZoneID: "Asia/Shanghai")
        let studyDay = dayPlan.studyDay

        // A：今日到期的 review 卡——走 dueRows 动态准入。
        let noteA = try await fixture.addNote(deckID: deckID)
        let cardA = try await fixture.addCard(
            noteID: noteA,
            template: .vocabularyJapaneseToChinese,
            state: .review,
            dueAt: now.addingTimeInterval(-60),
            firstStudiedAt: now.addingTimeInterval(-86_400)
        )
        let unitA = try await fixture.linkNewUnit(noteID: noteA)
        // B：已学过且 due 推到学习日之外——completedCount 的锚点。
        let noteB = try await fixture.addNote(deckID: deckID)
        let cardB = try await fixture.addCard(
            noteID: noteB,
            template: .vocabularyJapaneseToChinese,
            state: .review,
            dueAt: studyDay.endsAt.addingTimeInterval(3_600),
            firstStudiedAt: now.addingTimeInterval(-86_400)
        )
        let unitB = try await fixture.linkNewUnit(noteID: noteB)
        try await fixture.admitTask(
            cardID: cardB,
            studyDayID: studyDay.id,
            category: "review"
        )
        try await fixture.insertReviewLog(
            cardID: cardB,
            noteID: noteB,
            studyDayID: studyDay.id,
            reviewedAt: now
        )

        var summary = try await queue.fetchSummary(
            for: studyDay,
            deckID: nil,
            at: now
        )
        XCTAssertEqual(summary.completedCount, 1, "今日已学先占位")
        var plan = try await build(
            at: now.addingTimeInterval(30),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertTrue(
            plan.availableNow.contains { $0.cardID == cardA },
            "未标 flag 时 A 出现在 due 队列"
        )

        try await fixture.setTooEasy(unitID: unitA, value: true)
        try await fixture.setTooEasy(unitID: unitB, value: true)
        summary = try await queue.fetchSummary(
            for: studyDay,
            deckID: nil,
            at: now.addingTimeInterval(60)
        )
        plan = try await build(
            at: now.addingTimeInterval(60),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertFalse(
            plan.availableNow.contains { $0.cardID == cardA },
            "tooEasy 后 due 队列剔除 A"
        )
        XCTAssertEqual(
            summary.completedCount,
            1,
            "历史已完成评分数不随 flag 消失（daily_tasks/review_logs 保留）"
        )
        XCTAssertEqual(summary.reviewCount, 0)

        try await fixture.setTooEasy(unitID: unitA, value: false)
        plan = try await build(
            at: now.addingTimeInterval(120),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertTrue(
            plan.availableNow.contains { $0.cardID == cardA },
            "解除 flag 后已到期 enabled 卡恢复今日队列"
        )
    }

    /// 同一张已挂单元且被 flag 的 vocabulary Note：其三方向卡出局，
    /// 但 cloze/grammar 模板照常出现——非词汇模板不受 flag 影响。
    func testTodayQueueNonVocabularyTemplatesUnaffectedOnFlaggedNote() async throws {
        let fixture = try await EligibilityFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let vocabCard = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            state: .new,
            dueAt: now
        )
        let clozeCard = try await fixture.addCard(
            noteID: noteID,
            template: .sentenceCloze,
            state: .new,
            dueAt: now.addingTimeInterval(1)
        )
        let grammarCard = try await fixture.addCard(
            noteID: noteID,
            template: .grammarFormToExplanation,
            state: .new,
            dueAt: now.addingTimeInterval(2)
        )
        let unitID = try await fixture.linkNewUnit(noteID: noteID)
        try await fixture.setTooEasy(unitID: unitID, value: true)

        let build = BuildTodayPlan(
            studyDayRepository: GRDBStudyDayPlanningRepository(
                database: fixture.database
            ),
            queueRepository: GRDBTodayQueueRepository(
                database: fixture.database
            )
        )
        let plan = try await build(at: now, defaultTimeZoneID: "Asia/Shanghai")
        let ids = Set(plan.availableNow.map(\.cardID))
        XCTAssertFalse(ids.contains(vocabCard))
        XCTAssertTrue(ids.contains(clozeCard), "sentence_cloze 不受 tooEasy 影响")
        XCTAssertTrue(ids.contains(grammarCard), "grammar 模板不受 tooEasy 影响")
    }

    // MARK: - Study Day Planning

    /// 预约释放：flag 后未学习 'new' 预约让位给候补词；解除后旧卡
    /// 按正常额度规则（最早入队优先）竞争回来——不是盲目恢复。
    func testPlannerReleasesTooEasyReservationAndRequeuesNormally() async throws {
        let fixture = try await EligibilityFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck(sortOrder: 0)
        var unitIDs: [UUID] = []
        var cardIDs: [UUID] = []
        for index in 0..<3 {
            let noteID = try await fixture.addNote(deckID: deckID)
            cardIDs.append(
                try await fixture.addCard(
                    noteID: noteID,
                    template: .vocabularyJapaneseToChinese,
                    state: .new,
                    dueAt: now.addingTimeInterval(TimeInterval(index))
                )
            )
            unitIDs.append(try await fixture.linkNewUnit(noteID: noteID))
        }
        let prepare = PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(
                database: fixture.database
            )
        )

        let initial = try await prepare.setDailyNewCardLimit(
            2,
            at: now,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(
            Set(initial.reservations.map(\.cardID)),
            Set([cardIDs[0], cardIDs[1]]),
            "基线：A/B 拿到两个名额"
        )

        try await fixture.setTooEasy(unitID: unitIDs[0], value: true)
        let flagged = try await prepare(
            at: now.addingTimeInterval(30),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(
            Set(flagged.reservations.map(\.cardID)),
            Set([cardIDs[1], cardIDs[2]]),
            "tooEasy 释放未学习预约，C 补位"
        )
        XCTAssertEqual(flagged.reservedNoteCount, 2)
        for cardID in cardIDs {
            let stillEnabled = try await fixture.isEnabled(cardID: cardID)
            XCTAssertTrue(
                stillEnabled,
                "planner 也不得把 tooEasy 写成 is_enabled = 0"
            )
        }

        try await fixture.setTooEasy(unitID: unitIDs[0], value: false)
        let restored = try await prepare(
            at: now.addingTimeInterval(60),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(
            Set(restored.reservations.map(\.cardID)),
            Set([cardIDs[0], cardIDs[1]]),
            "解除后按正常额度重排——A 凭最早入队时间赢回名额"
        )
    }

    /// 用户停用的卡与 flag 正交：停用不因 flag 改变，也不进预约。
    func testPlannerKeepsDisabledCardExcludedIndependently() async throws {
        let fixture = try await EligibilityFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let cardID = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            state: .new,
            dueAt: now,
            isEnabled: false
        )
        let unitID = try await fixture.linkNewUnit(noteID: noteID)
        let prepare = PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(
                database: fixture.database
            )
        )
        var plan = try await prepare.setDailyNewCardLimit(
            5,
            at: now,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertTrue(plan.reservations.isEmpty)

        try await fixture.setTooEasy(unitID: unitID, value: true)
        plan = try await prepare(
            at: now.addingTimeInterval(30),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertTrue(plan.reservations.isEmpty)
        let stillDisabled = try await fixture.isEnabled(cardID: cardID)
        XCTAssertFalse(
            stillDisabled,
            "tooEasy 不碰用户停用状态"
        )
    }

    // MARK: - Custom Study

    /// 矩阵：scheduled 恒排除；practiceOnly 默认排除、includeMastered
    /// 放行；非词汇模板不受 flag 影响；buildQueue 与
    /// countQueueCandidates 同一 WHERE。
    func testCustomStudyQueueRespectsModeAndIncludeMastered() async throws {
        let fixture = try await EligibilityFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let vocabCard = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            state: .new,
            dueAt: now
        )
        let clozeCard = try await fixture.addCard(
            noteID: noteID,
            template: .sentenceCloze,
            state: .new,
            dueAt: now.addingTimeInterval(1)
        )
        let unitID = try await fixture.linkNewUnit(noteID: noteID)
        try await fixture.setTooEasy(unitID: unitID, value: true)
        let repository = GRDBCustomStudyRepository(database: fixture.database)

        let practiceContext = CustomStudyQueueContext(
            now: now,
            mode: .practiceOnly
        )
        let plain = try await repository.buildQueue(
            filter: CustomStudyFilter(),
            context: practiceContext
        )
        XCTAssertEqual(
            plain,
            [clozeCard],
            "practiceOnly 默认排除 tooEasy 词汇卡，cloze 不受影响"
        )
        let candidateCount = try await repository.countQueueCandidates(
            filter: CustomStudyFilter(),
            context: practiceContext
        )
        XCTAssertEqual(
            candidateCount,
            plain.count,
            "预览计数与队列共用同一 WHERE"
        )

        let mastered = try await repository.buildQueue(
            filter: CustomStudyFilter(includeMastered: true),
            context: practiceContext
        )
        XCTAssertEqual(
            Set(mastered),
            Set([vocabCard, clozeCard]),
            "practiceOnly + includeMastered 放行已掌握单元"
        )

        let scheduled = try await repository.buildQueue(
            filter: CustomStudyFilter(includeMastered: true),
            context: CustomStudyQueueContext(now: now, mode: .scheduled)
        )
        XCTAssertEqual(
            scheduled,
            [clozeCard],
            "scheduled 恒排除——includeMastered 不适用（D15）"
        )

        try await fixture.setTooEasy(unitID: unitID, value: false)
        let cleared = try await repository.buildQueue(
            filter: CustomStudyFilter(),
            context: practiceContext
        )
        XCTAssertEqual(
            Set(cleared),
            Set([vocabCard, clozeCard]),
            "解除 flag 后词汇卡恢复为普通候选"
        )
    }

    /// frozen queue 恢复重算：启动后标 flag → 读路径剔除该单元的
    /// 词汇卡；queue_json 保持启动时原样（非破坏性投影）；非
    /// active session 直接返回冻结态。
    func testFetchSessionRecomputesQueueFromCurrentFlag() async throws {
        let fixture = try await EligibilityFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let vocabCard = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            state: .new,
            dueAt: now
        )
        let clozeCard = try await fixture.addCard(
            noteID: noteID,
            template: .sentenceCloze,
            state: .new,
            dueAt: now.addingTimeInterval(1)
        )
        let unitID = try await fixture.linkNewUnit(noteID: noteID)
        let repository = GRDBCustomStudyRepository(database: fixture.database)
        let session = try CustomStudyService().makeSession(
            filter: CustomStudyFilter(),
            queue: CustomStudyQueue.ordered(
                cardIDs: [vocabCard, clozeCard],
                order: .due,
                randomSeed: nil,
                generatedAt: now
            ),
            mode: .practiceOnly,
            now: now
        )
        try await repository.createSession(session)

        try await fixture.setTooEasy(unitID: unitID, value: true)
        let recomputed = try await repository.fetchSession(id: session.id)
        XCTAssertEqual(
            recomputed?.queue.cardIDs,
            [clozeCard],
            "active session 按当前 flag 重算呈现队列"
        )
        let active = try await repository.fetchActiveSession()
        XCTAssertEqual(active?.queue.cardIDs, [clozeCard])
        let rawQueueJSON = try await fixture.rawQueueJSON(sessionID: session.id)
        XCTAssertTrue(
            rawQueueJSON?.contains(vocabCard.uuidString.lowercased()) == true
                || rawQueueJSON?.contains(vocabCard.uuidString) == true,
            "queue_json 保持启动时冻结原样——重算不破坏持久化队列"
        )

        try await repository.updateSessionStatus(
            id: session.id,
            to: .finished,
            finishedAt: now
        )
        let finished = try await repository.fetchSession(id: session.id)
        XCTAssertEqual(
            finished?.queue.cardIDs,
            [vocabCard, clozeCard],
            "非 active session 返回冻结态不重算"
        )
    }

    /// practice 提交复核：默认排除的 session 在卡被标 tooEasy 后
    /// 拒绝继续写 practice_attempts；includeMastered session 放行，
    /// 且只写 practice_attempts——不动 FSRS/review_logs（D06/D15）。
    func testRecordPracticeAttemptRechecksEligibility() async throws {
        let fixture = try await EligibilityFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let vocabCard = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            state: .new,
            dueAt: now
        )
        let unitID = try await fixture.linkNewUnit(noteID: noteID)
        let repository = GRDBCustomStudyRepository(database: fixture.database)

        let strictSession = try CustomStudyService().makeSession(
            filter: CustomStudyFilter(),
            queue: CustomStudyQueue.ordered(
                cardIDs: [vocabCard],
                order: .due,
                randomSeed: nil,
                generatedAt: now
            ),
            mode: .practiceOnly,
            now: now
        )
        try await repository.createSession(strictSession)
        let masteredSession = try CustomStudyService().makeSession(
            filter: CustomStudyFilter(includeMastered: true),
            queue: CustomStudyQueue.ordered(
                cardIDs: [vocabCard],
                order: .due,
                randomSeed: nil,
                generatedAt: now
            ),
            mode: .practiceOnly,
            now: now
        )
        try await repository.createSession(masteredSession)

        try await fixture.setTooEasy(unitID: unitID, value: true)
        do {
            _ = try await repository.recordPracticeAttempt(
                fixture.attempt(
                    sessionID: strictSession.id,
                    cardKey: vocabCard,
                    noteID: noteID,
                    answeredAt: now
                )
            )
            XCTFail("默认排除的 session 不得继续积累 tooEasy 练习")
        } catch {
            XCTAssertEqual(
                error as? CustomStudyRepositoryError,
                .cardNotPracticeEligible(
                    cardID: vocabCard,
                    sessionID: strictSession.id
                )
            )
        }

        let recorded = try await repository.recordPracticeAttempt(
            fixture.attempt(
                sessionID: masteredSession.id,
                cardKey: vocabCard,
                noteID: noteID,
                answeredAt: now
            )
        )
        XCTAssertEqual(recorded.sessionID, masteredSession.id)
        let counts = try await fixture.reviewLogAndStateVersion(of: vocabCard)
        XCTAssertEqual(counts.reviewLogs, 0, "practice 永不写 review_logs")
        XCTAssertEqual(
            counts.stateVersion,
            0,
            "practice 不动 FSRS state_version"
        )
    }

    /// 旧版 filter_json（无 includeMastered 键）解码回退默认 false——
    /// v0.6.0 落库 session 升级后仍可恢复。
    func testLegacyFilterJSONDecodesWithIncludeMasteredFalse() throws {
        let legacyJSON = """
            {"deckIDs":[],"favoriteOnly":false,"jlptLevels":[],"limit":50,"order":"due","tagIDs":[]}
            """
        let filter = try JSONDecoder().decode(
            CustomStudyFilter.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertFalse(filter.includeMastered)
        XCTAssertEqual(filter.limit, 50)
        XCTAssertEqual(filter.order, .due)

        let encoded = try JSONEncoder().encode(
            CustomStudyFilter(includeMastered: true)
        )
        let roundTrip = try JSONDecoder().decode(
            CustomStudyFilter.self,
            from: encoded
        )
        XCTAssertTrue(roundTrip.includeMastered)
    }

    // MARK: - Review Submission

    /// 迟到正式评分的事务内复核：队列/预检都过时——另一窗口在提交
    /// 间隙标了 tooEasy → 结构化拒绝，不写 review_logs、不动 FSRS；
    /// 解除 flag 后同一请求可提交。
    func testCommitReviewRejectsLateRatingWhenUnitFlaggedTooEasy() async throws {
        let fixture = try await EligibilityFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let studyDayID = try await fixture.insertStudyDay(containing: now)
        let noteID = try await fixture.addNote(deckID: deckID)
        let cardID = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            state: .review,
            dueAt: now.addingTimeInterval(-60),
            stability: 4,
            firstStudiedAt: now.addingTimeInterval(-86_400),
            stateVersion: 4
        )
        try await fixture.admitTask(
            cardID: cardID,
            studyDayID: studyDayID,
            category: "review"
        )
        let unitID = try await fixture.linkNewUnit(noteID: noteID)
        let submit = SubmitReview(
            repository: GRDBReviewSubmissionRepository(
                database: fixture.database
            ),
            scheduler: SwiftFSRSReviewScheduler(),
            clock: EligibilityFixedClock(value: now)
        )
        let request = SubmitReviewRequest(
            eventID: UUID(),
            cardID: cardID,
            expectedStateVersion: 4,
            rating: .good,
            durationMilliseconds: 900,
            studyDay: StudyDayContext(id: studyDayID),
            policy: .normal
        )

        try await fixture.setTooEasy(unitID: unitID, value: true)
        do {
            _ = try await submit(request)
            XCTFail("tooEasy 单元的迟到评分必须被事务内复核拒绝")
        } catch {
            XCTAssertEqual(
                error as? SubmitReviewError,
                .cardNotSchedulingEligible(cardID: cardID)
            )
        }
        let state = try await fixture.reviewLogAndStateVersion(of: cardID)
        XCTAssertEqual(state.reviewLogs, 0, "拒绝不得产生 review_log")
        XCTAssertEqual(state.stateVersion, 4, "拒绝不得动 FSRS")

        try await fixture.setTooEasy(unitID: unitID, value: false)
        let log = try await submit(
            SubmitReviewRequest(
                eventID: UUID(),
                cardID: cardID,
                expectedStateVersion: 4,
                rating: .good,
                durationMilliseconds: 900,
                studyDay: StudyDayContext(id: studyDayID),
                policy: .normal
            )
        )
        XCTAssertEqual(log.cardKey, cardID, "解除后正常提交")
    }

    /// `.customScheduled` 提交：冻结队列成员检查通过后，flag 复核
    /// 仍然拦截；同一 flagged Note 上的 grammar/cloze 卡照常提交——
    /// 非词汇模板不受 flag 影响。
    func testCustomScheduledAndNonVocabularyCardsAcrossFlag() async throws {
        let fixture = try await EligibilityFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let studyDayID = try await fixture.insertStudyDay(containing: now)
        let noteID = try await fixture.addNote(deckID: deckID)
        let vocabCard = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            state: .review,
            dueAt: now.addingTimeInterval(3_600),
            stability: 4,
            firstStudiedAt: now.addingTimeInterval(-86_400),
            stateVersion: 4
        )
        let grammarCard = try await fixture.addCard(
            noteID: noteID,
            template: .grammarFormToExplanation,
            state: .review,
            dueAt: now.addingTimeInterval(-60),
            stability: 2,
            firstStudiedAt: now.addingTimeInterval(-86_400),
            stateVersion: 2
        )
        try await fixture.admitTask(
            cardID: grammarCard,
            studyDayID: studyDayID,
            category: "review"
        )
        let unitID = try await fixture.linkNewUnit(noteID: noteID)
        let customRepository = GRDBCustomStudyRepository(
            database: fixture.database
        )
        let session = try CustomStudyService().makeSession(
            filter: CustomStudyFilter(),
            queue: CustomStudyQueue.ordered(
                cardIDs: [vocabCard],
                order: .due,
                randomSeed: nil,
                generatedAt: now
            ),
            mode: .scheduled,
            now: now
        )
        try await customRepository.createSession(session)
        let submit = SubmitReview(
            repository: GRDBReviewSubmissionRepository(
                database: fixture.database
            ),
            scheduler: SwiftFSRSReviewScheduler(),
            clock: EligibilityFixedClock(value: now)
        )

        try await fixture.setTooEasy(unitID: unitID, value: true)
        do {
            _ = try await submit(
                SubmitReviewRequest(
                    eventID: UUID(),
                    cardID: vocabCard,
                    expectedStateVersion: 4,
                    rating: .good,
                    durationMilliseconds: 900,
                    studyDay: StudyDayContext(id: studyDayID),
                    policy: .customScheduled(sessionID: session.id)
                )
            )
            XCTFail("customScheduled 也不得绕过 flag 复核")
        } catch {
            XCTAssertEqual(
                error as? SubmitReviewError,
                .cardNotSchedulingEligible(cardID: vocabCard)
            )
        }
        let origin = try await customRepository.fetchScheduledOrigin(
            eventID: UUID()
        )
        XCTAssertNil(origin)
        let state = try await fixture.reviewLogAndStateVersion(
            of: vocabCard
        )
        XCTAssertEqual(state.reviewLogs, 0)
        XCTAssertEqual(state.stateVersion, 4)

        // 同一张 flagged Note 上的非词汇模板照常提交。
        let grammarLog = try await submit(
            SubmitReviewRequest(
                eventID: UUID(),
                cardID: grammarCard,
                expectedStateVersion: 2,
                rating: .good,
                durationMilliseconds: 900,
                studyDay: StudyDayContext(id: studyDayID),
                policy: .normal
            )
        )
        XCTAssertEqual(
            grammarLog.cardKey,
            grammarCard,
            "grammar 模板不受 tooEasy flag 影响"
        )
    }
}

// MARK: - 测试夹具

private struct EligibilityFixedClock: SchedulingClock {
    let value: Date

    func now() -> Date { value }
}

/// 自建最小夹具：v1–v23 全量迁移（`OboeDatabase(path:)`）+ 调度
/// profile；覆盖词汇/非词汇模板卡、v23 unit/link/flag、daily_tasks、
/// study_days、practice/review 写路径。
private final class EligibilityFixture: @unchecked Sendable {
    let directoryURL: URL
    let database: OboeDatabase
    let profileID: UUID
    private var sequence = 0

    private init(
        directoryURL: URL,
        database: OboeDatabase,
        profileID: UUID
    ) {
        self.directoryURL = directoryURL
        self.database = database
        self.profileID = profileID
    }

    static func make() async throws -> EligibilityFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Oboe-Eligibility-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let database = try OboeDatabase(
            path: directoryURL.appendingPathComponent("oboe.sqlite").path
        )
        let profileID = UUID()
        let profile = SchedulerProfile.standard
        let parameters = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version,
                        library_revision, parameters_json, desired_retention,
                        max_interval_days, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(profileID),
                    profile.configurationVersion,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    SwiftFSRSReviewScheduler.dependencyRevision,
                    parameters,
                    profile.targetRetention,
                    profile.maximumIntervalDays
                ]
            )
        }
        return EligibilityFixture(
            directoryURL: directoryURL,
            database: database,
            profileID: profileID
        )
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func addDeck(sortOrder: Int = 0) async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    "Deck \(sortOrder)",
                    sortOrder
                ]
            )
        }
        return id
    }

    func addNote(
        deckID: UUID,
        kind: String = "vocabulary"
    ) async throws -> UUID {
        sequence += 1
        let id = UUID()
        let meaning: String? = kind == "sentence" ? nil : "含义 \(sequence)"
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(deckID),
                    kind,
                    "词 \(sequence)",
                    "よみ \(sequence)",
                    meaning,
                    sequence,
                    sequence
                ]
            )
            try insertHomeMembershipIfSupported(
                noteID: id,
                deckID: deckID,
                in: db
            )
        }
        return id
    }

    @discardableResult
    func addCard(
        noteID: UUID,
        template: CardTemplateKind,
        state: SchedulingState,
        dueAt: Date,
        isEnabled: Bool = true,
        stability: Double = 1,
        firstStudiedAt: Date? = nil,
        stateVersion: Int = 0
    ) async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state,
                        due_at_ms, last_review_at_ms, stability, difficulty,
                        reps, lapses, scheduled_days, elapsed_days,
                        learning_step, first_studied_at_ms, state_version,
                        algorithm_version, profile_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 5, 1, 0, 1, 1, 0, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(noteID),
                    template.rawValue,
                    isEnabled,
                    state.rawValue,
                    try DatabaseValueCodec.encode(dueAt),
                    try firstStudiedAt.map(DatabaseValueCodec.encode),
                    stability,
                    try firstStudiedAt.map(DatabaseValueCodec.encode),
                    stateVersion,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
        return id
    }

    /// 该 Note 建一个 `.localNote` unit 并挂 primary link（S04 仓储
    /// 正路——本测试不绕过校验）。
    func linkNewUnit(noteID: UUID) async throws -> UUID {
        try await database.pool.write { db in
            let unit = try GRDBLearningUnitRepository.resolveOrCreateUnit(
                identityKind: .localNote,
                identityKey: "local:\(noteID.uuidString)",
                lemma: "词",
                reading: nil,
                atMilliseconds: 1,
                in: db
            )
            _ = try GRDBLearningUnitRepository.linkNote(
                unitID: unit.id,
                noteID: noteID,
                role: .primary,
                origin: .manual,
                atMilliseconds: 1,
                in: db
            )
            return unit.id
        }
    }

    /// 正路 CAS 写 flag（读当前 revision → setFlagTooEasy）。
    func setTooEasy(unitID: UUID, value: Bool) async throws {
        try await database.pool.write { db in
            let current = try GRDBLearningUnitRepository
                .fetchFlag(unitID: unitID, in: db)
            _ = try GRDBLearningUnitRepository.setFlagTooEasy(
                unitID: unitID,
                value: value,
                expectedRevision: current?.revision ?? 0,
                operationID: UUID(),
                atMilliseconds: 2,
                in: db
            )
        }
    }

    func admitTask(
        cardID: UUID,
        studyDayID: UUID,
        category: String
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO daily_tasks(
                        study_day_id, card_id, category_at_admission,
                        admitted_at_ms
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(studyDayID),
                    DatabaseValueCodec.encode(cardID),
                    category,
                    Int64(1)
                ]
            )
        }
    }

    func insertStudyDay(containing instant: Date) async throws -> UUID {
        let id = UUID()
        let startsAt = instant.addingTimeInterval(-8 * 3_600)
        let endsAt = instant.addingTimeInterval(16 * 3_600)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id,
                        starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2027-01-05', 'Asia/Shanghai', ?, ?, 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    try DatabaseValueCodec.encode(startsAt),
                    try DatabaseValueCodec.encode(endsAt)
                ]
            )
        }
        return id
    }

    func insertReviewLog(
        cardID: UUID,
        noteID: UUID,
        studyDayID: UUID,
        reviewedAt: Date
    ) async throws {
        try await database.pool.write { db in
            let deckID: String = try String.fetchOne(
                db,
                sql: "SELECT deck_id FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )!
            try db.execute(
                sql: """
                    INSERT INTO review_logs(
                        id, event_id, card_id, card_key, note_id,
                        deck_id_at_review, reviewed_at_ms, study_day_id,
                        was_first_study, rating, previous_state_json,
                        next_state_json, duration_ms, content_version,
                        profile_id, algorithm_version
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 3, '{}', '{}',
                              100, 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(noteID),
                    deckID,
                    try DatabaseValueCodec.encode(reviewedAt),
                    DatabaseValueCodec.encode(studyDayID),
                    DatabaseValueCodec.encode(profileID),
                    SwiftFSRSReviewScheduler.algorithmVersion
                ]
            )
        }
    }

    func isEnabled(cardID: UUID) async throws -> Bool {
        try await database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT is_enabled FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) ?? false
        }
    }

    func reviewLogAndStateVersion(
        of cardID: UUID
    ) async throws -> (reviewLogs: Int, stateVersion: Int) {
        try await database.pool.read { db in
            let logs = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_logs WHERE card_key = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) ?? 0
            let version = try Int.fetchOne(
                db,
                sql: "SELECT state_version FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) ?? -1
            return (logs, version)
        }
    }

    func rawQueueJSON(sessionID: UUID) async throws -> String? {
        try await database.pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT queue_json FROM custom_study_sessions WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(sessionID)]
            )
        }
    }

    func attempt(
        sessionID: UUID,
        cardKey: UUID,
        noteID: UUID,
        answeredAt: Date
    ) -> PracticeAttempt {
        PracticeAttempt(
            id: UUID(),
            eventID: UUID(),
            sessionID: sessionID,
            cardKey: cardKey,
            noteID: noteID,
            rating: .good,
            answeredAt: answeredAt,
            durationMilliseconds: 900,
            contentVersion: 1
        )
    }
}

private func localDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    timeZoneID: String
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneID)!
    return calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}
