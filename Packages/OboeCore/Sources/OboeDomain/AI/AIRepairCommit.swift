import CryptoKit
import Foundation

/// The user-confirmed in-place repair payload (设计 §6.3, T08): exactly what
/// the user saw in the preview when they tapped adopt — which suggestion,
/// its effective content (the edited candidate when present) and the note
/// version it was previewed against. Hashed into the commit receipt so a
/// retried operation can be recognized or rejected as a different payload.
public struct AIRepairConfirmedMutation: Codable, Equatable, Sendable {
    public var suggestionIndex: Int
    public var suggestion: AIRepairSuggestion
    public var expectedContentVersion: Int

    public init(
        suggestionIndex: Int,
        suggestion: AIRepairSuggestion,
        expectedContentVersion: Int
    ) {
        self.suggestionIndex = suggestionIndex
        self.suggestion = suggestion
        self.expectedContentVersion = expectedContentVersion
    }

    /// Lowercase SHA-256 hex over the canonical JSON encoding — `.sortedKeys`
    /// makes the bytes deterministic across launches and devices.
    public func payloadHash() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One new Note's complete write plan inside a confirmed split (设计 §6.5):
/// the directions the user picked plus the identifiers the commit will
/// write. Every id is derived deterministically from the operation id, so a
/// retried commit rebuilds byte-identical plans — the payload hash stays
/// stable and a retry can never mint second-generation rows.
public struct AIRepairSplitNotePlan: Codable, Equatable, Sendable {
    public var noteID: UUID
    public var exampleID: UUID
    public var schedulerProfileID: UUID
    /// `cardIDs[i]` belongs to `templateKinds[i]`; both are sorted by
    /// template raw value so equivalent user selections hash identically.
    public var templateKinds: [CardTemplateKind]
    public var cardIDs: [UUID]

    public init(
        noteID: UUID,
        exampleID: UUID,
        schedulerProfileID: UUID,
        templateKinds: [CardTemplateKind],
        cardIDs: [UUID]
    ) {
        self.noteID = noteID
        self.exampleID = exampleID
        self.schedulerProfileID = schedulerProfileID
        self.templateKinds = templateKinds
        self.cardIDs = cardIDs
    }
}

/// The user-confirmed split payload (设计 §6.5, T09): which suggestion, the
/// deck and per-candidate directions the user picked, the required
/// original-card disposition, the direction snapshot the preview anchored
/// on and the stable pre-generated ID set — everything the atomic split
/// transaction writes, hashed into the commit receipt for idempotent
/// replay/conflict detection exactly like the in-place mutation.
public struct AIRepairSplitConfirmedMutation: Codable, Equatable, Sendable {
    public var suggestionIndex: Int
    public var suggestion: AIRepairSuggestion
    public var expectedContentVersion: Int
    /// Sorted template kinds present on the target Note at preview time —
    /// a direction change since then must force a re-preview, never a
    /// silent commit over it.
    public var expectedTemplateKinds: [CardTemplateKind]
    public var deckID: UUID
    public var originalCardDisposition: AIRepairOriginalCardDisposition
    /// Parallel to `suggestion.splitNotes` — plan[i] writes candidate[i].
    public var plans: [AIRepairSplitNotePlan]

    public init(
        suggestionIndex: Int,
        suggestion: AIRepairSuggestion,
        expectedContentVersion: Int,
        expectedTemplateKinds: [CardTemplateKind],
        deckID: UUID,
        originalCardDisposition: AIRepairOriginalCardDisposition,
        plans: [AIRepairSplitNotePlan]
    ) {
        self.suggestionIndex = suggestionIndex
        self.suggestion = suggestion
        self.expectedContentVersion = expectedContentVersion
        self.expectedTemplateKinds = expectedTemplateKinds
        self.deckID = deckID
        self.originalCardDisposition = originalCardDisposition
        self.plans = plans
    }

    /// Deterministic plans for `directions` (parallel to `candidates`):
    /// identifiers derive from `operationID` so a retry of the same
    /// operation always proposes the same IDs (设计 §6.5 稳定 ID).
    public static func makePlans(
        operationID: UUID,
        directions: [[CardTemplateKind]]
    ) -> [AIRepairSplitNotePlan] {
        directions.enumerated().map { index, kinds in
            let sorted = kinds.sorted { $0.rawValue < $1.rawValue }
            return AIRepairSplitNotePlan(
                noteID: deriveID(operationID: operationID, role: "note", index: index),
                exampleID: deriveID(operationID: operationID, role: "example", index: index),
                schedulerProfileID: deriveID(
                    operationID: operationID,
                    role: "profile",
                    index: index
                ),
                templateKinds: sorted,
                cardIDs: sorted.enumerated().map { cardIndex, _ in
                    deriveID(
                        operationID: operationID,
                        role: "card-\(index)",
                        index: cardIndex
                    )
                }
            )
        }
    }

