import Foundation
import XCTest
@testable import OboeDomain

/// T05: the AI repair request/response protocol — whitelisted request
/// encoding, strict response decoding, suggestion semantics and preview
/// candidate generation. All inputs are synthetic; nothing here touches a
/// database, matching the T05 completion criterion.
final class AIRepairProtocolTests: XCTestCase {

    // MARK: - Request encoding (设计 §6.1 whitelist)

    func testRequestEncodesOnlyWhitelistedFields() throws {
        let context = makeVocabularyRequestContext()
        let json = try AIRepairRequestEncoder.encode(context)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["schemaVersion", "promptVersion", "note", "direction", "reviewSummary", "userComment"]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(object["promptVersion"] as? String, AIRepairPromptV2.promptVersion)
        XCTAssertEqual(object["direction"] as? String, "vocabulary_ja_zh")
        XCTAssertEqual(object["userComment"] as? String, "例句总是记不住")

        let note = try XCTUnwrap(object["note"] as? [String: Any])
        // Nil optionals are omitted; every emitted key must be whitelisted.
        XCTAssertTrue(
            Set(note.keys).isSubset(of: [
                "kind", "headword", "reading", "meaningZH", "partsOfSpeech",
                "pitchAccent", "usage", "connection", "examples", "notes"
            ])
        )
        XCTAssertTrue(Set(note.keys).isSuperset(of: ["kind", "headword", "meaningZH"]))
        XCTAssertEqual(note["kind"] as? String, "vocabulary")
        XCTAssertEqual(note["headword"] as? String, "受ける")
        XCTAssertEqual(note["partsOfSpeech"] as? [String], ["一段动词", "他动词"])
        XCTAssertEqual(note["pitchAccent"] as? Int, 2)

        let summary = try XCTUnwrap(object["reviewSummary"] as? [String: Any])
        XCTAssertEqual(
            Set(summary.keys),
            ["recentCount", "recentAgainCount", "dueAgainStreak", "lifetimeLapses"]
        )

        // The whitelist is structural: identifiers, deck, source text, full
        // history, typed answers, other notes and credentials have no slot.
        for forbidden in [
            "id", "noteID", "cardID", "deckID", "jlpt", "contentVersion",
            "sourceText", "sourceRef", "reviewLogs", "typedAnswer",
            "apiKey", "credential", "device"
        ] {
            XCTAssertFalse(json.contains("\"\(forbidden)\""), "leaked \(forbidden)")
        }
    }

    func testRequestRejectsOversizedCommentAndContext() throws {
        var context = makeVocabularyRequestContext()
        context.userComment = String(repeating: "字", count: 1_001)
        XCTAssertThrowsError(try AIRepairRequestEncoder.encode(context)) { error in
            XCTAssertEqual(error as? AIRepairError, .userCommentTooLong)
        }

        context.userComment = ""
        context.note.notes = String(repeating: "備", count: 17 * 1_024)
        XCTAssertThrowsError(try AIRepairRequestEncoder.encode(context)) { error in
            XCTAssertEqual(error as? AIRepairError, .contextTooLarge)
        }
    }

    func testReviewSummaryMapsFromAdaptiveMetrics() {
        let metrics = AdaptiveMetrics(
            lifetimeLapses: 9,
            recentCount: 6,
            recentAgainCount: 3,
            shortWindowAgainCount: 2,
            totalCount: 20,
            totalAgainCount: 8,
            againRatio: 0.4,
            dueAgainStreak: 2,
            lastDueReviewAt: Date(),
            lastAgainAt: Date(),
            lastDueIntervalDays: 1.5,
            difficulty: 7.1,
            stability: 4.2,
            consecutiveDueSuccesses: 0
        )
        let summary = AIRepairReviewSummary(metrics: metrics)
        XCTAssertEqual(summary.recentCount, 6)
        XCTAssertEqual(summary.recentAgainCount, 3)
        XCTAssertEqual(summary.dueAgainStreak, 2)
        XCTAssertEqual(summary.lifetimeLapses, 9)
    }

    // MARK: - Valid responses decode into preview candidates

