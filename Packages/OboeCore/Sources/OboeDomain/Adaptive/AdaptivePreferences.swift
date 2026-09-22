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

    /// v0.5.5 起的产品默认：中文→日文与听力卡都默认要求先输入回答
    /// （typed recall on），听力自动播放与易错提醒保持开启。
    /// 仅作用于行缺失/旧备份补全——已存行的值一律保留，不会被改写。
    public static let defaults = AdaptivePreferences(
        typedAnswerChineseToJapanese: true,
        autoPlayListeningAudio: true,
        typedAnswerListening: true,
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
