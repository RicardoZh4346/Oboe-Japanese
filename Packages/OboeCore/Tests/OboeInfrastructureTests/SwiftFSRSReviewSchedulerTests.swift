import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class SwiftFSRSReviewSchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_768_478_400)
    private let profile = SchedulerProfile.standard

    func testLockedDependencyAndAlgorithmVersion() {
        XCTAssertEqual(
            SwiftFSRSReviewScheduler.dependencyRevision,
            "4fbaf20184d62f82a9f44f343337c61a2c5483e9"
        )
        XCTAssertEqual(SwiftFSRSReviewScheduler.algorithmVersion, "FSRS-6.0")
        XCTAssertEqual(profile.parameters.count, 21)
    }

    func testOfficialReferenceVectorsForAllStatesAndRatings() throws {
        let scheduler = SwiftFSRSReviewScheduler()

        for fixture in Self.referenceFixtures(now: now) {
            let original = fixture.card
            let choices = try scheduler.preview(card: fixture.card, at: now, profile: profile)

            XCTAssertEqual(fixture.card, original, "Preview must not mutate the input")
            for rating in ReviewRating.allCases {
                assertChoice(
                    choices[rating],
                    equals: try XCTUnwrap(fixture.expected[rating]),
                    state: fixture.card.state,
                    rating: rating
                )
            }
        }
    }

    func testSameDayRepeatMatchesOfficialReference() throws {
        let scheduler = SwiftFSRSReviewScheduler()
        let first = try scheduler.preview(
            card: SchedulingCard(dueAt: now),
            at: now,
            profile: profile
        ).again.card
        let secondReviewTime = first.dueAt
        let second = try scheduler.preview(
            card: first,
            at: secondReviewTime,
            profile: profile
        ).good.card

        XCTAssertEqual(second.state, .learning)
        XCTAssertEqual(second.dueAt.timeIntervalSince(now), 660, accuracy: 0.001)
        XCTAssertEqual(second.stability, 0.24668919, accuracy: 1e-8)
        XCTAssertEqual(second.difficulty, 6.40211507, accuracy: 1e-8)
        XCTAssertEqual(second.learningStep, 1)
        XCTAssertEqual(second.repetitions, 2)
        XCTAssertEqual(second.lastReviewAt, secondReviewTime)
    }

    func testOverdueReviewUsesElapsedTimeSinceLastReview() throws {
        let overdue = Self.referenceFixtures(now: now).first { $0.card.state == .review }!
        let choices = try SwiftFSRSReviewScheduler().preview(
            card: overdue.card,
            at: now,
            profile: profile
        )

        XCTAssertEqual(choices.again.card.elapsedDays, 30)
        XCTAssertEqual(choices.good.card.elapsedDays, 30)
        XCTAssertEqual(choices.good.card.scheduledDays, 72)
        XCTAssertGreaterThan(choices.good.dueAt, now)
    }

    func testOutputIsReproducibleAndClockIsInjectable() throws {
        let card = Self.referenceFixtures(now: now).first { $0.card.state == .review }!.card
        let scheduler = SwiftFSRSReviewScheduler(clock: FixedClock(value: now))

        let first = try scheduler.preview(card: card, profile: profile)
        let second = try scheduler.preview(card: card, profile: profile)
        let explicit = try scheduler.preview(card: card, at: now, profile: profile)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, explicit)
        for rating in ReviewRating.allCases {
            let next = first[rating].card
            XCTAssertTrue(next.stability.isFinite)
            XCTAssertTrue(next.difficulty.isFinite)
            XCTAssertGreaterThanOrEqual(next.stability, 0)
            XCTAssertGreaterThanOrEqual(next.difficulty, 0)
            XCTAssertGreaterThan(next.dueAt, now)
            XCTAssertEqual(first[rating].configurationVersion, profile.configurationVersion)
        }
    }

    func testRejectsNonFSRS6ParameterVector() {
        let invalid = SchedulerProfile(
            preset: .standard,
            parameters: Array(SchedulerProfile.fsrs6DefaultParameters.prefix(19))
        )

        XCTAssertThrowsError(
            try SwiftFSRSReviewScheduler().preview(
                card: SchedulingCard(dueAt: now),
                at: now,
                profile: invalid
            )
        ) { error in
            XCTAssertEqual(error as? SwiftFSRSSchedulerError, .invalidParameterCount(19))
        }
    }

    private func assertChoice(
        _ actual: ReviewChoice,
        equals expected: ExpectedCard,
        state: SchedulingState,
        rating: ReviewRating,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let context = "\(state)/\(rating)"
        XCTAssertEqual(actual.rating, rating, context, file: file, line: line)
        XCTAssertEqual(actual.reviewedAt, now, context, file: file, line: line)
        XCTAssertEqual(actual.configurationVersion, profile.configurationVersion, context, file: file, line: line)
        XCTAssertEqual(actual.card.dueAt.timeIntervalSince(now), expected.dueOffset, accuracy: 0.001, context, file: file, line: line)
        XCTAssertEqual(actual.card.stability, expected.stability, accuracy: 1e-8, context, file: file, line: line)
        XCTAssertEqual(actual.card.difficulty, expected.difficulty, accuracy: 1e-8, context, file: file, line: line)
        XCTAssertEqual(actual.card.elapsedDays, expected.elapsedDays, accuracy: 1e-8, context, file: file, line: line)
        XCTAssertEqual(actual.card.scheduledDays, expected.scheduledDays, accuracy: 1e-8, context, file: file, line: line)
        XCTAssertEqual(actual.card.learningStep, expected.learningStep, context, file: file, line: line)
        XCTAssertEqual(actual.card.repetitions, expected.repetitions, context, file: file, line: line)
        XCTAssertEqual(actual.card.lapses, expected.lapses, context, file: file, line: line)
        XCTAssertEqual(actual.card.state, expected.state, context, file: file, line: line)
        XCTAssertEqual(actual.card.lastReviewAt, now, context, file: file, line: line)
    }
}