    func testValidVocabularyResponseDecodesAndBuildsPreviews() throws {
        let response = try decodeResponse([
            "problemTypes": ["too_many_meanings", "lack_of_context"],
            "summary": "当前释义包含多个语境。",
            "suggestions": [
                [
                    "type": "rewrite_meaning",
                    "title": "精简释义",
                    "reason": "聚焦最常用的含义",
                    "replacement": ["meaningZH": "参加考试", "notes": "应试场景"],
                    "clearFields": ["partOfSpeech"]
                ],
                [
                    "type": "split_card",
                    "title": "按语境拆分",
                    "reason": "两种用法分别记忆",
                    "splitNotes": [
                        [
                            "kind": "vocabulary",
                            "headword": "試験を受ける",
                            "reading": "しけんをうける",
                            "meaningZH": "参加考试"
                        ],
                        [
                            "kind": "vocabulary",
                            "headword": "影響を受ける",
                            "reading": "えいきょうをうける",
                            "meaningZH": "受到影响"
                        ]
                    ]
                ]
            ]
        ])
        XCTAssertEqual(response.schemaVersion, 2)
        XCTAssertEqual(response.problemTypes, [.tooManyMeanings, .lackOfContext])
        XCTAssertEqual(response.suggestions.count, 2)

        let previews = try AIRepairPreviewBuilder.previews(
            for: response,
            note: makeVocabularySnapshot()
        )
        XCTAssertEqual(previews.count, 2)

        let patch = try XCTUnwrap(previews[0].resultContent)
        guard case let .vocabulary(content) = patch else {
            return XCTFail("expected vocabulary content")
        }
        XCTAssertEqual(content.headword, "受ける")
        XCTAssertEqual(content.meaningZH, "参加考试")
        XCTAssertNil(content.partOfSpeech)
        XCTAssertEqual(content.notes, "应试场景")
        XCTAssertEqual(content.jlpt, .n3)
        XCTAssertEqual(
            previews[0].changes.map(\.field),
            [.meaningZH, .partOfSpeech, .notes]
        )
        let meaningChange = previews[0].changes.first { $0.field == .meaningZH }
        XCTAssertEqual(meaningChange?.before, "接受；遭受")
        XCTAssertEqual(meaningChange?.after, "参加考试")

        XCTAssertEqual(previews[1].splitContents.count, 2)
        guard case let .vocabulary(first) = previews[1].splitContents[0] else {
            return XCTFail("expected vocabulary split content")
        }
        XCTAssertEqual(first.headword, "試験を受ける")
        XCTAssertEqual(first.meaningZH, "参加考试")
    }

    func testValidGrammarResponseDecodesAndBuildsPreview() throws {
        let response = try decodeResponse([
            "problemTypes": ["grammar_scope_too_broad"],
            "summary": "语法适用范围过宽。",
            "suggestions": [
                [
                    "type": "add_context",
                    "title": "限定使用语境",
                    "reason": "明确书面语场景",
                    "replacement": ["usage": "书面语；正式表达"]
                ],
                [
                    "type": "split_card",
                    "title": "按含义拆分",
                    "reason": "原因与手段分别记忆",
                    "splitNotes": [
                        [
                            "kind": "grammar",
                            "headword": "〜によって（原因）",
                            "meaningZH": "由于……",
                            "usage": "表原因",
                            "connection": "名词 + によって"
                        ],
                        [
                            "kind": "grammar",
                            "headword": "〜によって（手段）",
                            "meaningZH": "通过……方式",
                            "usage": "表手段"
                        ]
                    ]
                ]
            ]
        ])
        XCTAssertEqual(response.problemTypes, [.grammarScopeTooBroad])

        let previews = try AIRepairPreviewBuilder.previews(
            for: response,
            note: makeGrammarSnapshot()
        )
        guard case let .grammar(content) = previews[0].resultContent else {
            return XCTFail("expected grammar content")
        }
        XCTAssertEqual(content.grammarForm, "〜によって")
        XCTAssertEqual(content.usage, "书面语；正式表达")
        XCTAssertEqual(content.connection, "被动句中提示动作主体")
        XCTAssertEqual(previews[0].changes.map(\.field), [.usage])

        XCTAssertEqual(previews[1].splitContents.count, 2)
        guard case let .grammar(splitContent) = previews[1].splitContents[0] else {
            return XCTFail("expected grammar split content")
        }
        XCTAssertEqual(splitContent.grammarForm, "〜によって（原因）")
        XCTAssertEqual(splitContent.usage, "表原因")
    }

