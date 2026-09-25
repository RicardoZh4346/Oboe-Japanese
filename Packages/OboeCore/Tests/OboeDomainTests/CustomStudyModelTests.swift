import Foundation
import XCTest
@testable import OboeDomain

/// Custom Study 领域模型测试（设计 §7.1–7.3，D06/§2.4 冻结）：
/// filter/queue 的 Codable 稳定性、装配校验、状态机迁移、
/// 固定 seed 洗牌的确定性、scheduled 提交策略映射。
final class CustomStudyModelTests: XCTestCase {
    private let service = CustomStudyService()
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    // MARK: - Filter

    func testFilterDefaults() {
        let filter = CustomStudyFilter()
        XCTAssertNil(filter.preset)
        XCTAssertTrue(filter.deckIDs.isEmpty)
        XCTAssertTrue(filter.tagIDs.isEmpty)
        XCTAssertTrue(filter.jlptLevels.isEmpty)
        XCTAssertFalse(filter.favoriteOnly)
        XCTAssertEqual(filter.earlyReviewWindowDays, 7)
        XCTAssertEqual(filter.limit, 50)
        XCTAssertEqual(filter.order, .due)
        XCTAssertNil(filter.randomSeed)
    }

    func testFilterCodableRoundTrip() throws {
        let filter = CustomStudyFilter(
            preset: .earlyReview,
            deckIDs: [UUID(), UUID()],
            tagIDs: [UUID()],
            jlptLevels: [.n3, .n1],
            favoriteOnly: true,
            earlyReviewWindowDays: 14,
            limit: 120,
            order: .random,
            randomSeed: -42
        )
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(CustomStudyFilter.self, from: data)
        XCTAssertEqual(decoded, filter)
    }

    func testValidateRejectsOutOfRangeLimit() {
        for bad in [0, -1, 501, 10_000] {
            var filter = CustomStudyFilter()
            filter.limit = bad
            XCTAssertThrowsError(try service.validate(filter)) { error in
                XCTAssertEqual(
                    error as? CustomStudyError,
                    .invalidQueueLimit(bad)
                )
            }
        }
        for good in [1, 50, 500] {
            var filter = CustomStudyFilter()
            filter.limit = good
            XCTAssertNoThrow(try service.validate(filter))
        }
    }

    func testValidateEarlyReviewWindow() {
        for bad in [0, 31, -5] {
            let filter = CustomStudyFilter(
                preset: .earlyReview,
                earlyReviewWindowDays: bad
            )
            XCTAssertThrowsError(try service.validate(filter)) { error in
                XCTAssertEqual(
                    error as? CustomStudyError,
                    .invalidEarlyReviewWindow(bad)
                )
            }
        }
        // 非 earlyReview preset 时窗口值不参与校验。
        let ignored = CustomStudyFilter(
            preset: .dueSoon,
            earlyReviewWindowDays: 0
        )
        XCTAssertNoThrow(try service.validate(ignored))
    }

    func testValidateRandomRequiresSeed() {
        let filter = CustomStudyFilter(order: .random)
        XCTAssertThrowsError(try service.validate(filter)) { error in
            XCTAssertEqual(error as? CustomStudyError, .missingRandomSeed)
        }
        XCTAssertNoThrow(
            try service.validate(CustomStudyFilter(order: .random, randomSeed: 7))
        )
    }

    // MARK: - makeSession 冻结

    func testMakeSessionFreezesQueueAndMode() throws {
        let cardIDs = [UUID(), UUID(), UUID()]
        let queue = CustomStudyQueue(
            cardIDs: cardIDs,
            order: .due,
            randomSeed: nil,
            generatedAt: now
        )
        let session = try service.makeSession(
            filter: CustomStudyFilter(preset: .unstudiedNew),
            queue: queue,
            mode: .scheduled,
            now: now
        )
        XCTAssertEqual(session.status, .active)
        XCTAssertNil(session.finishedAt)
        XCTAssertEqual(session.mode, .scheduled)
        XCTAssertEqual(session.queue, queue)
        XCTAssertEqual(session.queue.cardIDs, cardIDs)
        XCTAssertEqual(session.startedAt, now)
        XCTAssertEqual(session.filter.preset, .unstudiedNew)
    }

    func testMakeSessionRejectsQueueBeyondLimit() {
        let filter = CustomStudyFilter(limit: 3)
        let queue = CustomStudyQueue(
            cardIDs: (0 ..< 4).map { _ in UUID() },
            order: .due,
            randomSeed: nil,
            generatedAt: now
        )
        XCTAssertThrowsError(
            try service.makeSession(
                filter: filter, queue: queue, mode: .practiceOnly, now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? CustomStudyError,
                .queueExceedsLimit(limit: 3, actual: 4)
            )
        }
    }

