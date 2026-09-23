import Foundation
import OboeDomain
import OboeInfrastructure
import OboeSharedCapture

/// 启动期环境解析：集中识别 `OBOE_UI_TEST_*` 环境变量并把可替换的
/// 服务/client 装配成 DEBUG stub，生产构造路径因此不被测试分支切碎。
/// release 构建一律返回真实实现。
struct AppBootstrapEnvironment {
    let speechService: any SpeechService
    let ocrService: any OCRRecognizing

    @MainActor
    init() {
        #if DEBUG
        if let stubMode = ProcessInfo.processInfo.environment["OBOE_UI_TEST_SPEECH_STUB"],
           let mode = UITestStubSpeechService.Mode(rawValue: stubMode) {
            speechService = UITestStubSpeechService(mode: mode)
        } else if ProcessInfo.processInfo.environment["OBOE_UI_TEST_SPEECH_UNAVAILABLE"] != nil {
            speechService = UITestUnavailableSpeechService()
        } else {
            speechService = SystemJapaneseSpeechService()
        }
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_OCR_STUB"] != nil {
            ocrService = UITestStubOCRService()
        } else {
            ocrService = VisionOCRService()
        }
        #else
        speechService = SystemJapaneseSpeechService()
        ocrService = VisionOCRService()
        #endif
    }

    /// UI 测试隔离数据库走临时目录；正式路径在 Application Support。
    static func applicationDataURL() -> URL {
        if let identifier = ProcessInfo.processInfo.environment["OBOE_UI_TEST_DATABASE_ID"],
           let uuid = UUID(uuidString: identifier) {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Oboe-UITests", isDirectory: true)
                .appendingPathComponent(uuid.uuidString, isDirectory: true)
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport.appendingPathComponent("Oboe", isDirectory: true)
    }

    /// UI 测试数据库使用内存凭据 store——模拟器未签名构建上 Keychain
    /// 会因缺少 entitlement 失败；正式运行总是 Keychain。
    static func makeAICredentialStore() -> any AICredentialStore {
        #if DEBUG
        if usesUITestDatabase {
            return UITestAICredentialStore()
        }
        #endif
        return KeychainAICredentialStore()
    }

    static func makeAIConnectionClient() -> any AIConnectionClient {
        #if DEBUG
        if usesUITestDatabase {
            return UITestAIConnectionClient()
        }
        #endif
        return ChatCompletionsAIConnectionClient()
    }

    static func makeAICardGenerationClient() -> any AICardGenerationClient {
        #if DEBUG
        if usesUITestDatabase {
            return UITestAICardGenerationClient()
        }
        #endif
        return ChatCompletionsAICardGenerationClient()
    }

    static func makeSentenceAnalysisClient() -> any SentenceAnalysisClient {
        #if DEBUG
        if usesUITestDatabase {
            return UITestSentenceAnalysisClient()
        }
        #endif
        return ChatCompletionsSentenceAnalysisClient()
    }

    static func makeAIRepairClient() -> any AIRepairClient {
        #if DEBUG
        if usesUITestDatabase {
            return UITestAIRepairClient()
        }
        #endif
        return ChatCompletionsAIRepairClient()
    }

    /// 显式 seam：即便不走 UITest 数据库也允许替换模型目录 client。
    static func makeModelCatalogClient() -> any AIModelCatalogClient {
        #if DEBUG
        if usesUITestDatabase
            || ProcessInfo.processInfo.environment["OBOE_UI_TEST_MODEL_CATALOG"] != nil {
            return UITestStubbedModelCatalogClient()
        }
        #endif
        return HTTPAIModelCatalogClient()
    }

    static func makeReviewContentRepository(
        base: any ReviewCardContentRepository
    ) -> any ReviewCardContentRepository {
        #if DEBUG
        if let identifier = ProcessInfo.processInfo.environment["OBOE_UI_TEST_DATABASE_ID"],
           UUID(uuidString: identifier) != nil,
           let raw = ProcessInfo.processInfo.environment["OBOE_UI_TEST_REVIEW_LOAD_DELAY"],
           let delay = Double(raw), delay.isFinite, delay >= 0 {
            let failures = Int(
                ProcessInfo.processInfo.environment["OBOE_UI_TEST_REVIEW_LOAD_FAILURES"] ?? "0"
            ) ?? 0
            return UITestDelayedReviewContentRepository(
                base: base, delay: delay, remainingFailures: failures
            )
        }
        #endif
        return base
    }

    static func makeSubmissionRepository(
        base: any ReviewSubmissionRepository
    ) -> any ReviewSubmissionRepository {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["OBOE_UI_TEST_SUBMIT_FAILURES"],
           let failures = Int(raw), failures > 0 {
            return UITestFlakySubmissionRepository(base: base, remainingFailures: failures)
        }
        #endif
        return base
    }

    /// UI tests inject an isolated queue directory; production resolves the
    /// shared App Group container. A nil store means the group entitlement is
    /// absent (e.g. unsigned builds) — the coordinator reports that honestly.
    static func resolveCaptureQueueStore() -> (any CaptureQueueStoring)? {
        if let override = ProcessInfo.processInfo.environment["OBOE_UI_TEST_CAPTURE_QUEUE"],
           !override.isEmpty {
            return AppGroupCaptureStore(
                queueDirectoryURL: URL(fileURLWithPath: override, isDirectory: true)
            )
        }
        return AppGroupCaptureStore()
    }

    /// Image attachments live in the app's own container (not the App Group —
    /// extensions never touch them). UI tests redirect the root via env.
    static func resolveInboxImageStore(baseURL: URL) -> InboxImageStore {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["OBOE_UI_TEST_IMAGE_STORE"],
           !override.isEmpty {
            return InboxImageStore(
                rootDirectoryURL: URL(fileURLWithPath: override, isDirectory: true)
            )
        }
        #endif
        return InboxImageStore(
            rootDirectoryURL: baseURL.appendingPathComponent(
                "InboxImages",
                isDirectory: true
            )
        )
    }

    static var usesUITestDatabase: Bool {
        ProcessInfo.processInfo.environment["OBOE_UI_TEST_DATABASE_ID"] != nil
    }
}
