#if DEBUG
import AVFoundation
import Foundation
import OboeDomain
import OboeInfrastructure
import OboeSharedCapture
import SwiftUI

actor UITestDelayedReviewContentRepository: ReviewCardContentRepository {
    let base: any ReviewCardContentRepository
    let delay: Double
    var remainingFailures: Int
    var hasLoaded = false

    init(base: any ReviewCardContentRepository, delay: Double, remainingFailures: Int) {
        self.base = base
        self.delay = delay
        self.remainingFailures = remainingFailures
    }

    func fetchReviewCardContent(cardID: UUID) async throws -> ReviewCardContent? {
        if hasLoaded {
            try await Task.sleep(for: .seconds(delay))
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw NSError(
                    domain: "OboeUITest",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "测试注入的下一张载入失败"]
                )
            }
        }
        hasLoaded = true
        return try await base.fetchReviewCardContent(cardID: cardID)
    }
}

/// UI tests run as unsigned simulator builds, where Keychain access can fail with
/// a missing-entitlement error. Release composition always uses Keychain.
actor UITestAICredentialStore: AICredentialStore {
    var credentials: [AICredentialReference: String] = [:]

    func readCredential(for reference: AICredentialReference) -> String? {
        credentials[reference]
    }

    func saveCredential(_ credential: String, for reference: AICredentialReference) {
        credentials[reference] = credential
    }

    func deleteCredential(for reference: AICredentialReference) {
        credentials.removeValue(forKey: reference)
    }
}