    func testMakeSessionRejectsQueueFilterMismatch() {
        let filter = CustomStudyFilter(order: .due)
        let queue = CustomStudyQueue(
            cardIDs: [UUID()],
            order: .random,
            randomSeed: 9,
            generatedAt: now
        )
        XCTAssertThrowsError(
            try service.makeSession(
                filter: filter, queue: queue, mode: .practiceOnly, now: now
            )
        ) { error in
            XCTAssertEqual(error as? CustomStudyError, .queueFilterMismatch)
        }
    }

    // MARK: - 状态机迁移（至多一个 active 的领域规则侧）

    func testInterruptTransitionRequiresActive() throws {
        let session = try makeActiveSession()
        let interrupted = try service.interruptTransition(of: session, at: now)
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(interrupted.finishedAt, now)
        // 幂等性约束：非 active 不得再迁移。
        XCTAssertThrowsError(
            try service.interruptTransition(of: interrupted, at: now)
        ) { error in
            XCTAssertEqual(
                error as? CustomStudyError,
                .sessionNotActive(session.id)
            )
        }
        XCTAssertThrowsError(
            try service.finishTransition(of: interrupted, at: now)
        ) { error in
            XCTAssertEqual(
                error as? CustomStudyError,
                .sessionNotActive(session.id)
            )
        }
    }

    func testFinishTransition() throws {
        let session = try makeActiveSession()
        let finished = try service.finishTransition(of: session, at: now)
        XCTAssertEqual(finished.status, .finished)
        XCTAssertEqual(finished.finishedAt, now)
        XCTAssertThrowsError(
            try service.finishTransition(of: finished, at: now)
        ) { error in
            XCTAssertEqual(
                error as? CustomStudyError,
                .sessionNotActive(session.id)
            )
        }
    }

    // MARK: - 冻结队列的随机序确定性

    func testSeededQueueOrderingIsDeterministic() {
        let cardIDs = (0 ..< 20).map { _ in UUID() }
        let first = CustomStudyQueue.ordered(
            cardIDs: cardIDs, order: .random, randomSeed: 99, generatedAt: now
        )
        let second = CustomStudyQueue.ordered(
            cardIDs: cardIDs, order: .random, randomSeed: 99, generatedAt: now
        )
        XCTAssertEqual(
            first.cardIDs, second.cardIDs,
            "同 seed + 同候选集必须给出同一序列"
        )
        XCTAssertEqual(
            Set(first.cardIDs), Set(cardIDs),
            "洗牌是置换，不丢不增"
        )
        let other = CustomStudyQueue.ordered(
            cardIDs: cardIDs, order: .random, randomSeed: 100, generatedAt: now
        )
        XCTAssertNotEqual(
            first.cardIDs, other.cardIDs,
            "不同 seed 应给出不同呈现序（20 元素下恒等的概率可忽略）"
        )
        let stable = CustomStudyQueue.ordered(
            cardIDs: cardIDs, order: .due, randomSeed: nil, generatedAt: now
        )
        XCTAssertEqual(stable.cardIDs, cardIDs, "due 序原样保留传入稳定序")
    }

    // MARK: - ReviewSubmissionPolicy（§7.3）

    func testSubmissionPolicyMapping() throws {
        let practice = try makeActiveSession(mode: .practiceOnly)
        XCTAssertNil(service.submissionPolicy(for: practice))
        let scheduled = try makeActiveSession(mode: .scheduled)
        XCTAssertEqual(
            service.submissionPolicy(for: scheduled),
            .customScheduled(sessionID: scheduled.id)
        )
        XCTAssertEqual(ReviewSubmissionPolicy.normal, .normal)
        XCTAssertNotEqual(
            ReviewSubmissionPolicy.customScheduled(sessionID: scheduled.id),
            .normal
        )
    }

    // MARK: - 工具

    private func makeActiveSession(
        mode: CustomStudyMode = .practiceOnly
    ) throws -> CustomStudySession {
        let filter = CustomStudyFilter()
        let queue = CustomStudyQueue(
            cardIDs: [UUID()],
            order: .due,
            randomSeed: nil,
            generatedAt: now
        )
        return try service.makeSession(
            filter: filter, queue: queue, mode: mode, now: now
        )
    }
}