    // MARK: - Unknown enums and unsupported versions are rejected

    func testUnknownEnumsAreRejected() {
        assertDecodeFails(
            suggestion: ["type": "make_easier", "title": "t", "reason": "r",
                         "replacement": ["notes": "x"]],
            equals: .unknownSuggestionType("make_easier")
        )
        XCTAssertThrowsError(try decodeResponse([
            "problemTypes": ["forgot_everything"],
            "summary": "s",
            "suggestions": [validSuggestion]
        ])) { error in
            XCTAssertEqual(error as? AIRepairError, .unknownProblemType("forgot_everything"))
        }
        assertDecodeFails(
            suggestion: ["type": "add_note", "title": "t", "reason": "r",
                         "clearFields": ["meaningZH"]],
            equals: .unknownClearableField("meaningZH")
        )
        assertDecodeFails(
            suggestion: ["type": "split_card", "title": "t", "reason": "r",
                         "splitNotes": [
                            ["kind": "kanji", "headword": "h", "meaningZH": "m"],
                            validSplitCandidate
                         ]],
            equals: .unknownNoteKind("kanji")
        )
    }

    func testUnsupportedSchemaVersionIsRejected() {
        XCTAssertThrowsError(try decodeResponse(
            ["schemaVersion": 99],
            suggestion: validSuggestion
        )) { error in
            XCTAssertEqual(error as? AIRepairError, .unsupportedSchemaVersion(99))
        }
    }

    func testV2ControlledPartsAndPitchAreValidatedWithoutGuessing() throws {
        let response = try decodeResponse([
            "problemTypes": ["lack_of_context"],
            "summary": "补齐受控字段。",
            "suggestions": [[
                "type": "add_note",
                "title": "补齐词性与音调",
                "reason": "提升辨识度",
                "replacement": [
                    "partsOfSpeech": ["一段动词", "他动词"],
                    "pitchAccent": 2
                ]
            ]]
        ])
        let preview = try AIRepairPreviewBuilder.preview(
            response.suggestions[0],
            note: makeVocabularySnapshot()
        )
        guard case let .vocabulary(content) = preview.resultContent else {
            return XCTFail("expected vocabulary content")
        }
        XCTAssertEqual(content.partOfSpeech, "一段动词 / 他动词")
        XCTAssertEqual(content.pitchAccent, PitchAccent(rawValue: 2))

        assertDecodeFails(
            suggestion: ["type": "add_note", "title": "t", "reason": "r",
                         "replacement": ["partsOfSpeech": ["未知词性"]]],
            equals: .invalidCandidate("无效或重复的词性：未知词性")
        )
        assertDecodeFails(
            suggestion: ["type": "add_note", "title": "t", "reason": "r",
                         "replacement": ["pitchAccent": -1]],
            equals: .invalidCandidate("音调必须是非负整数")
        )

        XCTAssertThrowsError(try decodeResponse(["schemaVersion": 1])) { error in
            XCTAssertEqual(error as? AIRepairError, .unsupportedSchemaVersion(1))
        }
    }

    // MARK: - Empty required fields are rejected

    func testEmptyRequiredFieldsAreRejected() {
        assertDecodeFails(
            suggestion: ["type": "add_note", "title": "", "reason": "r",
                         "replacement": ["notes": "x"]],
            equals: .emptyRequiredField("title")
        )
        assertDecodeFails(
            suggestion: ["type": "rewrite_meaning", "title": "t", "reason": "r",
                         "replacement": ["meaningZH": "   "]],
            equals: .emptyRequiredField("meaningZH")
        )
        assertDecodeFails(
            suggestion: ["type": "split_card", "title": "t", "reason": "r",
                         "splitNotes": [
                            ["kind": "vocabulary", "headword": "h", "meaningZH": ""],
                            validSplitCandidate
                         ]],
            equals: .emptyRequiredField("meaningZH")
        )
    }

    // MARK: - Fields outside the contract are rejected at every level

