import Foundation
import XCTest
@testable import OboeDomain

final class ContentCardServiceTests: XCTestCase {
    func testCommitRequiresDeckAndCardDirection() async throws {
        let service = ContentCardService(repository: ContentCardRepositorySpy())

        await XCTAssertThrowsErrorAsync(
            try await service.commitVocabulary(
                draftID: nil,
                deckID: nil,
                formData: VocabularyFormData(headword: "食べる", meaningZH: "吃"),
                directions: [.japaneseToChinese]
            )
        ) { error in
            XCTAssertEqual(error as? ContentCardError, .deckRequired)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.commitGrammar(
                draftID: nil,
                deckID: UUID(),
                formData: GrammarFormData(grammarForm: "～ながら", meaningZH: "一边……一边……"),
                includesDirection: false
            )
        ) { error in
            XCTAssertEqual(error as? ContentCardError, .cardDirectionRequired)
        }
    }

    func testVocabularyCommitMapsTwoDirectionsAndDeduplicatesTags() async throws {
        let repository = ContentCardRepositorySpy()
        let ids = LockedIDSequence((0..<8).map { _ in UUID() })
        let timestamp = Date(timeIntervalSince1970: 100)
        let service = ContentCardService(
            repository: repository,
            now: { timestamp },
            makeID: { ids.next() }
        )
        let deckID = UUID()

        let result = try await service.commitVocabulary(
            draftID: UUID(),
            deckID: deckID,
            formData: VocabularyFormData(headword: " 食べる ", meaningZH: " 吃 "),
            directions: [.japaneseToChinese, .chineseToJapanese],
            rawTagNames: [" N5 ", "ｎ５"]
        )

        let commit = await repository.vocabularyCommit()
        XCTAssertEqual(result.cardCount, 2)
        XCTAssertEqual(commit?.deckID, deckID)
        XCTAssertEqual(
            Set(commit?.cards.map(\.templateKind) ?? []),
            [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        XCTAssertEqual(commit?.tags.map(\.normalizedName), ["n5"])
        XCTAssertEqual(commit?.content.headword, "食べる")
        XCTAssertEqual(commit?.createdAt, timestamp)
    }

    /// T15: `.listening` maps to `vocabulary_listening` and all three
    /// directions commit through the same vocabulary card path.
    func testVocabularyCommitMapsListeningDirection() async throws {
        let repository = ContentCardRepositorySpy()
        let service = ContentCardService(repository: repository)

        let result = try await service.commitVocabulary(
            draftID: nil,
            deckID: UUID(),
            formData: VocabularyFormData(headword: "聞く", meaningZH: "听"),
            directions: [.japaneseToChinese, .chineseToJapanese, .listening]
        )

        XCTAssertEqual(result.cardCount, 3)
        let commit = await repository.vocabularyCommit()
        XCTAssertEqual(
            commit?.cards.map(\.templateKind),
            [.vocabularyJapaneseToChinese, .vocabularyListening, .vocabularyChineseToJapanese],
            "seeds stay sorted by template raw value"
        )
        XCTAssertEqual(VocabularyCardDirection.listening.templateKind, .vocabularyListening)
    }

    /// T15: a listening seed is a vocabulary template — it can never land on
    /// a grammar note, and a grammar template can never land on a vocabulary
    /// note. The service rejects before any repository write.
    func testReplaceDirectionsRejectsTemplatesOutsideNoteKind() async throws {
        let service = ContentCardService(repository: ContentCardRepositorySpy())

        await XCTAssertThrowsErrorAsync(
            try await service.replaceEnabledCardDirections(
                noteID: UUID(),
                kind: .grammar,
                enabledTemplates: [.vocabularyListening]
            )
        ) { error in
            XCTAssertEqual(error as? ContentCardError, .invalidTemplateForKnowledgePoint)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.replaceEnabledCardDirections(
                noteID: UUID(),
                kind: .vocabulary,
                enabledTemplates: [.grammarFormToExplanation]
            )
        ) { error in
            XCTAssertEqual(error as? ContentCardError, .invalidTemplateForKnowledgePoint)
        }
    }

    func testSingleCardCommandsDelegateToRepository() async throws {
        let repository = ContentCardRepositorySpy()
        let timestamp = Date(timeIntervalSince1970: 100)
        let service = ContentCardService(repository: repository, now: { timestamp })
        let cardID = UUID()

        let suspended = try await service.setCardEnabled(cardID: cardID, isEnabled: false)
        let toggle = await repository.toggleCall()
        XCTAssertEqual(toggle?.cardID, cardID)
        XCTAssertEqual(toggle?.isEnabled, false)
        XCTAssertEqual(toggle?.at, timestamp)
        XCTAssertEqual(suspended.isEnabled, false)

        try await service.deleteCard(cardID: cardID)
        let deleted = await repository.deletedCardID()
        XCTAssertEqual(deleted, cardID)
    }
}

private actor ContentCardRepositorySpy: ContentCardRepository {
    private var capturedVocabulary: VocabularyContentCommit?
    private var capturedToggle: (cardID: UUID, isEnabled: Bool, at: Date)?
    private var capturedDelete: UUID?

    func commitVocabulary(
        _ commit: VocabularyContentCommit,
        capture: CaptureCommitContext?
    ) async throws -> ContentCommitResult {
        capturedVocabulary = commit
        return ContentCommitResult(noteID: commit.noteID, cardCount: commit.cards.count)
    }

    func commitGrammar(
        _ commit: GrammarContentCommit,
        capture: CaptureCommitContext?
    ) async throws -> ContentCommitResult {
        ContentCommitResult(noteID: commit.noteID, cardCount: 1)
    }

    func fetchCardDirections(noteID: UUID) async throws -> [CardDirectionState] {
        []
    }

    func replaceEnabledCardDirections(
        _ replacement: CardDirectionReplacement
    ) async throws -> [CardDirectionState] {
        []
    }

    func setCardEnabled(
        cardID: UUID,
        isEnabled: Bool,
        at updatedAt: Date
    ) async throws -> CardDirectionState {
        capturedToggle = (cardID, isEnabled, updatedAt)
        return CardDirectionState(
            cardID: cardID,
            templateKind: .vocabularyJapaneseToChinese,
            isEnabled: isEnabled
        )
    }

    func deleteCard(cardID: UUID) async throws {
        capturedDelete = cardID
    }

    func vocabularyCommit() -> VocabularyContentCommit? {
        capturedVocabulary
    }

    func toggleCall() -> (cardID: UUID, isEnabled: Bool, at: Date)? {
        capturedToggle
    }

    func deletedCardID() -> UUID? {
        capturedDelete
    }
}

private final class LockedIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID]

    init(_ ids: [UUID]) {
        self.ids = ids
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return ids.removeFirst()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown")
    } catch {
        errorHandler(error)
    }
}
