import Foundation
import XCTest
@testable import OboeDomain

/// T01: freezes the adaptive-v1 leech rules (design §4.2). Every boundary the
/// plan lists is covered: 5/6 lapses, 9/10 samples, 4/5 window Again, 2/3 due
/// streaks, learning/relearning exclusion, difficulty alone, recovery and
/// relapse, empty history, same-millisecond ordering, undo removal.
final class LeechClassifierTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)
    private let classifier = LeechClassifier()

    // MARK: - Rule A: lifetime lapses

    func testLapsesFiveDoesNotTriggerRuleA() {
        let evidence = makeEvidence(lapses: 5, samples: [])
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertFalse(assessment.triggers.contains(.lifetimeLapses))
        XCTAssertEqual(assessment.status, .warning) // lapses≥3 warns
        XCTAssertFalse(assessment.isRecovered)
    }

    func testLapsesSixTriggersLeech() {
        let evidence = makeEvidence(lapses: 6, samples: [])
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertEqual(assessment.triggers, [.lifetimeLapses])
        XCTAssertEqual(assessment.status, .leech)
    }

    func testLapsesTwoIsNormalWithoutOtherEvidence() {
        let evidence = makeEvidence(
            lapses: 2,
            samples: [dueSample(.good, daysAgo: 3, stateVersion: 5)]
        )
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertEqual(assessment.status, .normal)
        XCTAssertTrue(assessment.triggers.isEmpty)
    }

    // MARK: - Rule B: recent window Again burst

    func testNineSamplesNeverTriggerRuleB() {
        // 使用 learning 样本避免到期连续 Again 触发 C：B 只看有效样本窗口。
        let samples = (0..<9).map { index in
            sample(.again, daysAgo: Double(index + 1), previousState: .learning, stateVersion: 100 - index)
        }
        let evidence = makeEvidence(lapses: 0, samples: samples)
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertEqual(assessment.metrics.recentCount, 9)
        XCTAssertEqual(assessment.metrics.recentAgainCount, 9)
        XCTAssertFalse(assessment.triggers.contains(.recentAgainBurst))
        // 短窗 5 条里 Again≥2 仍满足 warning 证据。
        XCTAssertEqual(assessment.status, .warning)
    }

    func testTenSamplesWithFourAgainDoesNotTriggerRuleB() {
        var samples = (0..<6).map { index in
            dueSample(.good, daysAgo: Double(index + 1), stateVersion: 100 - index)
        }
        samples += (0..<4).map { index in
            dueSample(.again, daysAgo: Double(index + 7), stateVersion: 94 - index)
        }
        let evidence = makeEvidence(lapses: 0, samples: samples)
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertFalse(assessment.triggers.contains(.recentAgainBurst))
        XCTAssertEqual(assessment.metrics.recentCount, 10)
        XCTAssertEqual(assessment.metrics.recentAgainCount, 4)
    }

    func testTenSamplesWithFiveAgainTriggersRuleB() {
        var samples = (0..<5).map { index in
            dueSample(.good, daysAgo: Double(index + 1), stateVersion: 100 - index)
        }
        samples += (0..<5).map { index in
            dueSample(.again, daysAgo: Double(index + 6), stateVersion: 95 - index)
        }
        let evidence = makeEvidence(lapses: 0, samples: samples)
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertTrue(assessment.triggers.contains(.recentAgainBurst))
        XCTAssertEqual(assessment.status, .leech)
    }

    // MARK: - Rule C: due-review Again streak

    func testTwoDueAgainStreakIsWarningNotRuleC() {
        let samples = [
            dueSample(.again, daysAgo: 1, stateVersion: 10),
            dueSample(.again, daysAgo: 4, stateVersion: 9),
            dueSample(.good, daysAgo: 8, stateVersion: 8)
        ]
        let evidence = makeEvidence(lapses: 0, samples: samples)
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertEqual(assessment.metrics.dueAgainStreak, 2)
        XCTAssertFalse(assessment.triggers.contains(.dueAgainStreak))
        XCTAssertEqual(assessment.status, .warning)
    }

    func testThreeDueAgainStreakTriggersRuleC() {
        let samples = [
            dueSample(.again, daysAgo: 1, stateVersion: 12),
            dueSample(.again, daysAgo: 4, stateVersion: 11),
            dueSample(.again, daysAgo: 8, stateVersion: 10),
            dueSample(.good, daysAgo: 15, stateVersion: 9)
        ]
        let evidence = makeEvidence(lapses: 0, samples: samples)
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertEqual(assessment.metrics.dueAgainStreak, 3)
        XCTAssertTrue(assessment.triggers.contains(.dueAgainStreak))
        XCTAssertEqual(assessment.status, .leech)
    }

    func testDueStreakOlderThanRecentWindowDoesNotTriggerRuleC() {
        let samples = [
            dueSample(.again, daysAgo: 31, stateVersion: 12),
            dueSample(.again, daysAgo: 35, stateVersion: 11),
            dueSample(.again, daysAgo: 40, stateVersion: 10)
        ]
        let evidence = makeEvidence(lapses: 0, samples: samples)
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertFalse(assessment.triggers.contains(.dueAgainStreak))
        XCTAssertEqual(assessment.status, .warning)
    }

    func testLearningAndRelearningLogsDoNotJoinDueSubsequence() {
        // due Again ×3，中间隔着 learning/relearning/首学日志——子序列不断。
        let samples = [
            dueSample(.again, daysAgo: 1, stateVersion: 14),
            sample(.again, daysAgo: 2, previousState: .learning, stateVersion: 13),
            dueSample(.again, daysAgo: 3, stateVersion: 12),
            sample(.good, daysAgo: 4, previousState: .relearning, stateVersion: 11),
            dueSample(.again, daysAgo: 5, stateVersion: 10),
            sample(.good, daysAgo: 6, previousState: .review, wasFirstStudy: true, stateVersion: 9)
        ]
        let evidence = makeEvidence(lapses: 0, samples: samples)
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertEqual(assessment.metrics.dueAgainStreak, 3)
        XCTAssertTrue(assessment.triggers.contains(.dueAgainStreak))
        XCTAssertEqual(assessment.metrics.totalCount, 6)
    }

    func testNotYetDueReviewDoesNotCountAsDueReview() {
        // previous dueAt 晚于 reviewedAt：提前评分不算到期 Review。
        let earlyDate = now.addingTimeInterval(-86_400)
        let premature = AdaptiveReviewSample(
            logID: UUID(),
            rating: .again,
            reviewedAt: earlyDate,
            wasFirstStudy: false,
            previousState: snapshot(
                state: .review,
                dueAt: earlyDate.addingTimeInterval(3_600),
                stateVersion: 8
            ),
            nextState: snapshot(state: .relearning, dueAt: earlyDate, stateVersion: 9)
        )
        let samples = [
            premature,
            dueSample(.again, daysAgo: 4, stateVersion: 7),
            dueSample(.again, daysAgo: 8, stateVersion: 6)
        ]
        let evidence = makeEvidence(lapses: 0, samples: samples)
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertEqual(assessment.metrics.dueAgainStreak, 2)
        XCTAssertFalse(assessment.triggers.contains(.dueAgainStreak))
    }

    // MARK: - Rule D: persistent difficulty

    func testHighDifficultyAloneNeverTriggers() {
        let samples = (0..<5).map { index in
            dueSample(.good, daysAgo: Double(index + 1), stateVersion: 20 - index)
        }
        let evidence = makeEvidence(difficulty: 9.8, lapses: 0, samples: samples)
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertFalse(assessment.triggers.contains(.persistentDifficulty))
    }

    func testRuleDRequiresDifficultyFailuresAndRecency() {
        let mixed = [
            dueSample(.again, daysAgo: 1, stateVersion: 30),
            dueSample(.again, daysAgo: 2, stateVersion: 29),
            dueSample(.good, daysAgo: 3, stateVersion: 28),
            dueSample(.good, daysAgo: 4, stateVersion: 27),
            dueSample(.hard, daysAgo: 5, stateVersion: 26)
        ]
        let triggered = classifier.assess(
            evidence: makeEvidence(difficulty: 8.5, lapses: 0, samples: mixed),
            at: now
        )
        XCTAssertTrue(triggered.triggers.contains(.persistentDifficulty))
        XCTAssertEqual(triggered.status, .leech)

        let easier = classifier.assess(
            evidence: makeEvidence(difficulty: 8.4, lapses: 0, samples: mixed),
            at: now
        )
        XCTAssertFalse(easier.triggers.contains(.persistentDifficulty))
        XCTAssertEqual(easier.status, .warning)

        let staleAgain = [
            dueSample(.again, daysAgo: 31, stateVersion: 30),
            dueSample(.again, daysAgo: 32, stateVersion: 29),
            dueSample(.good, daysAgo: 33, stateVersion: 28),
            dueSample(.good, daysAgo: 34, stateVersion: 27),
            dueSample(.good, daysAgo: 35, stateVersion: 26)
        ]
        let stale = classifier.assess(
            evidence: makeEvidence(difficulty: 9.0, lapses: 0, samples: staleAgain),
            at: now
        )
        XCTAssertFalse(stale.triggers.contains(.persistentDifficulty))
    }

    // MARK: - Recovery

    func testRecoveryOverridesLifetimeLapses() {
        let samples = [
            dueSample(.good, daysAgo: 2, stateVersion: 30),
            dueSample(.easy, daysAgo: 10, stateVersion: 29),
            dueSample(.good, daysAgo: 20, stateVersion: 28),
            dueSample(.again, daysAgo: 40, stateVersion: 27)
        ]
        let evidence = makeEvidence(
            state: .review,
            stability: 20,
            difficulty: 8.0,
            lapses: 8,
            samples: samples
        )
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertTrue(assessment.isRecovered)
        XCTAssertEqual(assessment.status, .normal)
        XCTAssertEqual(assessment.triggers, [.lifetimeLapses])
        XCTAssertEqual(assessment.metrics.lifetimeLapses, 8)
    }

    func testRecoveryNeedsThreeDueSuccesses() {
        let samples = [
            dueSample(.good, daysAgo: 2, stateVersion: 30),
            dueSample(.easy, daysAgo: 10, stateVersion: 29),
            dueSample(.again, daysAgo: 20, stateVersion: 28)
        ]
        let evidence = makeEvidence(
            state: .review,
            stability: 20,
            lapses: 7,
            samples: samples
        )
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertFalse(assessment.isRecovered)
        XCTAssertEqual(assessment.status, .leech)
    }

    func testRecoveryRequiresReviewStateAndStability() {
        let successes = [
            dueSample(.good, daysAgo: 2, stateVersion: 30),
            dueSample(.good, daysAgo: 10, stateVersion: 29),
            dueSample(.easy, daysAgo: 20, stateVersion: 28)
        ]
        let relearning = classifier.assess(
            evidence: makeEvidence(
                state: .relearning,
                stability: 20,
                lapses: 6,
                samples: successes
            ),
            at: now
        )
        XCTAssertFalse(relearning.isRecovered)

        let unstable = classifier.assess(
            evidence: makeEvidence(
                state: .review,
                stability: 13.9,
                lapses: 6,
                samples: successes
            ),
            at: now
        )
        XCTAssertFalse(unstable.isRecovered)
    }

    func testLearningAgainAfterSuccessesVoidsRecovery() {
        // 三次到期 Good 之间没有 Again，但最早的 Good 之后有一条 learning
        // Again——恢复证据失效，lapses 触发回归。
        let samples = [
            dueSample(.good, daysAgo: 2, stateVersion: 30),
            sample(.again, daysAgo: 5, previousState: .learning, stateVersion: 29),
            dueSample(.easy, daysAgo: 10, stateVersion: 28),
            dueSample(.good, daysAgo: 20, stateVersion: 27)
        ]
        let evidence = makeEvidence(
            state: .review,
            stability: 30,
            lapses: 6,
            samples: samples
        )
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertFalse(assessment.isRecovered)
        XCTAssertEqual(assessment.status, .leech)
    }

    func testNewAgainAfterRecoveryReTriggersLeech() {
        let samples = [
            dueSample(.again, daysAgo: 1, stateVersion: 31),
            dueSample(.good, daysAgo: 2, stateVersion: 30),
            dueSample(.easy, daysAgo: 10, stateVersion: 29),
            dueSample(.good, daysAgo: 20, stateVersion: 28)
        ]
        let evidence = makeEvidence(
            state: .review,
            stability: 20,
            lapses: 6,
            samples: samples
        )
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertFalse(assessment.isRecovered)
        XCTAssertEqual(assessment.status, .leech)
    }

    // MARK: - Evidence handling

    func testNoSamplesIsNormalWithNilRatio() {
        let evidence = makeEvidence(lapses: 0, samples: [])
        let assessment = classifier.assess(evidence: evidence, at: now)
        XCTAssertEqual(assessment.status, .normal)
        XCTAssertNil(assessment.metrics.againRatio)
        XCTAssertEqual(assessment.metrics.totalCount, 0)
        XCTAssertNil(assessment.metrics.lastAgainAt)
        XCTAssertNil(assessment.metrics.lastDueReviewAt)
    }

    func testSameMillisecondOrdersBySnapshotVersionDeterministically() {
        let timestamp = now.addingTimeInterval(-86_400)
        let olderVersionAgain = AdaptiveReviewSample(
            logID: UUID(),
            rating: .again,
            reviewedAt: timestamp,
            wasFirstStudy: false,
            previousState: snapshot(state: .review, dueAt: timestamp, stateVersion: 8),
            nextState: snapshot(state: .relearning, dueAt: timestamp, stateVersion: 9)
        )
        let newerVersionGood = AdaptiveReviewSample(
            logID: UUID(),
            rating: .good,
            reviewedAt: timestamp,
            wasFirstStudy: false,
            previousState: snapshot(state: .review, dueAt: timestamp, stateVersion: 9),
            nextState: snapshot(state: .review, dueAt: timestamp, stateVersion: 10)
        )
        for ordering in [[olderVersionAgain, newerVersionGood],
                         [newerVersionGood, olderVersionAgain]] {
            let assessment = classifier.assess(
                evidence: makeEvidence(lapses: 0, samples: ordering),
                at: now
            )
            XCTAssertEqual(assessment.metrics.dueAgainStreak, 0)
            XCTAssertEqual(assessment.metrics.recentAgainCount, 1)
        }
    }

    func testRemovingNewestSampleSimulatesUndoAndImprovesStatus() {
        let again = dueSample(.again, daysAgo: 1, stateVersion: 12)
        let history = [
            dueSample(.again, daysAgo: 4, stateVersion: 11),
            dueSample(.again, daysAgo: 8, stateVersion: 10),
            dueSample(.good, daysAgo: 12, stateVersion: 9)
        ]
        let withAgain = classifier.assess(
            evidence: makeEvidence(lapses: 0, samples: [again] + history),
            at: now
        )
        XCTAssertEqual(withAgain.metrics.dueAgainStreak, 3)
        XCTAssertEqual(withAgain.status, .leech)

        // 撤销最新 Again 后，有效样本与从未存在该日志一致。
        let afterUndo = classifier.assess(
            evidence: makeEvidence(lapses: 0, samples: history),
            at: now
        )
        XCTAssertEqual(afterUndo.metrics.dueAgainStreak, 2)
        XCTAssertEqual(afterUndo.status, .warning)
    }

    func testAssessmentIsDeterministicForIdenticalEvidence() {
        let evidence = makeEvidence(
            lapses: 6,
            samples: [dueSample(.again, daysAgo: 1, stateVersion: 3)]
        )
        let first = classifier.assess(evidence: evidence, at: now)
        let second = classifier.assess(evidence: evidence, at: now)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.policyVersion, AdaptivePolicy.currentVersion)
    }

    func testLastDueIntervalExplainsOverdueDays() {
        let reviewedAt = now.addingTimeInterval(-2 * 86_400)
        let sample = AdaptiveReviewSample(
            logID: UUID(),
            rating: .good,
            reviewedAt: reviewedAt,
            wasFirstStudy: false,
            previousState: snapshot(
                state: .review,
                dueAt: reviewedAt.addingTimeInterval(-3 * 86_400),
                stateVersion: 4
            ),
            nextState: snapshot(state: .review, dueAt: reviewedAt, stateVersion: 5)
        )
        let assessment = classifier.assess(
            evidence: makeEvidence(lapses: 0, samples: [sample]),
            at: now
        )
        XCTAssertEqual(assessment.metrics.lastDueIntervalDays ?? -1, 3, accuracy: 0.001)
    }

    // MARK: - Builders

    private func snapshot(
        state: SchedulingState,
        dueAt: Date,
        stability: Double = 1,
        difficulty: Double = 5,
        lapses: Int = 0,
        stateVersion: Int
    ) -> ReviewSchedulingSnapshot {
        ReviewSchedulingSnapshot(
            scheduling: SchedulingCard(
                dueAt: dueAt,
                stability: stability,
                difficulty: difficulty,
                elapsedDays: 0,
                scheduledDays: 0,
                learningStep: 0,
                repetitions: 0,
                lapses: lapses,
                state: state,
                lastReviewAt: nil
            ),
            firstStudiedAt: now.addingTimeInterval(-90 * 86_400),
            stateVersion: stateVersion,
            algorithmVersion: "fsrs-6-test",
            profileID: UUID()
        )
    }

    private func sample(
        _ rating: ReviewRating,
        daysAgo: Double,
        previousState: SchedulingState,
        wasFirstStudy: Bool = false,
        stateVersion: Int
    ) -> AdaptiveReviewSample {
        let reviewedAt = now.addingTimeInterval(-daysAgo * 86_400)
        return AdaptiveReviewSample(
            logID: UUID(),
            rating: rating,
            reviewedAt: reviewedAt,
            wasFirstStudy: wasFirstStudy,
            previousState: snapshot(
                state: previousState,
                dueAt: reviewedAt,
                stateVersion: stateVersion
            ),
            nextState: snapshot(
                state: rating == .again ? .relearning : .review,
                dueAt: reviewedAt,
                stateVersion: stateVersion + 1
            )
        )
    }

    /// A due-review sample: review state, already due, not first study.
    private func dueSample(
        _ rating: ReviewRating,
        daysAgo: Double,
        stateVersion: Int
    ) -> AdaptiveReviewSample {
        let reviewedAt = now.addingTimeInterval(-daysAgo * 86_400)
        return AdaptiveReviewSample(
            logID: UUID(),
            rating: rating,
            reviewedAt: reviewedAt,
            wasFirstStudy: false,
            previousState: snapshot(
                state: .review,
                dueAt: reviewedAt.addingTimeInterval(-3_600),
                stateVersion: stateVersion
            ),
            nextState: snapshot(
                state: rating == .again ? .relearning : .review,
                dueAt: reviewedAt,
                stateVersion: stateVersion + 1
            )
        )
    }

    private func makeEvidence(
        state: SchedulingState = .review,
        stability: Double = 5,
        difficulty: Double = 5,
        lapses: Int,
        samples: [AdaptiveReviewSample]
    ) -> AdaptiveCardEvidence {
        AdaptiveCardEvidence(
            cardID: UUID(),
            noteID: UUID(),
            deckID: UUID(),
            templateKind: .vocabularyJapaneseToChinese,
            isEnabled: true,
            scheduling: SchedulingCard(
                dueAt: now.addingTimeInterval(86_400),
                stability: stability,
                difficulty: difficulty,
                elapsedDays: 0,
                scheduledDays: 0,
                learningStep: 0,
                repetitions: 10,
                lapses: lapses,
                state: state,
                lastReviewAt: now.addingTimeInterval(-86_400)
            ),
            firstStudiedAt: now.addingTimeInterval(-90 * 86_400),
            samples: samples
        )
    }
}
