import Foundation
import XCTest
@testable import OboeDomain

final class InboxModelsTests: XCTestCase {
    func testEnumRawValuesMatchPersistedCheckConstraints() {
        XCTAssertEqual(
            Set(InboxSourceType.allCases.map(\.rawValue)),
            ["manual", "paste", "share", "ocr"]
        )
        XCTAssertEqual(
            Set(InboxStatus.allCases.map(\.rawValue)),
            ["unprocessed", "processing", "processed", "archived"]
        )
        XCTAssertEqual(
            Set(CaptureProcessingMode.allCases.map(\.rawValue)),
            [
                "vocabulary_generation", "grammar_generation",
                "sentence_analysis", "manual_edit"
            ]
        )
    }

    func testInboxTextRejectsEmptyAndWhitespaceOnly() {
        XCTAssertThrowsError(try InboxText(validating: "")) { error in
            XCTAssertEqual(error as? InboxTextValidationError, .empty)
        }
        XCTAssertThrowsError(try InboxText(validating: "  \n\t ")) { error in
            XCTAssertEqual(error as? InboxTextValidationError, .empty)
        }
    }

    func testInboxTextAcceptsUpToCharacterLimit() throws {
        let atLimit = String(repeating: "あ", count: InboxText.maximumCharacterCount)
        let text = try InboxText(validating: atLimit)
        XCTAssertEqual(text.value, atLimit)

        XCTAssertThrowsError(try InboxText(
            validating: atLimit + "い"
        )) { error in
            XCTAssertEqual(
                error as? InboxTextValidationError,
                .tooLong(maximumCharacters: InboxText.maximumCharacterCount)
            )
        }
    }

    func testInboxTextPreservesVerbatimValue() throws {
        let raw = "  そんなわけないでしょう。\n"
        let text = try InboxText(validating: raw)
        XCTAssertEqual(text.value, raw)
    }

    func testInboxTextByteLimitMatchesDocumentedBound() {
        XCTAssertEqual(InboxText.maximumUTF8ByteCount, 262_144)
        XCTAssertEqual(CaptureResumePayloadFormat.currentVersion, 1)
        XCTAssertEqual(CaptureResumePayloadFormat.maximumUTF8ByteCount, 262_144)
    }
}
