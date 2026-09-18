import Foundation
import XCTest
@testable import OboeDomain

final class CaptureResumePayloadTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        let itemID = UUID()
        let deckID = UUID()
        var draft = Self.makeCardDraft(id: itemID)
        draft.meaningZH = "用户改过的释义"
        draft.vocabularyDirections = [.japaneseToChinese, .chineseToJapanese]
        draft.createDespiteDuplicate = true
        let payload = CaptureResumePayload(
            selection: CaptureTextSelection(utf16Offset: 3, utf16Length: 7),
            targetDeckID: deckID,
            vocabularyDirections: [.chineseToJapanese],
            grammarFormToExplanation: false,
            selectedAnalysisItemIDs: [itemID],
            editedCardDrafts: [draft],
            analysisContentRevision: 2,
            pendingOperationID: UUID()
        )

        let json = try CaptureResumePayloadCodec.encode(payload)
        let decoded = try CaptureResumePayloadCodec.decode(json)

        XCTAssertEqual(decoded, payload)
    }

    func testDecodeDefaultsOptionalCollectionsAndDirections() throws {
        let decoded = try CaptureResumePayloadCodec.decode("{\"version\":1}")
        XCTAssertNil(decoded.selection)
        XCTAssertNil(decoded.targetDeckID)
        XCTAssertEqual(decoded.vocabularyDirections, [.japaneseToChinese])
        XCTAssertTrue(decoded.grammarFormToExplanation)
        XCTAssertEqual(decoded.selectedAnalysisItemIDs, [])
        XCTAssertEqual(decoded.editedCardDrafts, [])
        XCTAssertNil(decoded.analysisContentRevision)
        XCTAssertNil(decoded.pendingOperationID)
    }

    func testDecodeRejectsUnsupportedVersion() {
        XCTAssertThrowsError(try CaptureResumePayloadCodec.decode("{\"version\":2}")) { error in
            XCTAssertEqual(
                error as? CaptureResumePayloadError,
                .unsupportedVersion(2)
            )
        }
    }

    func testDecodeRejectsNonJSONAndMissingVersion() {
        XCTAssertThrowsError(try CaptureResumePayloadCodec.decode("not-json")) { error in
            XCTAssertEqual(error as? CaptureResumePayloadError, .invalidJSON)
        }
        XCTAssertThrowsError(try CaptureResumePayloadCodec.decode("{}")) { error in
            XCTAssertEqual(error as? CaptureResumePayloadError, .invalidJSON)
        }
    }

    func testDecodeRejectsOversizedPayload() {
        let oversized = String(repeating: "あ", count: 200_000)
        let json = """
            {"version":1,"editedCardDrafts":[{"id":"\
            \(UUID().uuidString)","kind":"vocabulary","headword":"h","reading":"",\
            "meaningZH":"m","partOfSpeech":"","usage":"","connection":"",\
            "exampleJapanese":"","exampleTranslationZH":"","notes":"\(oversized)",\
            "vocabularyDirections":["japaneseToChinese"],"createDespiteDuplicate":false}]}
            """
        XCTAssertThrowsError(try CaptureResumePayloadCodec.decode(json)) { error in
            guard case .payloadTooLarge = error as? CaptureResumePayloadError else {
                return XCTFail("预期 payloadTooLarge，得到 \(error)")
            }
        }
    }

    func testValidationRejectsTooManySelectedItems() {
        let payload = CaptureResumePayload(
            selectedAnalysisItemIDs: (0..<31).map { _ in UUID() }
        )
        XCTAssertThrowsError(try CaptureResumePayloadCodec.encode(payload)) { error in
            XCTAssertEqual(
                error as? CaptureResumePayloadError,
                .tooManyItems(field: "selectedAnalysisItemIDs", maximum: 30)
            )
        }
    }

    func testValidationRejectsEditedDraftOutsideSelection() {
        let payload = CaptureResumePayload(
            selectedAnalysisItemIDs: [UUID()],
            editedCardDrafts: [Self.makeCardDraft(id: UUID())]
        )
        XCTAssertThrowsError(try CaptureResumePayloadCodec.encode(payload)) { error in
            XCTAssertEqual(
                error as? CaptureResumePayloadError,
                .invalidField("editedCardDrafts")
            )
        }
    }

    func testValidationRejectsNegativeSelection() {
        let payload = CaptureResumePayload(
            selection: CaptureTextSelection(utf16Offset: -1, utf16Length: 5)
        )
        XCTAssertThrowsError(try CaptureResumePayloadCodec.encode(payload)) { error in
            XCTAssertEqual(
                error as? CaptureResumePayloadError,
                .invalidField("selection")
            )
        }
    }

    func testValidateSelectionChecksBoundsAgainstSnapshotText() throws {
        let selection = CaptureTextSelection(utf16Offset: 1, utf16Length: 4)
        try CaptureResumePayloadCodec.validateSelection(selection, within: "あいうえお")
        XCTAssertThrowsError(
            try CaptureResumePayloadCodec.validateSelection(selection, within: "あい")
        ) { error in
            XCTAssertEqual(
                error as? CaptureResumePayloadError,
                .invalidField("selection")
            )
        }
    }

    func testSessionFlagsStaleAnalysisAndSanitizesResumeData() {
        let item = InboxItem(
            id: UUID(),
            text: "新しい原文",
            sourceType: .manual,
            status: .processing,
            contentRevision: 3,
            sourceApp: nil,
            sourceURL: nil,
            imageReference: nil,
            createdAt: Date(timeIntervalSince1970: 1_768_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_768_000_000),
            processedAt: nil,
            archivedAt: nil,
            statusBeforeArchive: nil
        )
        let context = InboxProcessingContext(
            id: UUID(),
            inboxItemID: item.id,
            contentRevision: 3,
            inputText: item.text,
            mode: .sentenceAnalysis,
            draftID: UUID(),
            payloadVersion: 1,
            resumePayloadJSON: nil,
            updatedAt: item.updatedAt
        )
        let itemID = UUID()
        let deckID = UUID()
        let payload = CaptureResumePayload(
            selection: CaptureTextSelection(utf16Offset: 0, utf16Length: 3),
            targetDeckID: deckID,
            vocabularyDirections: [.chineseToJapanese],
            selectedAnalysisItemIDs: [itemID],
            editedCardDrafts: [Self.makeCardDraft(id: itemID)],
            analysisContentRevision: 2,
            pendingOperationID: UUID()
        )
        let session = CaptureProcessingSession(item: item, context: context, payload: payload)

        XCTAssertFalse(session.isSourceRevised)
        XCTAssertTrue(session.isAnalysisStale)
        let resumable = session.resumablePayload
        XCTAssertEqual(resumable?.targetDeckID, deckID)
        XCTAssertEqual(resumable?.vocabularyDirections, [.chineseToJapanese])
        XCTAssertEqual(resumable?.pendingOperationID, payload.pendingOperationID)
        XCTAssertNil(resumable?.selection)
        XCTAssertEqual(resumable?.selectedAnalysisItemIDs, [])
        XCTAssertEqual(resumable?.editedCardDrafts, [])
        XCTAssertNil(resumable?.analysisContentRevision)
    }

    func testSessionWithoutAnalysisKeepsPayloadUnchanged() {
        let item = InboxItem(
            id: UUID(),
            text: "原文",
            sourceType: .manual,
            status: .processing,
            contentRevision: 1,
            sourceApp: nil,
            sourceURL: nil,
            imageReference: nil,
            createdAt: Date(timeIntervalSince1970: 1_768_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_768_000_000),
            processedAt: nil,
            archivedAt: nil,
            statusBeforeArchive: nil
        )
        let context = InboxProcessingContext(
            id: UUID(),
            inboxItemID: item.id,
            contentRevision: 1,
            inputText: item.text,
            mode: .manualEdit,
            draftID: nil,
            payloadVersion: 1,
            resumePayloadJSON: nil,
            updatedAt: item.updatedAt
        )
        let payload = CaptureResumePayload(targetDeckID: UUID())
        let session = CaptureProcessingSession(item: item, context: context, payload: payload)

        XCTAssertFalse(session.isSourceRevised)
        XCTAssertFalse(session.isAnalysisStale)
        XCTAssertEqual(session.resumablePayload, payload)
    }

    func testSuggestedModeHeuristic() {
        XCTAssertEqual(
            CaptureProcessingMode.suggested(forText: "食べる"),
            .vocabularyGeneration
        )
        XCTAssertEqual(
            CaptureProcessingMode.suggested(forText: "  辞書  "),
            .vocabularyGeneration
        )
        XCTAssertEqual(
            CaptureProcessingMode.suggested(forText: "毎朝パンを食べます。"),
            .sentenceAnalysis
        )
        XCTAssertEqual(
            CaptureProcessingMode.suggested(forText: "行きますか？"),
            .sentenceAnalysis
        )
        XCTAssertEqual(
            CaptureProcessingMode.suggested(forText: "一行目\n二行目"),
            .sentenceAnalysis
        )
        let longText = String(repeating: "あ", count: 201)
        XCTAssertEqual(
            CaptureProcessingMode.suggested(forText: longText),
            .sentenceAnalysis
        )
    }

    private static func makeCardDraft(id: UUID) -> SentenceAnalysisCardDraft {
        SentenceAnalysisCardDraft(
            id: id,
            kind: .vocabulary,
            headword: "食べる",
            meaningZH: "吃"
        )
    }
}
