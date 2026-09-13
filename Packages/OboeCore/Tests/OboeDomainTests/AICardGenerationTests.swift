import Foundation
import XCTest
@testable import OboeDomain

final class AICardGenerationTests: XCTestCase {
    func testDecodesVersionedVocabularyAndGrammarCandidates() throws {
        let vocabularyInput = AICardGenerationInput(
            requestID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            inputVersion: 7,
            kind: .vocabulary,
            text: " 食べる ",
            context: "朝食"
        )
        let vocabulary = try AICardOutputDecoder.decode(
            Self.vocabularyJSON,
            requestID: vocabularyInput.requestID,
            sourceInput: try AICardOutputDecoder.validated(vocabularyInput)
        )
        XCTAssertEqual(vocabulary.promptVersion, "oboe-card-generation-v1")
        XCTAssertEqual(vocabulary.schemaVersion, 1)
        XCTAssertEqual(vocabulary.sourceInput.inputVersion, 7)
        guard case let .vocabulary(form) = vocabulary.payload else {
            return XCTFail("Expected vocabulary payload")
        }
        XCTAssertEqual(form.headword, "食べる")
        XCTAssertEqual(form.reading, "たべる")
        XCTAssertEqual(form.meaningZH, "吃")
        XCTAssertEqual(form.jlpt, .n5)
        XCTAssertEqual(form.exampleJapanese, "毎朝パンを食べます。")
        XCTAssertEqual(vocabulary.warnings, ["语境不足时请核对词义"])

        let grammarInput = AICardGenerationInput(kind: .grammar, text: "～たことがある")
        let grammar = try AICardOutputDecoder.decode(
            Self.grammarJSON,
            requestID: grammarInput.requestID,
            sourceInput: grammarInput
        )
        guard case let .grammar(grammarForm) = grammar.payload else {
            return XCTFail("Expected grammar payload")
        }
        XCTAssertEqual(grammarForm.grammarForm, "～たことがある")
        XCTAssertEqual(grammarForm.meaningZH, "曾经……过")
        XCTAssertEqual(grammarForm.jlpt, .n4)
    }

