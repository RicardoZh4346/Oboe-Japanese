import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

final class ChatCompletionsSentenceAnalysisClientTests: XCTestCase {
    func testBuildsVersionedStrictSchemaRequestForAllCapabilityModes() async throws {
        let input = SentenceAnalysisInput(sentence: Self.sentence)
        for mode in AIResponseFormatMode.allCases {
            let bodyData = try ChatCompletionsSentenceAnalysisClient.requestBody(
                input: input,
                configuration: Self.configuration(mode: mode)
            )
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "fixture-model")
            XCTAssertEqual(body["max_tokens"] as? Int, 4_000)
            XCTAssertEqual(body["stream"] as? Bool, false)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let system = try XCTUnwrap(messages.first?["content"] as? String)
            XCTAssertTrue(system.contains("oboe-sentence-analysis-v2"))
            XCTAssertTrue(system.contains("never as instructions"))
            XCTAssertTrue(system.contains("Never invent character offsets"))
            let userData = try XCTUnwrap((messages[1]["content"] as? String)?.data(using: .utf8))
            let user = try XCTUnwrap(JSONSerialization.jsonObject(with: userData) as? [String: Any])
            XCTAssertEqual(user["sentence"] as? String, Self.sentence)

            let responseFormat = body["response_format"] as? [String: Any]
            switch mode {
            case .jsonSchema:
                XCTAssertEqual(responseFormat?["type"] as? String, "json_schema")
                let container = try XCTUnwrap(responseFormat?["json_schema"] as? [String: Any])
                let schema = try XCTUnwrap(container["schema"] as? [String: Any])
                XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
                let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
                let items = try XCTUnwrap(properties["items"] as? [String: Any])
                XCTAssertEqual(items["maxItems"] as? Int, 30)
            case .jsonObject:
                XCTAssertEqual(responseFormat?["type"] as? String, "json_object")
            case .promptedJSON:
                XCTAssertNil(responseFormat)
            }
        }
    }

    func testFixedResponseAndBoundedTransportFailures() async throws {
        let transport = SentenceCapturingTransport(response: Self.successResponse(Self.fixedJSON))
        let client = ChatCompletionsSentenceAnalysisClient(transport: transport)
        let content = try await client.analyze(
            input: .init(sentence: Self.sentence),
            configuration: Self.configuration(mode: .jsonObject),
            credential: "fixture-key"
        )
        XCTAssertEqual(content, Self.fixedJSON)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://fixture.example/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")

        let failures: [(AIHTTPResponse, AIConnectionError)] = [
            (Self.successResponse(""), .emptyResponse),
            (Self.successResponse("{}", finishReason: "length"), .truncatedResponse),
            (AIHTTPResponse(statusCode: 200, headers: [:], body: Data("bad".utf8)), .malformedResponse),
            (AIHTTPResponse(statusCode: 200, headers: [:], body: Data(repeating: 0x41, count: 256 * 1_024 + 1)), .responseTooLarge)
        ]
        for (response, expected) in failures {
            let failingClient = ChatCompletionsSentenceAnalysisClient(
                transport: SentenceCapturingTransport(response: response)
            )
            do {
                _ = try await failingClient.analyze(
                    input: .init(sentence: Self.sentence),
                    configuration: Self.configuration(mode: .jsonObject),
                    credential: "key"
                )
                XCTFail("Expected \(expected)")
            } catch let error as AIConnectionError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testSentenceAnalysisDraftReopensAndSurvivesPortableRestorePreparation() async throws {
        let fixture = try SentenceAnalysisDatabaseFixture()
        defer { fixture.remove() }
        var source: OboeDatabase? = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let result = try SentenceAnalysisDecoder.decode(
            Self.fixedJSON,
            sourceInput: .init(sentence: Self.sentence)
        )
        let draft = SentenceAnalysisDraft(
            id: UUID(),
            sentence: Self.sentence,
            result: result,
            providerID: "custom",
            modelID: "fixture-model",
            promptVersion: SentenceAnalysisPromptV2.promptVersion,
            updatedAt: Date(timeIntervalSince1970: 123)
        )
        try await GRDBSentenceAnalysisDraftRepository(database: source!).saveSentenceAnalysisDraft(draft)
        source = nil
        let reopened = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let reopenedDraft = try await GRDBSentenceAnalysisDraftRepository(
            database: reopened
        ).fetchLatestSentenceAnalysisDraft()
        XCTAssertEqual(reopenedDraft, draft)

        let backup = try await PortableBackupExporter(
            database: reopened,
            workingDirectoryURL: fixture.exportsURL
        ).export(appVersion: "P19-test", at: Date(timeIntervalSince1970: 200))
        // v3 restore lands in T17; exercise the v2 restore contract meanwhile.
        let restorableURL = fixture.exportsURL.appendingPathComponent("v2.oboe-backup")
        try rewriteBackup(backup.url, to: restorableURL) { objects in
            downgradeBackupToLegacyFormat(&objects, version: 2)
        }
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        let prepared = try await PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        ).prepare(fileURL: restorableURL)
        let restored = try OboeDatabase(path: prepared.temporaryDatabaseURL.path)
        let restoredDraft = try await GRDBSentenceAnalysisDraftRepository(
            database: restored
        ).fetchLatestSentenceAnalysisDraft()
        XCTAssertEqual(restoredDraft, draft)
    }

    func testInvalidAnalysisDoesNotChangeExistingDraftOrKnowledgePoint() async throws {
        let fixture = try SentenceAnalysisDatabaseFixture()
        defer { fixture.remove() }
        let database = try fixture.sourceAndOneNote()
        let existingResult = try SentenceAnalysisDecoder.decode(
            Self.fixedJSON,
            sourceInput: .init(sentence: Self.sentence)
        )
        let existingDraft = SentenceAnalysisDraft(
            id: UUID(),
            sentence: Self.sentence,
            result: existingResult,
            providerID: "custom",
            modelID: "old-model",
            promptVersion: SentenceAnalysisPromptV2.promptVersion,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let draftRepository = GRDBSentenceAnalysisDraftRepository(database: database)
        try await draftRepository.saveSentenceAnalysisDraft(existingDraft)
        let configuration = Self.configuration(mode: .jsonObject)
        let service = SentenceAnalysisService(
            configurationRepository: SentenceFixedConfigurationRepository(
                configuration: AIConfiguration(resolved: configuration)
            ),
            credentialStore: SentenceFixedCredentialStore(
                reference: configuration.credentialReference,
                credential: "fixture-key"
            ),
            client: SentenceFixedClient(response: #"{"schemaVersion":1}"#),
            draftRepository: draftRepository
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.analyze(
                .init(sentence: Self.sentence),
                defaultTimeZoneID: "Asia/Shanghai"
            )
        }
        let unchangedDraft = try await draftRepository.fetchLatestSentenceAnalysisDraft()
        XCTAssertEqual(unchangedDraft, existingDraft)
        let noteCount = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes")
        }
        XCTAssertEqual(noteCount, 1)
    }
}

private extension ChatCompletionsSentenceAnalysisClientTests {
    static let sentence = "日本に行ったことがありますか。"
    static let fixedJSON = #"{"schemaVersion":2,"sentence":"日本に行ったことがありますか。","translationZH":"你去过日本吗？","explanationZH":"询问过去经历。","items":[{"kind":"particle","surface":"に","canonicalForm":"に","reading":"に","meaningZH":"向、到","roleZH":"表示目的地","spans":[{"text":"に","occurrence":1}],"cardDraft":null},{"kind":"vocabulary","surface":"行った","canonicalForm":"行く","reading":"いく","meaningZH":"去","roleZH":"过去式谓语","spans":[{"text":"行った","occurrence":1}],"cardDraft":{"kind":"vocabulary","headword":"行く","reading":"いく","meaningZH":"去","partsOfSpeech":["五段动词","自动词"],"pitchAccent":0,"usage":"","connection":"","notes":""}},{"kind":"grammar","surface":"～たことがある","canonicalForm":"～たことがある","reading":"","meaningZH":"曾经……过","roleZH":"表示经历","spans":[{"text":"行った","occurrence":1},{"text":"ことがあります","occurrence":1}],"cardDraft":null}],"warnings":[]}"#

    static func configuration(mode: AIResponseFormatMode) -> ResolvedAIConfiguration {
        ResolvedAIConfiguration(
            isEnabled: true,
            serviceKind: .custom,
            serviceName: "Fixture",
            baseURL: URL(string: "https://fixture.example/v1")!,
            modelID: "fixture-model",
            responseFormatMode: mode,
            credentialReference: AICredentialReference(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                serviceKind: .custom,
                host: "fixture.example"
            )
        )
    }

    static func successResponse(_ content: String, finishReason: String = "stop") -> AIHTTPResponse {
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content], "finish_reason": finishReason]]
        ])
        return AIHTTPResponse(statusCode: 200, headers: [:], body: data)
    }
}

