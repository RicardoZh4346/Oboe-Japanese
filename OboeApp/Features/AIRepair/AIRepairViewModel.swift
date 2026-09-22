import Foundation
import OboeDomain
import Observation

/// Drives the AI repair screen (T07): the draft is the single source of
/// truth — reopening the page restores the user's explanation and any
/// suggested response, cancellation marks the in-flight request stale, and
/// every failure leaves the draft retryable. Nothing here ever writes a
/// Note or Card; adopting a suggestion is T08's transaction.
@MainActor
@Observable
final class AIRepairViewModel {
    private let service: AIRepairService
    private let deckService: DeckManagementService?
    let cardID: UUID

    private(set) var draftID: UUID?
    private(set) var envelope: AIRepairDraftEnvelope?
    private(set) var previews: [AIRepairSuggestionPreview] = []
    private(set) var editedPreview: AIRepairSuggestionPreview?
    private(set) var previewNote: AIRepairNoteSnapshot?
    /// T09 split preview: decks for the new-note deck picker and the target
    /// note's own deck (the default selection, 设计 §6.5 同牌组默认).
    private(set) var decks: [DeckSummary] = []
    private(set) var targetDeckID: UUID?
    private(set) var isLoading = true
    private(set) var isAnalyzing = false
    private(set) var isCommitting = false
    private(set) var loadErrorMessage: String?
    var analysisErrorMessage: String?
    var commitErrorMessage: String?
    var comment = ""
    /// Fired once a suggestion commit lands — callers re-present the card
    /// (review resets the revealed answer back to the question face).
    var onCommitted: (() async -> Void)?

    private var analysisTask: Task<Void, Never>?
    /// Distinguishes a user-cancelled request's late `staleResponse` error
    /// from a genuine superseded one — the former needs no error banner.
    private var userCancelled = false

    init(
        service: AIRepairService,
        cardID: UUID,
        deckService: DeckManagementService? = nil,
        onCommitted: (() async -> Void)? = nil
    ) {
        self.service = service
        self.cardID = cardID
        self.deckService = deckService
        self.onCommitted = onCommitted
    }

    var phase: AIRepairDraftPhase? {
        envelope?.phase
    }

    var isBlocked: Bool {
        envelope?.adoptionBlocked == true
    }

    var showsAnalyzingState: Bool {
        isAnalyzing || phase == .analyzing
    }

    var canAnalyze: Bool {
        guard !isAnalyzing, !isBlocked else { return false }
        return phase?.canAnalyze ?? false
    }

    var commentIsOverLimit: Bool {
        comment.utf16.count > AIRepairRequestEncoder.maximumUserCommentLength
    }

    /// Response content stays readable from `suggested` through `committed`
    /// — previewing and the post-commit state still show the suggestions.
    private var showsResponse: Bool {
        phase == .suggested || phase == .previewing || phase == .committed
    }

    var suggestions: [AIRepairSuggestion] {
        guard showsResponse else { return [] }
        return envelope?.response?.suggestions ?? []
    }

    var responseSummary: String? {
        guard showsResponse else { return nil }
        return envelope?.response?.summary
    }

    var problemTypes: [AIRepairProblemType] {
        guard showsResponse else { return [] }
        return envelope?.response?.problemTypes ?? []
    }

    var editedCandidate: AIRepairSuggestion? {
        envelope?.editedCandidate
    }

    var isCommitted: Bool {
        phase == .committed
    }

    /// Suggestions list visibility — shown while browsing candidates and
    /// kept after commit so the adopted state stays reviewable.
    var showsSuggestions: Bool {
        showsResponse && (!suggestions.isEmpty || editedCandidate != nil)
    }

    var committedReceipt: AIRepairCommitReceipt? {
        envelope?.commitReceipt
    }

    /// A commit may start from the response phases only — `.committing` is
    /// excluded here (the button disables itself via `isCommitting`) but the
    /// service still owns the retry path for an interrupted attempt.
    var canCommit: Bool {
        guard !isCommitting, !isBlocked else { return false }
        return phase == .suggested || phase == .previewing
    }

    /// Preview for a suggestion row — nil when the response predates this
    /// build or preview validation fails (the row stays readable either way).
    func preview(for suggestion: AIRepairSuggestion) -> AIRepairSuggestionPreview? {
        previews.first(where: {
            $0.title == suggestion.title && $0.type == suggestion.type
        })
    }

    // MARK: - Lifecycle

