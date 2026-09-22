import Foundation
import XCTest
@testable import OboeDomain

final class SentenceAnalysisTests: XCTestCase {
    func testFixedSentenceExplainsParticleLemmaAndGrammarWithLocalRanges() throws {
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        ]
        var index = 0
        let input = SentenceAnalysisInput(sentence: Self.sentence)
        let result = try SentenceAnalysisDecoder.decode(
            Self.fixedJSON,
            sourceInput: input,
            makeID: {
                defer { index += 1 }
                return ids[index]
            }
        )

        XCTAssertEqual(result.promptVersion, "oboe-sentence-analysis-v2")
        XCTAssertEqual(result.translationZH, "你去过日本吗？")
        XCTAssertEqual(result.items.map(\.kind), [.particle, .vocabulary, .grammar])
        XCTAssertEqual(result.items[0].surface, "に")
        XCTAssertEqual(result.items[0].alignedRanges, [.init(lowerBound: 2, upperBound: 3)])
        XCTAssertEqual(result.items[1].canonicalForm, "行く")
        XCTAssertEqual(result.items[1].suggestedCard?.headword, "行く")
        XCTAssertEqual(result.items[1].suggestedCard?.partOfSpeech, "五段动词 / 自动词")
        XCTAssertEqual(result.items[1].suggestedCard?.pitchAccent, PitchAccent(rawValue: 0))
        XCTAssertEqual(
            result.items[2].alignedRanges,
            [.init(lowerBound: 3, upperBound: 6), .init(lowerBound: 6, upperBound: 13)]
        )
    }

    func testRepeatedCrossFragmentAndUnalignedItemsRemainReadableWithoutFalseRanges() throws {
        let sentence = "雨が降ると、雨が好きになる。"
        let json = #"{"schemaVersion":2,"sentence":"雨が降ると、雨が好きになる。","translationZH":"下雨时会变得喜欢雨。","explanationZH":"用于验证重复片段。","items":[{"kind":"vocabulary","surface":"雨","canonicalForm":"雨","reading":"あめ","meaningZH":"雨","roleZH":"第一次出现","spans":[{"text":"雨","occurrence":1}],"cardDraft":null},{"kind":"vocabulary","surface":"雨","canonicalForm":"雨","reading":"あめ","meaningZH":"雨","roleZH":"第二次出现","spans":[{"text":"雨","occurrence":2}],"cardDraft":null},{"kind":"grammar","surface":"～と～なる","canonicalForm":"～と～なる","reading":"","meaningZH":"一……就变得……","roleZH":"跨片段结构","spans":[{"text":"と","occurrence":1},{"text":"になる","occurrence":1}],"cardDraft":null},{"kind":"expression","surface":"未对齐表达","canonicalForm":"未对齐表达","reading":"","meaningZH":"仍可阅读","roleZH":"模型片段不存在","spans":[{"text":"雪","occurrence":1}],"cardDraft":null}],"warnings":[]}"#
        let result = try SentenceAnalysisDecoder.decode(
            json,
            sourceInput: .init(sentence: sentence)
        )

        XCTAssertEqual(result.items[0].alignedRanges, [.init(lowerBound: 0, upperBound: 1)])
        XCTAssertEqual(result.items[1].alignedRanges, [.init(lowerBound: 6, upperBound: 7)])
        XCTAssertEqual(result.items[2].alignedRanges.count, 2)
        XCTAssertFalse(result.items[3].isFullyAligned)
        XCTAssertNil(result.items[3].spans[0].range)
        XCTAssertEqual(result.items[3].meaningZH, "仍可阅读")
    }

    func testStrictStructureLimitsAndSentenceIdentityAreRejected() throws {
        let input = SentenceAnalysisInput(sentence: Self.sentence)
        let failures: [(String, SentenceAnalysisError)] = [
            (Self.fixedJSON.replacingOccurrences(of: #""warnings":[]}"#, with: #""warnings":[],"extra":1}"#), .unexpectedFields),
            (Self.fixedJSON.replacingOccurrences(of: #""schemaVersion":2"#, with: #""schemaVersion":1"#), .unsupportedSchemaVersion),
            (Self.fixedJSON.replacingOccurrences(of: Self.sentence, with: "日本へ行きますか。"), .sentenceMismatch),
            (Self.fixedJSON.replacingOccurrences(of: #""kind":"particle""#, with: #""kind":"unknown""#), .invalidItemKind),
            (Self.fixedJSON.replacingOccurrences(of: #""occurrence":1"#, with: #""occurrence":0"#), .invalidOccurrence),
            (Self.fixedJSON.replacingOccurrences(of: #""roleZH":"目的地を示す助词""#, with: #""roleZH":"目的地を示す助词","extra":true"#), .unexpectedFields)
        ]
        for (json, expected) in failures {
            XCTAssertThrowsError(try SentenceAnalysisDecoder.decode(json, sourceInput: input)) {
                XCTAssertEqual($0 as? SentenceAnalysisError, expected)
            }
        }
        XCTAssertThrowsError(
            try SentenceAnalysisDecoder.validated(.init(sentence: String(repeating: "日", count: 1_001)))
        ) { XCTAssertEqual($0 as? SentenceAnalysisError, .sentenceTooLong) }
    }

    func testV2RejectsUnknownPartsInvalidPitchAndGrammarPitch() throws {
        let input = SentenceAnalysisInput(sentence: Self.sentence)
        let failures: [(String, SentenceAnalysisError)] = [
            (Self.fixedJSON.replacingOccurrences(of: #"["五段动词","自动词"]"#, with: #"["未知词性"]"#), .invalidPartOfSpeech("未知词性")),
            (Self.fixedJSON.replacingOccurrences(of: #""pitchAccent":0"#, with: #""pitchAccent":-1"#), .invalidPitchAccent),
            (Self.fixedJSON.replacingOccurrences(of: #""pitchAccent":0"#, with: #""pitchAccent":3"#), .invalidPitchAccent),
            (Self.fixedJSON.replacingOccurrences(of: #""partsOfSpeech":[],"pitchAccent":null,"usage":"接在地点后""#, with: #""partsOfSpeech":[],"pitchAccent":0,"usage":"接在地点后""#), .invalidPitchAccent)
        ]
        for (json, expected) in failures {
            XCTAssertThrowsError(try SentenceAnalysisDecoder.decode(json, sourceInput: input)) {
                XCTAssertEqual($0 as? SentenceAnalysisError, expected)
            }
        }
    }

    func testServiceUsesCurrentBindingAndPersistsOnlyExplicitDraft() async throws {
        let reference = AICredentialReference(
            id: UUID(),
            serviceKind: .custom,
            host: "fixture.example"
        )
        let configuration = AIConfiguration(
            isEnabled: true,
            serviceKind: .custom,
            serviceName: "Fixture",
            baseURL: URL(string: "https://fixture.example/v1")!,
            modelID: "fixture-model",
            responseFormatMode: .jsonSchema,
            credentialReference: reference
        )
        let draftRepository = MemorySentenceDraftRepository()
        let client = FixedSentenceAnalysisClient(response: Self.fixedJSON)
        let fixedID = UUID()
        let service = SentenceAnalysisService(
            configurationRepository: FixedSentenceConfigurationRepository(configuration: configuration),
            credentialStore: FixedSentenceCredentialStore(reference: reference, credential: "fixture-key"),
            client: client,
            draftRepository: draftRepository,
            now: { Date(timeIntervalSince1970: 123) },
            makeID: { fixedID }
        )
        let candidate = try await service.analyze(
            .init(inputVersion: 4, sentence: Self.sentence),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        let draftBeforeSave = try await service.fetchLatestDraft()
        XCTAssertNil(draftBeforeSave, "分析响应本身不得隐式写入草稿")
        let draft = try await service.saveDraft(
            id: nil,
            sentence: Self.sentence,
            result: candidate.result,
            providerID: candidate.providerID,
            modelID: candidate.modelID
        )

        XCTAssertEqual(draft.id, fixedID)
        XCTAssertEqual(draft.providerID, "custom")
        XCTAssertEqual(draft.modelID, "fixture-model")
        XCTAssertEqual(draft.result?.items.count, 3)
        let restoredDraft = try await service.fetchLatestDraft()
        XCTAssertEqual(restoredDraft, draft)
        let captured = await client.captured()
        XCTAssertEqual(captured?.0.sentence, Self.sentence)
        XCTAssertEqual(captured?.1, configuration)
        XCTAssertEqual(captured?.2, "fixture-key")
    }
}

private extension SentenceAnalysisTests {
    static let sentence = "日本に行ったことがありますか。"
    static let fixedJSON = #"{"schemaVersion":2,"sentence":"日本に行ったことがありますか。","translationZH":"你去过日本吗？","explanationZH":"询问对方是否有去日本的经历。","items":[{"kind":"particle","surface":"に","canonicalForm":"に","reading":"に","meaningZH":"向、到","roleZH":"目的地を示す助词","spans":[{"text":"に","occurrence":1}],"cardDraft":{"kind":"grammar","headword":"に","reading":"","meaningZH":"表示移动目的地","partsOfSpeech":[],"pitchAccent":null,"usage":"接在地点后","connection":"地点＋に","notes":""}},{"kind":"vocabulary","surface":"行った","canonicalForm":"行く","reading":"いく","meaningZH":"去","roleZH":"谓语「行く」的过去式","spans":[{"text":"行った","occurrence":1}],"cardDraft":{"kind":"vocabulary","headword":"行く","reading":"いく","meaningZH":"去","partsOfSpeech":["五段动词","自动词"],"pitchAccent":0,"usage":"","connection":"","notes":""}},{"kind":"grammar","surface":"～たことがある","canonicalForm":"～たことがある","reading":"","meaningZH":"曾经……过","roleZH":"表示过去经历","spans":[{"text":"行った","occurrence":1},{"text":"ことがあります","occurrence":1}],"cardDraft":{"kind":"grammar","headword":"～たことがある","reading":"","meaningZH":"曾经……过","partsOfSpeech":[],"pitchAccent":null,"usage":"表示过去经历","connection":"动词た形＋ことがある","notes":""}}],"warnings":[]}"#
}

private actor FixedSentenceAnalysisClient: SentenceAnalysisClient {
    let response: String
    private var lastCaptured: (SentenceAnalysisInput, AIConfiguration, String)?

    init(response: String) { self.response = response }

    func analyze(
        input: SentenceAnalysisInput,
        configuration: AIConfiguration,
        credential: String
    ) -> String {
        lastCaptured = (input, configuration, credential)
        return response
    }

    func captured() -> (SentenceAnalysisInput, AIConfiguration, String)? { lastCaptured }
}

private actor MemorySentenceDraftRepository: SentenceAnalysisDraftRepository {
    private var draft: SentenceAnalysisDraft?

    func saveSentenceAnalysisDraft(_ draft: SentenceAnalysisDraft) { self.draft = draft }
    func fetchLatestSentenceAnalysisDraft() -> SentenceAnalysisDraft? { draft }
    func fetchSentenceAnalysisDraft(id: UUID) -> SentenceAnalysisDraft? {
        draft?.id == id ? draft : nil
    }
    func deleteSentenceAnalysisDraft(id: UUID) {
        if draft?.id == id { draft = nil }
    }
}

private actor FixedSentenceConfigurationRepository: AIConfigurationRepository {
    let configuration: AIConfiguration
    init(configuration: AIConfiguration) { self.configuration = configuration }
    func loadOrCreateAIConfiguration(defaultTimeZoneID: String) -> AIConfiguration { configuration }
    func saveAIConfiguration(_ configuration: AIConfiguration) {}
}

private actor FixedSentenceCredentialStore: AICredentialStore {
    let reference: AICredentialReference
    let credential: String
    init(reference: AICredentialReference, credential: String) {
        self.reference = reference
        self.credential = credential
    }
    func readCredential(for reference: AICredentialReference) -> String? {
        reference == self.reference ? credential : nil
    }
    func saveCredential(_ credential: String, for reference: AICredentialReference) {}
    func deleteCredential(for reference: AICredentialReference) {}
}
