import Foundation

/// 需求 §8.2 — the ten problem classifications an AI repair analysis may report.
public enum AIRepairProblemType: String, CaseIterable, Codable, Hashable, Sendable {
    case tooManyMeanings = "too_many_meanings"
    case ambiguousPrompt = "ambiguous_prompt"
    case lackOfContext = "lack_of_context"
    case exampleTooComplex = "example_too_complex"
    case exampleNotRepresentative = "example_not_representative"
    case answerTooLong = "answer_too_long"
    case similarWordsConfusion = "similar_words_confusion"
    case multipleReadings = "multiple_readings"
    case grammarScopeTooBroad = "grammar_scope_too_broad"
    case unknown
}

/// 需求 §8.3 — the seven suggestion kinds an AI repair analysis may offer.
public enum AIRepairSuggestionType: String, CaseIterable, Codable, Hashable, Sendable {
    case rewriteMeaning = "rewrite_meaning"
    case replaceExample = "replace_example"
    case addContext = "add_context"
    case splitCard = "split_card"
    case shortenAnswer = "shorten_answer"
    case addDisambiguation = "add_disambiguation"
    case addNote = "add_note"
}

/// Optional Note fields a repair patch may clear via `clearFields`. Required
/// fields (headword/meaningZH) can never appear here.
public enum AIRepairClearableField: String, CaseIterable, Codable, Hashable, Sendable {
    case reading
    case partOfSpeech
    case pitchAccent
    case usage
    case connection
    case notes
}

public struct AIRepairExampleCandidate: Codable, Equatable, Sendable {
    public var japanese: String
    public var translationZH: String?

    public init(japanese: String, translationZH: String? = nil) {
        self.japanese = japanese
        self.translationZH = translationZH
    }
}

/// Partial patch over the whitelisted Note fields (设计 §6.2): an absent field
/// means "unchanged"; optional-field removal uses the suggestion's
/// `clearFields`, never a null here.
public struct AIRepairFieldPatch: Codable, Equatable, Sendable {
    public var headword: String?
    public var reading: String?
    public var meaningZH: String?
    public var partOfSpeech: String?
    public var pitchAccent: PitchAccent?
    public var usage: String?
    public var connection: String?
    public var notes: String?
    /// Full replacement of the example list when present.
    public var examples: [AIRepairExampleCandidate]?

    public init(
        headword: String? = nil,
        reading: String? = nil,
        meaningZH: String? = nil,
        partOfSpeech: String? = nil,
        usage: String? = nil,
        connection: String? = nil,
        notes: String? = nil,
        examples: [AIRepairExampleCandidate]? = nil,
        pitchAccent: PitchAccent? = nil
    ) {
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.pitchAccent = pitchAccent
        self.usage = usage
        self.connection = connection
        self.notes = notes
        self.examples = examples
    }
}

/// A complete Note candidate inside a `split_card` suggestion. IDs, origin,
/// sourceRef, directions and the original card's disposition are all assigned
/// by the app at commit time — never by the AI (设计 §6.2).
public struct AIRepairNoteCandidate: Codable, Equatable, Sendable {
    public var kind: KnowledgePointKind
    public var headword: String
    public var reading: String?
    public var meaningZH: String
    public var partOfSpeech: String?
    public var pitchAccent: PitchAccent?
    public var jlpt: String?
    public var usage: String?
    public var connection: String?
    public var notes: String?
    public var examples: [AIRepairExampleCandidate]?

    public init(
        kind: KnowledgePointKind,
        headword: String,
        reading: String? = nil,
        meaningZH: String,
        partOfSpeech: String? = nil,
        jlpt: String? = nil,
        usage: String? = nil,
        connection: String? = nil,
        notes: String? = nil,
        examples: [AIRepairExampleCandidate]? = nil,
        pitchAccent: PitchAccent? = nil
    ) {
        self.kind = kind
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.pitchAccent = pitchAccent
        self.jlpt = jlpt
        self.usage = usage
        self.connection = connection
        self.notes = notes
        self.examples = examples
    }
}

public struct AIRepairSuggestion: Codable, Equatable, Sendable {
    public var type: AIRepairSuggestionType
    public var title: String
    public var reason: String
    public var replacement: AIRepairFieldPatch?
    public var clearFields: [AIRepairClearableField]?
    public var splitNotes: [AIRepairNoteCandidate]?

    public init(
        type: AIRepairSuggestionType,
        title: String,
        reason: String,
        replacement: AIRepairFieldPatch? = nil,
        clearFields: [AIRepairClearableField]? = nil,
        splitNotes: [AIRepairNoteCandidate]? = nil
    ) {
        self.type = type
        self.title = title
        self.reason = reason
        self.replacement = replacement
        self.clearFields = clearFields
        self.splitNotes = splitNotes
    }
}

