import Foundation

/// Editable Note fields a preview diff can describe — the patch whitelist.
public enum AIRepairPreviewField: String, CaseIterable, Codable, Hashable, Sendable {
    case headword
    case reading
    case meaningZH
    case partOfSpeech
    case usage
    case connection
    case notes
    case examples
}

/// One before→after pair shown in the repair preview (需求 §8.6).
public struct AIRepairFieldChange: Equatable, Sendable {
    public let field: AIRepairPreviewField
    public let before: String
    public let after: String

    public init(field: AIRepairPreviewField, before: String, after: String) {
        self.field = field
        self.before = before
        self.after = after
    }
}

/// Validated note content a suggestion would produce — the same
/// `Validated*Content` values the repositories persist for manual edits.
public enum AIRepairValidatedContent: Equatable, Sendable {
    case vocabulary(ValidatedVocabularyContent)
    case grammar(ValidatedGrammarContent)
}

/// A fully validated, previewable form of one suggestion. Nothing here has
/// been written: adopting a preview is a later, transactional step (T08/T09).
public struct AIRepairSuggestionPreview: Equatable, Sendable {
    public let suggestionIndex: Int
    public let type: AIRepairSuggestionType
    public let title: String
    public let reason: String
    /// In-place repair: the note's content after applying
    /// replacement + clearFields. `nil` for `split_card`.
    public let resultContent: AIRepairValidatedContent?
    /// In-place repair: only the fields whose value would actually change.
    public let changes: [AIRepairFieldChange]
    /// `split_card`: the validated content of each new note, in order.
    public let splitContents: [AIRepairValidatedContent]

    public init(
        suggestionIndex: Int,
        type: AIRepairSuggestionType,
        title: String,
        reason: String,
        resultContent: AIRepairValidatedContent?,
        changes: [AIRepairFieldChange],
        splitContents: [AIRepairValidatedContent]
    ) {
        self.suggestionIndex = suggestionIndex
        self.type = type
        self.title = title
        self.reason = reason
        self.resultContent = resultContent
        self.changes = changes
        self.splitContents = splitContents
    }
}

/// Turns decoded suggestions into preview candidates by merging them into the
/// target note's snapshot and running the existing form validation — the same
/// checks a manual edit would face (T05 completion criterion: synthetic
/// responses yield preview candidates without any Note/Card writes).
public enum AIRepairPreviewBuilder {
    public static func previews(
        for response: AIRepairResponse,
        note: AIRepairNoteSnapshot
    ) throws -> [AIRepairSuggestionPreview] {
        try response.suggestions.enumerated().map { index, suggestion in
            try preview(suggestion, index: index, note: note)
        }
    }

    /// Validates and previews a single suggestion — used both for decoded
    /// responses and for the user-edited candidate stored in the draft.
    public static func preview(
        _ suggestion: AIRepairSuggestion,
        index: Int = 0,
        note: AIRepairNoteSnapshot
    ) throws -> AIRepairSuggestionPreview {
        try AIRepairOutputDecoder.validateSemantics(of: suggestion)
        if suggestion.type == .splitCard {
            let contents = try (suggestion.splitNotes ?? []).map(validatedContent)
            return AIRepairSuggestionPreview(
                suggestionIndex: index,
                type: suggestion.type,
                title: suggestion.title,
                reason: suggestion.reason,
                resultContent: nil,
                changes: [],
                splitContents: contents
            )
        }
        let result = try mergedContent(of: note, suggestion: suggestion)
        return AIRepairSuggestionPreview(
            suggestionIndex: index,
            type: suggestion.type,
            title: suggestion.title,
            reason: suggestion.reason,
            resultContent: result,
            changes: changes(from: note, to: result),
            splitContents: []
        )
    }

    /// Applies replacement + clearFields to the snapshot and validates the
    /// result through the same form path a manual edit uses.
    static func mergedContent(
        of note: AIRepairNoteSnapshot,
        suggestion: AIRepairSuggestion
    ) throws -> AIRepairValidatedContent {
        let patch = suggestion.replacement
        let clear = Set(suggestion.clearFields ?? [])
        switch note.kind {
        case .vocabulary:
            for field in ["usage", "connection"] where patchValue(patch, field) != nil {
                throw AIRepairError.fieldNotApplicableForKind(field)
            }
            for field in [AIRepairClearableField.usage, .connection] where clear.contains(field) {
                throw AIRepairError.fieldNotApplicableForKind(field.rawValue)
            }
            let example = mergedExample(patch: patch, note: note)
            let form = VocabularyFormData(
                headword: patch?.headword ?? note.headword,
                reading: merged(patch?.reading, cleared: clear.contains(.reading), fallback: note.reading),
                meaningZH: patch?.meaningZH ?? note.meaningZH,
                partOfSpeech: merged(
                    patch?.partOfSpeech,
                    cleared: clear.contains(.partOfSpeech),
                    fallback: note.partOfSpeech
                ),
                jlpt: note.jlpt,
                exampleJapanese: example?.japanese ?? "",
                exampleTranslationZH: example?.translationZH ?? "",
                notes: merged(patch?.notes, cleared: clear.contains(.notes), fallback: note.notes)
            )
            do {
                return .vocabulary(try form.validatedContent())
            } catch let error as VocabularyValidationError {
                throw AIRepairError.invalidCandidate(String(describing: error))
            }
        case .grammar:
            for field in ["reading", "partOfSpeech"] where patchValue(patch, field) != nil {
                throw AIRepairError.fieldNotApplicableForKind(field)
            }
            for field in [AIRepairClearableField.reading, .partOfSpeech] where clear.contains(field) {
                throw AIRepairError.fieldNotApplicableForKind(field.rawValue)
            }
            let example = mergedExample(patch: patch, note: note)
            let form = GrammarFormData(
                grammarForm: patch?.headword ?? note.headword,
                meaningZH: patch?.meaningZH ?? note.meaningZH,
                usage: merged(patch?.usage, cleared: clear.contains(.usage), fallback: note.usage),
                connection: merged(
                    patch?.connection,
                    cleared: clear.contains(.connection),
                    fallback: note.connection
                ),
                exampleJapanese: example?.japanese ?? "",
                exampleTranslationZH: example?.translationZH ?? "",
                jlpt: note.jlpt,
                notes: merged(patch?.notes, cleared: clear.contains(.notes), fallback: note.notes)
            )
            do {
                return .grammar(try form.validatedContent())
            } catch let error as GrammarValidationError {
                throw AIRepairError.invalidCandidate(String(describing: error))
            }
        }
    }

