import OboeDomain
import XCTest
@testable import Oboe

/// S07 查词→制卡预填测试：词条→表单折叠、zh→en 回退、JMdict POS
/// →白名单映射、来源草稿的 lookup 合并与捕获来源事实装配。
final class DictionaryCardPrefillTests: XCTestCase {

    private func makeEntry(
        id: Int64 = 1000,
        primaryForm: String = "食べる",
        reading: String? = "たべる",
        zhGlosses: [String] = [],
        enGlosses: [String] = [],
        posCodes: [String] = ["v1"]
    ) -> DictionaryEntry {
        var glosses: [DictionaryGloss] = []
        for (index, text) in zhGlosses.enumerated() {
            glosses.append(
                DictionaryGloss(
                    language: "zho", text: text, order: index,
                    sourceID: "tomoshi", isMachineGenerated: false,
                    sourceFingerprint: "fp\(index)"
                )
            )
        }
        for (index, text) in enGlosses.enumerated() {
            glosses.append(
                DictionaryGloss(
                    language: "eng", text: text, order: index,
                    sourceID: "jmdict", isMachineGenerated: false
                )
            )
        }
        return DictionaryEntry(
            id: id,
            primaryForm: primaryForm,
            commonRank: nil,
            forms: [
                DictionaryForm(id: 1, text: primaryForm, formType: "keb", priority: nil)
            ],
            readings: reading.map {
                [
                    DictionaryReading(
                        id: 1, reading: $0, noKanji: false,
                        restrictedFormIDs: [], restrictedForms: []
                    )
                ]
            } ?? [],
            senses: [
                DictionarySense(
                    id: 1, order: 0, posCodes: posCodes, tags: [], glosses: glosses
                )
            ]
        )
    }

    // MARK: - 表单预填

    func testVocabularyFormUsesPrimaryFormFirstReadingAndChineseGloss() {
        let entry = makeEntry(
            zhGlosses: ["吃", "饮用"],
            enGlosses: ["to eat"]
        )
        let form = DictionaryCardPrefill.vocabularyForm(from: entry)
        XCTAssertEqual(form.headword, "食べる")
        XCTAssertEqual(form.reading, "たべる")
        XCTAssertEqual(form.meaningZH, "吃；饮用")
        XCTAssertEqual(form.partOfSpeech, "一段动词")
        // 来源字段一律不编造
        XCTAssertEqual(form.exampleJapanese, "")
        XCTAssertEqual(form.exampleTranslationZH, "")
    }

    func testVocabularyFormFallsBackToEnglishGloss() {
        let entry = makeEntry(enGlosses: ["to eat", "to consume"])
        let form = DictionaryCardPrefill.vocabularyForm(from: entry)
        XCTAssertEqual(form.meaningZH, "to eat；to consume")
    }

    func testVocabularyFormWithoutReadingsOrGlosses() {
        let entry = makeEntry(reading: nil)
        let form = DictionaryCardPrefill.vocabularyForm(from: entry)
        XCTAssertEqual(form.reading, "")
        XCTAssertEqual(form.meaningZH, "")
    }

    // MARK: - POS 映射

    func testPartOfSpeechMappingGodanIchidanKuruSuru() {
        XCTAssertEqual(
            DictionaryCardPrefill.vocabularyForm(
                from: makeEntry(posCodes: ["v5u"])
            ).partOfSpeech,
            "五段动词"
        )
        XCTAssertEqual(
            DictionaryCardPrefill.vocabularyForm(
                from: makeEntry(posCodes: ["vk"])
            ).partOfSpeech,
            "くる动词"
        )
        XCTAssertEqual(
            DictionaryCardPrefill.vocabularyForm(
                from: makeEntry(posCodes: ["vs"])
            ).partOfSpeech,
            "する动词"
        )
    }

    func testPartOfSpeechMappingNounAdjectiveUnmapped() {
        XCTAssertEqual(
            DictionaryCardPrefill.vocabularyForm(
                from: makeEntry(posCodes: ["n"])
            ).partOfSpeech,
            "名词"
        )
        XCTAssertEqual(
            DictionaryCardPrefill.vocabularyForm(
                from: makeEntry(posCodes: ["adj-i"])
            ).partOfSpeech,
            "い形容词"
        )
        XCTAssertEqual(
            DictionaryCardPrefill.vocabularyForm(
                from: makeEntry(posCodes: ["adj-na"])
            ).partOfSpeech,
            "な形容词"
        )
        // 不可映射 code → 空串，用户可再选
        XCTAssertEqual(
            DictionaryCardPrefill.vocabularyForm(
                from: makeEntry(posCodes: ["unc"])
            ).partOfSpeech,
            ""
        )
    }

