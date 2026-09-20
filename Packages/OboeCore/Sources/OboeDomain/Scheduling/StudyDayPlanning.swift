import Foundation

public struct StudyPlanningSettings: Codable, Equatable, Sendable {
    public let learningTimeZoneID: String
    public let dailyNewCardLimit: Int
    public let retentionPreset: RetentionPreset
    /// 主牌组：每日新卡额度先分配给该牌组，剩余额度再分配给其他牌组。
    public let primaryDeckID: UUID?

    public init(
        learningTimeZoneID: String,
        dailyNewCardLimit: Int,
        retentionPreset: RetentionPreset = .standard,
        primaryDeckID: UUID? = nil
    ) {
        self.learningTimeZoneID = learningTimeZoneID
        self.dailyNewCardLimit = dailyNewCardLimit
        self.retentionPreset = retentionPreset
        self.primaryDeckID = primaryDeckID
    }
}

public struct StudyDay: Codable, Equatable, Sendable {
    public let id: UUID
    public let localDate: String
    public let timeZoneID: String
    public let startsAt: Date
    public let endsAt: Date
    public let newCardLimit: Int

    public init(
        id: UUID,
        localDate: String,
        timeZoneID: String,
        startsAt: Date,
        endsAt: Date,
        newCardLimit: Int
    ) {
        self.id = id
        self.localDate = localDate
        self.timeZoneID = timeZoneID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.newCardLimit = newCardLimit
    }

    public var context: StudyDayContext { StudyDayContext(id: id) }

    public func replacingNewCardLimit(_ limit: Int) -> StudyDay {
        StudyDay(
            id: id,
            localDate: localDate,
            timeZoneID: timeZoneID,
            startsAt: startsAt,
            endsAt: endsAt,
            newCardLimit: limit
        )
    }
}

public struct NewCardReservation: Codable, Equatable, Sendable {
    public let cardID: UUID
    public let deckID: UUID
    public let admittedAt: Date

    public init(cardID: UUID, deckID: UUID, admittedAt: Date) {
        self.cardID = cardID
        self.deckID = deckID
        self.admittedAt = admittedAt
    }
}

public struct DailyNewCardPlan: Codable, Equatable, Sendable {
    public let studyDay: StudyDay
    /// 今日已首学的“词”数（按 note 去重）——一个词的任意方向首学即占一个名额。
    public let usedCount: Int
    /// 占用名额的预约词数（不含已开始词的免费续学方向）。
    public let reservedNoteCount: Int
    /// 逐卡的预约队列项——一个词的全部未学方向一起收录，故数量可能超过名额。
    public let reservations: [NewCardReservation]

    public init(
        studyDay: StudyDay,
        usedCount: Int,
        reservedNoteCount: Int,
        reservations: [NewCardReservation]
    ) {
        self.studyDay = studyDay
        self.usedCount = usedCount
        self.reservedNoteCount = reservedNoteCount
        self.reservations = reservations
    }

    public var reservedCount: Int { reservations.count }

    public var availableCount: Int {
        max(0, studyDay.newCardLimit - usedCount - reservedNoteCount)
    }
}

public enum StudyDayPlanningError: Error, Equatable, Sendable {
    case invalidTimeZone(String)
    case invalidNewCardLimit(Int)
    case invalidStudyDayBoundary
    case invalidPersistedStudyDay
}

public struct StudyDayBoundaryCalculator: Sendable {
    public static let rolloverHour = 4

    public init() {}

    public func studyDay(
        containing instant: Date,
        timeZoneID: String,
        newCardLimit: Int,
        id: UUID = UUID()
    ) throws -> StudyDay {
        guard newCardLimit >= 0 else {
            throw StudyDayPlanningError.invalidNewCardLimit(newCardLimit)
        }
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw StudyDayPlanningError.invalidTimeZone(timeZoneID)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var localDay = calendar.startOfDay(for: instant)
        let hour = calendar.component(.hour, from: instant)
        if hour < Self.rolloverHour {
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: localDay) else {
                throw StudyDayPlanningError.invalidStudyDayBoundary
            }
            localDay = previousDay
        }
        let components = calendar.dateComponents([.year, .month, .day], from: localDay)
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let startsAt = calendar.date(
                from: DateComponents(
                    timeZone: timeZone,
                    year: year,
                    month: month,
                    day: day,
                    hour: Self.rolloverHour
                )
              ),
              let endsAt = calendar.date(byAdding: .day, value: 1, to: startsAt),
              startsAt <= instant,
              instant < endsAt else {
            throw StudyDayPlanningError.invalidStudyDayBoundary
        }
        return StudyDay(
            id: id,
            localDate: String(format: "%04d-%02d-%02d", year, month, day),
            timeZoneID: timeZoneID,
            startsAt: startsAt,
            endsAt: endsAt,
            newCardLimit: newCardLimit
        )
    }

    public func nextBoundary(after instant: Date, timeZoneID: String) throws -> Date {
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw StudyDayPlanningError.invalidTimeZone(timeZoneID)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let boundary = calendar.nextDate(
            after: instant,
            matching: DateComponents(hour: Self.rolloverHour),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            throw StudyDayPlanningError.invalidStudyDayBoundary
        }
        return boundary
    }
}