    func testRejectsMalformedWrongVersionKindUnknownFieldsAndInvalidValues() throws {
        let input = AICardGenerationInput(kind: .vocabulary, text: "食べる")
        let failures: [(String, AICardGenerationError)] = [
            ("not-json", .invalidJSON),
            (Self.vocabularyJSON.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":2"#), .unsupportedSchemaVersion),
            (Self.vocabularyJSON.replacingOccurrences(of: #""kind":"vocabulary""#, with: #""kind":"grammar""#), .kindMismatch),
            (Self.vocabularyJSON.replacingOccurrences(of: #""warnings":["语境不足时请核对词义"]"#, with: #""warnings":[],"extra":"no""#), .unexpectedFields),
            (Self.vocabularyJSON.replacingOccurrences(of: #""jlpt":"N5""#, with: #""jlpt":"N0""#), .invalidJLPT),
            (Self.vocabularyJSON.replacingOccurrences(of: #""headword":"食べる""#, with: #""headword":"taberu""#), .japaneseTextRequired("headword")),
            (Self.vocabularyJSON.replacingOccurrences(of: #""examples":[{"japanese":"毎朝パンを食べます。","translationZH":"我每天早上吃面包。"}]"#, with: #""examples":[{"japanese":"食べます。","translationZH":"吃。"},{"japanese":"飲みます。","translationZH":"喝。"}]"#), .tooManyExamples)
        ]

        for (json, expected) in failures {
            XCTAssertThrowsError(
                try AICardOutputDecoder.decode(json, requestID: input.requestID, sourceInput: input)
            ) { error in
                XCTAssertEqual(error as? AICardGenerationError, expected)
            }
        }
    }

    func testInputLimitsAndRequestGateProtectAgainstLateResponses() throws {
        XCTAssertThrowsError(
            try AICardOutputDecoder.validated(.init(kind: .vocabulary, text: "  "))
        ) { XCTAssertEqual($0 as? AICardGenerationError, .inputRequired) }
        XCTAssertThrowsError(
            try AICardOutputDecoder.validated(.init(kind: .grammar, text: String(repeating: "あ", count: 201)))
        ) { XCTAssertEqual($0 as? AICardGenerationError, .inputTooLong) }
        XCTAssertThrowsError(
            try AICardOutputDecoder.validated(
                .init(kind: .grammar, text: "～たことがある", context: String(repeating: "文", count: 1_001))
            )
        ) { XCTAssertEqual($0 as? AICardGenerationError, .contextTooLong) }

        let first = UUID()
        let second = UUID()
        var gate = AIGenerationRequestGate()
        gate.begin(first)
        gate.begin(second)
        XCTAssertFalse(gate.finish(first), "旧请求的迟到响应不得成为当前候选")
        XCTAssertTrue(gate.finish(second))
        gate.begin(first)
        gate.cancel()
        XCTAssertFalse(gate.finish(first), "取消后的响应不得恢复编辑状态")
    }

    func testServiceUsesEnabledPersistedBindingAndFixedResponse() async throws {
        let reference = AICredentialReference(
            id: UUID(),
            serviceKind: .custom,
            host: "ai.example"
        )
        let configuration = AIConfiguration(
            isEnabled: true,
            serviceKind: .custom,
            serviceName: "Fixture",
            baseURL: URL(string: "https://ai.example/v1")!,
            modelID: "fixture-model",
            responseFormatMode: .jsonSchema,
            credentialReference: reference
        )
        let client = FixedCardClient(content: Self.vocabularyJSON)
        let service = AICardGenerationService(
            repository: FixedAIRepository(configuration: configuration),
            credentialStore: FixedCredentialStore(value: "fixture-key"),
            client: client
        )
        let input = AICardGenerationInput(kind: .vocabulary, text: "食べる")

        let candidate = try await service.generate(input, defaultTimeZoneID: "Asia/Shanghai")

        XCTAssertEqual(candidate.requestID, input.requestID)
        let captured = await client.captured()
        XCTAssertEqual(captured?.0, try AICardOutputDecoder.validated(input))
        XCTAssertEqual(captured?.1, configuration)
        XCTAssertEqual(captured?.2, "fixture-key")
    }
}

private extension AICardGenerationTests {
    static let vocabularyJSON = #"{"schemaVersion":1,"kind":"vocabulary","headword":"食べる","reading":"たべる","meaningZH":"吃","partOfSpeech":"一段动词","jlpt":"N5","examples":[{"japanese":"毎朝パンを食べます。","translationZH":"我每天早上吃面包。"}],"notes":"","warnings":["语境不足时请核对词义"]}"#
    static let grammarJSON = #"{"schemaVersion":1,"kind":"grammar","grammarForm":"～たことがある","meaningZH":"曾经……过","usage":"表示过去的经历","connection":"动词た形＋ことがある","jlpt":"N4","examples":[{"japanese":"日本へ行ったことがあります。","translationZH":"我去过日本。"}],"notes":"","warnings":[]}"#
}

private struct FixedAIRepository: AIConfigurationRepository {
    let configuration: AIConfiguration

    func loadOrCreateAIConfiguration(defaultTimeZoneID: String) async throws -> AIConfiguration {
        configuration
    }

    func saveAIConfiguration(_ configuration: AIConfiguration) async throws {}
}

private struct FixedCredentialStore: AICredentialStore {
    let value: String?

    func readCredential(for reference: AICredentialReference) async throws -> String? { value }
    func saveCredential(_ credential: String, for reference: AICredentialReference) async throws {}
    func deleteCredential(for reference: AICredentialReference) async throws {}
}

private actor FixedCardClient: AICardGenerationClient {
    let content: String
    private var lastCaptured: (AICardGenerationInput, AIConfiguration, String)?

    init(content: String) {
        self.content = content
    }

    func generate(
        input: AICardGenerationInput,
        configuration: AIConfiguration,
        credential: String
    ) async throws -> String {
        lastCaptured = (input, configuration, credential)
        return content
    }

    func captured() -> (AICardGenerationInput, AIConfiguration, String)? { lastCaptured }
}