    /// Lowercase SHA-256 hex over the canonical JSON encoding — `.sortedKeys`
    /// makes the bytes deterministic across launches and devices.
    public func payloadHash() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// UUID-v4-shaped value derived from `operationID` + role + index —
    /// deterministic across retries of the same operation.
    private static func deriveID(operationID: UUID, role: String, index: Int) -> UUID {
        var bytes = Array(
            SHA256.hash(data: Data(
                "\(operationID.uuidString):\(role):\(index)".utf8
            )).prefix(16)
        )
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// The resolved write one split candidate produces — the validated content
/// (same types the note editor persists) plus the plan's stable IDs.
public struct AIRepairSplitNoteCommit: Equatable, Sendable {
    public var noteID: UUID
    public var exampleID: UUID
    public var deckID: UUID
    public var content: AIRepairValidatedContent
    public var cards: [NewCardSeed]
    public var schedulerProfileID: UUID
    public var createdAt: Date

    public init(
        noteID: UUID,
        exampleID: UUID,
        deckID: UUID,
        content: AIRepairValidatedContent,
        cards: [NewCardSeed],
        schedulerProfileID: UUID,
        createdAt: Date
    ) {
        self.noteID = noteID
        self.exampleID = exampleID
        self.deckID = deckID
        self.content = content
        self.cards = cards
        self.schedulerProfileID = schedulerProfileID
        self.createdAt = createdAt
    }
}

public enum AIRepairCommitError: Error, Equatable, Sendable {
    case draftNotFound
    /// Target Note/Card no longer resolves — the draft stays readable but
    /// can never be adopted.
    case targetUnavailable
    /// The draft's phase cannot enter a commit (`editing`/`analyzing` have
    /// nothing to adopt; `committed` is handled by the replay path).
    case notCommittable(AIRepairDraftPhase)
    /// No suggestion exists at the requested index and no edited candidate
    /// was stored.
    case suggestionUnavailable
    /// `split_card` suggestions commit through the split transaction (T09),
    /// never through the in-place repair path.
    case splitRequiresSplitCommit
    /// The split commit path only accepts `split_card` suggestions.
    case notSplitSuggestion
    /// The split plan failed validation — empty/duplicated directions or a
    /// template that does not match the candidate's note kind. Raised before
    /// the transaction so an invalid selection never reaches the database.
    case invalidSplitPlan(String)
    /// The note's `content_version` moved since the draft was snapshotted —
    /// a manual edit happened during preview, so adopting would overwrite
    /// user work and is refused.
    case contentConflict
    /// The operation already committed a different payload (receipt hash
    /// mismatch) — the caller must not reinterpret the receipt as theirs.
    case operationConflict
}

extension AIRepairCommitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .draftNotFound: "修卡草稿不存在。"
        case .targetUnavailable: "目标卡片或笔记已被删除，无法采用建议。"
        case let .notCommittable(phase): "当前修卡状态（\(phase.rawValue)）不能采用建议。"
        case .suggestionUnavailable: "这条建议已不可用。"
        case .splitRequiresSplitCommit: "拆卡建议需要走拆卡确认流程。"
        case .notSplitSuggestion: "该建议不是拆卡建议。"
        case let .invalidSplitPlan(reason): "拆卡方案无效：\(reason)"
        case .contentConflict: "卡片内容或学习方向在预览期间被修改，请重新预览后再试。"
        case .operationConflict: "本次提交与已完成的提交不一致，已被拒绝。"
        }
    }
}

/// The atomic write side of an in-place repair commit (设计 §6.3). One
/// transaction performs all of: the content-version-guarded note update,
/// the primary-example/index sync, and the draft's `committed` phase +
/// receipt persistence. Any failure — including the receipt write — rolls
/// everything back, so the database only ever sees "untouched" or "fully
/// committed".
public protocol AIRepairCommitStore: Sendable {
    /// Applies `content` to `envelope.targetNoteID` guarded by
    /// `envelope.expectedContentVersion` and persists `envelope` (which must
    /// already carry `.committed` + `commitReceipt`) in the same
    /// transaction. Throws `AIRepairCommitError.contentConflict` when the
    /// note version moved, `draftNotFound` when the draft row vanished.
    func commitInPlaceRepair(
        draftID: UUID,
        envelope: AIRepairDraftEnvelope,
        provenance: AIRepairDraftProvenance,
        content: AIRepairValidatedContent,
        newExampleID: UUID,
        updatedAt: Date
    ) async throws

    /// The atomic write side of a confirmed split (设计 §6.5, T09). One
    /// `pool.write` performs ALL of: target Note/Card existence +
    /// `content_version` + direction-snapshot guards, deck check, every new
    /// Note/Example/Card insert (`origin=ai`, `source_ref`/`source_text`
    /// NULL, cards in New state with the existing profile-selection flow),
    /// the original card's disposition (`keep`/`pause`/`delete`) and the
    /// draft's `committed` + receipt upsert. Any failure — including a
    /// later candidate's insert or the receipt write — rolls everything
    /// back; no partial split can ever persist.
    func commitSplitRepair(
        draftID: UUID,
        envelope: AIRepairDraftEnvelope,
        provenance: AIRepairDraftProvenance,
        commits: [AIRepairSplitNoteCommit],
        originalCardDisposition: AIRepairOriginalCardDisposition,
        updatedAt: Date
    ) async throws
}
