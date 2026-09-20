import Foundation

public enum RecallMode: Equatable, Sendable {
    case revealOnly
    case typedJapanese

    public static func resolve(
        template: CardTemplateKind,
        preferences: AdaptivePreferences
    ) -> RecallMode {
        switch template {
        case .vocabularyChineseToJapanese:
            preferences.typedAnswerChineseToJapanese ? .typedJapanese : .revealOnly
        case .vocabularyListening:
            preferences.typedAnswerListening ? .typedJapanese : .revealOnly
        case .vocabularyJapaneseToChinese, .grammarFormToExplanation:
            .revealOnly
        }
    }
}

public enum RecallPhase: Equatable, Sendable {
    case question
    case answer
    case submitting
}

/// String comparison is feedback only; it never selects a review rating.
public enum RecallComparison: Equatable, Sendable {
    case matched
    case close
    case different
}

/// A presentation-local attempt, deliberately neither Codable nor a repository
/// model. Confirming input has no scheduling, logging, or persistence effects.
/// Create a new value for each next-card presentation (even for the same card).
public struct RecallAttempt: Equatable, Sendable {
    public let cardID: UUID
    public let mode: RecallMode
    public private(set) var contentVersion: Int
    public private(set) var phase: RecallPhase = .question
    public private(set) var rawInput = ""
    public private(set) var comparison: RecallComparison?
    /// Supplied only by the explicit rating action. The caller retains its
    /// PendingSubmission payload, including rating and duration, for retries.
    public private(set) var pendingEventID: UUID?

    public init(
        cardID: UUID,
        contentVersion: Int,
        template: CardTemplateKind,
        preferences: AdaptivePreferences
    ) {
        self.cardID = cardID
        self.contentVersion = contentVersion
        self.mode = RecallMode.resolve(template: template, preferences: preferences)
    }

    public var canConfirm: Bool {
        phase == .question && (mode == .revealOnly
            || !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @discardableResult
    public mutating func updateInput(_ input: String) -> Bool {
        guard phase == .question, mode == .typedJapanese else { return false }
        rawInput = input
        return true
    }

    /// Return and the confirmation button share this action. The UI must finish
    /// IME marked text before calling it. Preserve the original input for display.
    @discardableResult
    public mutating func confirmInput(comparison: RecallComparison? = nil) -> Bool {
        guard canConfirm else { return false }
        self.comparison = mode == .typedJapanese ? comparison : nil
        phase = .answer
        return true
    }

    /// This transition does not submit a review. Only the existing SubmitReview
    /// use case may write a ReviewLog. A failed request must reuse its event ID.
    @discardableResult
    public mutating func beginSubmission(eventID: UUID) -> Bool {
        guard phase == .answer,
              pendingEventID == nil || pendingEventID == eventID else { return false }
        pendingEventID = eventID
        phase = .submitting
        return true
    }

    @discardableResult
    public mutating func submissionFailed(eventID: UUID) -> Bool {
        guard phase == .submitting, pendingEventID == eventID else { return false }
        phase = .answer
        return true
    }

    /// An ordinary refresh with unchanged content preserves the attempt. A
    /// content edit resets it without adopting settings changed mid-presentation.
    public mutating func reloadContent(version: Int) {
        guard contentVersion != version else { return }
        contentVersion = version
        restart()
    }

    /// Explicit reload after undo also clears an attempt with unchanged content.
    public mutating func restart() {
        phase = .question
        rawInput = ""
        comparison = nil
        pendingEventID = nil
    }
}