    /// Cleared fields win over the snapshot; an absent patch value keeps the
    /// current content. A patch value for a cleared field was already rejected
    /// as a conflict upstream.
    private static func merged(
        _ patchValue: String?,
        cleared: Bool,
        fallback: String?
    ) -> String {
        if cleared { return "" }
        return patchValue ?? fallback ?? ""
    }

    /// `patch.examples` replaces the whole example list; absent keeps the
    /// snapshot's. The form model carries a single example.
    private static func mergedExample(
        patch: AIRepairFieldPatch?,
        note: AIRepairNoteSnapshot
    ) -> AIRepairExampleCandidate? {
        if let examples = patch?.examples {
            return examples.first
        }
        return note.examples.first
    }

    private static func patchValue(_ patch: AIRepairFieldPatch?, _ field: String) -> String? {
        guard let patch else { return nil }
        switch field {
        case "headword": return patch.headword
        case "reading": return patch.reading
        case "meaningZH": return patch.meaningZH
        case "partOfSpeech": return patch.partOfSpeech
        case "usage": return patch.usage
        case "connection": return patch.connection
        case "notes": return patch.notes
        default: return nil
        }
    }

    private static func validatedContent(
        of candidate: AIRepairNoteCandidate
    ) throws -> AIRepairValidatedContent {
        do {
            switch candidate.kind {
            case .vocabulary:
                return .vocabulary(try candidate.vocabularyFormData().validatedContent())
            case .grammar:
                return .grammar(try candidate.grammarFormData().validatedContent())
            }
        } catch let error as VocabularyValidationError {
            throw AIRepairError.invalidCandidate(String(describing: error))
        } catch let error as GrammarValidationError {
            throw AIRepairError.invalidCandidate(String(describing: error))
        }
    }

    private static func changes(
        from note: AIRepairNoteSnapshot,
        to result: AIRepairValidatedContent
    ) -> [AIRepairFieldChange] {
        fieldValues(note).compactMap { field, before in
            let after = fieldValue(result, field)
            guard before != after else { return nil }
            return AIRepairFieldChange(field: field, before: before, after: after)
        }
    }

    private static func fieldValues(
        _ note: AIRepairNoteSnapshot
    ) -> [(AIRepairPreviewField, String)] {
        switch note.kind {
        case .vocabulary:
            return [
                (.headword, note.headword),
                (.reading, note.reading ?? ""),
                (.meaningZH, note.meaningZH),
                (.partOfSpeech, note.partOfSpeech ?? ""),
                (.notes, note.notes ?? ""),
                (.examples, render(note.examples))
            ]
        case .grammar:
            return [
                (.headword, note.headword),
                (.meaningZH, note.meaningZH),
                (.usage, note.usage ?? ""),
                (.connection, note.connection ?? ""),
                (.notes, note.notes ?? ""),
                (.examples, render(note.examples))
            ]
        }
    }

    private static func fieldValue(
        _ content: AIRepairValidatedContent,
        _ field: AIRepairPreviewField
    ) -> String {
        switch content {
        case let .vocabulary(value):
            switch field {
            case .headword: return value.headword
            case .reading: return value.reading ?? ""
            case .meaningZH: return value.meaningZH
            case .partOfSpeech: return value.partOfSpeech ?? ""
            case .notes: return value.notes ?? ""
            case .examples:
                return value.example.map {
                    render([AIRepairExampleCandidate(
                        japanese: $0.japanese,
                        translationZH: $0.translationZH
                    )])
                } ?? ""
            default: return ""
            }
        case let .grammar(value):
            switch field {
            case .headword: return value.grammarForm
            case .meaningZH: return value.meaningZH
            case .usage: return value.usage ?? ""
            case .connection: return value.connection ?? ""
            case .notes: return value.notes ?? ""
            case .examples:
                return value.example.map {
                    render([AIRepairExampleCandidate(
                        japanese: $0.japanese,
                        translationZH: $0.translationZH
                    )])
                } ?? ""
            default: return ""
            }
        }
    }

    private static func render(_ examples: [AIRepairExampleCandidate]) -> String {
        examples.map { example in
            if let translation = example.translationZH {
                return "\(example.japanese) ／ \(translation)"
            }
            return example.japanese
        }.joined(separator: "\n")
    }
}