public struct AIRepairResponse: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var problemTypes: [AIRepairProblemType]
    public var summary: String
    public var suggestions: [AIRepairSuggestion]

    public init(
        schemaVersion: Int = AIRepairPromptV2.schemaVersion,
        problemTypes: [AIRepairProblemType],
        summary: String,
        suggestions: [AIRepairSuggestion]
    ) {
        self.schemaVersion = schemaVersion
        self.problemTypes = problemTypes
        self.summary = summary
        self.suggestions = suggestions
    }
}

/// 设计 §6.3 — `editing → analyzing → suggested → previewing → committing →
/// committed`; failures return to a retryable earlier phase.
public enum AIRepairDraftPhase: String, CaseIterable, Codable, Hashable, Sendable {
    case editing
    case analyzing
    case suggested
    case previewing
    case committing
    case committed
}

/// How the user chose to treat the repaired card when it was committed.
public enum AIRepairOriginalCardDisposition: String, CaseIterable, Codable, Hashable, Sendable {
    case keep
    case pause
    case delete
}

/// The durable commit receipt embedded in a committed draft (设计 §6.3). UUIDs
/// inside are operation-result identifiers, not foreign keys — they may
/// legitimately reference objects the user deleted later.
public struct AIRepairCommitReceipt: Codable, Equatable, Sendable {
    public var operationID: UUID
    /// Lowercase SHA-256 hex of the normalized user-confirmed payload.
    public var payloadHash: String
    public var createdNoteIDs: [UUID]
    public var createdCardIDs: [UUID]
    public var originalCardDisposition: AIRepairOriginalCardDisposition

    public init(
        operationID: UUID,
        payloadHash: String,
        createdNoteIDs: [UUID] = [],
        createdCardIDs: [UUID] = [],
        originalCardDisposition: AIRepairOriginalCardDisposition
    ) {
        self.operationID = operationID
        self.payloadHash = payloadHash
        self.createdNoteIDs = createdNoteIDs
        self.createdCardIDs = createdCardIDs
        self.originalCardDisposition = originalCardDisposition
    }
}

/// Versioned `drafts.payload_json` envelope for `draft_kind = 'ai_repair'`
/// (设计 §6.3). Carries everything needed to resume a repair session after
/// restart and to replay an already-committed operation idempotently.
public struct AIRepairDraftEnvelope: Equatable, Sendable {
    public var schemaVersion: Int
    public var targetNoteID: UUID
    public var targetCardID: UUID
    /// Note `content_version` the analysis ran against; commit re-checks it.
    public var expectedContentVersion: Int
    public var targetCardEnabled: Bool
    /// Snapshot of the card directions present on the Note at analysis time.
    public var affectedTemplateKinds: [CardTemplateKind]
    public var userComment: String
    /// Monotonic counter distinguishing repeated analysis requests.
    public var requestGeneration: Int
    public var response: AIRepairResponse?
    /// The candidate the user edited before adopting, if any.
    public var editedCandidate: AIRepairSuggestion?
    /// Assigned when a commit attempt begins; kept across retries.
    public var operationID: UUID?
    public var phase: AIRepairDraftPhase
    public var commitReceipt: AIRepairCommitReceipt?
    /// Set when the target Note/Card no longer resolves (e.g. deleted before or
    /// during restore): the draft stays readable but can never be adopted.
    public var adoptionBlocked: Bool

    public init(
        schemaVersion: Int = AIRepairDraftFormat.currentSchemaVersion,
        targetNoteID: UUID,
        targetCardID: UUID,
        expectedContentVersion: Int,
        targetCardEnabled: Bool,
        affectedTemplateKinds: [CardTemplateKind],
        userComment: String = "",
        requestGeneration: Int = 1,
        response: AIRepairResponse? = nil,
        editedCandidate: AIRepairSuggestion? = nil,
        operationID: UUID? = nil,
        phase: AIRepairDraftPhase,
        commitReceipt: AIRepairCommitReceipt? = nil,
        adoptionBlocked: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.targetNoteID = targetNoteID
        self.targetCardID = targetCardID
        self.expectedContentVersion = expectedContentVersion
        self.targetCardEnabled = targetCardEnabled
        self.affectedTemplateKinds = affectedTemplateKinds
        self.userComment = userComment
        self.requestGeneration = requestGeneration
        self.response = response
        self.editedCandidate = editedCandidate
        self.operationID = operationID
        self.phase = phase
        self.commitReceipt = commitReceipt
        self.adoptionBlocked = adoptionBlocked
    }
}

public enum AIRepairDraftFormat {
    public static let currentSchemaVersion = 1
    /// `drafts.payload_version` value for `ai_repair` envelopes.
    public static let currentPayloadVersion = 1
    public static let draftKind = "ai_repair"
    /// AI output itself is capped at 64KiB (设计 §6.1); the persisted envelope
    /// additionally carries request context and the user's edited candidate.
    public static let maximumUTF8ByteCount = 256 * 1_024
    /// 设计 §6.1 — user-supplied comment is bounded at the request layer too.
    public static let maximumUserCommentLength = 1_000
}

