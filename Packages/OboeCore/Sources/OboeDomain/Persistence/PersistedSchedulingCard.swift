import Foundation

public enum CardTemplateKind: String, CaseIterable, Codable, Hashable, Sendable {
    case vocabularyJapaneseToChinese = "vocabulary_ja_zh"
    case vocabularyChineseToJapanese = "vocabulary_zh_ja"
    case vocabularyListening = "vocabulary_listening"
    case grammarFormToExplanation = "grammar_form_explanation"

    /// 同一 Note 的方向卡在队列里的固定顺序：日→中、中→日、听力
    /// （从易到难——新词先认形再回忆最后辨音）。非方向模板返回 0。
    public var directionQueueRank: Int {
        switch self {
        case .vocabularyJapaneseToChinese: 0
        case .vocabularyChineseToJapanese: 1
        case .vocabularyListening: 2
        case .grammarFormToExplanation: 0
        }
    }
}

public struct PersistedSchedulingCard: Codable, Equatable, Sendable {
    public let id: UUID
    public let noteID: UUID
    public let templateKind: CardTemplateKind
    public let isEnabled: Bool
    public let scheduling: SchedulingCard
    public let firstStudiedAt: Date?
    public let stateVersion: Int
    public let algorithmVersion: String
    public let profileID: UUID

    public init(
        id: UUID,
        noteID: UUID,
        templateKind: CardTemplateKind,
        isEnabled: Bool,
        scheduling: SchedulingCard,
        firstStudiedAt: Date?,
        stateVersion: Int,
        algorithmVersion: String,
        profileID: UUID
    ) {
        self.id = id
        self.noteID = noteID
        self.templateKind = templateKind
        self.isEnabled = isEnabled
        self.scheduling = scheduling
        self.firstStudiedAt = firstStudiedAt
        self.stateVersion = stateVersion
        self.algorithmVersion = algorithmVersion
        self.profileID = profileID
    }
}

public protocol SchedulingCardRepository: Sendable {
    func fetchCard(id: UUID) async throws -> PersistedSchedulingCard?
    func saveCard(_ card: PersistedSchedulingCard) async throws
}

public protocol NoteRepository: Sendable {
    func noteExists(id: UUID) async throws -> Bool
}
