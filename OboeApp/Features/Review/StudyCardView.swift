import OboeDomain
import SwiftUI

struct StudyCardView: View {
    let content: ReviewCardContent
    let isAnswerVisible: Bool
    let isSpeechAvailable: Bool
    let onPrimarySpeech: () -> Void
    let onExampleSpeech: () -> Void

    var body: some View {
        OboeCardSurface {
            VStack(alignment: .leading, spacing: OboeTheme.Spacing.lg) {
                question
                if isAnswerVisible {
                    VStack(alignment: .leading, spacing: OboeTheme.Spacing.lg) {
                        Divider()
                        answer
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
            Text(questionHint)
                .oboeFont(.hint)
                .foregroundStyle(.secondary)
            Text(questionText)
                .oboeFont(.questionHeadword)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if ReviewSpeechPolicy(content: content).exposesJapaneseOnQuestion {
                OboeSpeechButton("播放日语发音", action: onPrimarySpeech)
                    .disabled(!isSpeechAvailable)
                    .accessibilityIdentifier("review-question-speech-button")
            }
            if content.templateKind == .vocabularyChineseToJapanese,
               let partOfSpeech = content.partOfSpeech {
                Text(partOfSpeech)
                    .oboeFont(.hint)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-question")
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.md) {
            Text("答案")
                .font(.headline)
            switch content.templateKind {
            case .vocabularyJapaneseToChinese:
                fact("假名", content.reading, font: .kana, secondary: true)
                fact("中文", content.meaningZH, font: .meaningZH)
                optionalFact("词性", content.partOfSpeech)
                exampleFacts
                optionalFact("说明", content.notes)
            case .vocabularyChineseToJapanese:
                speechFact(
                    "日语", content.headword,
                    font: .answerHeadword,
                    identifier: "review-answer-speech-button",
                    action: onPrimarySpeech
                )
                fact("假名", content.reading, font: .kana, secondary: true)
                exampleFacts
                optionalFact("说明", content.notes)
            case .grammarFormToExplanation:
                fact("含义", content.meaningZH, font: .meaningZH)
                optionalFact("接续", content.connection, font: .exampleJapanese, secondary: false)
                optionalFact("用法", content.usage, font: .exampleJapanese, secondary: false)
                exampleFacts
                optionalFact("注意", content.notes)
            }
        }
        .accessibilityIdentifier("review-answer")
    }

    @ViewBuilder
    private var exampleFacts: some View {
        if let example = content.exampleJapanese, !example.isEmpty {
            speechFact(
                "例句", example,
                font: .exampleJapanese,
                identifier: "review-example-speech-button",
                action: onExampleSpeech
            )
        }
        optionalFact("例句翻译", content.exampleTranslationZH)
    }

    @ViewBuilder
    private func fact(
        _ label: String,
        _ value: String?,
        font: OboeFontStyle,
        secondary: Bool = false
    ) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .oboeFont(font)
                    .foregroundStyle(secondary ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func optionalFact(
        _ label: String,
        _ value: String?,
        font: OboeFontStyle = .translation,
        secondary: Bool = true
    ) -> some View {
        fact(label, value, font: font, secondary: secondary)
    }

    private func speechFact(
        _ label: String,
        _ value: String,
        font: OboeFontStyle,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.xs) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .oboeFont(font)
                .textSelection(.enabled)
            OboeSpeechButton("播放\(label)发音", action: action)
                .disabled(!isSpeechAvailable)
                .accessibilityIdentifier(identifier)
        }
    }

    private var questionText: String {
        content.templateKind == .vocabularyChineseToJapanese
            ? content.meaningZH
            : content.headword
    }

    private var questionHint: String {
        switch content.templateKind {
        case .vocabularyJapaneseToChinese: "请回忆中文含义"
        case .vocabularyChineseToJapanese: "请回忆日语表达"
        case .grammarFormToExplanation: "请回忆语法含义和用法"
        }
    }
}
