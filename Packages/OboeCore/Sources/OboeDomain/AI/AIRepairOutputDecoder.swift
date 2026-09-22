import Foundation

/// Strict decoder for the AI repair response (设计 §6.2). Rejects unknown
/// enums, extra keys, conflicting patches, malformed splits and candidates
/// that would not pass the same form validation as manually created content.
/// Produces a fully validated `AIRepairResponse`; nothing here touches the
/// database.
public enum AIRepairOutputDecoder {
    /// 设计 §6.1 — raw model output is capped at 64KiB.
    public static let maximumUTF8ByteCount = 64 * 1_024
    /// 设计 §6.2 — at most five suggestions per response.
    public static let maximumSuggestions = 5
    /// 设计 §6.2 — at most four new notes per split suggestion.
    public static let maximumSplitNotes = 4
    /// 设计 §6.2 — at most two notes per split.
    public static let minimumSplitNotes = 2
    /// The current form model supports a single example per note.
    public static let maximumExamples = 1

    private static let responseKeys: Set<String> = [
        "schemaVersion", "problemTypes", "summary", "suggestions"
    ]
    private static let suggestionKeys: Set<String> = [
        "type", "title", "reason", "replacement", "clearFields", "splitNotes"
    ]
    private static let requiredSuggestionKeys: Set<String> = ["type", "title", "reason"]
    private static let patchKeys: Set<String> = [
        "headword", "reading", "meaningZH", "partsOfSpeech", "pitchAccent",
        "usage", "connection", "notes", "examples"
    ]
    private static let candidateKeys: Set<String> = [
        "kind", "headword", "reading", "meaningZH", "partsOfSpeech", "pitchAccent",
        "jlpt", "usage", "connection", "notes", "examples"
    ]
    private static let exampleKeys: Set<String> = ["japanese", "translationZH"]

    private static let fieldLimits: [String: Int] = [
        "title": 200,
        "reason": 500,
        "summary": 1_000,
        "headword": 200,
        "reading": 100,
        "meaningZH": 1_000,
        "usage": 2_000,
        "connection": 1_000,
        "notes": 2_000,
        "japanese": 500,
        "translationZH": 1_000
    ]

    public static func decode(_ content: String) throws -> AIRepairResponse {
        guard let data = content.data(using: .utf8) else {
            throw AIRepairError.invalidJSON
        }
        guard data.count <= maximumUTF8ByteCount else {
            throw AIRepairError.responseTooLarge
        }
        guard let rawObject = try? JSONSerialization.jsonObject(with: data),
              let object = rawObject as? [String: Any] else {
            throw AIRepairError.invalidJSON
        }
        guard Set(object.keys) == responseKeys else {
            throw AIRepairError.unexpectedFields
        }
        guard let schemaVersion = object["schemaVersion"] as? Int else {
            throw AIRepairError.invalidJSON
        }
        guard schemaVersion == AIRepairPromptV2.schemaVersion else {
            throw AIRepairError.unsupportedSchemaVersion(schemaVersion)
        }
        guard let rawProblemTypes = object["problemTypes"] as? [String] else {
            throw AIRepairError.invalidJSON
        }
        let problemTypes = try rawProblemTypes.map { rawValue in
            guard let type = AIRepairProblemType(rawValue: rawValue) else {
                throw AIRepairError.unknownProblemType(rawValue)
            }
            return type
        }
        let summary = try requiredString(object["summary"], field: "summary")
        guard let rawSuggestions = object["suggestions"] as? [[String: Any]] else {
            throw AIRepairError.invalidJSON
        }
        guard rawSuggestions.count <= maximumSuggestions else {
            throw AIRepairError.tooManySuggestions
        }
        let suggestions = try rawSuggestions.map { try decodeSuggestion($0) }
        return AIRepairResponse(
            schemaVersion: schemaVersion,
            problemTypes: problemTypes,
            summary: summary,
            suggestions: suggestions
        )
    }

