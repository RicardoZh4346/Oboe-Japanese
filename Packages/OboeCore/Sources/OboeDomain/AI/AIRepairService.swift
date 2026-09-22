import Foundation

/// Non-secret provenance columns stored on the `drafts` row for diagnostics —
/// never credentials, endpoints or keys (设计 §6.3).
public struct AIRepairDraftProvenance: Equatable, Sendable {
    public let providerID: String?
    public let modelID: String?
    public let promptVersion: String?

    public init(providerID: String?, modelID: String?, promptVersion: String?) {
        self.providerID = providerID
        self.modelID = modelID
        self.promptVersion = promptVersion
    }

    public init(configuration: AIConfiguration) {
        self.init(
            providerID: configuration.serviceKind.rawValue,
            modelID: configuration.modelID,
            promptVersion: AIRepairPromptV2.promptVersion
        )
    }
}

/// Persistence boundary for `draft_kind = 'ai_repair'` rows (设计 §6.3).
public protocol AIRepairDraftStore: Sendable {
    func saveDraft(
        id: UUID,
        envelope: AIRepairDraftEnvelope,
        provenance: AIRepairDraftProvenance,
        updatedAt: Date
    ) async throws
    func fetchDraft(id: UUID) async throws -> AIRepairDraftEnvelope?
    /// Every stored `ai_repair` envelope with its row id — draft counts are
    /// small, so target/operation lookups filter in memory rather than
    /// reaching into payload JSON from SQL.
    func fetchAllDrafts() async throws -> [(id: UUID, envelope: AIRepairDraftEnvelope)]
    func deleteDraft(id: UUID) async throws
}

public enum AIRepairServiceError: Error, Equatable, Sendable {
    case draftNotFound
    /// Target Note/Card no longer resolves — the draft stays readable but
    /// can never be adopted.
    case targetUnavailable
    /// The draft is in a phase that cannot start a new analysis
    /// (`committing`/`committed`).
    case draftNotAnalyzable(AIRepairDraftPhase)
    /// A newer request already owns this draft — the late response is dropped.
    case staleResponse
}

extension AIRepairServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .draftNotFound: "修卡草稿不存在。"
        case .targetUnavailable: "目标卡片或笔记已被删除，无法继续修卡。"
        case let .draftNotAnalyzable(phase): "当前修卡状态（\(phase.rawValue)）不能发起分析。"
        case .staleResponse: "较早的修卡响应已失效。"
        }
    }
}

