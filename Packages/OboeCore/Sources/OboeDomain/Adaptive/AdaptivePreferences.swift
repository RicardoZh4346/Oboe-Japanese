import Foundation

/// v0.4 feature toggles persisted in `app_settings` next to, but independent
/// from, the existing speech preferences: they must never map onto
/// `auto_play_word_audio`/`auto_play_example_audio`.
public struct AdaptivePreferences: Equatable, Sendable {
    /// 中文→日文 cards may ask for typed Japanese recall instead of reveal-only.
    public let typedAnswerChineseToJapanese: Bool
    /// Listening cards play their prompt audio when the question face appears.
    public let autoPlayListeningAudio: Bool
    /// Listening cards may ask for typed Japanese recall instead of reveal-only.
    public let typedAnswerListening: Bool
    /// The answer face may surface a lightweight warning/leech reminder.
    public let leechRemindersEnabled: Bool

    public init(
        typedAnswerChineseToJapanese: Bool,
        autoPlayListeningAudio: Bool,
        typedAnswerListening: Bool,
        leechRemindersEnabled: Bool
    ) {
        self.typedAnswerChineseToJapanese = typedAnswerChineseToJapanese
        self.autoPlayListeningAudio = autoPlayListeningAudio
        self.typedAnswerListening = typedAnswerListening
        self.leechRemindersEnabled = leechRemindersEnabled
    }

    /// Requirement §16 defaults: typed recall off, listening autoplay on,
    /// listening typed recall off, leech reminders on.
    public static let defaults = AdaptivePreferences(
        typedAnswerChineseToJapanese: false,
        autoPlayListeningAudio: true,
        typedAnswerListening: false,
        leechRemindersEnabled: true
    )
}

public protocol AdaptivePreferencesRepository: Sendable {
    func loadOrCreateAdaptivePreferences(
        defaultTimeZoneID: String
    ) async throws -> AdaptivePreferences
    func updateTypedAnswerChineseToJapanese(_ isEnabled: Bool) async throws -> AdaptivePreferences
    func updateAutoPlayListeningAudio(_ isEnabled: Bool) async throws -> AdaptivePreferences
    func updateTypedAnswerListening(_ isEnabled: Bool) async throws -> AdaptivePreferences
    func updateLeechRemindersEnabled(_ isEnabled: Bool) async throws -> AdaptivePreferences
}

public struct AdaptivePreferencesService: Sendable {
    private let repository: any AdaptivePreferencesRepository

    public init(repository: any AdaptivePreferencesRepository) {
        self.repository = repository
    }

    public func load(defaultTimeZoneID: String) async throws -> AdaptivePreferences {
        guard TimeZone(identifier: defaultTimeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(defaultTimeZoneID)
        }
        return try await repository.loadOrCreateAdaptivePreferences(
            defaultTimeZoneID: defaultTimeZoneID
        )
    }

    public func setTypedAnswerChineseToJapanese(
        _ isEnabled: Bool
    ) async throws -> AdaptivePreferences {
        try await repository.updateTypedAnswerChineseToJapanese(isEnabled)
    }

    public func setAutoPlayListeningAudio(_ isEnabled: Bool) async throws -> AdaptivePreferences {
        try await repository.updateAutoPlayListeningAudio(isEnabled)
    }

    public func setTypedAnswerListening(_ isEnabled: Bool) async throws -> AdaptivePreferences {
        try await repository.updateTypedAnswerListening(isEnabled)
    }

    public func setLeechRemindersEnabled(_ isEnabled: Bool) async throws -> AdaptivePreferences {
        try await repository.updateLeechRemindersEnabled(isEnabled)
    }
}
