import OboeDomain
import SwiftUI

/// Display text for the AI repair flow (T07). Mirrors the Adaptive center's
/// honesty rule: suggestions stay candidates — copy never claims the card
/// was or will be changed (设计 §6.4).
extension AIRepairProblemType {
    var title: String {
        switch self {
        case .tooManyMeanings: "义项过多"
        case .ambiguousPrompt: "提示含糊"
        case .lackOfContext: "缺少语境"
        case .exampleTooComplex: "例句过难"
        case .exampleNotRepresentative: "例句不典型"
        case .answerTooLong: "答案过长"
        case .similarWordsConfusion: "易与近形词混淆"
        case .multipleReadings: "读音过多"
        case .grammarScopeTooBroad: "语法范围过宽"
        case .unknown: "其他原因"
        }
    }
}

extension AIRepairSuggestionType {
    var title: String {
        switch self {
        case .rewriteMeaning: "改写释义"
        case .replaceExample: "替换例句"
        case .addContext: "补充语境"
        case .splitCard: "拆分为多张卡"
        case .shortenAnswer: "精简答案"
        case .addDisambiguation: "增加辨析"
        case .addNote: "补充说明"
        }
    }

    var systemImage: String {
        switch self {
        case .rewriteMeaning: "text.word.spacing"
        case .replaceExample: "arrow.triangle.2.circlepath"
        case .addContext: "text.append"
        case .splitCard: "rectangle.split.2x1"
        case .shortenAnswer: "scissors"
        case .addDisambiguation: "questionmark.circle"
        case .addNote: "note.text"
        }
    }
}

extension AIRepairOriginalCardDisposition {
    /// 设计 §6.4 — 三项单选；「推荐」仅是展示标记，选中仍需用户点击。
    var title: String {
        switch self {
        case .keep: "保留原卡"
        case .pause: "暂停原卡（推荐）"
        case .delete: "删除原卡"
        }
    }

    /// 每个选项的明确影响说明（§6.4：删除须显示影响）。
    var detail: String {
        switch self {
        case .keep:
            "原卡继续出现在复习中，调度与复习历史不变。"
        case .pause:
            "原卡保留调度与复习历史，但不再出现在复习中，可稍后重新启用。"
        case .delete:
            "仅删除当前学习方向；复习历史保留，但不能撤销该卡已提交的评分。"
        }
    }

    var systemImage: String {
        switch self {
        case .keep: "checkmark.circle"
        case .pause: "pause.circle"
        case .delete: "trash"
        }
    }
}

extension AIRepairPreviewField {
    var title: String {
        switch self {
        case .headword: "写法"
        case .reading: "读音"
        case .meaningZH: "释义"
        case .partOfSpeech: "词性"
        case .pitchAccent: "音调"
        case .usage: "用法"
        case .connection: "接续"
        case .notes: "说明"
        case .examples: "例句"
        }
    }
}

extension AIRepairValidatedContent {
    /// One-line candidate summary for split preview rows.
    var candidateSummary: String {
        switch self {
        case let .vocabulary(content):
            let reading = content.reading ?? "—"
            return "\(content.headword)（\(reading)）\(content.meaningZH)"
        case let .grammar(content):
            return "\(content.grammarForm)：\(content.meaningZH)"
        }
    }
}

/// The flat field set the "编辑后采用" sheet binds to (T08). Every
/// whitelisted Note field in one bag so a single form serves both note
/// kinds — kind-inapplicable fields are simply not shown.
struct AIRepairEditableFields: Equatable {
    var headword = ""
    var reading = ""
    var meaningZH = ""
    var partOfSpeech = ""
    var pitchAccent: PitchAccent?
    var usage = ""
    var connection = ""
    var notes = ""
    var exampleJapanese = ""
    var exampleTranslationZH = ""

    /// Required fields only — the domain validator does the full check
    /// before the candidate is allowed into the draft.
    var hasRequiredContent: Bool {
        !headword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !meaningZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Builds the full-replacement candidate a hand edit produces: every
    /// carried field becomes a patch value or a `clearFields` entry, so
    /// adopting the edit writes exactly what the user saw — never a stale
    /// merge of the original suggestion.
    func editedSuggestion(kind: KnowledgePointKind) -> AIRepairSuggestion {
        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var clear: [AIRepairClearableField] = []
        func optionalValue(_ raw: String, _ field: AIRepairClearableField) -> String? {
            let value = trimmed(raw)
            if value.isEmpty {
                clear.append(field)
                return nil
            }
            return value
        }
        let exampleText = trimmed(exampleJapanese)
        let exampleTranslation = trimmed(exampleTranslationZH)
        // `patch.examples` is a full-list replacement — an empty array clears
        // the note's example rather than leaving it untouched.
        let examples: [AIRepairExampleCandidate] = exampleText.isEmpty
            ? []
            : [AIRepairExampleCandidate(
                japanese: exampleText,
                translationZH: exampleTranslation.isEmpty ? nil : exampleTranslation
            )]
        let patch: AIRepairFieldPatch
        switch kind {
        case .vocabulary:
            if pitchAccent == nil {
                clear.append(.pitchAccent)
            }
            patch = AIRepairFieldPatch(
                headword: trimmed(headword),
                reading: optionalValue(reading, .reading),
                meaningZH: trimmed(meaningZH),
                partOfSpeech: optionalValue(partOfSpeech, .partOfSpeech),
                notes: optionalValue(notes, .notes),
                examples: examples,
                pitchAccent: pitchAccent
            )
        case .grammar:
            patch = AIRepairFieldPatch(
                headword: trimmed(headword),
                meaningZH: trimmed(meaningZH),
                usage: optionalValue(usage, .usage),
                connection: optionalValue(connection, .connection),
                notes: optionalValue(notes, .notes),
                examples: examples
            )
        }
        return AIRepairSuggestion(
            type: .rewriteMeaning,
            title: "手动调整",
            reason: "你在建议预览基础上编辑的内容。",
            replacement: patch,
            clearFields: clear.isEmpty ? nil : clear
        )
    }
}

extension AIRepairValidatedContent {
    var kind: KnowledgePointKind {
        switch self {
        case .vocabulary: .vocabulary
        case .grammar: .grammar
        }
    }

    /// Pre-fill values for the edit-before-adopt sheet — exactly the
    /// validated content the preview diff was computed against.
    var editableFields: AIRepairEditableFields {
        switch self {
        case let .vocabulary(content):
            return AIRepairEditableFields(
                headword: content.headword,
                reading: content.reading ?? "",
                meaningZH: content.meaningZH,
                partOfSpeech: content.partOfSpeech ?? "",
                pitchAccent: content.pitchAccent,
                notes: content.notes ?? "",
                exampleJapanese: content.example?.japanese ?? "",
                exampleTranslationZH: content.example?.translationZH ?? ""
            )
        case let .grammar(content):
            return AIRepairEditableFields(
                headword: content.grammarForm,
                meaningZH: content.meaningZH,
                usage: content.usage ?? "",
                connection: content.connection ?? "",
                notes: content.notes ?? "",
                exampleJapanese: content.example?.japanese ?? "",
                exampleTranslationZH: content.example?.translationZH ?? ""
            )
        }
    }
}

extension AIRepairDraftPhase {
    /// Whether the analyze button may be offered in this phase. `.analyzing`
    /// is excluded — the in-flight request owns the draft until it resolves
    /// (设计 §6.1: 连点只有当前请求生效).
    var canAnalyze: Bool {
        switch self {
        case .editing, .suggested, .previewing: true
        case .analyzing, .committing, .committed: false
        }
    }
}