    func testUnexpectedFieldsAreRejectedAtEveryLevel() {
        // Response level: scheduling/ID/command keys have no place.
        XCTAssertThrowsError(try decodeResponse(
            ["problemTypes": [], "summary": "s", "suggestions": [validSuggestion],
             "cardID": "x", "rating": "good", "fsrsStability": 3, "deleteNote": true]
        )) { error in
            XCTAssertEqual(error as? AIRepairError, .unexpectedFields)
        }
        assertDecodeFails(
            suggestion: ["type": "add_note", "title": "t", "reason": "r",
                         "replacement": ["notes": "x"], "noteID": "abc"],
            equals: .unexpectedFields
        )
        assertDecodeFails(
            suggestion: ["type": "add_note", "title": "t", "reason": "r",
                         "replacement": ["notes": "x", "deckID": "abc"]],
            equals: .unexpectedFields
        )
        assertDecodeFails(
            suggestion: ["type": "split_card", "title": "t", "reason": "r",
                         "splitNotes": [
                            ["kind": "vocabulary", "headword": "h", "meaningZH": "m",
                             "cardID": "x"],
                            validSplitCandidate
                         ]],
            equals: .unexpectedFields
        )
        assertDecodeFails(
            suggestion: ["type": "replace_example", "title": "t", "reason": "r",
                         "replacement": ["examples": [["japanese": "例", "rating": "again"]]]],
            equals: .unexpectedFields
        )
    }

    // MARK: - Split, conflict and payload rules

    func testSplitRulesAreEnforced() {
        // Fewer than two candidates.
        assertDecodeFails(
            suggestion: ["type": "split_card", "title": "t", "reason": "r",
                         "splitNotes": [validSplitCandidate]],
            equals: .incompleteSplit
        )
        // No candidates at all.
        assertDecodeFails(
            suggestion: ["type": "split_card", "title": "t", "reason": "r"],
            equals: .incompleteSplit
        )
        // More than four candidates.
        assertDecodeFails(
            suggestion: ["type": "split_card", "title": "t", "reason": "r",
                         "splitNotes": Array(repeating: validSplitCandidate, count: 5)],
            equals: .tooManySplitNotes
        )
        // splitNotes on a non-split suggestion.
        assertDecodeFails(
            suggestion: ["type": "rewrite_meaning", "title": "t", "reason": "r",
                         "replacement": ["meaningZH": "m"],
                         "splitNotes": [validSplitCandidate, validSplitCandidate]],
            equals: .splitNotesNotAllowed
        )
        // A split suggestion must not also patch the original note.
        assertDecodeFails(
            suggestion: ["type": "split_card", "title": "t", "reason": "r",
                         "replacement": ["meaningZH": "m"],
                         "splitNotes": [validSplitCandidate, validSplitCandidate]],
            equals: .patchNotAllowedForSplit
        )
    }

    func testPatchClearConflictIsRejected() {
        assertDecodeFails(
            suggestion: ["type": "add_context", "title": "t", "reason": "r",
                         "replacement": ["usage": "u"],
                         "clearFields": ["usage"]],
            equals: .patchClearConflict("usage")
        )
    }

    func testSuggestionWithoutPayloadIsRejected() {
        assertDecodeFails(
            suggestion: ["type": "add_disambiguation", "title": "t", "reason": "r"],
            equals: .emptySuggestion
        )
        assertDecodeFails(
            suggestion: ["type": "add_note", "title": "t", "reason": "r",
                         "replacement": [:]],
            equals: .emptySuggestion
        )
    }

    // MARK: - Size limits

    func testOutputLimitsAreEnforced() throws {
        let suggestions = Array(
            repeating: validSuggestion,
            count: AIRepairOutputDecoder.maximumSuggestions + 1
        )
        XCTAssertThrowsError(try decodeResponse([
            "problemTypes": [], "summary": "s", "suggestions": suggestions
        ])) { error in
            XCTAssertEqual(error as? AIRepairError, .tooManySuggestions)
        }

        var object: [String: Any] = [
            "schemaVersion": 2,
            "problemTypes": [],
            "summary": String(repeating: "长", count: 64 * 1_024),
            "suggestions": []
        ]
        let oversized = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        XCTAssertThrowsError(try AIRepairOutputDecoder.decode(oversized)) { error in
            XCTAssertEqual(error as? AIRepairError, .responseTooLarge)
        }

        object["summary"] = String(repeating: "长", count: 1_001)
        let tooLongField = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        XCTAssertThrowsError(try AIRepairOutputDecoder.decode(tooLongField)) { error in
            XCTAssertEqual(error as? AIRepairError, .fieldTooLong("summary"))
        }
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try AIRepairOutputDecoder.decode("not json")) { error in
            XCTAssertEqual(error as? AIRepairError, .invalidJSON)
        }
        XCTAssertThrowsError(try AIRepairOutputDecoder.decode(#"["array"]"#)) { error in
            XCTAssertEqual(error as? AIRepairError, .invalidJSON)
        }
    }

