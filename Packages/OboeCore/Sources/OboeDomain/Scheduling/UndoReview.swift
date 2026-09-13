import Foundation

public struct UndoReviewRequest: Equatable, Sendable {
    public let eventID: UUID
    public let studyDay: StudyDayContext

    public init(eventID: UUID, studyDay: StudyDayContext) {
        self.eventID = eventID
        self.studyDay = studyDay
    }
}

public protocol ReviewUndoRepository: Sendable {
    func commitUndo(_ request: UndoReviewRequest, undoneAt: Date) async throws -> ReviewLogRecord
}

public enum UndoReviewError: Error, Equatable, Sendable {
    case reviewNotFound
    case alreadyUndone
    case studyDayMismatch
    case studyDayNotActive
    case cardNotFound
    case cardDisabled
    case cardNotInStudyPlan
    case subsequentReviewExists
    case stateConflict
}

public struct UndoReview: Sendable {
    private let repository: any ReviewUndoRepository
    private let clock: any SchedulingClock

    public init(
        repository: any ReviewUndoRepository,
        clock: any SchedulingClock = SystemSchedulingClock()
    ) {
        self.repository = repository
        self.clock = clock
    }

    public func callAsFunction(_ request: UndoReviewRequest) async throws -> ReviewLogRecord {
        try await repository.commitUndo(request, undoneAt: clock.now())
    }
}
