import Foundation
import OboeDomain
import XCTest

/// v0.7.0 S13：编辑面领域契约（设计 §9.2——「编辑句子后必须重新选择
/// 并验证范围；只改翻译/hint 不变 range；contentVersion 递增」）。
/// 覆盖 surfaceRanges 出现枚举、SentenceFormData 的选择/失效语义与
/// SentenceService 的读-改-写版本传递。
final class SentenceEditingTests: XCTestCase {

    private let sentence = "私は昨日映画を見た。"

    private func utf16(_ needle: String, in haystack: String) -> (Int, Int) {
        let ns = NSRange(haystack.range(of: needle)!, in: haystack)
        return (ns.location, ns.length)
    }

    private func makeDefinition(
        sentence: String = "彼が言ったことは彼が言った通りだ",
        occurrence: Int = 0,
        contentVersion: Int = 3
    ) throws -> ClozeDefinition {
        let ranges = ClozeValidator.surfaceRanges(of: "言った", in: sentence)
        let content = try ValidatedClozeContent(
            sentenceSnapshot: sentence,
            utf16Start: ranges[occurrence].utf16Start,
            utf16Length: ranges[occurrence].utf16Length,
            targetSurface: "言った",
            targetLemma: "言う",
            targetReading: "いった",
            acceptedAnswers: ["言った", "いった"],
            hint: "動詞"
        )
        return content.makeDefinition(
            id: UUID(),
            noteID: UUID(),
            cardID: UUID(),
            sourceContextID: nil,
            contentVersion: contentVersion
        )
    }

    // MARK: - surfaceRanges（编辑器候选枚举）

