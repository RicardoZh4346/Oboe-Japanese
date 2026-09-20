import Foundation

public struct SpeechPreferences: Equatable, Sendable {
    public let autoPlayWordAudio: Bool
    public let autoPlayExampleAudio: Bool

    public init(autoPlayWordAudio: Bool, autoPlayExampleAudio: Bool) {
        self.autoPlayWordAudio = autoPlayWordAudio
        self.autoPlayExampleAudio = autoPlayExampleAudio
    }

    public static let defaults = SpeechPreferences(
        autoPlayWordAudio: false,
        autoPlayExampleAudio: false
    )
}

public protocol SpeechPreferencesRepository: Sendable {
    func loadOrCreateSpeechPreferences(defaultTimeZoneID: String) async throws -> SpeechPreferences
    func updateAutoPlayWordAudio(_ isEnabled: Bool) async throws -> SpeechPreferences
    func updateAutoPlayExampleAudio(_ isEnabled: Bool) async throws -> SpeechPreferences
}

public struct SpeechPreferencesService: Sendable {
    private let repository: any SpeechPreferencesRepository

    public init(repository: any SpeechPreferencesRepository) {
        self.repository = repository
    }

    public func load(defaultTimeZoneID: String) async throws -> SpeechPreferences {
        guard TimeZone(identifier: defaultTimeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(defaultTimeZoneID)
        }
        return try await repository.loadOrCreateSpeechPreferences(
            defaultTimeZoneID: defaultTimeZoneID
        )
    }

    public func setAutoPlayWordAudio(_ isEnabled: Bool) async throws -> SpeechPreferences {
        try await repository.updateAutoPlayWordAudio(isEnabled)
    }

    public func setAutoPlayExampleAudio(_ isEnabled: Bool) async throws -> SpeechPreferences {
        try await repository.updateAutoPlayExampleAudio(isEnabled)
    }
}

public enum JapaneseSpeechAvailability: Equatable, Sendable {
    case available(voiceName: String)
    case unavailable

    public var isAvailable: Bool {
        if case .available = self { true } else { false }
    }
}

public enum JapaneseSpeechError: Error, Equatable, Sendable {
    case voiceUnavailable
    case noSpeakableText
    case audioSessionUnavailable
}

/// T18 (设计 §8.3): request-scoped playback lifecycle. `started` only means
/// the engine began — it is not proof of audible output. `cancelled` covers
/// interruptions, route changes, page exit and superseding requests; it is
/// neither a failure nor a completion. Every event echoes the requestID
/// returned by `speakWithEvents` so late callbacks from a superseded request
/// can be dropped by the caller.
public enum SpeechPlaybackEvent: Equatable, Sendable {
    case started(requestID: UUID)
    case completed(requestID: UUID)
    case failed(requestID: UUID, error: JapaneseSpeechError)
    case cancelled(requestID: UUID)

    public var requestID: UUID {
        switch self {
        case let .started(requestID), let .completed(requestID),
             let .cancelled(requestID), let .failed(requestID, _):
            requestID
        }
    }
}

public typealias SpeechFailureHandler = @MainActor @Sendable (JapaneseSpeechError) -> Void
public typealias SpeechEventHandler = @MainActor @Sendable (SpeechPlaybackEvent) -> Void

@MainActor
public protocol SpeechService: AnyObject {
    var availability: JapaneseSpeechAvailability { get }
    /// T18: primary playback API. Returns the requestID carried by every
    /// event of this request. `stop()` reports `.cancelled` for a request
    /// still in flight; a request that already reached a terminal event
    /// (completed/failed) emits nothing further.
    @discardableResult
    func speakWithEvents(_ texts: [String], onEvent: @escaping SpeechEventHandler) -> UUID
    func stop()
}

public extension SpeechService {
    /// Legacy error-only surface (设计 §8.3 "保留旧接口适配"): word/example
    /// audio call sites that only need failures keep the original signature.
    func speak(_ texts: [String], onError: @escaping SpeechFailureHandler) {
        speakWithEvents(texts) { event in
            if case let .failed(_, error) = event {
                onError(error)
            }
        }
    }
}

public struct ReviewSpeechPolicy: Equatable, Sendable {
    public let templateKind: CardTemplateKind
    public let primaryText: String
    public let exampleText: String?

    public init(content: ReviewCardContent) {
        templateKind = content.templateKind
        let reading = content.reading?.trimmingCharacters(in: .whitespacesAndNewlines)
        primaryText = content.templateKind.knowledgePointKind == .vocabulary
            ? (reading?.isEmpty == false ? reading! : content.headword)
            : content.headword
        let example = content.exampleJapanese?.trimmingCharacters(in: .whitespacesAndNewlines)
        exampleText = example?.isEmpty == false ? example : nil
    }

    /// Explicit per-template decision (设计 §8): a negative check like
    /// "not zh→ja" would silently expose Japanese on the listening card's
    /// question face. Listening prompt audio rides its own
    /// `autoPlayListeningAudio` channel — never this word-audio gate.
    public var exposesJapaneseOnQuestion: Bool {
        switch templateKind {
        case .vocabularyJapaneseToChinese, .grammarFormToExplanation:
            true
        case .vocabularyChineseToJapanese, .vocabularyListening:
            false
        }
    }

    public var exposesPrimaryOnAnswer: Bool {
        switch templateKind {
        case .vocabularyChineseToJapanese, .vocabularyListening:
            true
        case .vocabularyJapaneseToChinese, .grammarFormToExplanation:
            false
        }
    }

    /// T17 (设计 §8.2): the listening card's question audio is ONLY the word
    /// prompt — a non-empty reading is preferred, otherwise the headword; the
    /// example sentence is never part of it. nil for non-listening templates
    /// so no other card can route through this channel.
    public var listeningPromptText: String? {
        templateKind == .vocabularyListening ? primaryText : nil
    }

    public func automaticQuestionTexts(preferences: SpeechPreferences) -> [String] {
        guard preferences.autoPlayWordAudio, exposesJapaneseOnQuestion else { return [] }
        return [primaryText]
    }

    public func automaticAnswerTexts(preferences: SpeechPreferences) -> [String] {
        var texts: [String] = []
        if preferences.autoPlayWordAudio, exposesPrimaryOnAnswer {
            texts.append(primaryText)
        }
        if preferences.autoPlayExampleAudio, let exampleText {
            texts.append(exampleText)
        }
        return texts
    }
}