    private static func decodeSuggestion(
        _ object: [String: Any]
    ) throws -> AIRepairSuggestion {
        guard requiredSuggestionKeys.isSubset(of: object.keys),
              Set(object.keys).isSubset(of: suggestionKeys) else {
            throw AIRepairError.unexpectedFields
        }
        guard let rawType = object["type"] as? String else {
            throw AIRepairError.invalidJSON
        }
        guard let type = AIRepairSuggestionType(rawValue: rawType) else {
            throw AIRepairError.unknownSuggestionType(rawType)
        }
        let title = try requiredString(object["title"], field: "title")
        let reason = try requiredString(object["reason"], field: "reason")

        let suggestion = AIRepairSuggestion(
            type: type,
            title: title,
            reason: reason,
            replacement: try decodePatch(object["replacement"]),
            clearFields: try decodeClearFields(object["clearFields"]),
            splitNotes: try decodeSplitNotes(object["splitNotes"])
        )
        try validateSemantics(of: suggestion)
        return suggestion
    }

    /// Suggestion-level semantic rules shared by the decoder and the preview
    /// builder (user-edited candidates must pass the same checks before they
    /// can be previewed or applied).
    static func validateSemantics(of suggestion: AIRepairSuggestion) throws {
        if let replacement = suggestion.replacement {
            let patchedFields = replacement.populatedFieldNames()
            for field in suggestion.clearFields ?? [] where patchedFields.contains(field.rawValue) {
                throw AIRepairError.patchClearConflict(field.rawValue)
            }
        }
        if suggestion.type == .splitCard {
            guard suggestion.replacement == nil, suggestion.clearFields == nil else {
                throw AIRepairError.patchNotAllowedForSplit
            }
            guard let splitNotes = suggestion.splitNotes,
                  splitNotes.count >= minimumSplitNotes else {
                throw AIRepairError.incompleteSplit
            }
            guard splitNotes.count <= maximumSplitNotes else {
                throw AIRepairError.tooManySplitNotes
            }
            for candidate in splitNotes {
                try validateCandidate(candidate)
            }
        } else {
            guard suggestion.splitNotes == nil else {
                throw AIRepairError.splitNotesNotAllowed
            }
            let hasPatch = suggestion.replacement?.hasContent == true
            let hasClear = !(suggestion.clearFields?.isEmpty ?? true)
            guard hasPatch || hasClear else {
                throw AIRepairError.emptySuggestion
            }
        }
    }