    func testSurfaceRangesEnumeratesAllOccurrencesInOrder() throws {
        let sentence = "彼が言ったことは彼が言った通りだ"
        let ranges = ClozeValidator.surfaceRanges(of: "言った", in: sentence)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.map(\.utf16Start), [2, 10])
        XCTAssertEqual(ranges.map(\.utf16Length), [3, 3])
        // 每处候选自身就是合法 blank range。
        for range in ranges {
            XCTAssertNoThrow(
                try ClozeValidator.validate(
                    sentence: sentence,
                    range: range,
                    targetSurface: "言った",
                    acceptedAnswers: ["言った"]
                )
            )
        }
    }

    func testSurfaceRangesIsGraphemeAligned() {
        // bare「か」不命中组合序列「が」内部；canonical「が」命中整簇。
        let decomposed = "彼は「か\u{3099}」と言った。"
        XCTAssertTrue(
            ClozeValidator.surfaceRanges(of: "か", in: decomposed).isEmpty
        )
        let hits = ClozeValidator.surfaceRanges(of: "が", in: decomposed)
        XCTAssertEqual(hits.map(\.utf16Start), [3])
        XCTAssertEqual(hits.map(\.utf16Length), [2])
        // emoji 本体也是合法 target。
        let emoji = "答えは🎯だ。"
        let emojiHits = ClozeValidator.surfaceRanges(of: "🎯", in: emoji)
        XCTAssertEqual(emojiHits.map(\.utf16Start), [3])
        XCTAssertEqual(emojiHits.map(\.utf16Length), [2])
    }

    func testSurfaceRangesEdgeInputs() {
        XCTAssertTrue(ClozeValidator.surfaceRanges(of: "", in: sentence).isEmpty)
        XCTAssertTrue(ClozeValidator.surfaceRanges(of: "見た", in: "").isEmpty)
        XCTAssertTrue(
            ClozeValidator.surfaceRanges(of: "行く", in: sentence).isEmpty
        )
    }

    // MARK: - SentenceFormData 选择语义

    func testFormDataPrefillSelectsCurrentRange() throws {
        let definition = try makeDefinition(occurrence: 1)
        var form = SentenceFormData(
            definition: definition,
            meaningZH: "如他所说",
            notes: "note"
        )
        XCTAssertEqual(form.sentence, definition.sentenceSnapshot)
        XCTAssertEqual(form.targetSurface, "言った")
        XCTAssertEqual(form.utf16Start, 10)
        XCTAssertEqual(form.utf16Length, 3)
        XCTAssertEqual(form.selectedOccurrenceOrdinal, 1)
        XCTAssertEqual(form.meaningZH, "如他所说")
        XCTAssertEqual(form.notes, "note")
        // 重选到第一处。
        XCTAssertTrue(form.selectOccurrence(0))
        XCTAssertEqual(form.utf16Start, 2)
        XCTAssertEqual(form.selectedOccurrenceOrdinal, 0)
    }

    func testFormDataRejectsOutOfBoundsOccurrenceAndUnselectedSave() throws {
        var form = SentenceFormData(
            sentence: sentence,
            targetSurface: "見た",
            acceptedAnswers: ["見た"]
        )
        // 未选范围直接保存 → invalidRange。
        XCTAssertNil(form.selectedOccurrenceOrdinal)
        XCTAssertThrowsError(try form.validatedContent()) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
        // 越界序号不改动现状。
        XCTAssertFalse(form.selectOccurrence(5))
        XCTAssertNil(form.selectedOccurrenceOrdinal)
        // 合法序号 → 保存成功。
        XCTAssertTrue(form.selectOccurrence(0))
        let content = try form.validatedContent()
        XCTAssertEqual(content.targetSurface, "見た")
        XCTAssertEqual(content.range.utf16Start, 7)
    }

    /// §9.2：编辑句子后必须重选范围——UI 清坐标，域内未选即拒。
    func testFormDataSentenceEditRequiresReselection() throws {
        var form = SentenceFormData(
            definition: try makeDefinition(),
            meaningZH: nil,
            notes: nil
        )
        XCTAssertNotNil(form.selectedOccurrenceOrdinal)
        // 句子变了：旧坐标失效，必须重选。
        form.sentence = "彼は静かに言った。"
        form.invalidateRangeSelection()
        XCTAssertThrowsError(try form.validatedContent()) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
        // 新句候选只有一处；重选后通过。
        XCTAssertEqual(form.candidateRanges.count, 1)
        XCTAssertTrue(form.selectOccurrence(0))
        XCTAssertEqual(form.selectedOccurrenceOrdinal, 0)
        XCTAssertNoThrow(try form.validatedContent())
    }

    func testFormDataMakeUpdateTrimsMeaningAndNotes() throws {
        var form = SentenceFormData(
            sentence: sentence,
            targetSurface: "見た",
            acceptedAnswers: ["見た"],
            meaningZH: "  ",
            notes: "  备注  "
        )
        XCTAssertTrue(form.selectOccurrence(0))
        let update = try form.makeUpdate(expectedContentVersion: 7)
        XCTAssertEqual(update.expectedContentVersion, 7)
        XCTAssertNil(update.meaningZH)      // 空白 → NULL（CHECK 允许）
        XCTAssertEqual(update.notes, "备注")
        XCTAssertEqual(update.cloze.sentenceSnapshot, sentence)
    }

    /// 空白句在持久化前拒掉——与 `trim(headword)>0` CHECK 同判据（S13
    /// 收紧：不再把约束违例留给 commit 事务兜底）。
    func testWhitespaceOnlySentenceRejectedEarly() {
        var form = SentenceFormData(
            sentence: "   ",
            utf16Start: 0,
            utf16Length: 1,
            targetSurface: " ",
            acceptedAnswers: [" "]
        )
        XCTAssertThrowsError(try form.validatedContent()) {
            XCTAssertEqual($0 as? ClozeError, .emptySentence)
        }
        form.sentence = "私は昨日映画を見た。"
        form.utf16Start = 7
        form.utf16Length = 2
        form.targetSurface = "見た"
        form.acceptedAnswers = ["見た"]
        XCTAssertNoThrow(try form.validatedContent())
    }

    // MARK: - SentenceService

    func testServiceUpdatePassesLoadedVersionAndReturnsNilForMissing() async throws {
        let repository = StubClozeEditingRepository()
        let service = SentenceService(repository: repository)

        // 不存在的 note → nil，不调用仓储更新。
        let missing = try await service.updateSentence(
            noteID: UUID(),
            formData: SentenceFormData()
        )
        XCTAssertNil(missing)
        XCTAssertNil(repository.lastUpdate)

        // 存在的 note → expectedContentVersion 取持久化行版本。
        let noteID = UUID()
        let definition = try makeDefinition(contentVersion: 4)
        repository.stored = SentenceNote(
            id: noteID,
            deckID: UUID(),
            deckIDs: [UUID()],
            definition: ClozeDefinition(
                id: definition.id,
                noteID: noteID,
                cardID: definition.cardID,
                sourceContextID: nil,
                sentenceSnapshot: definition.sentenceSnapshot,
                sentenceSHA256: definition.sentenceSHA256,
                range: definition.range,
                targetSurface: definition.targetSurface,
                targetLemma: definition.targetLemma,
                targetReading: definition.targetReading,
                acceptedAnswers: definition.acceptedAnswers,
                hint: definition.hint,
                contentVersion: definition.contentVersion
            ),
            meaningZH: nil,
            notes: nil,
            noteContentVersion: 9,
            createdAt: Date(),
            updatedAt: Date()
        )
        var form = SentenceFormData(
            definition: repository.stored!.definition,
            meaningZH: nil,
            notes: nil
        )
        XCTAssertTrue(form.selectOccurrence(0))
        _ = try await service.updateSentence(noteID: noteID, formData: form)
        XCTAssertEqual(repository.lastUpdate?.expectedContentVersion, 4)
    }
}

/// SentenceService 的内存桩——记录最后一次更新载荷，fetch 返回预设聚合。
private final class StubClozeEditingRepository: ClozeEditingRepository, @unchecked Sendable {
    var stored: SentenceNote?
    var lastUpdate: SentenceContentUpdate?

    func fetchDefinition(noteID: UUID) async throws -> ClozeDefinition? {
        stored?.definition.noteID == noteID ? stored?.definition : nil
    }

    func fetchDefinition(cardID: UUID) async throws -> ClozeDefinition? {
        stored?.definition.cardID == cardID ? stored?.definition : nil
    }

    func fetchSentence(noteID: UUID) async throws -> SentenceNote? {
        stored?.id == noteID ? stored : nil
    }

    func updateSentence(
        noteID: UUID,
        update: SentenceContentUpdate,
        at date: Date
    ) async throws -> SentenceNote? {
        lastUpdate = update
        return stored
    }
}