    // MARK: - 来源草稿

    func testSourceContextDraftStampsDictionarySnapshot() {
        let entry = makeEntry(id: 42, zhGlosses: ["吃"])
        let draft = DictionaryCardPrefill.sourceContextDraft(
            from: entry,
            datasetVersion: "2025-01-01"
        )
        XCTAssertEqual(draft.sourceType, .dictionary)
        XCTAssertEqual(draft.dictionaryEntryID, 42)
        XCTAssertEqual(draft.dictionaryVersion, "2025-01-01")
        XCTAssertEqual(draft.selectedGlossLanguage, "zho")
        XCTAssertTrue(draft.isPrimary)
    }

    func testSourceContextDraftRecordsEnglishFallbackLanguage() {
        let entry = makeEntry(enGlosses: ["to eat"])
        let draft = DictionaryCardPrefill.sourceContextDraft(
            from: entry,
            datasetVersion: nil
        )
        XCTAssertEqual(draft.selectedGlossLanguage, "eng")
    }

    func testSourceContextDraftMergesLookupFacts() {
        let lookup = SourceContextDraft(
            sourceType: .ocr,
            originalSentence: "彼は寿司を食べた。",
            sourceURL: "https://example.com",
            imageReference: "img-1"
        )
        let entry = makeEntry(id: 7, zhGlosses: ["吃"])
        let draft = DictionaryCardPrefill.sourceContextDraft(
            from: entry,
            datasetVersion: "v",
            lookup: lookup
        )
        XCTAssertEqual(draft.sourceType, .ocr)
        XCTAssertEqual(draft.originalSentence, "彼は寿司を食べた。")
        XCTAssertEqual(draft.imageReference, "img-1")
        XCTAssertEqual(draft.sourceURL, "https://example.com")
        XCTAssertEqual(draft.dictionaryEntryID, 7)
        XCTAssertEqual(draft.dictionaryVersion, "v")
        XCTAssertEqual(draft.selectedGlossLanguage, "zho")
    }

    // MARK: - 捕获来源事实装配

    private func makeInboxItem(
        sourceType: InboxSourceType,
        text: String = "原文"
    ) -> InboxItem {
        InboxItem(
            id: UUID(),
            text: text,
            sourceType: sourceType,
            status: .unprocessed,
            contentRevision: 0,
            sourceApp: "Safari",
            sourceURL: "https://example.com/a",
            imageReference: "img-x",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            processedAt: nil,
            archivedAt: nil,
            statusBeforeArchive: nil
        )
    }

    func testCaptureSourceDraftMapsItemSourceTypes() {
        let ocrDraft = AddContentViewModel.captureSourceDraft(
            item: makeInboxItem(sourceType: .ocr),
            fragment: "原句"
        )
        XCTAssertEqual(ocrDraft?.sourceType, .ocr)
        XCTAssertEqual(ocrDraft?.originalSentence, "原句")
        XCTAssertEqual(ocrDraft?.imageReference, "img-x")
        XCTAssertEqual(ocrDraft?.sourceURL, "https://example.com/a")
        XCTAssertEqual(ocrDraft?.sourceApp, "Safari")

        let shareDraft = AddContentViewModel.captureSourceDraft(
            item: makeInboxItem(sourceType: .share),
            fragment: nil
        )
        XCTAssertEqual(shareDraft?.sourceType, .share)

        // paste 按设计 §6.1 归为 manual
        let pasteDraft = AddContentViewModel.captureSourceDraft(
            item: makeInboxItem(sourceType: .paste),
            fragment: nil
        )
        XCTAssertEqual(pasteDraft?.sourceType, .manual)
    }

    func testCaptureSourceDraftNilItem() {
        XCTAssertNil(
            AddContentViewModel.captureSourceDraft(item: nil, fragment: "x")
        )
    }
}
