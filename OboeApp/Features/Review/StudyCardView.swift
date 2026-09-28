import OboeDomain
import OboeInfrastructure
import SwiftUI
import UIKit

struct StudyCardView: View {
    let content: ReviewCardContent
    let isAnswerVisible: Bool
    let isSpeechAvailable: Bool
    /// Warning/leech status shown as a lightweight reminder on the ANSWER face
    /// only (T03). Nil on the question face — the prompt must never hint at
    /// adaptive status. Already gated by `leechRemindersEnabled` upstream.
    let leechReminderStatus: AdaptiveCardStatus?
    let onPrimarySpeech: () -> Void
    let onExampleSpeech: () -> Void
    /// T17: the listening card's question-face prompt — its own channel,
    /// never routed through the word-audio gate.
    var onListeningPrompt: (() -> Void)? = nil
    /// T18: generic playback status for the listening question face.
    var listeningPromptStatus: ListeningPromptPlaybackStatus = .idle
    /// T07 answer-face AI repair entry — nil hides it (question face never
    /// shows it either way).
    var typedAnswer: String? = nil
    /// T13 answer-face comparison feedback — informational only, never a
    /// rating preselection.
    var typedAnswerComparison: RecallComparison? = nil
    var onAIRepair: (() -> Void)? = nil
    /// S07：背面「来源」折叠区——nil 时整块不渲染（旧调用点零变化）。
    var sourceContextRepository: (any SourceContextRepository)? = nil
    var inboxImageStore: InboxImageStore? = nil

    @State private var primarySource: SourceContext?
    @State private var sourceImageData: Data?
    @State private var sourceImageUnavailable = false
    @State private var isSourceExpanded = false
    /// S14（设计 §9.3）：cloze 正面的 hint 是「用户可选」——默认收起，
    /// 由用户显式展开；hint 内容由作者撰写，不得直接含答案。
    @State private var isClozeHintRevealed = false

    /// T14: when the answer face appears, VoiceOver focus moves to its first
    /// heading so the reveal is announced in order. The question face never
    /// builds answer content, so nothing readable exists before reveal.
    @AccessibilityFocusState private var yourAnswerHeadingFocused: Bool
    @AccessibilityFocusState private var standardAnswerHeadingFocused: Bool

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
                    .onAppear {
                        // The input field and confirm button leave the tree at
                        // this moment — park VoiceOver on the first answer
                        // heading instead of letting focus drop unpredictably.
                        DispatchQueue.main.async {
                            if typedAnswer == nil {
                                standardAnswerHeadingFocused = true
                            } else {
                                yourAnswerHeadingFocused = true
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: content.noteID) {
            primarySource = nil
            sourceImageData = nil
            sourceImageUnavailable = false
            isClozeHintRevealed = false
            guard let sourceContextRepository else { return }
            primarySource = try? await sourceContextRepository
                .fetchPrimary(noteID: content.noteID)
        }
    }

    @ViewBuilder
    private var question: some View {
        if content.templateKind == .vocabularyListening {
            ListeningQuestionView(
                isSpeechAvailable: isSpeechAvailable,
                status: listeningPromptStatus,
                onPlay: onListeningPrompt ?? {}
            )
        } else {
            visualQuestion
        }
    }

    private var visualQuestion: some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
            Text(questionHint)
                .oboeFont(.hint)
                .foregroundStyle(.secondary)
            Text(questionText)
                .oboeFont(questionFontStyle)
                .minimumScaleFactor(0.55)
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
            if content.templateKind == .sentenceCloze,
               let hint = content.cloze?.hint,
               !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clozeHintControl(hint)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-question")
    }