public protocol StudyDayPlanningRepository: Sendable {
    func loadOrCreateSettings(defaultTimeZoneID: String) async throws -> StudyPlanningSettings
    func updateDailyNewCardLimit(_ limit: Int) async throws -> StudyPlanningSettings
    func updateLearningTimeZoneID(_ timeZoneID: String) async throws -> StudyPlanningSettings
    func updateRetentionPreset(_ preset: RetentionPreset) async throws -> StudyPlanningSettings
    func updatePrimaryDeck(_ deckID: UUID?) async throws -> StudyPlanningSettings
    func fetchStudyDay(containing instant: Date) async throws -> StudyDay?
    func fetchLatestStudyDay(endingAtOrBefore instant: Date) async throws -> StudyDay?
    func persistAndReconcileNewCards(_ studyDay: StudyDay, at instant: Date) async throws -> DailyNewCardPlan
}

public struct PrepareStudyDay: Sendable {
    private let repository: any StudyDayPlanningRepository
    private let boundaryCalculator: StudyDayBoundaryCalculator

    public init(
        repository: any StudyDayPlanningRepository,
        boundaryCalculator: StudyDayBoundaryCalculator = StudyDayBoundaryCalculator()
    ) {
        self.repository = repository
        self.boundaryCalculator = boundaryCalculator
    }

    public func callAsFunction(
        at instant: Date,
        defaultTimeZoneID: String
    ) async throws -> DailyNewCardPlan {
        let settings = try await repository.loadOrCreateSettings(
            defaultTimeZoneID: defaultTimeZoneID
        )
        if let active = try await repository.fetchStudyDay(containing: instant) {
            return try await repository.persistAndReconcileNewCards(
                active.replacingNewCardLimit(settings.dailyNewCardLimit),
                at: instant
            )
        }

        var candidate = try boundaryCalculator.studyDay(
            containing: instant,
            timeZoneID: settings.learningTimeZoneID,
            newCardLimit: settings.dailyNewCardLimit
        )
        if let previous = try await repository.fetchLatestStudyDay(endingAtOrBefore: instant),
           previous.timeZoneID != candidate.timeZoneID,
           candidate.startsAt < previous.endsAt {
            let adjustedEnd = try boundaryCalculator.nextBoundary(
                after: previous.endsAt,
                timeZoneID: candidate.timeZoneID
            )
            candidate = StudyDay(
                id: candidate.id,
                localDate: candidate.localDate,
                timeZoneID: candidate.timeZoneID,
                startsAt: previous.endsAt,
                endsAt: adjustedEnd,
                newCardLimit: candidate.newCardLimit
            )
        }
        return try await repository.persistAndReconcileNewCards(candidate, at: instant)
    }

    public func setDailyNewCardLimit(
        _ limit: Int,
        at instant: Date,
        defaultTimeZoneID: String
    ) async throws -> DailyNewCardPlan {
        guard limit >= 0 else {
            throw StudyDayPlanningError.invalidNewCardLimit(limit)
        }
        _ = try await repository.loadOrCreateSettings(defaultTimeZoneID: defaultTimeZoneID)
        _ = try await repository.updateDailyNewCardLimit(limit)
        return try await self(at: instant, defaultTimeZoneID: defaultTimeZoneID)
    }

    public func loadSettings(defaultTimeZoneID: String) async throws -> StudyPlanningSettings {
        try await repository.loadOrCreateSettings(defaultTimeZoneID: defaultTimeZoneID)
    }

    @discardableResult
    public func setLearningTimeZone(
        _ timeZoneID: String,
        defaultTimeZoneID: String
    ) async throws -> StudyPlanningSettings {
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(timeZoneID)
        }
        _ = try await repository.loadOrCreateSettings(defaultTimeZoneID: defaultTimeZoneID)
        return try await repository.updateLearningTimeZoneID(timeZoneID)
    }

    @discardableResult
    public func setRetentionPreset(
        _ preset: RetentionPreset,
        defaultTimeZoneID: String
    ) async throws -> StudyPlanningSettings {
        _ = try await repository.loadOrCreateSettings(defaultTimeZoneID: defaultTimeZoneID)
        return try await repository.updateRetentionPreset(preset)
    }

    /// 切换主牌组后立即重算当日计划：额度先满足新主牌组，剩余再轮转其他
    /// 牌组；既有未学预约按新份额让位/保留，已学额度不回退。
    @discardableResult
    public func setPrimaryDeck(
        _ deckID: UUID?,
        at instant: Date,
        defaultTimeZoneID: String
    ) async throws -> DailyNewCardPlan {
        _ = try await repository.loadOrCreateSettings(defaultTimeZoneID: defaultTimeZoneID)
        _ = try await repository.updatePrimaryDeck(deckID)
        return try await self(at: instant, defaultTimeZoneID: defaultTimeZoneID)
    }
}

extension StudyDayPlanningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidTimeZone(identifier):
            "无效的学习时区：\(identifier)"
        case let .invalidNewCardLimit(limit):
            "每日新卡数量无效：\(limit)"
        case .invalidStudyDayBoundary:
            "无法计算连续的学习日边界。"
        case .invalidPersistedStudyDay:
            "保存的学习设置或学习日无效。"
        }
    }
}