    private static func decodePatch(_ value: Any?) throws -> AIRepairFieldPatch? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any],
              Set(object.keys).isSubset(of: patchKeys) else {
            throw AIRepairError.unexpectedFields
        }
        func patchField(_ name: String) throws -> String? {
            try optionalPatchString(object[name], field: name)
        }
        return try AIRepairFieldPatch(
            headword: patchField("headword"),
            reading: patchField("reading"),
            meaningZH: patchField("meaningZH"),
            partOfSpeech: try decodePartsOfSpeech(object["partsOfSpeech"], allowEmpty: false),
            usage: patchField("usage"),
            connection: patchField("connection"),
            notes: patchField("notes"),
            examples: decodeExamples(object["examples"]),
            pitchAccent: try decodePitchAccent(object["pitchAccent"])
        )
    }

    /// A present patch value must be a non-empty trimmed string — clearing a
    /// field is expressed through `clearFields`, never an empty replacement.
    private static func optionalPatchString(
        _ value: Any?,
        field: String
    ) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else {
            throw AIRepairError.invalidJSON
        }
        return try requiredString(string, field: field)
    }

    private static func decodeClearFields(
        _ value: Any?
    ) throws -> [AIRepairClearableField]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rawFields = value as? [String] else {
            throw AIRepairError.invalidJSON
        }
        return try rawFields.map { rawValue in
            guard let field = AIRepairClearableField(rawValue: rawValue) else {
                throw AIRepairError.unknownClearableField(rawValue)
            }
            return field
        }
    }

    private static func decodeSplitNotes(
        _ value: Any?
    ) throws -> [AIRepairNoteCandidate]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rawCandidates = value as? [[String: Any]] else {
            throw AIRepairError.invalidJSON
        }
        guard rawCandidates.count <= maximumSplitNotes else {
            throw AIRepairError.tooManySplitNotes
        }
        return try rawCandidates.map { try decodeSplitCandidate($0) }
    }

    private static func decodeSplitCandidate(
        _ object: [String: Any]
    ) throws -> AIRepairNoteCandidate {
        guard Set(object.keys) == candidateKeys else {
            throw AIRepairError.unexpectedFields
        }
        guard let rawKind = object["kind"] as? String else {
            throw AIRepairError.invalidJSON
        }
        guard let kind = KnowledgePointKind(rawValue: rawKind) else {
            throw AIRepairError.unknownNoteKind(rawKind)
        }
        let headword = try requiredString(object["headword"], field: "headword")
        let meaningZH = try requiredString(object["meaningZH"], field: "meaningZH")
        let reading = try optionalString(object["reading"], field: "reading")
        let partOfSpeech = try decodePartsOfSpeech(object["partsOfSpeech"], allowEmpty: true)
        let pitchAccent = try decodePitchAccent(object["pitchAccent"])
        let usage = try optionalString(object["usage"], field: "usage")
        let connection = try optionalString(object["connection"], field: "connection")
        let notes = try optionalString(object["notes"], field: "notes")
        let jlpt = try decodeJLPT(object["jlpt"])
        let examples = try decodeExamples(object["examples"])

        let candidate = AIRepairNoteCandidate(
            kind: kind,
            headword: headword,
            reading: reading,
            meaningZH: meaningZH,
            partOfSpeech: partOfSpeech,
            jlpt: jlpt?.rawValue,
            usage: usage,
            connection: connection,
            notes: notes,
            examples: examples,
            pitchAccent: pitchAccent
        )
        try validateCandidate(candidate)
        return candidate
    }

    /// Runs the same form validation manual content creation uses — a split
    /// candidate that could not be saved through the editor cannot be shown
    /// as an adoptable suggestion. Also rejects fields that do not exist on
    /// the candidate's note kind.
    static func validateCandidate(_ candidate: AIRepairNoteCandidate) throws {
        switch candidate.kind {
        case .vocabulary:
            for field in ["usage", "connection"]
            where (field == "usage" ? candidate.usage : candidate.connection) != nil {
                throw AIRepairError.fieldNotApplicableForKind(field)
            }
        case .grammar:
            for field in ["reading", "partOfSpeech"]
            where (field == "reading" ? candidate.reading : candidate.partOfSpeech) != nil {
                throw AIRepairError.fieldNotApplicableForKind(field)
            }
            guard candidate.pitchAccent == nil else {
                throw AIRepairError.fieldNotApplicableForKind("pitchAccent")
            }
        }
        if let jlpt = candidate.jlpt, JLPTLevel(rawValue: jlpt) == nil {
            throw AIRepairError.invalidJLPT(jlpt)
        }
        do {
            switch candidate.kind {
            case .vocabulary:
                _ = try candidate.vocabularyFormData().validatedContent()
            case .grammar:
                _ = try candidate.grammarFormData().validatedContent()
            }
        } catch let error as VocabularyValidationError {
            throw AIRepairError.invalidCandidate(String(describing: error))
        } catch let error as GrammarValidationError {
            throw AIRepairError.invalidCandidate(String(describing: error))
        }
    }

    static func decodeJLPT(_ value: Any?) throws -> JLPTLevel? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else {
            throw AIRepairError.invalidJSON
        }
        guard let level = JLPTLevel(rawValue: string) else {
            throw AIRepairError.invalidJLPT(string)
        }
        return level
    }

    private static func decodePartsOfSpeech(
        _ value: Any?,
        allowEmpty: Bool
    ) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rawValues = value as? [String], allowEmpty || !rawValues.isEmpty else {
            throw AIRepairError.invalidJSON
        }
        var parts: [VocabularyPartOfSpeech] = []
        for rawValue in rawValues {
            guard let part = VocabularyPartOfSpeech(rawValue: rawValue), !parts.contains(part) else {
                throw AIRepairError.invalidCandidate("无效或重复的词性：\(rawValue)")
            }
            parts.append(part)
        }
        return VocabularyPartOfSpeech.format(parts)
    }

    private static func decodePitchAccent(_ value: Any?) throws -> PitchAccent? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rawValue = value as? Int, let pitch = PitchAccent(rawValue: rawValue) else {
            throw AIRepairError.invalidCandidate("音调必须是非负整数")
        }
        return pitch
    }

    private static func decodeExamples(
        _ value: Any?
    ) throws -> [AIRepairExampleCandidate]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rawExamples = value as? [[String: Any]] else {
            throw AIRepairError.invalidJSON
        }
        guard rawExamples.count <= maximumExamples else {
            throw AIRepairError.tooManyExamples
        }
        return try rawExamples.map { object in
            guard Set(object.keys).isSubset(of: exampleKeys) else {
                throw AIRepairError.unexpectedFields
            }
            return try AIRepairExampleCandidate(
                japanese: requiredString(object["japanese"], field: "japanese"),
                translationZH: optionalString(
                    object["translationZH"],
                    field: "translationZH"
                )
            )
        }
    }

    private static func requiredString(_ value: Any?, field: String) throws -> String {
        guard let string = value as? String else {
            throw AIRepairError.emptyRequiredField(field)
        }
        return try requiredString(string, field: field)
    }

    private static func requiredString(_ string: String, field: String) throws -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIRepairError.emptyRequiredField(field)
        }
        try checkLength(trimmed, field: field)
        return trimmed
    }

    private static func optionalString(_ value: Any?, field: String) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else {
            throw AIRepairError.invalidJSON
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        try checkLength(trimmed, field: field)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func checkLength(_ string: String, field: String) throws {
        if let limit = fieldLimits[field], string.count > limit {
            throw AIRepairError.fieldTooLong(field)
        }
    }
}

