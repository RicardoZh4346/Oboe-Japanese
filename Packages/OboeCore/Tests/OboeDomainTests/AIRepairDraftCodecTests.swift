import Foundation
import XCTest
@testable import OboeDomain

/// T00B: the `ai_repair` draft envelope v1 — strict round-trip, phase/receipt
/// consistency, and the rejection rules backup validation relies on.
final class AIRepairDraftCodecTests: XCTestCase {
    func testRoundTripPreservesEveryField() throws {
        let envelope = AIRepairDraftEnvelope(
            targetNoteID: UUID(),
            targetCardID: UUID(),
            expectedContentVersion: 3,
            targetCardEnabled: true,
            affectedTemplateKinds: [.vocabularyJapaneseToChinese, .vocabularyListening],
            userComment: "例句太难",
            requestGeneration: 2,
            response: AIRepairResponse(
                problemTypes: [.tooManyMeanings, .lackOfContext],
                summary: "释义过多",
                suggestions: [
                    AIRepairSuggestion(
                        type: .splitCard,
                        title: "按语境拆分",
                        reason: "不同语境分别记忆",
                        splitNotes: [
                            AIRepairNoteCandidate(
                                kind: .vocabulary,
                                headword: "試験を受ける",
                                reading: "しけんをうける",
                                meaningZH: "参加考试"
                            )
                        ]
                    ),
                    AIRepairSuggestion(
                        type: .rewriteMeaning,
                        title: "改写释义",
                        reason: "聚焦单一含义",
                        replacement: AIRepairFieldPatch(meaningZH: "吃；服用"),
                        clearFields: [.notes]
                    )
                ]
            ),
            editedCandidate: AIRepairSuggestion(
                type: .addContext,
                title: "补充语境",
                reason: "说明使用场景",
                replacement: AIRepairFieldPatch(usage: "用于口语")
            ),
            phase: .suggested
        )

        let json = try AIRepairDraftCodec.encode(envelope)
        XCTAssertEqual(try AIRepairDraftCodec.decode(json), envelope)
    }

