import Foundation
import XCTest
@testable import OboeDomain

final class OboeDomainTests: XCTestCase {
    func testModuleIsAvailable() {
        XCTAssertEqual(OboeDomainInfo.moduleName, "OboeDomain")
    }

    func testStandardProfileExplicitlyDefinesFSRS6() {
        let profile = SchedulerProfile.standard

        XCTAssertEqual(profile.parameters.count, 21)
        XCTAssertEqual(profile.targetRetention, 0.9)
        XCTAssertEqual(profile.configurationVersion, "fsrs-6.0-default-r90-v1")
        XCTAssertEqual(profile.learningSteps, ["1m", "10m"])
        XCTAssertEqual(profile.relearningSteps, ["10m"])
    }

    func testReviewChoicesExposeExactlyFourRatings() {
        let reviewedAt = Date(timeIntervalSince1970: 1_768_478_400)
        let card = SchedulingCard(dueAt: reviewedAt)
        func choice(_ rating: ReviewRating) -> ReviewChoice {
            ReviewChoice(
                rating: rating,
                card: card,
                reviewedAt: reviewedAt,
                configurationVersion: "test"
            )
        }
        let choices = ReviewChoices(
            again: choice(.again),
            hard: choice(.hard),
            good: choice(.good),
            easy: choice(.easy)
        )

        XCTAssertEqual(ReviewRating.allCases.map { choices[$0].rating }, ReviewRating.allCases)
    }
}