public enum AIRepairDraftError: Error, Equatable, Sendable {
    case invalidJSON
    case unsupportedSchemaVersion(Int)
    case payloadTooLarge(limit: Int)
    case invalidField(String)
}

public enum AIRepairDraftCodec {
    public static func encode(_ envelope: AIRepairDraftEnvelope) throws -> String {
        try validate(envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(WireEnvelope(envelope))
        } catch {
            throw AIRepairDraftError.invalidJSON
        }
        guard data.count <= AIRepairDraftFormat.maximumUTF8ByteCount,
              let json = String(data: data, encoding: .utf8) else {
            throw AIRepairDraftError.payloadTooLarge(
                limit: AIRepairDraftFormat.maximumUTF8ByteCount
            )
        }
        return json
    }

    public static func decode(_ json: String) throws -> AIRepairDraftEnvelope {
        guard let data = json.data(using: .utf8) else {
            throw AIRepairDraftError.invalidJSON
        }
        guard data.count <= AIRepairDraftFormat.maximumUTF8ByteCount else {
            throw AIRepairDraftError.payloadTooLarge(
                limit: AIRepairDraftFormat.maximumUTF8ByteCount
            )
        }
        let wire: WireEnvelope
        do {
            wire = try JSONDecoder().decode(WireEnvelope.self, from: data)
        } catch {
            throw AIRepairDraftError.invalidJSON
        }
        guard wire.schemaVersion == AIRepairDraftFormat.currentSchemaVersion else {
            throw AIRepairDraftError.unsupportedSchemaVersion(wire.schemaVersion)
        }
        let envelope = wire.makeEnvelope()
        try validate(envelope)
        return envelope
    }

    static func validate(_ envelope: AIRepairDraftEnvelope) throws {
        guard envelope.schemaVersion == AIRepairDraftFormat.currentSchemaVersion else {
            throw AIRepairDraftError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.expectedContentVersion >= 1 else {
            throw AIRepairDraftError.invalidField("expectedContentVersion")
        }
        guard envelope.requestGeneration >= 1 else {
            throw AIRepairDraftError.invalidField("requestGeneration")
        }
        guard !envelope.affectedTemplateKinds.isEmpty else {
            throw AIRepairDraftError.invalidField("affectedTemplateKinds")
        }
        guard envelope.userComment.utf16.count
                <= AIRepairDraftFormat.maximumUserCommentLength else {
            throw AIRepairDraftError.invalidField("userComment")
        }
        switch envelope.phase {
        case .committed:
            guard let receipt = envelope.commitReceipt else {
                throw AIRepairDraftError.invalidField("commitReceipt")
            }
            guard receipt.operationID == envelope.operationID else {
                throw AIRepairDraftError.invalidField("operationID")
            }
            guard isLowercaseSHA256Hex(receipt.payloadHash) else {
                throw AIRepairDraftError.invalidField("payloadHash")
            }
        default:
            guard envelope.commitReceipt == nil else {
                throw AIRepairDraftError.invalidField("commitReceipt")
            }
        }
    }

    static func isLowercaseSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character)
        }
    }

    private struct WireEnvelope: Codable {
        var schemaVersion: Int
        var targetNoteID: UUID
        var targetCardID: UUID
        var expectedContentVersion: Int
        var targetCardEnabled: Bool
        var affectedTemplateKinds: [CardTemplateKind]
        var userComment: String
        var requestGeneration: Int
        var response: AIRepairResponse?
        var editedCandidate: AIRepairSuggestion?
        var operationID: UUID?
        var phase: AIRepairDraftPhase
        var commitReceipt: AIRepairCommitReceipt?
        var adoptionBlocked: Bool?

        init(_ envelope: AIRepairDraftEnvelope) {
            schemaVersion = envelope.schemaVersion
            targetNoteID = envelope.targetNoteID
            targetCardID = envelope.targetCardID
            expectedContentVersion = envelope.expectedContentVersion
            targetCardEnabled = envelope.targetCardEnabled
            affectedTemplateKinds = envelope.affectedTemplateKinds
            userComment = envelope.userComment
            requestGeneration = envelope.requestGeneration
            response = envelope.response
            editedCandidate = envelope.editedCandidate
            operationID = envelope.operationID
            phase = envelope.phase
            commitReceipt = envelope.commitReceipt
            adoptionBlocked = envelope.adoptionBlocked
        }

        func makeEnvelope() -> AIRepairDraftEnvelope {
            AIRepairDraftEnvelope(
                schemaVersion: schemaVersion,
                targetNoteID: targetNoteID,
                targetCardID: targetCardID,
                expectedContentVersion: expectedContentVersion,
                targetCardEnabled: targetCardEnabled,
                affectedTemplateKinds: affectedTemplateKinds,
                userComment: userComment,
                requestGeneration: requestGeneration,
                response: response,
                editedCandidate: editedCandidate,
                operationID: operationID,
                phase: phase,
                commitReceipt: commitReceipt,
                adoptionBlocked: adoptionBlocked ?? false
            )
        }
    }
}