/// Coordinates the AI repair analysis flow (设计 §6.3): the draft's user
/// input is persisted before any request leaves the device, at most one
/// analysis runs at a time, and every failure returns the draft to the
/// retryable `editing` phase. No automatic retries and no Note/Card writes
/// ever happen here.
public actor AIRepairService {
    private let draftStore: any AIRepairDraftStore
    private let commitStore: any AIRepairCommitStore
    private let configurationRepository: any AIConfigurationRepository
    private let credentialStore: any AICredentialStore
    private let client: any AIRepairClient
    private let vocabularyRepository: any VocabularyRepository
    private let grammarRepository: any GrammarRepository
    private let contentCardRepository: any ContentCardRepository
    private let adaptiveCardService: AdaptiveCardService
    private let clock: @Sendable () -> Date

    private var gate = AIGenerationRequestGate()
    /// The draft the in-flight request belongs to — a response for any other
    /// draft, or any older generation of this one, is stale.
    private var activeDraftID: UUID?

    public init(
        draftStore: any AIRepairDraftStore,
        commitStore: any AIRepairCommitStore,
        configurationRepository: any AIConfigurationRepository,
        credentialStore: any AICredentialStore,
        client: any AIRepairClient,
        vocabularyRepository: any VocabularyRepository,
        grammarRepository: any GrammarRepository,
        contentCardRepository: any ContentCardRepository,
        adaptiveCardService: AdaptiveCardService,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.draftStore = draftStore
        self.commitStore = commitStore
        self.configurationRepository = configurationRepository
        self.credentialStore = credentialStore
        self.client = client
        self.vocabularyRepository = vocabularyRepository
        self.grammarRepository = grammarRepository
        self.contentCardRepository = contentCardRepository
        self.adaptiveCardService = adaptiveCardService
        self.clock = clock
    }

    // MARK: - Draft lifecycle

    /// Opens the repair session for a card: returns the existing resumable
    /// draft when one already targets this card (user input is preserved), or
    /// snapshots the note into a fresh `editing` draft.
    public func prepareDraft(
        cardID: UUID,
        userComment: String = ""
    ) async throws -> (id: UUID, envelope: AIRepairDraftEnvelope) {
        if let existing = try await fetchAllDrafts().first(where: {
            $0.envelope.targetCardID == cardID
                && $0.envelope.phase != .committed
        }) {
            return try await refreshTarget(of: existing)
        }
        let envelope = try await snapshotEnvelope(
            cardID: cardID,
            userComment: userComment,
            requestGeneration: 1
        )
        let draftID = UUID()
        try await save(draftID: draftID, envelope: envelope)
        return (draftID, envelope)
    }

    /// Persists the user's explanation before any analysis runs — the draft
    /// must always carry the latest input across restarts.
    public func updateUserComment(draftID: UUID, comment: String) async throws {
        var envelope = try await requireDraft(draftID)
        guard envelope.phase != .committed, envelope.phase != .committing else {
            throw AIRepairServiceError.draftNotAnalyzable(envelope.phase)
        }
        envelope.userComment = comment
        try await save(draftID: draftID, envelope: envelope)
    }

    public func loadDraft(id: UUID) async throws -> AIRepairDraftEnvelope? {
        try await draftStore.fetchDraft(id: id)
    }

    /// The whitelisted note content a draft's suggestions merge onto — the
    /// preview builder needs exactly this snapshot, never a live write
    /// handle. Re-resolved on each call so previews always reflect the note
    /// the commit conflict check will anchor on.
    public func previewNoteSnapshot(draftID: UUID) async throws -> AIRepairNoteSnapshot {
        let envelope = try await requireDraft(draftID)
        guard let detail = try await adaptiveCardService.detail(
            cardID: envelope.targetCardID,
            at: clock()
        ) else {
            throw AIRepairServiceError.targetUnavailable
        }
        return try await noteSnapshot(
            noteID: envelope.targetNoteID,
            kind: detail.item.templateKind.knowledgePointKind
        ).snapshot
    }

    /// Unsubmitted drafts may be deleted by the user; committed receipts stay.
    public func discardDraft(id: UUID) async throws {
        try await draftStore.deleteDraft(id: id)
    }

    /// Idempotency receipt for an operation id (设计 §6.3) — commit retries
    /// must consult this before mutating anything.
    public func committedReceipt(
        for operationID: UUID
    ) async throws -> AIRepairCommitReceipt? {
        try await fetchAllDrafts().first(where: {
            $0.envelope.operationID == operationID
                || $0.envelope.commitReceipt?.operationID == operationID
        })?.envelope.commitReceipt
    }

    /// Restart sweep: `analyzing` drafts return to `editing` (the request is
    /// gone), `committing` is left for the commit path's receipt check, and
    /// drafts whose target vanished become non-adoptable but stay readable.
    public func restoreDraftsForLaunch() async throws {
        for (id, stored) in try await fetchAllDrafts() {
            var envelope = stored
            var changed = false
            if envelope.phase == .analyzing {
                envelope.phase = .editing
                changed = true
            }
            if envelope.phase != .committed,
               try await adaptiveCardService.detail(cardID: envelope.targetCardID, at: clock()) == nil {
                envelope.adoptionBlocked = true
                changed = true
            }
            if changed {
                try await save(draftID: id, envelope: envelope)
            }
        }
    }

    // MARK: - Analysis

    /// Runs one user-triggered analysis: snapshots the current target,
    /// persists the `analyzing` phase, sends the whitelisted request and
    /// stores the strictly decoded response as `suggested`. Any failure —
    /// disabled AI, missing credential, transport error, cancellation,
    /// malformed output — returns the draft to `editing` and rethrows.
    public func analyze(
        draftID: UUID,
        defaultTimeZoneID: String
    ) async throws -> AIRepairDraftEnvelope {
        var envelope = try await requireDraft(draftID)
        switch envelope.phase {
        case .editing, .suggested, .previewing:
            break
        case .analyzing:
            // Resumable retry after restart — safe to run again with a new
            // generation; the old response can never arrive.
            break
        case .committing, .committed:
            throw AIRepairServiceError.draftNotAnalyzable(envelope.phase)
        }
        guard !envelope.adoptionBlocked else {
            throw AIRepairServiceError.targetUnavailable
        }

        // Re-snapshot: the note may have been edited since the draft opened;
        // the analysis and the later commit conflict check both anchor on
        // the version seen now.
        envelope = try await snapshotEnvelope(
            cardID: envelope.targetCardID,
            userComment: envelope.userComment,
            requestGeneration: envelope.requestGeneration + 1,
            carrying: envelope
        )
        envelope.phase = .analyzing

        let configuration = try await configurationRepository
            .loadOrCreateAIConfiguration(defaultTimeZoneID: defaultTimeZoneID)
        guard configuration.isEnabled else {
            try await save(draftID: draftID, envelope: revertingToEditing(envelope))
            throw AIConnectionError.aiDisabled
        }
        guard let credential = try await credentialStore.readCredential(
            for: configuration.credentialReference
        ), !credential.isEmpty else {
            try await save(draftID: draftID, envelope: revertingToEditing(envelope))
            throw AIConnectionError.credentialMissing
        }

        let provenance = AIRepairDraftProvenance(configuration: configuration)
        try await draftStore.saveDraft(
            id: draftID,
            envelope: envelope,
            provenance: provenance,
            updatedAt: clock()
        )

        let context = try await makeContext(from: envelope)
        let requestID = UUID()
        gate.begin(requestID)
        activeDraftID = draftID
        do {
            let content = try await client.analyze(
                context: context,
                configuration: configuration,
                credential: credential
            )
            let response = try AIRepairOutputDecoder.decode(content)
            return try await applyResponse(
                response,
                draftID: draftID,
                requestID: requestID,
                generation: envelope.requestGeneration
            )
        } catch {
            gate.finish(requestID)
            if activeDraftID == draftID { activeDraftID = nil }
            // Revert only while this generation still owns the draft — a
            // superseded request (newer analyze, discard, restore) must not
            // clobber the state that replaced it.
            try await revertToEditingIfStillOwned(
                draftID: draftID,
                generation: envelope.requestGeneration
            )
            if isCancellation(error) {
                throw AIConnectionError.cancelled
            }
            throw error
        }
    }

    /// User-initiated cancel: the in-flight response becomes stale and is
    /// discarded when it arrives. The transport additionally observes task
    /// cancellation through `Task.checkCancellation`.
    public func cancelAnalysis() {
        gate.cancel()
        activeDraftID = nil
    }

    // MARK: - Preview & commit (T08)

    /// Marks entry into the suggestion preview — a read-only phase change
    /// that lets the draft distinguish "browsing candidates" from a fresh
    /// response. `.suggested`/`.previewing` round-trip freely.
    public func markPreviewing(draftID: UUID) async throws {
        var envelope = try await requireDraft(draftID)
        guard envelope.phase == .suggested else { return }
        envelope.phase = .previewing
        try await save(draftID: draftID, envelope: envelope)
    }

    /// Persists the user's hand-edited candidate (编辑后采用). Validated
    /// through the same strict semantics pass as decoded AI output before it
    /// is allowed into the envelope — an invalid candidate would otherwise
    /// make the draft itself undecodable.
    public func updateEditedCandidate(
        draftID: UUID,
        candidate: AIRepairSuggestion?
    ) async throws {
        var envelope = try await requireDraft(draftID)
        guard envelope.phase == .suggested || envelope.phase == .previewing else {
            throw AIRepairCommitError.notCommittable(envelope.phase)
        }
        if let candidate {
            try AIRepairOutputDecoder.validateSemantics(of: candidate)
        }
        envelope.editedCandidate = candidate
        try await save(draftID: draftID, envelope: envelope)
    }

    /// Commits an in-place repair suggestion (T08): resolves the effective
    /// suggestion, re-checks the note's `content_version`, marks the draft
    /// `committing` with a stable `operationID`, then runs the single
    /// transaction that updates the note + example index and stores the
    /// committed draft with its receipt.
    ///
    /// Idempotency: a `.committed` draft replays to its stored receipt when
    /// the operation id and payload hash match, and rejects a different
    /// payload under the same id. A `.committing` draft retries with the
    /// operation id assigned by the interrupted attempt — safe because the
    /// transaction either fully committed (then the draft would read
    /// `.committed`) or left nothing behind.
    public func commitInPlaceRepair(
        draftID: UUID,
        suggestionIndex: Int,
        adoptingEditedCandidate: Bool = false
    ) async throws -> AIRepairCommitReceipt {
        var envelope = try await requireDraft(draftID)
        guard !envelope.adoptionBlocked else {
            throw AIRepairCommitError.targetUnavailable
        }
        // `editing`/`analyzing` carry nothing adoptable — reject before any
        // suggestion resolution so the phase error stays honest.
        guard envelope.phase != .editing, envelope.phase != .analyzing else {
            throw AIRepairCommitError.notCommittable(envelope.phase)
        }

        let suggestion = try resolveSuggestion(
            from: envelope,
            suggestionIndex: suggestionIndex,
            adoptingEditedCandidate: adoptingEditedCandidate
        )
        guard suggestion.type != .splitCard else {
            throw AIRepairCommitError.splitRequiresSplitCommit
        }

        let mutation = AIRepairConfirmedMutation(
            suggestionIndex: suggestionIndex,
            suggestion: suggestion,
            expectedContentVersion: envelope.expectedContentVersion
        )
        let payloadHash = try mutation.payloadHash()

        // Replay path: the operation already committed — identical payloads
        // return the stored receipt (even when the note moved on since),
        // anything else is a conflict.
        if envelope.phase == .committed {
            guard let receipt = envelope.commitReceipt else {
                throw AIRepairCommitError.notCommittable(envelope.phase)
            }
            guard receipt.operationID == envelope.operationID,
                  receipt.payloadHash == payloadHash else {
                throw AIRepairCommitError.operationConflict
            }
            return receipt
        }
        guard envelope.phase == .suggested
                || envelope.phase == .previewing
                || envelope.phase == .committing else {
            throw AIRepairCommitError.notCommittable(envelope.phase)
        }

        // Anchor the preview on the live note so the conflict check and the
        // merged content always agree.
        let detail = try await adaptiveCardService.detail(
            cardID: envelope.targetCardID,
            at: clock()
        )
        guard let detail else {
            throw AIRepairCommitError.targetUnavailable
        }
        let (snapshot, currentVersion) = try await noteSnapshot(
            noteID: envelope.targetNoteID,
            kind: detail.item.templateKind.knowledgePointKind
        )
        guard currentVersion == envelope.expectedContentVersion else {
            throw AIRepairCommitError.contentConflict
        }

        // Rebuild the merged content against the live snapshot — the exact
        // value the guarded write will persist.
        let preview = try AIRepairPreviewBuilder.preview(
            suggestion,
            index: suggestionIndex,
            note: snapshot
        )
        guard let content = preview.resultContent else {
            throw AIRepairCommitError.suggestionUnavailable
        }

        envelope.operationID = envelope.operationID ?? UUID()
        envelope.phase = .committing
        try await save(draftID: draftID, envelope: envelope)

        let receipt = AIRepairCommitReceipt(
            operationID: envelope.operationID ?? UUID(),
            payloadHash: payloadHash,
            originalCardDisposition: .keep
        )
        var committed = envelope
        committed.phase = .committed
        committed.commitReceipt = receipt

        do {
            try await commitStore.commitInPlaceRepair(
                draftID: draftID,
                envelope: committed,
                provenance: AIRepairDraftProvenance(
                    providerID: nil,
                    modelID: nil,
                    promptVersion: AIRepairPromptV2.promptVersion
                ),
                content: content,
                newExampleID: UUID(),
                updatedAt: clock()
            )
        } catch {
            // The transaction rolled back atomically; return the draft to a
            // browsable state (operation id kept for a stable retry).
            var reverted = envelope
            reverted.phase = .previewing
            try? await save(draftID: draftID, envelope: reverted)
            throw error
        }
        return receipt
    }

    // MARK: - Split commit (T09)

    /// The deck the split's new notes default to — the target note's own
    /// deck (设计 §6.5: 默认同牌组，用户可在预览中改). Read live so a deck
    /// move mid-session never points the picker at a stale deck.
    public func targetDeckID(draftID: UUID) async throws -> UUID {
        let envelope = try await requireDraft(draftID)
        guard let detail = try await adaptiveCardService.detail(
            cardID: envelope.targetCardID,
            at: clock()
        ) else {
            throw AIRepairServiceError.targetUnavailable
        }
        switch detail.item.templateKind.knowledgePointKind {
        case .vocabulary:
            guard let note = try await vocabularyRepository.fetchVocabulary(
                id: envelope.targetNoteID
            ) else {
                throw AIRepairServiceError.targetUnavailable
            }
            return note.deckID
        case .grammar:
            guard let note = try await grammarRepository.fetchGrammar(
                id: envelope.targetNoteID
            ) else {
                throw AIRepairServiceError.targetUnavailable
            }
            return note.deckID
        }
    }

    /// Commits a `split_card` suggestion (设计 §6.5, T09): validates every
    /// candidate and the user's per-candidate direction picks, anchors the
    /// confirmed mutation — content version + direction snapshot + deck +
    /// disposition + the operation's stable ID set — into the payload hash,
    /// then runs the single transaction that creates all new Notes/Cards,
    /// applies the original-card disposition and persists the receipt.
    ///
    /// `directions` is parallel to the suggestion's `splitNotes` and must be
    /// non-empty, duplicate-free and applicable to each candidate's kind —
    /// the UI greys out invalid selections, but the service re-checks so an
    /// invalid plan can never reach the transaction. `disposition` is a
    /// required explicit choice; "推荐暂停" lives in the UI, never as a
    /// default here.
    public func commitSplitRepair(
        draftID: UUID,
        suggestionIndex: Int,
        adoptingEditedCandidate: Bool = false,
        deckID: UUID,
        deckIDs: Set<UUID>? = nil,
        directions: [[CardTemplateKind]],
        originalCardDisposition: AIRepairOriginalCardDisposition
    ) async throws -> AIRepairCommitReceipt {
        let membership = (deckIDs ?? []).union([deckID])
        var envelope = try await requireDraft(draftID)
        guard !envelope.adoptionBlocked else {
            throw AIRepairCommitError.targetUnavailable
        }
        // `editing`/`analyzing` carry nothing adoptable — reject before any
        // suggestion resolution so the phase error stays honest.
        guard envelope.phase != .editing, envelope.phase != .analyzing else {
            throw AIRepairCommitError.notCommittable(envelope.phase)
        }

        let suggestion = try resolveSuggestion(
            from: envelope,
            suggestionIndex: suggestionIndex,
            adoptingEditedCandidate: adoptingEditedCandidate
        )
        guard suggestion.type == .splitCard,
              let candidates = suggestion.splitNotes else {
            throw AIRepairCommitError.notSplitSuggestion
        }
        guard candidates.count == directions.count else {
            throw AIRepairCommitError.invalidSplitPlan("每个候选都必须选择学习方向。")
        }
        for (index, kinds) in directions.enumerated() {
            guard !kinds.isEmpty else {
                throw AIRepairCommitError.invalidSplitPlan(
                    "第 \(index + 1) 个候选至少需要一个学习方向。"
                )
            }
            guard Set(kinds).count == kinds.count else {
                throw AIRepairCommitError.invalidSplitPlan(
                    "第 \(index + 1) 个候选的学习方向重复。"
                )
            }
            let allowed = Set(CardTemplateKind.applicable(to: candidates[index].kind))
            guard kinds.allSatisfy(allowed.contains) else {
                throw AIRepairCommitError.invalidSplitPlan(
                    "第 \(index + 1) 个候选包含不适用的学习方向。"
                )
            }
        }

        // Assign the operation id BEFORE building plans — every identifier
        // the commit writes derives from it, so a retry of this operation
        // always proposes the same IDs and the same payload hash.
        envelope.operationID = envelope.operationID ?? UUID()
        let operationID = envelope.operationID ?? UUID()
        let plans = AIRepairSplitConfirmedMutation.makePlans(
            operationID: operationID,
            directions: directions
        )
        let mutation = AIRepairSplitConfirmedMutation(
            suggestionIndex: suggestionIndex,
            suggestion: suggestion,
            expectedContentVersion: envelope.expectedContentVersion,
            expectedTemplateKinds: envelope.affectedTemplateKinds
                .sorted { $0.rawValue < $1.rawValue },
            deckID: deckID,
            // 单牌组选择与旧载荷编码一致（deckIDs 缺省），保证升级前已提交
            // 草稿的 payloadHash 回放路径不变。
            deckIDs: membership == [deckID] ? nil : membership,
            originalCardDisposition: originalCardDisposition,
            plans: plans
        )
        let payloadHash = try mutation.payloadHash()

        // Replay path: identical operation id + identical payload returns
        // the stored receipt; a different payload under the same id is a
        // conflict. Either way nothing is written.
        if envelope.phase == .committed {
            guard let receipt = envelope.commitReceipt else {
                throw AIRepairCommitError.notCommittable(envelope.phase)
            }
            guard receipt.operationID == envelope.operationID,
                  receipt.payloadHash == payloadHash else {
                throw AIRepairCommitError.operationConflict
            }
            return receipt
        }
        guard envelope.phase == .suggested
                || envelope.phase == .previewing
                || envelope.phase == .committing else {
            throw AIRepairCommitError.notCommittable(envelope.phase)
        }

        // Pre-flight guards (the transaction re-verifies atomically): the
        // target still resolves, the note's content version is the
        // previewed one and the direction snapshot hasn't moved — a user
        // who changed directions mid-preview must re-preview.
        let detail = try await adaptiveCardService.detail(
            cardID: envelope.targetCardID,
            at: clock()
        )
        guard let detail else {
            throw AIRepairCommitError.targetUnavailable
        }
        let (snapshot, currentVersion) = try await noteSnapshot(
            noteID: envelope.targetNoteID,
            kind: detail.item.templateKind.knowledgePointKind
        )
        guard currentVersion == envelope.expectedContentVersion else {
            throw AIRepairCommitError.contentConflict
        }
        let liveKinds = try await contentCardRepository.fetchCardDirections(
            noteID: envelope.targetNoteID
        ).map(\.templateKind)
        guard Set(liveKinds) == Set(envelope.affectedTemplateKinds) else {
            throw AIRepairCommitError.contentConflict
        }

        // All candidates validate before anything is staged — a mixed
        // valid/invalid suggestion writes nothing (计划 T09 必验).
        let preview = try AIRepairPreviewBuilder.preview(
            suggestion,
            index: suggestionIndex,
            note: snapshot
        )
        guard preview.splitContents.count == plans.count else {
            throw AIRepairCommitError.invalidSplitPlan("候选数量与拆分方案不一致。")
        }
        let createdAt = clock()
        let commits = zip(preview.splitContents, plans).map { content, plan in
            AIRepairSplitNoteCommit(
                noteID: plan.noteID,
                exampleID: plan.exampleID,
                deckID: deckID,
                deckIDs: membership,
                content: content,
                cards: zip(plan.templateKinds, plan.cardIDs).map {
                    NewCardSeed(id: $1, templateKind: $0)
                },
                schedulerProfileID: plan.schedulerProfileID,
                createdAt: createdAt
            )
        }

        envelope.phase = .committing
        try await save(draftID: draftID, envelope: envelope)

        let receipt = AIRepairCommitReceipt(
            operationID: operationID,
            payloadHash: payloadHash,
            createdNoteIDs: plans.map(\.noteID),
            createdCardIDs: plans.flatMap(\.cardIDs),
            originalCardDisposition: originalCardDisposition
        )
        var committed = envelope
        committed.phase = .committed
        committed.commitReceipt = receipt

        do {
            try await commitStore.commitSplitRepair(
                draftID: draftID,
                envelope: committed,
                provenance: AIRepairDraftProvenance(
                    providerID: nil,
                    modelID: nil,
                    promptVersion: AIRepairPromptV2.promptVersion
                ),
                commits: commits,
                originalCardDisposition: originalCardDisposition,
                updatedAt: createdAt
            )
        } catch {
            // The transaction rolled back atomically; return the draft to a
            // browsable state (operation id kept for a stable retry).
            var reverted = envelope
            reverted.phase = .previewing
            try? await save(draftID: draftID, envelope: reverted)
            throw error
        }
        return receipt
    }

    // MARK: - Private

    /// Picks the suggestion a commit applies: the stored edited candidate
    /// when the caller adopted that preview, otherwise the response entry at
    /// `suggestionIndex`.
    private func resolveSuggestion(
        from envelope: AIRepairDraftEnvelope,
        suggestionIndex: Int,
        adoptingEditedCandidate: Bool
    ) throws -> AIRepairSuggestion {
        if adoptingEditedCandidate, let candidate = envelope.editedCandidate {
            return candidate
        }
        guard let response = envelope.response,
              response.suggestions.indices.contains(suggestionIndex) else {
            throw AIRepairCommitError.suggestionUnavailable
        }
        return response.suggestions[suggestionIndex]
    }

    private func applyResponse(
        _ response: AIRepairResponse,
        draftID: UUID,
        requestID: UUID,
        generation: Int
    ) async throws -> AIRepairDraftEnvelope {
        let isCurrentRequest = gate.finish(requestID)
        if activeDraftID == draftID { activeDraftID = nil }
        // Stale check: the draft must still exist, still be analyzing this
        // generation and still target the same card — covers late responses,
        // double-taps, discards and database restores alike.
        guard isCurrentRequest,
              let current = try await draftStore.fetchDraft(id: draftID),
              current.phase == .analyzing,
              current.requestGeneration == generation else {
            throw AIRepairServiceError.staleResponse
        }
        var updated = current
        updated.response = response
        updated.phase = .suggested
        try await save(draftID: draftID, envelope: updated)
        return updated
    }

    private func revertingToEditing(_ envelope: AIRepairDraftEnvelope) -> AIRepairDraftEnvelope {
        var reverted = envelope
        reverted.phase = .editing
        return reverted
    }

    /// Returns a draft to the retryable `editing` phase only when it is still
    /// analyzing this exact generation — otherwise the failure belongs to a
    /// superseded request and the current state wins.
    private func revertToEditingIfStillOwned(draftID: UUID, generation: Int) async throws {
        guard let current = try await draftStore.fetchDraft(id: draftID),
              current.phase == .analyzing,
              current.requestGeneration == generation else { return }
        try await save(draftID: draftID, envelope: revertingToEditing(current))
    }

    private func requireDraft(_ draftID: UUID) async throws -> AIRepairDraftEnvelope {
        guard let envelope = try await draftStore.fetchDraft(id: draftID) else {
            throw AIRepairServiceError.draftNotFound
        }
        return envelope
    }

    private func save(draftID: UUID, envelope: AIRepairDraftEnvelope) async throws {
        try await draftStore.saveDraft(
            id: draftID,
            envelope: envelope,
            provenance: AIRepairDraftProvenance(
                providerID: nil,
                modelID: nil,
                promptVersion: AIRepairPromptV2.promptVersion
            ),
            updatedAt: clock()
        )
    }

    /// Re-checks that an existing draft's target still resolves; blocked
    /// drafts stay readable for manual copying but can never be adopted.
    private func refreshTarget(
        of draft: (id: UUID, envelope: AIRepairDraftEnvelope)
    ) async throws -> (id: UUID, envelope: AIRepairDraftEnvelope) {
        var envelope = draft.envelope
        if try await adaptiveCardService.detail(cardID: envelope.targetCardID, at: clock()) == nil {
            envelope.adoptionBlocked = true
            try await save(draftID: draft.id, envelope: envelope)
        }
        return (draft.id, envelope)
    }

    /// Builds a fresh envelope snapshot for the target card — note content,
    /// content version, card enabled state and the full direction set. Throws
    /// `targetUnavailable` when the card or note no longer resolves.
    private func snapshotEnvelope(
        cardID: UUID,
        userComment: String,
        requestGeneration: Int,
        carrying previous: AIRepairDraftEnvelope? = nil
    ) async throws -> AIRepairDraftEnvelope {
        guard let detail = try await adaptiveCardService.detail(
            cardID: cardID,
            at: clock()
        ) else {
            throw AIRepairServiceError.targetUnavailable
        }
        let item = detail.item
        let note = try await noteSnapshot(noteID: item.noteID, kind: item.templateKind.knowledgePointKind)
        let directions = try await contentCardRepository.fetchCardDirections(
            noteID: item.noteID
        ).map(\.templateKind)
        return AIRepairDraftEnvelope(
            targetNoteID: item.noteID,
            targetCardID: cardID,
            expectedContentVersion: note.contentVersion,
            targetCardEnabled: item.isEnabled,
            affectedTemplateKinds: directions,
            userComment: userComment,
            requestGeneration: requestGeneration,
            response: previous?.response,
            editedCandidate: previous?.editedCandidate,
            operationID: previous?.operationID,
            phase: previous?.phase ?? .editing,
            commitReceipt: previous?.commitReceipt
        )
    }

    /// Loads the whitelisted note content for both request building and the
    /// preview snapshot. `contentVersion` travels alongside for the draft's
    /// conflict anchor — it never enters the request payload.
    private func noteSnapshot(
        noteID: UUID,
        kind: KnowledgePointKind
    ) async throws -> (snapshot: AIRepairNoteSnapshot, contentVersion: Int) {
        switch kind {
        case .vocabulary:
            guard let note = try await vocabularyRepository.fetchVocabulary(id: noteID) else {
                throw AIRepairServiceError.targetUnavailable
            }
            return (AIRepairNoteSnapshot(note), note.contentVersion)
        case .grammar:
            guard let note = try await grammarRepository.fetchGrammar(id: noteID) else {
                throw AIRepairServiceError.targetUnavailable
            }
            return (AIRepairNoteSnapshot(note), note.contentVersion)
        }
    }

    private func makeContext(
        from envelope: AIRepairDraftEnvelope
    ) async throws -> AIRepairRequestContext {
        guard let detail = try await adaptiveCardService.detail(
            cardID: envelope.targetCardID,
            at: clock()
        ) else {
            throw AIRepairServiceError.targetUnavailable
        }
        let item = detail.item
        let (note, _) = try await noteSnapshot(
            noteID: item.noteID,
            kind: item.templateKind.knowledgePointKind
        )
        return AIRepairRequestContext(
            note: note,
            direction: item.templateKind,
            reviewSummary: AIRepairReviewSummary(metrics: item.assessment.metrics),
            userComment: envelope.userComment
        )
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let connectionError = error as? AIConnectionError {
            return connectionError == .cancelled
        }
        return false
    }

    private func fetchAllDrafts() async throws -> [(id: UUID, envelope: AIRepairDraftEnvelope)] {
        try await draftStore.fetchAllDrafts()
    }
}
