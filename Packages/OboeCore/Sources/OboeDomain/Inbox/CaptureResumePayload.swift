import Foundation

/// UTF-16 range into the capture context's `inputText`, describing which part of
/// the source the user selected for processing.
public struct CaptureTextSelection: Codable, Equatable, Sendable {
    public var utf16Offset: Int
    public var utf16Length: Int

    public init(utf16Offset: Int, utf16Length: Int) {
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
    }
}

/// Versioned resume data for an in-progress capture processing session.
/// Analysis results themselves live in the linked `drafts` row; this payload
/// holds user state that has no other home: the selected source range, target
/// deck, card directions, chosen analysis items and their edited card drafts,
/// the revision analysis ran against, and a pending commit operation ID.
public struct CaptureResumePayload: Equatable, Sendable {
    public var selection: CaptureTextSelection?
    public var targetDeckID: UUID?
    public var vocabularyDirections: Set<VocabularyCardDirection>
    public var grammarFormToExplanation: Bool
    public var selectedAnalysisItemIDs: [UUID]
    public var editedCardDrafts: [SentenceAnalysisCardDraft]
    public var analysisContentRevision: Int?
    public var pendingOperationID: UUID?

    public init(
        selection: CaptureTextSelection? = nil,
        targetDeckID: UUID? = nil,
        vocabularyDirections: Set<VocabularyCardDirection> = [.japaneseToChinese],
        grammarFormToExplanation: Bool = true,
        selectedAnalysisItemIDs: [UUID] = [],
        editedCardDrafts: [SentenceAnalysisCardDraft] = [],
        analysisContentRevision: Int? = nil,
        pendingOperationID: UUID? = nil
    ) {
        self.selection = selection
        self.targetDeckID = targetDeckID
        self.vocabularyDirections = vocabularyDirections
        self.grammarFormToExplanation = grammarFormToExplanation
        self.selectedAnalysisItemIDs = selectedAnalysisItemIDs
        self.editedCardDrafts = editedCardDrafts
        self.analysisContentRevision = analysisContentRevision
        self.pendingOperationID = pendingOperationID
    }
}

public enum CaptureResumePayloadError: Error, Equatable, Sendable {
    case invalidJSON
    case unsupportedVersion(Int)
    case payloadTooLarge(limit: Int)
    case invalidField(String)
    case tooManyItems(field: String, maximum: Int)
}

public enum CaptureResumePayloadCodec {
    public static let maximumAnalysisItems = 30

    public static func encode(_ payload: CaptureResumePayload) throws -> String {
        try validate(payload)
        let wire = WirePayload(payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(wire)
        } catch {
            throw CaptureResumePayloadError.invalidJSON
        }
        guard data.count <= CaptureResumePayloadFormat.maximumUTF8ByteCount,
              let json = String(data: data, encoding: .utf8) else {
            throw CaptureResumePayloadError.payloadTooLarge(
                limit: CaptureResumePayloadFormat.maximumUTF8ByteCount
            )
        }
        return json
    }

    public static func decode(_ json: String) throws -> CaptureResumePayload {
        guard let data = json.data(using: .utf8) else {
            throw CaptureResumePayloadError.invalidJSON
        }
        guard data.count <= CaptureResumePayloadFormat.maximumUTF8ByteCount else {
            throw CaptureResumePayloadError.payloadTooLarge(
                limit: CaptureResumePayloadFormat.maximumUTF8ByteCount
            )
        }
        let wire: WirePayload
        do {
            wire = try JSONDecoder().decode(WirePayload.self, from: data)
        } catch {
            throw CaptureResumePayloadError.invalidJSON
        }
        guard wire.version == CaptureResumePayloadFormat.currentVersion else {
            throw CaptureResumePayloadError.unsupportedVersion(wire.version)
        }
        let payload = wire.makePayload()
        try validate(payload)
        return payload
    }

    /// Bounds-checks a decoded selection against the snapshot text it was
    /// recorded for. Called when loading a session since the codec alone
    /// cannot see the input text.
    public static func validateSelection(
        _ selection: CaptureTextSelection,
        within inputText: String
    ) throws {
        guard selection.utf16Offset + selection.utf16Length <= inputText.utf16.count else {
            throw CaptureResumePayloadError.invalidField("selection")
        }
    }

    private static func validate(_ payload: CaptureResumePayload) throws {
        if let selection = payload.selection {
            guard selection.utf16Offset >= 0, selection.utf16Length > 0 else {
                throw CaptureResumePayloadError.invalidField("selection")
            }
        }
        guard payload.selectedAnalysisItemIDs.count <= maximumAnalysisItems else {
            throw CaptureResumePayloadError.tooManyItems(
                field: "selectedAnalysisItemIDs",
                maximum: maximumAnalysisItems
            )
        }
        guard payload.editedCardDrafts.count <= maximumAnalysisItems else {
            throw CaptureResumePayloadError.tooManyItems(
                field: "editedCardDrafts",
                maximum: maximumAnalysisItems
            )
        }
        let selectedIDs = Set(payload.selectedAnalysisItemIDs)
        guard payload.editedCardDrafts.allSatisfy({ selectedIDs.contains($0.id) }) else {
            throw CaptureResumePayloadError.invalidField("editedCardDrafts")
        }
        if let revision = payload.analysisContentRevision {
            guard revision >= 1 else {
                throw CaptureResumePayloadError.invalidField("analysisContentRevision")
            }
        }
    }

    private struct WirePayload: Codable {
        var version: Int
        var selection: CaptureTextSelection?
        var targetDeckID: UUID?
        var vocabularyDirections: Set<VocabularyCardDirection>?
        var grammarFormToExplanation: Bool?
        var selectedAnalysisItemIDs: [UUID]?
        var editedCardDrafts: [SentenceAnalysisCardDraft]?
        var analysisContentRevision: Int?
        var pendingOperationID: UUID?

        init(_ payload: CaptureResumePayload) {
            version = CaptureResumePayloadFormat.currentVersion
            selection = payload.selection
            targetDeckID = payload.targetDeckID
            vocabularyDirections = payload.vocabularyDirections
            grammarFormToExplanation = payload.grammarFormToExplanation
            selectedAnalysisItemIDs = payload.selectedAnalysisItemIDs
            editedCardDrafts = payload.editedCardDrafts
            analysisContentRevision = payload.analysisContentRevision
            pendingOperationID = payload.pendingOperationID
        }

        func makePayload() -> CaptureResumePayload {
            CaptureResumePayload(
                selection: selection,
                targetDeckID: targetDeckID,
                vocabularyDirections: vocabularyDirections ?? [.japaneseToChinese],
                grammarFormToExplanation: grammarFormToExplanation ?? true,
                selectedAnalysisItemIDs: selectedAnalysisItemIDs ?? [],
                editedCardDrafts: editedCardDrafts ?? [],
                analysisContentRevision: analysisContentRevision,
                pendingOperationID: pendingOperationID
            )
        }
    }
}