struct UITestAIConnectionClient: AIConnectionClient {
    func testConnection(
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> AIConnectionTestResult {
        AIConnectionTestResult(
            serviceName: configuration.serviceName,
            modelID: configuration.modelID,
            responseFormatMode: configuration.responseFormatMode
        )
    }
}

struct UITestAICardGenerationClient: AICardGenerationClient {
    func generate(
        input: AICardGenerationInput,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> String {
        try await Task.sleep(for: .seconds(5))
        switch input.kind {
        case .vocabulary:
            return #"{"schemaVersion":2,"kind":"vocabulary","headword":"食べる","reading":"たべる","meaningZH":"吃","partsOfSpeech":["一段动词","他动词"],"pitchAccent":2,"jlpt":"N5","examples":[{"japanese":"毎朝パンを食べます。","translationZH":"我每天早上吃面包。"}],"notes":"","warnings":[]}"#
        case .grammar:
            return #"{"schemaVersion":2,"kind":"grammar","grammarForm":"～たことがある","meaningZH":"曾经……过","usage":"表示过去的经历","connection":"动词た形＋ことがある","jlpt":"N4","examples":[{"japanese":"日本へ行ったことがあります。","translationZH":"我去过日本。"}],"notes":"","warnings":[]}"#
        }
    }
}

/// Deterministic repair analysis for UI tests (T07): a short delay keeps the
/// analyzing state observable so cancel can be exercised end to end.
/// `OBOE_UI_TEST_AI_REPAIR_FAIL=1` simulates a transport failure instead.
struct UITestAIRepairClient: AIRepairClient {
    func analyze(
        context: AIRepairRequestContext,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> String {
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_AI_REPAIR_FAIL"] != nil {
            throw AIConnectionError.serviceUnavailable(statusCode: 503)
        }
        try await Task.sleep(for: .milliseconds(3_000))
        return #"{"schemaVersion":2,"problemTypes":["similar_words_confusion","example_too_complex"],"summary":"这张卡可能因近形词混淆而难记，例句也偏复杂。","suggestions":[{"type":"add_disambiguation","title":"补充辨析说明","reason":"与近形词区分度不足","replacement":{"notes":"注意与「受け取る」区分：受ける偏被动接受。"}},{"type":"split_card","title":"拆为两张卡","reason":"义项跨语境，合并回忆目标过宽","splitNotes":[{"kind":"vocabulary","headword":"受ける","reading":"うける","meaningZH":"接受（考试、治疗等）","partsOfSpeech":["一段动词","他动词"],"pitchAccent":2,"jlpt":"N3","usage":null,"connection":null,"notes":null,"examples":[{"japanese":"試験を受ける","translationZH":"参加考试"}]},{"kind":"vocabulary","headword":"受ける","reading":"うける","meaningZH":"遭受（损失、攻击等）","partsOfSpeech":["一段动词","他动词"],"pitchAccent":2,"jlpt":"N3","usage":null,"connection":null,"notes":null,"examples":[{"japanese":"被害を受ける","translationZH":"遭受损失"}]}]}]}"#
    }
}

struct UITestSentenceAnalysisClient: SentenceAnalysisClient {
    func analyze(
        input: SentenceAnalysisInput,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> String {
        try await Task.sleep(for: .seconds(1))
        return #"{"schemaVersion":2,"sentence":"日本に行ったことがありますか。","translationZH":"你去过日本吗？","explanationZH":"询问对方是否有去日本的经历。","items":[{"kind":"particle","surface":"に","canonicalForm":"に","reading":"に","meaningZH":"向、到","roleZH":"表示移动的目的地","spans":[{"text":"に","occurrence":1}],"cardDraft":{"kind":"grammar","headword":"に","reading":"","meaningZH":"表示移动目的地","partsOfSpeech":[],"pitchAccent":null,"usage":"接在地点后","connection":"地点＋に","notes":""}},{"kind":"vocabulary","surface":"行った","canonicalForm":"行く","reading":"いく","meaningZH":"去","roleZH":"动词「行く」的过去式","spans":[{"text":"行った","occurrence":1}],"cardDraft":{"kind":"vocabulary","headword":"行く","reading":"いく","meaningZH":"去","partsOfSpeech":["五段动词","自动词"],"pitchAccent":0,"usage":"","connection":"","notes":""}},{"kind":"grammar","surface":"～たことがある","canonicalForm":"～たことがある","reading":"","meaningZH":"曾经……过","roleZH":"表示过去经历","spans":[{"text":"行った","occurrence":1},{"text":"ことがあります","occurrence":1}],"cardDraft":{"kind":"grammar","headword":"～たことがある","reading":"","meaningZH":"曾经……过","partsOfSpeech":[],"pitchAccent":null,"usage":"表示过去经历","connection":"动词た形＋ことがある","notes":""}},{"kind":"expression","surface":"未对齐项目","canonicalForm":"未对齐项目","reading":"","meaningZH":"即使定位失败，解释仍然可读","roleZH":"验证安全降级","spans":[{"text":"存在しない","occurrence":1}],"cardDraft":null}],"warnings":["请核对语境后再用于学习"]}"#
    }
}

/// UI 测试模型目录 stub：返回稳定的虚拟模型列表，不发起网络请求。
/// `OBOE_UI_TEST_MODEL_CATALOG_DELAY`（秒）制造可取消的慢请求；
/// `OBOE_UI_TEST_MODEL_CATALOG_FAIL=1` 始终失败；
/// `OBOE_UI_TEST_MODEL_CATALOG_FAIL_COUNT=N` 前 N 次失败后成功（重试路径）；
/// `OBOE_UI_TEST_MODEL_CATALOG_EMPTY=1` 返回空列表错误（空态）。
actor UITestStubbedModelCatalogClient: AIModelCatalogClient {
    var remainingFailures: Int

    init() {
        remainingFailures = Int(
            ProcessInfo.processInfo
                .environment["OBOE_UI_TEST_MODEL_CATALOG_FAIL_COUNT"] ?? "0"
        ) ?? 0
    }

    func fetchModels(
        configuration: AIConfiguration,
        credential: String
    ) async throws -> [AIModelDescriptor] {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["OBOE_UI_TEST_MODEL_CATALOG_DELAY"],
           let delay = Double(raw), delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        try Task.checkCancellation()
        if environment["OBOE_UI_TEST_MODEL_CATALOG_EMPTY"] != nil {
            throw AIModelCatalogError.emptyModelList
        }
        if environment["OBOE_UI_TEST_MODEL_CATALOG_FAIL"] != nil {
            throw AIModelCatalogError.serviceUnavailable(statusCode: 503)
        }
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw AIModelCatalogError.serviceUnavailable(statusCode: 503)
        }
        let prefix = "uitest-\(configuration.serviceKind.rawValue)"
        return [
            AIModelDescriptor(id: "\(prefix)-model-a", displayName: "UITest Model A"),
            AIModelDescriptor(id: "\(prefix)-model-b", displayName: "UITest Model B"),
            AIModelDescriptor(
                id: "\(prefix)-model-c-with-a-deliberately-long-identifier-for-layout",
                displayName: "UITest Model C（超长 ID）"
            ),
        ]
    }
}

/// Deterministic OCR for UI tests — real Vision output varies by simulator
/// build, so the scripted blocks keep the selection/edit/save flow stable.
/// `OBOE_UI_TEST_OCR_FAIL=1` simulates a recognition failure instead;
/// `OBOE_UI_TEST_OCR_LONG=1` returns a block over the Inbox length limit.
struct UITestStubOCRService: OCRRecognizing {
    func recognize(imageData: Data) async throws -> OCRResult {
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_OCR_FAIL"] != nil {
            throw OCRError.recognitionFailed("测试注入的识别失败")
        }
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_OCR_LONG"] != nil {
            return OCRResult(
                blocks: [
                    OCRTextBlock(
                        id: 0,
                        text: String(repeating: "あ", count: InboxText.maximumCharacterCount + 1),
                        confidence: 0.9,
                        boundingBox: OCRBoundingBox(x: 0.1, y: 0.1, width: 0.8, height: 0.2)
                    ),
                ],
                recognizedLanguages: ["ja-JP"]
            )
        }
        return OCRResult(
            blocks: [
                OCRTextBlock(
                    id: 0,
                    text: "今日はいい天気です",
                    confidence: 0.96,
                    boundingBox: OCRBoundingBox(x: 0.1, y: 0.1, width: 0.8, height: 0.2)
                ),
                OCRTextBlock(
                    id: 1,
                    text: "駅まで歩きます",
                    confidence: 0.42,
                    boundingBox: OCRBoundingBox(x: 0.1, y: 0.4, width: 0.8, height: 0.2)
                ),
            ],
            recognizedLanguages: ["ja-JP"]
        )
    }
}

