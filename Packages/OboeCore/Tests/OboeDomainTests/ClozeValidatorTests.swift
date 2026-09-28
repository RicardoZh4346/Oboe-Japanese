import Foundation
import OboeDomain
import XCTest

/// v0.7.0 S12：Cloze 领域契约（设计 §9.1–9.3，D07）。
/// 覆盖 UTF-16 range 编码、Unicode 边界安全、快照 hash、
/// accepted-answers 归一化与「正面不泄题」渲染原语。
final class ClozeValidatorTests: XCTestCase {

    /// 定位子串在句中的 UTF-16 range（测试装配的输入坐标系与持久化一致）。
    private func utf16Range(
        of needle: String,
        in sentence: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (start: Int, length: Int) {
        guard let range = sentence.range(of: needle) else {
            XCTFail("子串不在句中", file: file, line: line)
            return (0, 0)
        }
        let ns = NSRange(range, in: sentence)
        return (ns.location, ns.length)
    }

    private let sentence = "私は昨日映画を見た。"
    // UTF-8 SHA-256 的外部参考值（`echo -n ... | shasum -a 256`）。
    private let sentenceHash = "2b2de942e32d25fdad26ce16a510651a223645ddd6d25bf08bf286ebfac90302"

    // MARK: - ClozeRange

    func testRangeKeepsCurrentVersionAndOffsets() throws {
        let range = try ClozeRange(utf16Start: 6, utf16Length: 2)
        XCTAssertEqual(range.version, ClozeRange.currentVersion)
        XCTAssertEqual(range.utf16Start, 6)
        XCTAssertEqual(range.utf16Length, 2)
        XCTAssertEqual(range.utf16End, 8)
    }

    func testRangeRejectsNegativeStartAndNonPositiveLength() {
        XCTAssertThrowsError(try ClozeRange(utf16Start: -1, utf16Length: 2)) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
        XCTAssertThrowsError(try ClozeRange(utf16Start: 0, utf16Length: 0)) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
        XCTAssertThrowsError(try ClozeRange(utf16Start: 0, utf16Length: -3)) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
    }

    /// 持久化回放：只有当前编码版本可解码；未来版本必须拒绝而不是
    /// 按 v1 语义误读（§9.1 range_version 的设计意图）。
    func testPersistedRangeRejectsUnknownVersion() throws {
        let replayed = try ClozeRange(
            persistedVersion: ClozeRange.currentVersion,
            utf16Start: 2,
            utf16Length: 1
        )
        XCTAssertEqual(replayed.version, ClozeRange.currentVersion)
        XCTAssertThrowsError(
            try ClozeRange(persistedVersion: 0, utf16Start: 0, utf16Length: 1)
        ) {
            XCTAssertEqual($0 as? ClozeError, .unsupportedRangeVersion)
        }
        XCTAssertThrowsError(
            try ClozeRange(persistedVersion: 2, utf16Start: 0, utf16Length: 1)
        ) {
            XCTAssertEqual($0 as? ClozeError, .unsupportedRangeVersion)
        }
        // 版本合法但 offset 非法仍走 invalidRange。
        XCTAssertThrowsError(
            try ClozeRange(
                persistedVersion: ClozeRange.currentVersion,
                utf16Start: -1,
                utf16Length: 0
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
    }

    // MARK: - validate：基本拒绝

    func testValidateRejectsEmptySentenceAndEmptyAnswers() throws {
        let range = try ClozeRange(utf16Start: 0, utf16Length: 1)
        XCTAssertThrowsError(
            try ClozeValidator.validate(
                sentence: "", range: range,
                targetSurface: "x", acceptedAnswers: ["x"]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .emptySentence)
        }
        XCTAssertThrowsError(
            try ClozeValidator.validate(
                sentence: sentence, range: range,
                targetSurface: "私", acceptedAnswers: []
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .emptyAcceptedAnswers)
        }
    }

    func testValidateAcceptsExactRangeSurfaceMatch() throws {
        let (start, length) = utf16Range(of: "見た", in: sentence)
        try ClozeValidator.validate(
            sentence: sentence,
            range: ClozeRange(utf16Start: start, utf16Length: length),
            targetSurface: "見た",
            acceptedAnswers: ["見た", "みた"]
        )
    }

    func testValidateRejectsOutOfBoundsRange() {
        // utf16End 越过句尾 → Range(NSRange, in:) 为 nil。
        XCTAssertThrowsError(
            try ClozeValidator.validate(
                sentence: sentence,
                range: ClozeRange(
                    utf16Start: sentence.utf16.count - 1,
                    utf16Length: 5
                ),
                targetSurface: "x",
                acceptedAnswers: ["x"]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
        // 起点已在句外。
        XCTAssertThrowsError(
            try ClozeValidator.validate(
                sentence: sentence,
                range: ClozeRange(
                    utf16Start: sentence.utf16.count + 4,
                    utf16Length: 1
                ),
                targetSurface: "x",
                acceptedAnswers: ["x"]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
    }

    /// UTF-16 边界落在代理对（emoji）中间：Range(NSRange,in:) 会把
    /// {1,1} 静默扩展成整个 emoji——span 与坐标不符 → invalidRange。
    func testValidateRejectsRangeSplittingSurrogatePair() {
        let sentenceWithEmoji = "🎌を掲げた"
        // 🎌 占两个 UTF-16 unit；start=1 落在 low-surrogate 上。
        XCTAssertThrowsError(
            try ClozeValidator.validate(
                sentence: sentenceWithEmoji,
                range: ClozeRange(utf16Start: 1, utf16Length: 1),
                targetSurface: "を",
                acceptedAnswers: ["を"]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
    }

    /// UTF-16 边界切开组合字符（か + 组合浊点 U+3099）→ 拒绝。
    /// Range(NSRange,in:) 对 {0,1} 会截断出「か」——截取值恰等于
    /// 声明 surface，仅靠 surface 比对挡不住这类劈字。
    func testValidateRejectsRangeSplittingComposedCharacter() {
        let decomposed = "か\u{3099}くせい"   // が = か + ◌゙
        // 只覆盖「か」、丢掉组合符 → 边界在 grapheme 内部。
        XCTAssertThrowsError(
            try ClozeValidator.validate(
                sentence: decomposed,
                range: ClozeRange(utf16Start: 0, utf16Length: 1),
                targetSurface: "か",
                acceptedAnswers: ["か"]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
        // 只截取组合符本身同样非法。
        XCTAssertThrowsError(
            try ClozeValidator.validate(
                sentence: decomposed,
                range: ClozeRange(utf16Start: 1, utf16Length: 1),
                targetSurface: "\u{3099}",
                acceptedAnswers: ["\u{3099}"]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
        // 覆盖完整的 か+◌゙（两个 UTF-16 unit）是合法的。
        XCTAssertNoThrow(
            try ClozeValidator.validate(
                sentence: decomposed,
                range: ClozeRange(utf16Start: 0, utf16Length: 2),
                targetSurface: "か\u{3099}",
                acceptedAnswers: ["か\u{3099}"]
            )
        )
    }

    /// ZWJ 序列（家庭 emoji）是单一 grapheme、多个 UTF-16 unit——
    /// 切中间必然 invalidRange（即便截取结果是可打印的半个 emoji）。
    func testValidateRejectsRangeInsideZWJSequence() {
        let emojiSentence = "絵文字👨‍👩‍👧が好き"
        let emoji = "👨‍👩‍👧"
        let emojiStart = emojiSentence.utf16.count - "が好き".utf16.count - emoji.utf16.count
        XCTAssertThrowsError(
            try ClozeValidator.validate(
                sentence: emojiSentence,
                range: ClozeRange(utf16Start: emojiStart + 1, utf16Length: 2),
                targetSurface: "xx",
                acceptedAnswers: ["xx"]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .invalidRange)
        }
    }

    /// range 合法但截取文本 ≠ targetSurface → rangeSurfaceMismatch
    /// （错位卡会比失败更糟——§9.3 不让它落库）。
    func testValidateRejectsSurfaceMismatch() throws {
        let (start, length) = utf16Range(of: "映画", in: sentence)
        XCTAssertThrowsError(
            try ClozeValidator.validate(
                sentence: sentence,
                range: ClozeRange(utf16Start: start, utf16Length: length),
                targetSurface: "見た",
                acceptedAnswers: ["見た"]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .rangeSurfaceMismatch)
        }
    }

    // MARK: - maskedSentence（正面渲染原语）

    func testMaskedSentenceReplacesOnlySelectedRange() throws {
        let repeated = "見た。そしてまた見た。"
        let (start, length) = utf16Range(of: "見た", in: repeated)
        let masked = ClozeValidator.maskedSentence(
            repeated,
            range: try ClozeRange(utf16Start: start, utf16Length: length),
            blank: "＿＿"
        )
        XCTAssertEqual(masked, "＿＿。そしてまた見た。")
        // 关键：第二次出现的同形词不被替换——不做全局替换（§9.2）。
        XCTAssertTrue(masked.contains("見た"))
    }

    /// 损坏行的渲染安全：range 无法解析时**绝不返回原句**（原句含
    /// 答案，正面展示即泄题）——退化为 blank 占位符。
    func testMaskedSentenceNeverLeaksAnswerOnUnresolvableRange() throws {
        let masked = ClozeValidator.maskedSentence(
            sentence,
            range: try ClozeRange(utf16Start: 500, utf16Length: 2),
            blank: "＿"
        )
        XCTAssertEqual(masked, "＿")
        XCTAssertFalse(masked.contains("見た"))
    }

    // MARK: - snapshotSHA256 / validatePersisted

    func testSnapshotHashIsLowercaseUTF8SHA256() {
        let hash = ClozeValidator.snapshotSHA256(sentence)
        XCTAssertEqual(hash, sentenceHash)
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, hash.lowercased())
        // 「見た」独立向量。
        XCTAssertEqual(
            ClozeValidator.snapshotSHA256("見た"),
            "48bd8234d8083c7bfae7e243bc8af6994b5ea8d5d09900e74ccd4ee43a3533f1"
        )
    }

    func testValidatePersistedRejectsTamperedHash() throws {
        let (start, length) = utf16Range(of: "見た", in: sentence)
        let range = try ClozeRange(utf16Start: start, utf16Length: length)
        let badHash = String(repeating: "0", count: 64)
        XCTAssertThrowsError(
            try ClozeValidator.validatePersisted(
                sentence: sentence,
                sentenceSHA256: badHash,
                range: range,
                targetSurface: "見た",
                acceptedAnswers: ["見た"]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .snapshotHashMismatch)
        }
    }

    /// 判分集不含 surface 本体即拒绝——只含读音/活用的集合不成立（§9.3）。
    func testValidatePersistedRequiresSurfaceInAcceptedAnswers() throws {
        let (start, length) = utf16Range(of: "見た", in: sentence)
        let range = try ClozeRange(utf16Start: start, utf16Length: length)
        XCTAssertThrowsError(
            try ClozeValidator.validatePersisted(
                sentence: sentence,
                sentenceSHA256: sentenceHash,
                range: range,
                targetSurface: "見た",
                acceptedAnswers: ["みた"]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .acceptedAnswersMissingSurface)
        }
        // 含 surface 即放行。
        XCTAssertNoThrow(
            try ClozeValidator.validatePersisted(
                sentence: sentence,
                sentenceSHA256: sentenceHash,
                range: range,
                targetSurface: "見た",
                acceptedAnswers: ["見た", "みた"]
            )
        )
    }

    // MARK: - ValidatedClozeContent

    func testValidatedContentComputesHashAndNormalizesAnswers() throws {
        let (start, length) = utf16Range(of: "見た", in: sentence)
        let content = try ValidatedClozeContent(
            sentenceSnapshot: sentence,
            utf16Start: start,
            utf16Length: length,
            targetSurface: "見た",
            targetLemma: "見る",
            targetReading: " みた ",
            acceptedAnswers: [" 見た ", "", "みた", "見た", "  "],
            hint: " 过去式 "
        )
        XCTAssertEqual(content.sentenceSnapshot, sentence)
        XCTAssertEqual(content.sentenceSHA256, sentenceHash)
        XCTAssertEqual(content.targetSurface, "見た")
        XCTAssertEqual(content.targetLemma, "見る")
        // 归一化：trim/去空/保序去重。
        XCTAssertEqual(content.acceptedAnswers, ["見た", "みた"])
        XCTAssertEqual(content.targetReading, "みた")
        XCTAssertEqual(content.hint, "过去式")
        XCTAssertEqual(content.range.version, ClozeRange.currentVersion)
    }

    /// 归一化后 surface 不在集合内仍拒绝（如 [" みた "] 无本体）。
    func testValidatedContentRejectsAnswersMissingSurface() throws {
        let (start, length) = utf16Range(of: "見た", in: sentence)
        XCTAssertThrowsError(
            try ValidatedClozeContent(
                sentenceSnapshot: sentence,
                utf16Start: start,
                utf16Length: length,
                targetSurface: "見た",
                acceptedAnswers: [" みた "]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .acceptedAnswersMissingSurface)
        }
    }

    func testValidatedContentRejectsAllBlankAnswers() throws {
        let (start, length) = utf16Range(of: "見た", in: sentence)
        XCTAssertThrowsError(
            try ValidatedClozeContent(
                sentenceSnapshot: sentence,
                utf16Start: start,
                utf16Length: length,
                targetSurface: "見た",
                acceptedAnswers: ["", "   "]
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .emptyAcceptedAnswers)
        }
    }

    /// 恢复路径：hash 由调用方声明——不符即拒绝（§14.2 预检同一判据）。
    func testRestoringContentValidatesDeclaredHash() throws {
        let (start, length) = utf16Range(of: "見た", in: sentence)
        let range = try ClozeRange(utf16Start: start, utf16Length: length)
        XCTAssertThrowsError(
            try ValidatedClozeContent(
                restoringSentenceSnapshot: sentence,
                sentenceSHA256: String(repeating: "f", count: 64),
                range: range,
                targetSurface: "見た",
                targetLemma: nil,
                targetReading: nil,
                acceptedAnswers: ["見た"],
                hint: nil
            )
        ) {
            XCTAssertEqual($0 as? ClozeError, .snapshotHashMismatch)
        }
        let restored = try ValidatedClozeContent(
            restoringSentenceSnapshot: sentence,
            sentenceSHA256: sentenceHash,
            range: range,
            targetSurface: "見た",
            targetLemma: nil,
            targetReading: nil,
            acceptedAnswers: ["見た"],
            hint: nil
        )
        XCTAssertEqual(restored.sentenceSHA256, sentenceHash)
    }

    func testMakeDefinitionMapsAllFields() throws {
        let (start, length) = utf16Range(of: "見た", in: sentence)
        let content = try ValidatedClozeContent(
            sentenceSnapshot: sentence,
            utf16Start: start,
            utf16Length: length,
            targetSurface: "見た",
            acceptedAnswers: ["見た"]
        )
        let (id, noteID, cardID, sourceID) = (UUID(), UUID(), UUID(), UUID())
        let definition = content.makeDefinition(
            id: id, noteID: noteID, cardID: cardID,
            sourceContextID: sourceID, contentVersion: 3
        )
        XCTAssertEqual(definition.id, id)
        XCTAssertEqual(definition.noteID, noteID)
        XCTAssertEqual(definition.cardID, cardID)
        XCTAssertEqual(definition.sourceContextID, sourceID)
        XCTAssertEqual(definition.sentenceSnapshot, sentence)
        XCTAssertEqual(definition.sentenceSHA256, sentenceHash)
        XCTAssertEqual(definition.acceptedAnswers, ["見た"])
        XCTAssertEqual(definition.contentVersion, 3)
    }

    // MARK: - SentenceContentCommit 不变量

    func testSentenceCommitAlwaysIncludesHomeDeck() throws {
        let (start, length) = utf16Range(of: "見た", in: sentence)
        let home = UUID()
        let other = UUID()
        let commit = SentenceContentCommit(
            noteID: UUID(),
            clozeID: UUID(),
            deckID: home,
            cloze: try ValidatedClozeContent(
                sentenceSnapshot: sentence,
                utf16Start: start,
                utf16Length: length,
                targetSurface: "見た",
                acceptedAnswers: ["見た"]
            ),
            card: NewCardSeed(id: UUID(), templateKind: .sentenceCloze),
            schedulerProfileID: UUID(),
            createdAt: Date(),
            deckIDs: [other]
        )
        XCTAssertEqual(commit.deckIDs, [home, other])
        XCTAssertEqual(commit.card.templateKind, .sentenceCloze)
    }

    // MARK: - 枚举/模板映射

    func testSentenceEnumRawValuesAndTemplateMapping() {
        XCTAssertEqual(KnowledgePointKind.sentence.rawValue, "sentence")
        XCTAssertEqual(CardTemplateKind.sentenceCloze.rawValue, "sentence_cloze")
        XCTAssertEqual(CardTemplateKind.sentenceCloze.knowledgePointKind, .sentence)
        XCTAssertEqual(CardTemplateKind.applicable(to: .sentence), [.sentenceCloze])
        XCTAssertEqual(ContentOrigin.reader.rawValue, "reader")
        XCTAssertEqual(ContentOrigin.import.rawValue, "import")
    }

    /// sentence_cloze 恒为输入型作答——不接受词汇 typed 开关控制（§9.3）。
    func testSentenceClozeAlwaysUsesTypedRecall() {
        for typed in [true, false] {
            let preferences = AdaptivePreferences(
                typedAnswerChineseToJapanese: typed,
                autoPlayListeningAudio: true,
                typedAnswerListening: typed,
                leechRemindersEnabled: true
            )
            XCTAssertEqual(
                RecallMode.resolve(
                    template: .sentenceCloze,
                    preferences: preferences
                ),
                .typedJapanese
            )
        }
    }

    // MARK: - AnswerComparator 的 acceptedAnswers 入口

    func testClozeAcceptedAnswersComparison() {
        let answers = ["見た", "みた"]
        XCTAssertEqual(
            AnswerComparator.compare(input: "見た", acceptedAnswers: answers),
            .matched
        )
        // 活用读音判对（§9.3 默认接受「みた」类实际读音）。
        XCTAssertEqual(
            AnswerComparator.compare(input: "みた", acceptedAnswers: answers),
            .matched
        )
        // 片假名经归一化等价。
        XCTAssertEqual(
            AnswerComparator.compare(input: "ミタ", acceptedAnswers: answers),
            .matched
        )
        // lemma 不在集合内不算对（不自动接受「見る」）。
        XCTAssertEqual(
            AnswerComparator.compare(input: "見る", acceptedAnswers: answers),
            .different
        )
        // 空集/空输入不判分。
        XCTAssertNil(AnswerComparator.compare(input: "", acceptedAnswers: answers))
        XCTAssertNil(AnswerComparator.compare(input: "見た", acceptedAnswers: []))
        XCTAssertNil(AnswerComparator.compare(input: "見た", acceptedAnswers: ["", "  "]))
    }

    /// close 规则沿用：长假名候选 1 个编辑距离内。
    func testClozeComparisonCloseRule() {
        let answers = ["おかあさん"]
        XCTAssertEqual(
            AnswerComparator.compare(input: "おばあさん", acceptedAnswers: answers),
            .close
        )
        XCTAssertEqual(
            AnswerComparator.compare(input: "おと", acceptedAnswers: answers),
            .different
        )
    }
}