    /// Opens (or resumes) the draft for this card. Re-entering the page
    /// restores the persisted explanation and suggested response — the
    /// resume guarantee behind "返回再进入说明仍在".
    func load() async {
        isLoading = true
        loadErrorMessage = nil
        do {
            let (id, envelope) = try await service.prepareDraft(cardID: cardID)
            draftID = id
            applyEnvelope(envelope, resettingComment: comment.isEmpty)
            // Split preview context: the target deck defaults the picker;
            // a fetch failure leaves the picker hidden and the default
            // still committable — never blocks the repair page.
            targetDeckID = try? await service.targetDeckID(draftID: id)
            if let deckService {
                decks = (try? await deckService.fetchDecks()) ?? []
            }
            await rebuildPreviews()
        } catch is CancellationError {
            isLoading = false
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Latest comment text is persisted before it can ever reach a request —
    /// called on submit, on disappear and ahead of every analysis.
    func persistComment() async {
        guard let draftID, let envelope,
              envelope.phase != .committed, envelope.phase != .committing,
              comment != envelope.userComment else { return }
        do {
            try await service.updateUserComment(draftID: draftID, comment: comment)
            self.envelope?.userComment = comment
        } catch {
            // Comment persistence failing must not break the page; the next
            // persist attempt or the analyze preflight retries it.
        }
    }

    // MARK: - Analysis

    /// Explicit user trigger only — no auto-analysis on load. The comment is
    /// persisted first so the request and the draft can never disagree.
    func analyze() {
        guard canAnalyze, !commentIsOverLimit, let draftID else { return }
        isAnalyzing = true
        userCancelled = false
        analysisErrorMessage = nil
        analysisTask = Task {
            defer { isAnalyzing = false }
            do {
                try await service.updateUserComment(draftID: draftID, comment: comment)
                let updated = try await service.analyze(
                    draftID: draftID,
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
                applyEnvelope(updated, resettingComment: false)
                await rebuildPreviews()
            } catch is CancellationError {
                await reloadDraft()
            } catch {
                await reloadDraft()
                if !(userCancelled && error is AIRepairServiceError) {
                    analysisErrorMessage = error.localizedDescription
                }
            }
        }
    }

    /// User-initiated cancel: the in-flight response becomes stale and can
    /// never overwrite the draft; the card is untouched by construction.
    func cancelAnalysis() {
        userCancelled = true
        Task { await service.cancelAnalysis() }
    }

    /// Target deleted/disabled drafts stay open for reading and manual
    /// copying but can never be analyzed or adopted.
    func discardDraft() async {
        guard let draftID else { return }
        try? await service.discardDraft(id: draftID)
    }

    // MARK: - Preview & commit (T08)

    /// Records that the user opened a suggestion preview — read-only phase
    /// change, `.suggested`/`.previewing` round-trip freely.
    func notePreviewing() async {
        guard let draftID, phase == .suggested else { return }
        try? await service.markPreviewing(draftID: draftID)
        await reloadDraft()
    }

    /// Persists the user's hand-edited candidate; the edited row then adopts
    /// through the same guarded commit as a decoded suggestion.
    func saveEditedCandidate(_ suggestion: AIRepairSuggestion?) async -> Bool {
        guard let draftID else { return false }
        do {
            try await service.updateEditedCandidate(draftID: draftID, candidate: suggestion)
            await reloadDraft()
            return true
        } catch {
            commitErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Adopts one in-place suggestion through the service's guarded,
    /// atomic commit. Safe to retry after a failure — the operation id and
    /// payload hash make a repeated call either replay the stored receipt
    /// or reject honestly.
    func adoptSuggestion(at index: Int, edited: Bool) async -> Bool {
        guard canCommit, let draftID else { return false }
        isCommitting = true
        commitErrorMessage = nil
        defer { isCommitting = false }
        do {
            _ = try await service.commitInPlaceRepair(
                draftID: draftID,
                suggestionIndex: index,
                adoptingEditedCandidate: edited
            )
            await reloadDraft()
            await onCommitted?()
            return true
        } catch {
            commitErrorMessage = error.localizedDescription
            await reloadDraft()
            return false
        }
    }

    /// Adopts one `split_card` suggestion (T09): per-candidate directions,
    /// one shared deck and the required original-card disposition go through
    /// the same guarded single-transaction commit — identical idempotency
    /// semantics to `adoptSuggestion`.
    func adoptSplitSuggestion(
        at index: Int,
        edited: Bool,
        deckID: UUID,
        deckIDs: Set<UUID>? = nil,
        directions: [[CardTemplateKind]],
        disposition: AIRepairOriginalCardDisposition
    ) async -> Bool {
        guard canCommit, let draftID else { return false }
        isCommitting = true
        commitErrorMessage = nil
        defer { isCommitting = false }
        do {
            _ = try await service.commitSplitRepair(
                draftID: draftID,
                suggestionIndex: index,
                adoptingEditedCandidate: edited,
                deckID: deckID,
                deckIDs: deckIDs,
                directions: directions,
                originalCardDisposition: disposition
            )
            await reloadDraft()
            await onCommitted?()
            return true
        } catch {
            commitErrorMessage = error.localizedDescription
            await reloadDraft()
            return false
        }
    }

    // MARK: - Private

    private func applyEnvelope(_ envelope: AIRepairDraftEnvelope, resettingComment: Bool) {
        self.envelope = envelope
        if resettingComment || comment.isEmpty {
            comment = envelope.userComment
        }
    }

    private func reloadDraft() async {
        guard let draftID else { return }
        if let fresh = try? await service.loadDraft(id: draftID) {
            applyEnvelope(fresh, resettingComment: false)
            await rebuildPreviews()
        }
    }

    /// Builds the read-only previews the suggestion rows navigate to. A
    /// preview failure (e.g. grammar-inapplicable field) never hides the
    /// suggestion — the row simply shows its title/reason without diffs.
    private func rebuildPreviews() async {
        guard let draftID,
              let envelope, showsResponse,
              let response = envelope.response else {
            previews = []
            editedPreview = nil
            previewNote = nil
            return
        }
        do {
            let note = try await service.previewNoteSnapshot(draftID: draftID)
            previewNote = note
            previews = (try? AIRepairPreviewBuilder.previews(
                for: response,
                note: note
            )) ?? []
            editedPreview = envelope.editedCandidate.flatMap {
                try? AIRepairPreviewBuilder.preview($0, index: -1, note: note)
            }
        } catch {
            previewNote = nil
            previews = []
            editedPreview = nil
        }
    }
}
