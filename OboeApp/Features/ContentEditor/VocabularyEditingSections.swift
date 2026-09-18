import OboeDomain
import SwiftUI

struct VocabularyRequiredSection: View {
    @Binding var form: VocabularyFormData

    var body: some View {
        Section("必填") {
            TextField("日语词形", text: $form.headword)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("vocabulary-headword-field")
            TextField("中文释义", text: $form.meaningZH)
                .accessibilityIdentifier("vocabulary-meaning-field")
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
                TextField("假名", text: $form.reading)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("vocabulary-reading-field")
                TextField("词性", text: $form.partOfSpeech)
                    .accessibilityIdentifier("vocabulary-part-of-speech-field")
                Picker("JLPT", selection: $form.jlpt) {
                    Text("未设置").tag(nil as JLPTLevel?)
                    ForEach(JLPTLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level as JLPTLevel?)
                    }
                }
                .accessibilityIdentifier("vocabulary-jlpt-picker")
                TextField("日语例句", text: $form.exampleJapanese, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("vocabulary-example-field")
                TextField("例句翻译", text: $form.exampleTranslationZH, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("vocabulary-example-translation-field")
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
            TextField("假名", text: $form.reading)
            TextField("词性", text: $form.partOfSpeech)
            Picker("JLPT", selection: $form.jlpt) {
                Text("未设置").tag(nil as JLPTLevel?)
                ForEach(JLPTLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level as JLPTLevel?)
                }
            }
        }
        Section("例句") {
            TextField("日语例句", text: $form.exampleJapanese, axis: .vertical)
            TextField("例句翻译", text: $form.exampleTranslationZH, axis: .vertical)
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
    let japaneseToChinese: Bool
    let chineseToJapanese: Bool

    var body: some View {
        if let content = try? form.validatedContent() {
            if japaneseToChinese {
                CardFacePreview(
                    title: "日语 → 中文",
                    front: [content.headword],
                    back: [
                        content.reading,
                        content.meaningZH,
                        content.partOfSpeech,
                        content.example?.japanese,
                        content.example?.translationZH
                    ].compactMap { $0 },
                    identifier: "vocabulary-ja-zh"
                )
            }
            if chineseToJapanese {
                CardFacePreview(
                    title: "中文 → 日语",
                    front: [content.meaningZH, content.partOfSpeech].compactMap { $0 },
                    back: [
                        content.headword,
                        content.reading,
                        content.example?.japanese
                    ].compactMap { $0 },
                    identifier: "vocabulary-zh-ja"
                )
            }
            if !japaneseToChinese && !chineseToJapanese {
                Text("选择方向后显示卡片预览。")
                    .foregroundStyle(.secondary)
            }
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
        return "请填写中文释义。"
    } catch VocabularyValidationError.exampleJapaneseRequired {
        return "填写例句翻译时，也需要填写日语例句。"
    } catch {
        return "内容格式不正确。"
    }
}
