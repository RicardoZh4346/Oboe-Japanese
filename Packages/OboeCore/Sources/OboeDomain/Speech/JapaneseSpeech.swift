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

public typealias SpeechFailureHandler = @MainActor @Sendable (JapaneseSpeechError) -> Void

@MainActor
public protocol SpeechService: AnyObject {
    var availability: JapaneseSpeechAvailability { get }
    func speak(_ texts: [String], onError: @escaping SpeechFailureHandler)
    func stop()
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

    public var exposesJapaneseOnQuestion: Bool {
        templateKind != .vocabularyChineseToJapanese
    }

    public var exposesPrimaryOnAnswer: Bool {
        templateKind == .vocabularyChineseToJapanese
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