    /// S14：挖空 hint 的用户可选入口——收起时只有「显示提示」按钮
    /// （label 不含 hint 内容，VoiceOver 不会提前读出）；展开后展示
    /// hint 原文。按钮没有泄题面：hint 本身是作者写的提示语。
    @ViewBuilder
    private func clozeHintControl(_ hint: String) -> some View {
        if isClozeHintRevealed {
            VStack(alignment: .leading, spacing: OboeTheme.Spacing.xs) {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("隐藏提示") { isClozeHintRevealed = false }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(OboeTheme.Colors.accent)
                    .accessibilityIdentifier("review-cloze-hint-hide")
            }
        } else {
            Button("显示提示") { isClozeHintRevealed = true }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(OboeTheme.Colors.accent)
                .accessibilityIdentifier("review-cloze-hint-reveal")
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.md) {
            if let typedAnswer {
                Text("你的答案")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($yourAnswerHeadingFocused)
                Text(typedAnswer)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("review-your-answer")
                if let typedAnswerComparison {
                    Text(typedAnswerComparison.feedbackText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(typedAnswerComparison.tint)
                        .accessibilityIdentifier("review-comparison-feedback")
                }
            }
            Text(typedAnswer == nil ? "答案" : "标准答案")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($standardAnswerHeadingFocused)
            if let leechReminderStatus {
                leechReminder(leechReminderStatus)
            }
            switch content.templateKind {
            case .vocabularyJapaneseToChinese:
                fact("假名", content.reading, font: .kana, secondary: true)
                optionalFact("音调", pitchAccentDisplayValue(content.pitchAccent))
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
                optionalFact("音调", pitchAccentDisplayValue(content.pitchAccent))
                exampleFacts
                optionalFact("说明", content.notes)
            case .vocabularyListening:
                speechFact(
                    "日语", content.headword,
                    font: .answerHeadword,
                    identifier: "review-answer-speech-button",
                    action: onPrimarySpeech
                )
                fact("假名", content.reading, font: .kana, secondary: true)
                optionalFact("音调", pitchAccentDisplayValue(content.pitchAccent))
                fact("中文", content.meaningZH, font: .meaningZH)
                optionalFact("词性", content.partOfSpeech)
                exampleFacts
                optionalFact("说明", content.notes)
            case .grammarFormToExplanation:
                fact("含义", content.meaningZH, font: .meaningZH)
                optionalFact("接续", content.connection, font: .exampleJapanese, secondary: false)
                optionalFact("用法", content.usage, font: .exampleJapanese, secondary: false)
                exampleFacts
                optionalFact("注意", content.notes)
            case .sentenceCloze:
                // S12 背面：整句（含答案）只在背面出现；正面恒为遮罩句。
                speechFact(
                    "句子", content.headword,
                    font: .answerHeadword,
                    identifier: "review-answer-speech-button",
                    action: onPrimarySpeech
                )
                if let cloze = content.cloze {
                    fact("答案", cloze.targetSurface, font: .answerHeadword)
                    optionalFact("读音", cloze.targetReading, font: .kana)
                    optionalFact("原形", cloze.targetLemma, font: .kana)
                    let alternates = cloze.acceptedAnswers
                        .filter { $0 != cloze.targetSurface }
                    optionalFact(
                        "其他可接受答案",
                        alternates.isEmpty ? nil : alternates.joined(separator: " ・ "),
                        font: .kana
                    )
                    optionalFact("提示", cloze.hint)
                }
                fact("中文", content.meaningZH, font: .meaningZH)
                optionalFact("说明", content.notes)
            }
            if let onAIRepair {
                if content.templateKind == .sentenceCloze {
                    // S14（设计 §9.1）：AI 修卡只支持词汇/语法——句子卡走
                    // 手动编辑（S13 SentenceNoteEditView）。入口保留但置灰
                    // 并附说明，不开 AIRepairView（service 层亦拒）。
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text("AI 修卡")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("AI 修卡（句子卡不支持）")
                        .accessibilityIdentifier("review-ai-repair-disabled")
                        Text("句子卡暂不支持 AI 修卡，可在笔记详情中手动编辑。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(action: onAIRepair) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text("AI 修卡")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(OboeTheme.Colors.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            OboeTheme.Colors.accent.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("review-ai-repair-entry")
                }
            }
            if let primarySource {
                sourceSection(primarySource)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-answer")
    }

    /// S07 来源区（设计 §6.4）：折叠展示主来源——原句、出处元信息、
    /// OCR 原图（文件缺失时降级为「原图不可用」文案，不阻塞复习）。
    @ViewBuilder
    private func sourceSection(_ context: SourceContext) -> some View {
        DisclosureGroup(isExpanded: $isSourceExpanded) {
            VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
                if let sentence = context.originalSentence, !sentence.isEmpty {
                    Text(sentence)
                        .oboeFont(.exampleJapanese)
                        .textSelection(.enabled)
                }
                if let surrounding = context.surroundingText, !surrounding.isEmpty {
                    Text(surrounding)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                sourceMetadataRow(context)
                sourceImageBlock(context)
            }
        } label: {
            Label("来源", systemImage: "quote.opening")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("review-source-context")
        .onChange(of: isSourceExpanded) { _, expanded in
            guard expanded, sourceImageData == nil, !sourceImageUnavailable,
                  let reference = context.imageReference,
                  let inboxImageStore else { return }
            Task {
                if inboxImageStore.exists(reference),
                   let data = try? inboxImageStore.loadPreviewData(
                       for: reference
                   ) {
                    sourceImageData = data
                } else {
                    sourceImageUnavailable = true
                }
            }
        }
    }

    @ViewBuilder
    private func sourceMetadataRow(_ context: SourceContext) -> some View {
        let parts = [
            context.sourceTitle,
            context.sourceApp,
            context.sourceURL
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty || context.dictionaryEntryID != nil {
            HStack(spacing: 6) {
                ForEach(parts, id: \.self) { part in
                    Text(part)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if context.dictionaryEntryID != nil {
                    Text("词典")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceImageBlock(_ context: SourceContext) -> some View {
        if context.imageReference != nil {
            if let sourceImageData,
               let image = UIImage(data: sourceImageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if sourceImageUnavailable {
                Text("原图不可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review-source-image-missing")
            } else if isSourceExpanded {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// Answer-face reminder wording: a gentle recall signal, never a mastery
    /// claim — "这张卡近期经常遗忘，建议留意。"
    private func leechReminder(_ status: AdaptiveCardStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.arrow.circlepath")
            Text(status == .leech ? "这张卡近期经常遗忘，建议留意。" : "这张卡最近偏难，建议留意。")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review-leech-reminder")
        .font(.footnote.weight(.medium))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(status.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
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
        switch content.templateKind {
        case .vocabularyChineseToJapanese:
            return content.meaningZH
        case .vocabularyListening:
            // Unreachable — ListeningQuestionView owns the listening prompt
            // face and never renders text content.
            return ""
        case .sentenceCloze:
            // S12（设计 §9.3）：cloze 正面只渲染遮罩句——headword 即含
            // 答案的原句快照，直接展示等于泄题。定义缺失时仓储层已抛错，
            // 这里再兜底为不含任何答案字符的占位符。
            guard let cloze = content.cloze else { return "＿" }
            return ClozeValidator.maskedSentence(
                cloze.sentenceSnapshot,
                range: cloze.range,
                blank: String(
                    repeating: "＿",
                    count: max(cloze.targetSurface.count, 1)
                )
            )
        case .vocabularyJapaneseToChinese, .grammarFormToExplanation:
            return content.headword
        }
    }

    /// 中文→日语问题面是整句中文，用词头 46pt 会溢出/撑爆卡面——
    /// 句级 prompt 一档（26pt）+ minimumScaleFactor 兜底长串。
    /// cloze 遮罩句同为句级文本，共享 prompt 档。
    private var questionFontStyle: OboeFontStyle {
        switch content.templateKind {
        case .vocabularyChineseToJapanese, .sentenceCloze: .questionPrompt
        case .vocabularyJapaneseToChinese, .vocabularyListening,
             .grammarFormToExplanation: .questionHeadword
        }
    }

    private var questionHint: String {
        switch content.templateKind {
        case .vocabularyJapaneseToChinese: "请回忆中文含义"
        case .vocabularyChineseToJapanese: "请回忆日语表达"
        case .vocabularyListening: "请听音频回忆含义"
        case .grammarFormToExplanation: "请回忆语法含义和用法"
        case .sentenceCloze: "请输入挖空处的日语"
        }
    }
}