/// Simulates a device without a Japanese voice so UI tests can cover the
/// speech-unavailable and speech-error review states.
final class UITestUnavailableSpeechService: SpeechService {
    let availability: JapaneseSpeechAvailability = .unavailable

    @discardableResult
    func speakWithEvents(_ texts: [String], onEvent: @escaping SpeechEventHandler) -> UUID {
        let requestID = UUID()
        onEvent(.failed(requestID: requestID, error: .voiceUnavailable))
        return requestID
    }

    func stop() {}
}

/// T18 seam (`OBOE_UI_TEST_SPEECH_STUB=ok|fail|pending`): deterministic
/// playback events that don't depend on the simulator's voice install or
/// real TTS timing. `ok` completes shortly after start; `fail` reports
/// `audioSessionUnavailable`; `pending` starts but never finishes.
@MainActor
final class UITestStubSpeechService: SpeechService {
    enum Mode: String {
        case ok, fail, pending
    }

    let mode: Mode
    var inFlight: (id: UUID, onEvent: SpeechEventHandler)?

    init(mode: Mode) {
        self.mode = mode
    }

    var availability: JapaneseSpeechAvailability {
        .available(voiceName: "UITestStubVoice")
    }

    @discardableResult
    func speakWithEvents(_ texts: [String], onEvent: @escaping SpeechEventHandler) -> UUID {
        cancelInFlight()
        let requestID = UUID()
        inFlight = (requestID, onEvent)
        Task { @MainActor in
            guard self.inFlight?.id == requestID else { return }
            onEvent(.started(requestID: requestID))
            switch self.mode {
            case .ok:
                try? await Task.sleep(for: .milliseconds(250))
                guard self.inFlight?.id == requestID else { return }
                self.inFlight = nil
                onEvent(.completed(requestID: requestID))
            case .fail:
                guard self.inFlight?.id == requestID else { return }
                self.inFlight = nil
                onEvent(.failed(requestID: requestID, error: .audioSessionUnavailable))
            case .pending:
                break
            }
        }
        return requestID
    }

    /// Matches the real service: an interrupted request reports `.cancelled`
    /// so a backgrounded/pending playback never reads as failure or success.
    func stop() {
        cancelInFlight()
    }

    func cancelInFlight() {
        guard let inFlight else { return }
        self.inFlight = nil
        inFlight.onEvent(.cancelled(requestID: inFlight.id))
    }
}

/// Fails the first `remainingFailures` commit attempts with a recoverable
/// error, then forwards everything to the real repository.
actor UITestFlakySubmissionRepository: ReviewSubmissionRepository {
    let base: any ReviewSubmissionRepository
    var remainingFailures: Int

    init(base: any ReviewSubmissionRepository, remainingFailures: Int) {
        self.base = base
        self.remainingFailures = remainingFailures
    }

    func fetchSubmittedReview(eventID: UUID) async throws -> ReviewLogRecord? {
        try await base.fetchSubmittedReview(eventID: eventID)
    }

    func fetchReviewContext(cardID: UUID) async throws -> ReviewSubmissionContext? {
        try await base.fetchReviewContext(cardID: cardID)
    }

    func commitReview(_ mutation: ReviewSubmissionMutation) async throws -> ReviewLogRecord {
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw NSError(
                domain: "OboeUITest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "测试注入的保存失败"]
            )
        }
        return try await base.commitReview(mutation)
    }
}
#endif