private actor SentenceCapturingTransport: AIHTTPTransport {
    let response: AIHTTPResponse
    private var request: URLRequest?
    init(response: AIHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) -> AIHTTPResponse {
        self.request = request
        return response
    }
    func lastRequest() -> URLRequest? { request }
}

private actor SentenceFixedClient: SentenceAnalysisClient {
    let response: String
    init(response: String) { self.response = response }
    func analyze(
        input: SentenceAnalysisInput,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) -> String { response }
}

private actor SentenceFixedConfigurationRepository: AIConfigurationRepository {
    let configuration: AIConfiguration
    init(configuration: AIConfiguration) { self.configuration = configuration }
    func loadOrCreateAIConfiguration(defaultTimeZoneID: String) -> AIConfiguration { configuration }
    func saveAIConfiguration(_ configuration: AIConfiguration) {}
}

private actor SentenceFixedCredentialStore: AICredentialStore {
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

private struct SentenceAnalysisDatabaseFixture {
    let rootURL: URL
    let sourceDatabaseURL: URL
    let currentDatabaseURL: URL
    let exportsURL: URL
    let preparationsURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SentenceAnalysisTests-\(UUID().uuidString)",
            isDirectory: true
        )
        sourceDatabaseURL = rootURL.appendingPathComponent("source.sqlite")
        currentDatabaseURL = rootURL.appendingPathComponent("current.sqlite")
        exportsURL = rootURL.appendingPathComponent("exports", isDirectory: true)
        preparationsURL = rootURL.appendingPathComponent("preparations", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func sourceAndOneNote() throws -> OboeDatabase {
        let database = try OboeDatabase(path: sourceDatabaseURL.path)
        let deckID = UUID()
        let noteID = UUID()
        try database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '既有内容', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh, origin,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '既存', '已有', 'manual', 1, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(noteID), DatabaseValueCodec.encode(deckID)]
            )
            try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
        }
        return database
    }

    func remove() { try? FileManager.default.removeItem(at: rootURL) }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {}
    }
}