extension AIRepairFieldPatch {
    /// Field names carrying a non-null replacement value, for the
    /// patch-vs-clearFields conflict check.
    func populatedFieldNames() -> Set<String> {
        var names = Set<String>()
        if headword != nil { names.insert("headword") }
        if reading != nil { names.insert("reading") }
        if meaningZH != nil { names.insert("meaningZH") }
        if partOfSpeech != nil { names.insert("partOfSpeech") }
        if pitchAccent != nil { names.insert("pitchAccent") }
        if usage != nil { names.insert("usage") }
        if connection != nil { names.insert("connection") }
        if notes != nil { names.insert("notes") }
        if examples != nil { names.insert("examples") }
        return names
    }

    var hasContent: Bool {
        !populatedFieldNames().isEmpty
    }
}

extension AIRepairNoteCandidate {
    func vocabularyFormData() -> VocabularyFormData {
        VocabularyFormData(
            headword: headword,
            reading: reading ?? "",
            meaningZH: meaningZH,
            partOfSpeech: partOfSpeech ?? "",
            jlpt: jlpt.flatMap { JLPTLevel(rawValue: $0) },
            exampleJapanese: examples?.first?.japanese ?? "",
            exampleTranslationZH: examples?.first?.translationZH ?? "",
            notes: notes ?? "",
            pitchAccent: pitchAccent
        )
    }

    func grammarFormData() -> GrammarFormData {
        GrammarFormData(
            grammarForm: headword,
            meaningZH: meaningZH,
            usage: usage ?? "",
            connection: connection ?? "",
            exampleJapanese: examples?.first?.japanese ?? "",
            exampleTranslationZH: examples?.first?.translationZH ?? "",
            jlpt: jlpt.flatMap { JLPTLevel(rawValue: $0) },
            notes: notes ?? ""
        )
    }
}