    func testCommittedEnvelopeRequiresConsistentReceipt() throws {
        let operationID = UUID()
        let valid = AIRepairDraftEnvelope(
            targetNoteID: UUID(),
            targetCardID: UUID(),
            expectedContentVersion: 1,
            targetCardEnabled: false,
            affectedTemplateKinds: [.grammarFormToExplanation],
            requestGeneration: 1,
            operationID: operationID,
            phase: .committed,
            commitReceipt: AIRepairCommitReceipt(
                operationID: operationID,
                payloadHash: String(repeating: "a", count: 64),
                createdNoteIDs: [UUID()],
                createdCardIDs: [UUID(), UUID()],
                originalCardDisposition: .pause
            )
        )
        let json = try AIRepairDraftCodec.encode(valid)
        XCTAssertEqual(try AIRepairDraftCodec.decode(json), valid)

        var missingReceipt = valid
        missingReceipt.commitReceipt = nil
        XCTAssertThrowsError(try AIRepairDraftCodec.encode(missingReceipt)) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .invalidField("commitReceipt"))
        }

        var mismatchedOperation = valid
        mismatchedOperation.commitReceipt?.operationID = UUID()
        XCTAssertThrowsError(try AIRepairDraftCodec.encode(mismatchedOperation)) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .invalidField("operationID"))
        }

        var badHash = valid
        badHash.commitReceipt?.payloadHash = "not-a-sha256"
        XCTAssertThrowsError(try AIRepairDraftCodec.encode(badHash)) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .invalidField("payloadHash"))
        }
    }

    func testLegacyDraftPayloadWithoutPitchDecodesAsNil() throws {
        let envelope = AIRepairDraftEnvelope(
            targetNoteID: UUID(),
            targetCardID: UUID(),
            expectedContentVersion: 1,
            targetCardEnabled: true,
            affectedTemplateKinds: [.vocabularyJapaneseToChinese],
            response: AIRepairResponse(
                schemaVersion: 1,
                problemTypes: [.lackOfContext],
                summary: "旧草稿",
                suggestions: [AIRepairSuggestion(
                    type: .addNote,
                    title: "补充说明",
                    reason: "旧载荷没有音调键",
                    replacement: AIRepairFieldPatch(notes: "保留")
                )]
            ),
            phase: .suggested
        )
        let restored = try AIRepairDraftCodec.decode(AIRepairDraftCodec.encode(envelope))
        XCTAssertNil(restored.response?.suggestions.first?.replacement?.pitchAccent)
    }

    func testUncommittedEnvelopeRejectsReceipt() {
        var envelope = AIRepairDraftEnvelope(
            targetNoteID: UUID(),
            targetCardID: UUID(),
            expectedContentVersion: 1,
            targetCardEnabled: true,
            affectedTemplateKinds: [.vocabularyChineseToJapanese],
            phase: .previewing
        )
        envelope.commitReceipt = AIRepairCommitReceipt(
            operationID: UUID(),
            payloadHash: String(repeating: "0", count: 64),
            originalCardDisposition: .keep
        )
        XCTAssertThrowsError(try AIRepairDraftCodec.encode(envelope)) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .invalidField("commitReceipt"))
        }
    }

    func testUnknownSchemaVersionAndMalformedJSONAreRejected() throws {
        let valid = AIRepairDraftEnvelope(
            targetNoteID: UUID(),
            targetCardID: UUID(),
            expectedContentVersion: 1,
            targetCardEnabled: true,
            affectedTemplateKinds: [.vocabularyJapaneseToChinese],
            phase: .editing
        )
        var parsed = try JSONSerialization.jsonObject(
            with: Data(AIRepairDraftCodec.encode(valid).utf8)
        ) as! [String: Any]
        parsed["schemaVersion"] = 99
        let futureJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: parsed),
            as: UTF8.self
        )
        XCTAssertThrowsError(try AIRepairDraftCodec.decode(futureJSON)) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .unsupportedSchemaVersion(99))
        }

        XCTAssertThrowsError(try AIRepairDraftCodec.decode("not json")) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .invalidJSON)
        }
        XCTAssertThrowsError(try AIRepairDraftCodec.decode(#"{"schemaVersion":1}"#)) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .invalidJSON)
        }
        // Unknown enum raw values fail the typed decode.
        parsed["schemaVersion"] = 1
        parsed["phase"] = "bogus_phase"
        let badPhase = String(
            decoding: try JSONSerialization.data(withJSONObject: parsed),
            as: UTF8.self
        )
        XCTAssertThrowsError(try AIRepairDraftCodec.decode(badPhase)) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .invalidJSON)
        }
    }

    func testOversizedAndSemanticallyInvalidEnvelopesAreRejected() {
        var hugeComment = AIRepairDraftEnvelope(
            targetNoteID: UUID(),
            targetCardID: UUID(),
            expectedContentVersion: 1,
            targetCardEnabled: true,
            affectedTemplateKinds: [.vocabularyJapaneseToChinese],
            userComment: String(repeating: "界", count: 1_001),
            phase: .editing
        )
        XCTAssertThrowsError(try AIRepairDraftCodec.encode(hugeComment)) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .invalidField("userComment"))
        }
        hugeComment.userComment = ""

        var emptyDirections = hugeComment
        emptyDirections.affectedTemplateKinds = []
        XCTAssertThrowsError(try AIRepairDraftCodec.encode(emptyDirections)) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .invalidField("affectedTemplateKinds"))
        }

        var badGeneration = hugeComment
        badGeneration.requestGeneration = 0
        XCTAssertThrowsError(try AIRepairDraftCodec.encode(badGeneration)) { error in
            XCTAssertEqual(error as? AIRepairDraftError, .invalidField("requestGeneration"))
        }
    }
}