    // MARK: - Preview semantics

    func testClearFieldsAndPatchMergeSemantics() throws {
        let suggestion = AIRepairSuggestion(
            type: .shortenAnswer,
            title: "精简",
            reason: "只保留核心",
            replacement: AIRepairFieldPatch(meaningZH: "参加考试"),
            clearFields: [.reading, .pitchAccent, .notes]
        )
        let preview = try AIRepairPreviewBuilder.preview(
            suggestion,
            note: makeVocabularySnapshot()
        )
        guard case let .vocabulary(content) = preview.resultContent else {
            return XCTFail("expected vocabulary content")
        }
        XCTAssertNil(content.reading)
        XCTAssertNil(content.notes)
        XCTAssertEqual(content.meaningZH, "参加考试")
        XCTAssertEqual(
            preview.changes.map(\.field),
            [.reading, .meaningZH, .pitchAccent, .notes]
        )
    }

    func testPatchOnFieldMissingFromKindIsRejectedAtPreview() {
        let suggestion = AIRepairSuggestion(
            type: .addContext,
            title: "t",
            reason: "r",
            replacement: AIRepairFieldPatch(reading: "よみ")
        )
        XCTAssertThrowsError(
            try AIRepairPreviewBuilder.preview(suggestion, note: makeGrammarSnapshot())
        ) { error in
            XCTAssertEqual(error as? AIRepairError, .fieldNotApplicableForKind("reading"))
        }
        let clearReading = AIRepairSuggestion(
            type: .addContext,
            title: "t",
            reason: "r",
            clearFields: [.reading]
        )
        XCTAssertThrowsError(
            try AIRepairPreviewBuilder.preview(clearReading, note: makeGrammarSnapshot())
        ) { error in
            XCTAssertEqual(error as? AIRepairError, .fieldNotApplicableForKind("reading"))
        }
    }

    func testCandidateValidationFailuresPropagateThroughPreview() {
        // Wire decoding catches empty fields first; candidates built in code
        // (e.g. user-edited drafts) still get full validation via preview.
        let invalid = AIRepairSuggestion(
            type: .splitCard,
            title: "t",
            reason: "r",
            splitNotes: [
                AIRepairNoteCandidate(
                    kind: .vocabulary,
                    headword: "h",
                    meaningZH: "m",
                    usage: "不存在的字段"
                ),
                AIRepairNoteCandidate(kind: .vocabulary, headword: "h2", meaningZH: "m2")
            ]
        )
        XCTAssertThrowsError(
            try AIRepairPreviewBuilder.preview(invalid, note: makeVocabularySnapshot())
        ) { error in
            XCTAssertEqual(error as? AIRepairError, .fieldNotApplicableForKind("usage"))
        }

        let formInvalid = AIRepairSuggestion(
            type: .splitCard,
            title: "t",
            reason: "r",
            splitNotes: [
                AIRepairNoteCandidate(
                    kind: .vocabulary,
                    headword: "h",
                    meaningZH: "m",
                    examples: [AIRepairExampleCandidate(japanese: "", translationZH: "译文")]
                ),
                AIRepairNoteCandidate(kind: .vocabulary, headword: "h2", meaningZH: "m2")
            ]
        )
        XCTAssertThrowsError(
            try AIRepairPreviewBuilder.preview(formInvalid, note: makeVocabularySnapshot())
        ) { error in
            guard case .invalidCandidate = error as? AIRepairError else {
                return XCTFail("expected invalidCandidate, got \(error)")
            }
        }
    }