private struct FixedClock: SchedulingClock {
    let value: Date

    func now() -> Date { value }
}

private struct ExpectedCard {
    let dueOffset: TimeInterval
    let stability: Double
    let difficulty: Double
    let elapsedDays: Double
    let scheduledDays: Double
    let learningStep: Int
    let repetitions: Int
    let lapses: Int
    let state: SchedulingState
}

private struct ReferenceFixture {
    let card: SchedulingCard
    let expected: [ReviewRating: ExpectedCard]
}

private extension SwiftFSRSReviewSchedulerTests {
    // Oracle: open-spaced-repetition/ts-fsrs at
    // c8ca282edc3fe1cdfa1c24912437938b63a25cb3, generated with the exact
    // parameters in SchedulerProfile.standard and fuzzing disabled.
    static func referenceFixtures(now: Date) -> [ReferenceFixture] {
        let minute: TimeInterval = 60
        let day: TimeInterval = 86_400

        return [
            ReferenceFixture(
                card: SchedulingCard(dueAt: now),
                expected: [
                    .again: .init(dueOffset: 60, stability: 0.212, difficulty: 6.4133, elapsedDays: 0, scheduledDays: 0, learningStep: 0, repetitions: 1, lapses: 0, state: .learning),
                    .hard: .init(dueOffset: 360, stability: 1.2931, difficulty: 5.11217071, elapsedDays: 0, scheduledDays: 0, learningStep: 0, repetitions: 1, lapses: 0, state: .learning),
                    .good: .init(dueOffset: 600, stability: 2.3065, difficulty: 2.11810397, elapsedDays: 0, scheduledDays: 0, learningStep: 1, repetitions: 1, lapses: 0, state: .learning),
                    .easy: .init(dueOffset: 8 * day, stability: 8.2956, difficulty: 1, elapsedDays: 0, scheduledDays: 8, learningStep: 0, repetitions: 1, lapses: 0, state: .review)
                ]
            ),
            ReferenceFixture(
                card: SchedulingCard(
                    dueAt: now,
                    stability: 0.5,
                    difficulty: 6,
                    learningStep: 1,
                    repetitions: 1,
                    state: .learning,
                    lastReviewAt: now.addingTimeInterval(-10 * minute)
                ),
                expected: [
                    .again: .init(dueOffset: 60, stability: 0.18580415, difficulty: 8.67045557, elapsedDays: 0, scheduledDays: 0, learningStep: 0, repetitions: 2, lapses: 0, state: .learning),
                    .hard: .init(dueOffset: 360, stability: 0.5, difficulty: 7.32984197, elapsedDays: 0, scheduledDays: 0, learningStep: 1, repetitions: 2, lapses: 0, state: .learning),
                    .good: .init(dueOffset: day, stability: 0.54987621, difficulty: 5.98922837, elapsedDays: 0, scheduledDays: 1, learningStep: 0, repetitions: 2, lapses: 0, state: .review),
                    .easy: .init(dueOffset: day, stability: 0.94595328, difficulty: 4.64861476, elapsedDays: 0, scheduledDays: 1, learningStep: 0, repetitions: 2, lapses: 0, state: .review)
                ]
            ),
            ReferenceFixture(
                card: SchedulingCard(
                    dueAt: now.addingTimeInterval(-5 * day),
                    stability: 20,
                    difficulty: 5,
                    scheduledDays: 20,
                    repetitions: 10,
                    lapses: 1,
                    state: .review,
                    lastReviewAt: now.addingTimeInterval(-30 * day)
                ),
                expected: [
                    .again: .init(dueOffset: 600, stability: 2.04269331, difficulty: 8.34176237, elapsedDays: 30, scheduledDays: 0, learningStep: 0, repetitions: 11, lapses: 2, state: .relearning),
                    .hard: .init(dueOffset: 51 * day, stability: 51.10381688, difficulty: 6.66599536, elapsedDays: 30, scheduledDays: 51, learningStep: 0, repetitions: 11, lapses: 1, state: .review),
                    .good: .init(dueOffset: 72 * day, stability: 71.71901709, difficulty: 4.99022837, elapsedDays: 30, scheduledDays: 72, learningStep: 0, repetitions: 11, lapses: 1, state: .review),
                    .easy: .init(dueOffset: 117 * day, stability: 116.86454711, difficulty: 3.31446137, elapsedDays: 30, scheduledDays: 117, learningStep: 0, repetitions: 11, lapses: 1, state: .review)
                ]
            ),
            ReferenceFixture(
                card: SchedulingCard(
                    dueAt: now,
                    stability: 2,
                    difficulty: 7,
                    repetitions: 6,
                    lapses: 2,
                    state: .relearning,
                    lastReviewAt: now.addingTimeInterval(-10 * minute)
                ),
                expected: [
                    .again: .init(dueOffset: 600, stability: 0.67842191, difficulty: 8.99914877, elapsedDays: 0, scheduledDays: 0, learningStep: 0, repetitions: 7, lapses: 2, state: .relearning),
                    .hard: .init(dueOffset: 900, stability: 2, difficulty: 7.99368857, elapsedDays: 0, scheduledDays: 0, learningStep: 0, repetitions: 7, lapses: 2, state: .relearning),
                    .good: .init(dueOffset: 2 * day, stability: 2.0077488, difficulty: 6.98822837, elapsedDays: 0, scheduledDays: 2, learningStep: 0, repetitions: 7, lapses: 2, state: .review),
                    .easy: .init(dueOffset: 3 * day, stability: 3.45393478, difficulty: 5.98276817, elapsedDays: 0, scheduledDays: 3, learningStep: 0, repetitions: 7, lapses: 2, state: .review)
                ]
            )
        ]
    }
}
