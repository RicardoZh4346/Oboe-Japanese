import Foundation

public enum CaptureProcessingMode: String, Codable, CaseIterable, Sendable {
    case vocabularyGeneration = "vocabulary_generation"
    case grammarGeneration = "grammar_generation"
    case sentenceAnalysis = "sentence_analysis"
    case manualEdit = "manual_edit"

    /// Local heuristic for the default processing path. Texts containing
    /// sentence-ending punctuation or newlines, or exceeding the generation
    /// input limit, suggest sentence analysis; short single expressions suggest
    /// vocabulary. This only seeds the default choice — it never forces the
    /// user's save type.
    public static func suggested(forText text: String) -> CaptureProcessingMode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSentenceBoundary = trimmed.contains { character in
            "。！？!?…\n".contains(character)
        }
        return hasSentenceBoundary || trimmed.count > 200
            ? .sentenceAnalysis
            : .vocabularyGeneration
    }
}

public enum CaptureResumePayloadFormat {
    public static let currentVersion = 1
    public static let maximumUTF8ByteCount = 256 * 1_024
}

public struct InboxProcessingContext: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let inboxItemID: UUID
    public let contentRevision: Int
    public let inputText: String
    public let mode: CaptureProcessingMode
    public let draftID: UUID?
    public let payloadVersion: Int
    public let resumePayloadJSON: String?
    public let updatedAt: Date

    public init(
        id: UUID,
        inboxItemID: UUID,
        contentRevision: Int,
        inputText: String,
        mode: CaptureProcessingMode,
        draftID: UUID?,
        payloadVersion: Int,
        resumePayloadJSON: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.inboxItemID = inboxItemID
        self.contentRevision = contentRevision
        self.inputText = inputText
        self.mode = mode
        self.draftID = draftID
        self.payloadVersion = payloadVersion
        self.resumePayloadJSON = resumePayloadJSON
        self.updatedAt = updatedAt
    }
}

/// A processing context resolved against its inbox item: the persisted
/// context, the decoded resume payload, and staleness flags derived from
/// content-revision comparison.
public struct CaptureProcessingSession: Equatable, Sendable {
    public let item: InboxItem
    public let context: InboxProcessingContext
    public let payload: CaptureResumePayload?

    public init(
        item: InboxItem,
        context: InboxProcessingContext,
        payload: CaptureResumePayload?
    ) {
        self.item = item
        self.context = context
        self.payload = payload
    }

    /// The inbox text was edited after the context snapshot was last refreshed.
    public var isSourceRevised: Bool {
        item.contentRevision != context.contentRevision
    }

    /// Analysis-derived data (selected items, edited card drafts) belongs to an
    /// older source revision and must not be attached to the current text.
    public var isAnalysisStale: Bool {
        guard let payload, let revision = payload.analysisContentRevision else { return false }
        return revision != item.contentRevision
    }

    /// The payload with unusable analysis-derived fields cleared while user
    /// choices (deck, directions, pending operation) are preserved. The source
    /// selection is dropped whenever it can no longer be trusted.
    public var resumablePayload: CaptureResumePayload? {
        guard let payload else { return nil }
        guard isAnalysisStale else { return payload }
        var sanitized = payload
        sanitized.selection = nil
        sanitized.selectedAnalysisItemIDs = []
        sanitized.editedCardDrafts = []
        sanitized.analysisContentRevision = nil
        // 来源草稿里的句子字段派生自旧文本——改版后保留 app/url/
        // 图片等来源事实，但清掉不再可靠的文本快照。
        sanitized.sourceDraft = sanitized.sourceDraft.map {
            var draft = $0
            draft.originalSentence = nil
            draft.surroundingText = nil
            return draft
        }
        return sanitized
    }
}

public struct CaptureImportReceipt: Equatable, Sendable {
    public let captureID: UUID
    public let payloadHash: String
    public let inboxItemID: UUID?
    public let importedAt: Date

    public init(
        captureID: UUID,
        payloadHash: String,
        inboxItemID: UUID?,
        importedAt: Date
    ) {
        self.captureID = captureID
        self.payloadHash = payloadHash
        self.inboxItemID = inboxItemID
        self.importedAt = importedAt
    }
}

/// Carries the idempotency keys for a formal save that started from an Inbox
/// capture. `operationID` is stable across retries of the same confirmation;
/// the content digest is computed by the repository so callers cannot forge it.
public struct CaptureCommitContext: Equatable, Sendable {
    public let operationID: UUID
    public let processingContextID: UUID?
    public let inboxItemID: UUID
    /// Revision snapshotted by the processing context — committing against an
    /// item edited afterwards is a conflict, not a silent stale write.
    public let expectedContentRevision: Int
    public let sourceText: String

    public init(
        operationID: UUID,
        processingContextID: UUID?,
        inboxItemID: UUID,
        expectedContentRevision: Int,
        sourceText: String
    ) {
        self.operationID = operationID
        self.processingContextID = processingContextID
        self.inboxItemID = inboxItemID
        self.expectedContentRevision = expectedContentRevision
        self.sourceText = sourceText
    }
}

public struct InboxCommitReceipt: Equatable, Sendable {
    public let operationID: UUID
    public let processingContextID: UUID?
    public let payloadHash: String
    public let resultJSON: String
    public let committedAt: Date

    public init(
        operationID: UUID,
        processingContextID: UUID?,
        payloadHash: String,
        resultJSON: String,
        committedAt: Date
    ) {
        self.operationID = operationID
        self.processingContextID = processingContextID
        self.payloadHash = payloadHash
        self.resultJSON = resultJSON
        self.committedAt = committedAt
    }
}