    func testEditedCandidateRoundTripsThroughDraftEnvelope() throws {
        let response = try decodeResponse([
            "problemTypes": ["lack_of_context"],
            "summary": "s",
            "suggestions": [validSuggestion]
        ])
        let envelope = AIRepairDraftEnvelope(
            targetNoteID: UUID(),
            targetCardID: UUID(),
            expectedContentVersion: 2,
            targetCardEnabled: true,
            affectedTemplateKinds: [.vocabularyJapaneseToChinese],
            userComment: "补充说明",
            requestGeneration: 1,
            response: response,
            editedCandidate: response.suggestions[0],
            phase: .suggested
        )
        let restored = try AIRepairDraftCodec.decode(AIRepairDraftCodec.encode(envelope))
        XCTAssertEqual(restored.response, response)
        let previews = try AIRepairPreviewBuilder.previews(
            for: try XCTUnwrap(restored.response),
            note: makeVocabularySnapshot()
        )
        XCTAssertEqual(previews.count, 1)
    }

    // MARK: - Helpers

    private var validSuggestion: [String: Any] {
        ["type": "add_note", "title": "补充说明", "reason": "提供语境",
         "replacement": ["notes": "常用于口语"]]
    }

    private var validSplitCandidate: [String: Any] {
        ["kind": "vocabulary", "headword": "試験を受ける",
         "reading": "しけんをうける", "meaningZH": "参加考试"]
    }

    private func makeVocabularySnapshot() -> AIRepairNoteSnapshot {
        AIRepairNoteSnapshot(
            kind: .vocabulary,
            headword: "受ける",
            reading: "うける",
            meaningZH: "接受；遭受",
            partOfSpeech: "一段动词 / 他动词",
            pitchAccent: PitchAccent(rawValue: 2),
            jlpt: .n3,
            notes: "原注释",
            examples: [AIRepairExampleCandidate(
                japanese: "試験を受ける",
                translationZH: "参加考试"
            )]
        )
    }

    private func makeGrammarSnapshot() -> AIRepairNoteSnapshot {
        AIRepairNoteSnapshot(
            kind: .grammar,
            headword: "〜によって",
            meaningZH: "由于……；通过……",
            jlpt: .n3,
            usage: "书面语",
            connection: "被动句中提示动作主体",
            notes: "注意与 〜により 区分"
        )
    }

    private func makeVocabularyRequestContext() -> AIRepairRequestContext {
        AIRepairRequestContext(
            note: makeVocabularySnapshot(),
            direction: .vocabularyJapaneseToChinese,
            reviewSummary: AIRepairReviewSummary(
                recentCount: 6,
                recentAgainCount: 3,
                dueAgainStreak: 2,
                lifetimeLapses: 9
            ),
            userComment: "例句总是记不住"
        )
    }

    @discardableResult
    private func decodeResponse(
        _ overrides: [String: Any],
        suggestion: [String: Any]? = nil
    ) throws -> AIRepairResponse {
        var object: [String: Any] = [
            "schemaVersion": 2,
            "problemTypes": ["unknown"],
            "summary": "诊断",
            "suggestions": [suggestion ?? validSuggestion]
        ]
        for (key, value) in overrides {
            object[key] = value
        }
        if let suggestions = object["suggestions"] as? [[String: Any]] {
            object["suggestions"] = suggestions.map(upgradedSuggestion)
        }
        let json = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        return try AIRepairOutputDecoder.decode(json)
    }

    private func upgradedSuggestion(_ suggestion: [String: Any]) -> [String: Any] {
        guard let candidates = suggestion["splitNotes"] as? [[String: Any]] else {
            return suggestion
        }
        var suggestion = suggestion
        suggestion["splitNotes"] = candidates.map { candidate in
            var candidate = candidate
            candidate["reading"] = candidate["reading"] ?? NSNull()
            candidate["partsOfSpeech"] = candidate["partsOfSpeech"] ?? []
            candidate["pitchAccent"] = candidate["pitchAccent"] ?? NSNull()
            candidate["jlpt"] = candidate["jlpt"] ?? NSNull()
            candidate["usage"] = candidate["usage"] ?? NSNull()
            candidate["connection"] = candidate["connection"] ?? NSNull()
            candidate["notes"] = candidate["notes"] ?? NSNull()
            candidate["examples"] = candidate["examples"] ?? NSNull()
            return candidate
        }
        return suggestion
    }

    private func assertDecodeFails(
        suggestion: [String: Any],
        equals expected: AIRepairError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try decodeResponse([:], suggestion: suggestion)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AIRepairError, expected, file: file, line: line)
        }
    }
}
