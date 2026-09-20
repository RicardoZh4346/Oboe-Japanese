import Foundation

/// Minimal input contract for the sibling-separation selection policy
/// (design §9.1). The caller is responsible for scope filtering, due
/// eligibility, suspension and session-skip removal — the policy treats its
/// input as authoritative, never reads persistence and never mutates cards.
public protocol SiblingSelectionCandidate {
    var cardID: UUID { get }
    var noteID: UUID { get }
}

/// Pure sibling-separation selection over an already-ordered candidate list.
///
/// Callers carry two pieces of session state across invocations:
/// - `lastPresentedNoteID`: the note whose question face was actually shown
///   last. Set only when a card is truly presented — a load-skip, undo or
///   preview refresh does not count (§9.2).
/// - `deferredCardID`: the "separation debt" — the card that yielded its turn
///   to a spacer once and is owed the next non-conflicting presentation.
///
/// A conflicted `first` is deferred at most once: while a debt is pending,
/// the next same-note conflict presents `first` anyway and clears the debt,
/// so due learning/relearning cards cannot starve behind spacers.
public enum SiblingSelectionPolicy {

    public struct Selection<Candidate: SiblingSelectionCandidate> {
        /// The card to present next. Always a member of the input list.
        public let selected: Candidate
        /// Debt state to feed back into the next call. `nil` means no card
        /// is currently owed a turn.
        public let deferredCardID: UUID?
        /// Whether this call inserted a spacer — i.e. the selected card is
        /// not the queue's first candidate. Purely informational for the
        /// caller; derivable but convenient.
        public let insertedSpacer: Bool
    }

    public static func selectNext<Candidate: SiblingSelectionCandidate>(
        among candidates: [Candidate],
        lastPresentedNoteID: UUID?,
        deferredCardID: UUID?
    ) -> Selection<Candidate>? {
        guard let first = candidates.first else { return nil }

        // A debt only counts while the deferred card is still a candidate —
        // a card that left the queue (rated elsewhere, suspended, scope
        // change) is owed nothing, and a stale debt must not block future
        // deferrals.
        let outstandingDebt = deferredCardID.flatMap { id in
            candidates.contains(where: { $0.cardID == id }) ? id : nil
        }

        if first.noteID != lastPresentedNoteID {
            // Natural pick. Presenting the debt card itself repays the debt;
            // a different first card leaves it pending for its own turn.
            let repaid = first.cardID == outstandingDebt
            return Selection(
                selected: first,
                deferredCardID: repaid ? nil : outstandingDebt,
                insertedSpacer: false
            )
        }

        if outstandingDebt == nil,
           let spacer = candidates.first(where: { $0.noteID != first.noteID }) {
            // One deferral in flight: `first` is owed the next turn.
            return Selection(
                selected: spacer,
                deferredCardID: first.cardID,
                insertedSpacer: true
            )
        }

        // No alternate note, or a debt is already pending — present the
        // conflicted card anyway and consume the debt.
        return Selection(selected: first, deferredCardID: nil, insertedSpacer: false)
    }
}

extension TodayQueueItem: SiblingSelectionCandidate {}
