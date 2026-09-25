import OboeDomain
import SwiftUI

/// 受控词性多选入口。底层继续绑定兼容旧数据库的字符串，但所有新写入都
/// 通过 `VocabularyPartOfSpeech.format` 产生固定顺序。未知旧值只读展示；
/// 只有用户实际切换选项并点“完成”时才会被受控选择替换。
struct VocabularyPartOfSpeechField: View {
    @Binding var value: String
    var accessibilityIdentifier: String

    @State private var isPresented = false
    @State private var draft: Set<VocabularyPartOfSpeech> = []
    @State private var legacyUnknown: [String] = []
    @State private var didModifyDraft = false

    var body: some View {
        Button {
            prepareDraft()
            isPresented = true
        } label: {
            HStack {
                Text("词性")
                    .foregroundStyle(.primary)
                Spacer()
                Text(summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityLabel("词性")
        .accessibilityValue(summary)
        .accessibilityHint("双击打开词性多选列表")
        .accessibilityIdentifier(accessibilityIdentifier)
        .adaptivePresentation(role: .quickPicker, isPresented: $isPresented) {
            VocabularyPartOfSpeechPickerSheet(
                draft: $draft,
                legacyUnknown: legacyUnknown,
                didModifyDraft: $didModifyDraft,
                onCancel: { isPresented = false },
                onDone: completeSelection
            )
        }
    }

    private var summary: String {
        let parsed = VocabularyPartOfSpeech.parse(value)
        let known = VocabularyPartOfSpeech.format(parsed.known)
        if parsed.unknown.isEmpty {
            return known ?? "未设置"
        }
        if let known {
            return "\(known) · 含旧值"
        }
        return "旧值：\(parsed.unknown.joined(separator: " / "))"
    }

    private func prepareDraft() {
        let parsed = VocabularyPartOfSpeech.parse(value)
        draft = Set(parsed.known)
        legacyUnknown = parsed.unknown
        didModifyDraft = false
    }

    private func completeSelection() {
        if didModifyDraft {
            value = VocabularyPartOfSpeech.format(draft) ?? ""
        }
        isPresented = false
    }
}

private struct VocabularyPartOfSpeechPickerSheet: View {
    @Binding var draft: Set<VocabularyPartOfSpeech>
    let legacyUnknown: [String]
    @Binding var didModifyDraft: Bool
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                controlledOptionsSection
                legacyValuesSection
            }
            .navigationTitle("选择词性")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .accessibilityIdentifier("part-of-speech-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onDone)
                        .accessibilityIdentifier("part-of-speech-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var controlledOptionsSection: some View {
        Section {
            ForEach(VocabularyPartOfSpeech.allCases, id: \.self) { part in
                VocabularyPartOfSpeechOptionRow(
                    part: part,
                    isSelected: draft.contains(part)
                ) {
                    toggle(part)
                }
            }
        } header: {
            Text("可多选")
        } footer: {
            Text("保存时会按固定顺序组合；允许不选择词性。")
        }
    }

    @ViewBuilder
    private var legacyValuesSection: some View {
        if !legacyUnknown.isEmpty {
            Section {
                ForEach(legacyUnknown, id: \.self) { item in
                    LabeledContent("旧值", value: item)
                }
            } header: {
                Text("旧值（只读）")
            } footer: {
                Text("直接取消或不改选可保留旧值；主动改选后将由上方受控词性替换。")
            }
        }
    }

    private func toggle(_ part: VocabularyPartOfSpeech) {
        if draft.contains(part) {
            draft.remove(part)
        } else {
            draft.insert(part)
        }
        didModifyDraft = true
    }
}

private struct VocabularyPartOfSpeechOptionRow: View {
    let part: VocabularyPartOfSpeech
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(part.rawValue)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityLabel(part.rawValue)
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityHint("双击切换选择状态")
        .accessibilityIdentifier("part-of-speech-option-\(part.accessibilityKey)")
    }
}

private extension VocabularyPartOfSpeech {
    var accessibilityKey: String {
        switch self {
        case .noun: "noun"
        case .pronoun: "pronoun"
        case .godanVerb: "godan-verb"
        case .ichidanVerb: "ichidan-verb"
        case .suruVerb: "suru-verb"
        case .kuruVerb: "kuru-verb"
        case .transitive: "transitive"
        case .intransitive: "intransitive"
        case .iAdjective: "i-adjective"
        case .naAdjective: "na-adjective"
        case .adverb: "adverb"
        case .particle: "particle"
        case .auxiliaryVerb: "auxiliary-verb"
        case .conjunction: "conjunction"
        case .interjection: "interjection"
        case .counter: "counter"
        case .prefix: "prefix"
        case .suffix: "suffix"
        case .expression: "expression"
        }
    }
}

/// 读音驱动的东京式音调选择器。合法选项始终来自当前读音的
/// `0...moraCount`；已有值失效时保留并标红，等待用户主动修正。
struct VocabularyPitchAccentField: View {
    @Binding var reading: String
    @Binding var pitchAccent: PitchAccent?
    var accessibilityIdentifier: String

    private var trimmedReading: String {
        reading.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var moraCount: Int {
        JapaneseMoraCounter.moraCount(of: trimmedReading)
    }

    private var isInvalid: Bool {
        guard let pitchAccent else { return false }
        return !pitchAccent.isConsistent(withReading: trimmedReading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("音调", selection: $pitchAccent) {
                Text("未设置").tag(nil as PitchAccent?)
                if !trimmedReading.isEmpty {
                    ForEach(0...moraCount, id: \.self) { value in
                        Text(value == 0 ? "0（平板型）" : String(value))
                            .tag(PitchAccent(rawValue: value) as PitchAccent?)
                    }
                }
                if let pitchAccent, isInvalid {
                    Text("\(pitchAccent.rawValue)（与当前读音不符）")
                        .tag(pitchAccent as PitchAccent?)
                }
            }
            .disabled(trimmedReading.isEmpty)
            .tint(isInvalid ? .red : nil)
            .accessibilityIdentifier(accessibilityIdentifier)

            if isInvalid {
                Text("当前音调超出读音的 mora 范围，请重新选择或设为未设置。")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(accessibilityIdentifier)-error")
            } else if trimmedReading.isEmpty {
                Text("先填写假名读音，再按读音的 mora 数选择音调。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("东京式音调：0 为平板型，1 以上为从词首按 mora 计算的音调核位置。当前读音按 \(moraCount) 个 mora 计，可选 0–\(moraCount)。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

func pitchAccentDisplayValue(_ pitchAccent: PitchAccent?) -> String? {
    guard let pitchAccent else { return nil }
    return pitchAccent.rawValue == 0 ? "0（平板型）" : String(pitchAccent.rawValue)
}

struct VocabularyRequiredSection: View {
    @Binding var form: VocabularyFormData

    var body: some View {
        Section("必填") {
            LanguageHintTextField(
                placeholder: "日语词形",
                text: $form.headword,
                hint: .japanese,
                identifier: "vocabulary-headword-field"
            )
            LanguageHintTextField(
                placeholder: "释义（中文或英文）",
                text: $form.meaningZH,
                hint: .chinesePinyin,
                identifier: "vocabulary-meaning-field"
            )
        }
    }
}

struct VocabularyAdditionalFieldsSection: View {
    @Binding var form: VocabularyFormData
    @Binding var tagsText: String
    @Binding var isExpanded: Bool

    var body: some View {
        Section {
            DisclosureGroup("更多字段（可选）", isExpanded: $isExpanded) {
                LanguageHintTextField(
                    placeholder: "假名",
                    text: $form.reading,
                    hint: .japanese,
                    identifier: "vocabulary-reading-field"
                )
                VocabularyPitchAccentField(
                    reading: $form.reading,
                    pitchAccent: $form.pitchAccent,
                    accessibilityIdentifier: "vocabulary-pitch-accent-picker"
                )
                VocabularyPartOfSpeechField(
                    value: $form.partOfSpeech,
                    accessibilityIdentifier: "vocabulary-part-of-speech-field"
                )
                Picker("JLPT", selection: $form.jlpt) {
                    Text("未设置").tag(nil as JLPTLevel?)
                    ForEach(JLPTLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level as JLPTLevel?)
                    }
                }
                .accessibilityIdentifier("vocabulary-jlpt-picker")
                LanguageHintEditor(
                    placeholder: "日语例句",
                    text: $form.exampleJapanese,
                    hint: .japanese,
                    identifier: "vocabulary-example-field"
                )
                LanguageHintEditor(
                    placeholder: "例句翻译",
                    text: $form.exampleTranslationZH,
                    hint: .chinesePinyin,
                    identifier: "vocabulary-example-translation-field"
                )
                TextField("标签（逗号或换行分隔）", text: $tagsText)
                    .accessibilityIdentifier("vocabulary-new-tags-field")
                TextEditor(text: $form.notes)
                    .frame(minHeight: 90)
                    .accessibilityIdentifier("vocabulary-notes-field")
            }
        } footer: {
            Text("标签、例句、备注和卡片会在同一事务保存。")
        }
    }
}

struct VocabularyFormSections: View {
    @Binding var form: VocabularyFormData

    var body: some View {
        VocabularyRequiredSection(form: $form)
        Section("词条信息") {
            LanguageHintTextField(
                placeholder: "假名",
                text: $form.reading,
                hint: .japanese,
                identifier: ""
            )
            VocabularyPitchAccentField(
                reading: $form.reading,
                pitchAccent: $form.pitchAccent,
                accessibilityIdentifier: "vocabulary-edit-pitch-accent-picker"
            )
            VocabularyPartOfSpeechField(
                value: $form.partOfSpeech,
                accessibilityIdentifier: "vocabulary-edit-part-of-speech-field"
            )
            Picker("JLPT", selection: $form.jlpt) {
                Text("未设置").tag(nil as JLPTLevel?)
                ForEach(JLPTLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level as JLPTLevel?)
                }
            }
        }
        Section("例句") {
            LanguageHintEditor(
                placeholder: "日语例句",
                text: $form.exampleJapanese,
                hint: .japanese,
                identifier: ""
            )
            LanguageHintEditor(
                placeholder: "例句翻译",
                text: $form.exampleTranslationZH,
                hint: .chinesePinyin,
                identifier: ""
            )
        }
        Section("备注") {
            TextEditor(text: $form.notes)
                .frame(minHeight: 90)
        }
    }
}

struct VocabularyPreview: View {
    let form: VocabularyFormData

    var body: some View {
        if let content = try? form.validatedContent() {
            VStack(alignment: .leading, spacing: 6) {
                Text(content.headword)
                    .font(.title3.bold())
                if let reading = content.reading {
                    Text(reading)
                        .foregroundStyle(.secondary)
                }
                if let pitch = pitchAccentDisplayValue(content.pitchAccent) {
                    Text("音调：\(pitch)")
                        .foregroundStyle(.secondary)
                }
                Text(content.meaningZH)
                if let example = content.example {
                    Divider()
                    Text(example.japanese)
                    if let translation = example.translationZH {
                        Text(translation)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text(vocabularyValidationMessage(for: form))
                .foregroundStyle(.secondary)
        }
    }
}

struct VocabularyCardPreviews: View {
    let form: VocabularyFormData

    var body: some View {
        if let content = try? form.validatedContent() {
            CardFacePreview(
                title: "日语 → 中文",
                front: [content.headword],
                back: [
                    content.reading,
                    pitchAccentDisplayValue(content.pitchAccent).map { "音调：\($0)" },
                    content.meaningZH,
                    content.partOfSpeech,
                    content.example?.japanese,
                    content.example?.translationZH
                ].compactMap { $0 },
                identifier: "vocabulary-ja-zh"
            )
            CardFacePreview(
                title: "中文 → 日语",
                front: [content.meaningZH, content.partOfSpeech].compactMap { $0 },
                back: [
                    content.headword,
                    content.reading,
                    pitchAccentDisplayValue(content.pitchAccent).map { "音调：\($0)" },
                    content.example?.japanese
                ].compactMap { $0 },
                identifier: "vocabulary-zh-ja"
            )
            // The question face is an audio prompt — never the text.
            CardFacePreview(
                title: "听力 → 中文",
                front: ["🔊 播放单词音频"],
                back: [
                    content.headword,
                    content.reading,
                    pitchAccentDisplayValue(content.pitchAccent).map { "音调：\($0)" },
                    content.meaningZH,
                    content.partOfSpeech,
                    content.example?.japanese
                ].compactMap { $0 },
                identifier: "vocabulary-listening"
            )
        } else {
            Text("填写必填内容后显示卡片预览。")
                .foregroundStyle(.secondary)
        }
    }
}

func vocabularyValidationMessage(for form: VocabularyFormData) -> String {
    do {
        _ = try form.validatedContent()
        return "内容可用于正式保存。"
    } catch VocabularyValidationError.headwordRequired {
        return "请填写日语词形。"
    } catch VocabularyValidationError.meaningRequired {
        return "请填写释义。"
    } catch VocabularyValidationError.exampleJapaneseRequired {
        return "填写例句翻译时，也需要填写日语例句。"
    } catch VocabularyValidationError.pitchAccentRequiresReading {
        return "设置音调前请先填写假名读音。"
    } catch VocabularyValidationError.pitchAccentExceedsMora {
        return "音调不能超过当前读音的 mora 数。"
    } catch {
        return "内容格式不正确。"
    }
}
