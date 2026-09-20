import OboeDomain
import SwiftUI

struct GrammarRequiredSection: View {
    @Binding var form: GrammarFormData

    var body: some View {
        Section("必填") {
            LanguageHintTextField(
                placeholder: "语法形式",
                text: $form.grammarForm,
                hint: .japanese,
                identifier: "grammar-form-field"
            )
            LanguageHintTextField(
                placeholder: "中文含义",
                text: $form.meaningZH,
                hint: .chinesePinyin,
                identifier: "grammar-meaning-field"
            )
        }
    }
}

struct GrammarAdditionalFieldsSection: View {
    @Binding var form: GrammarFormData
    @Binding var tagsText: String
    @Binding var isExpanded: Bool

    var body: some View {
        Section {
            DisclosureGroup("更多字段（可选）", isExpanded: $isExpanded) {
                LanguageHintEditor(
                    placeholder: "使用说明",
                    text: $form.usage,
                    hint: .chinesePinyin,
                    identifier: "grammar-usage-field"
                )
                LanguageHintEditor(
                    placeholder: "接续方式",
                    text: $form.connection,
                    hint: .japanese,
                    identifier: "grammar-connection-field"
                )
                Picker("JLPT", selection: $form.jlpt) {
                    Text("未设置").tag(nil as JLPTLevel?)
                    ForEach(JLPTLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level as JLPTLevel?)
                    }
                }
                .accessibilityIdentifier("grammar-jlpt-picker")
                LanguageHintEditor(
                    placeholder: "日语例句",
                    text: $form.exampleJapanese,
                    hint: .japanese,
                    identifier: "grammar-example-field"
                )
                LanguageHintEditor(
                    placeholder: "例句翻译",
                    text: $form.exampleTranslationZH,
                    hint: .chinesePinyin,
                    identifier: "grammar-example-translation-field"
                )
                TextField("标签（逗号或换行分隔）", text: $tagsText)
                    .accessibilityIdentifier("grammar-new-tags-field")
                TextEditor(text: $form.notes)
                    .frame(minHeight: 90)
                    .accessibilityIdentifier("grammar-notes-field")
            }
        } footer: {
            Text("标签、例句、注意事项和卡片会在同一事务保存。")
        }
    }
}

struct GrammarFormSections: View {
    @Binding var form: GrammarFormData

    var body: some View {
        GrammarRequiredSection(form: $form)
        Section("语法信息") {
            LanguageHintEditor(
                placeholder: "使用说明",
                text: $form.usage,
                hint: .chinesePinyin,
                identifier: ""
            )
            LanguageHintEditor(
                placeholder: "接续方式",
                text: $form.connection,
                hint: .japanese,
                identifier: ""
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
        Section("注意事项") {
            TextEditor(text: $form.notes)
                .frame(minHeight: 90)
        }
    }
}

struct GrammarPreview: View {
    let form: GrammarFormData

    var body: some View {
        if let content = try? form.validatedContent() {
            VStack(alignment: .leading, spacing: 6) {
                Text(content.grammarForm)
                    .font(.title3.bold())
                Text(content.meaningZH)
                if let connection = content.connection {
                    LabeledContent("接续", value: connection)
                }
                if let usage = content.usage {
                    Text(usage)
                        .foregroundStyle(.secondary)
                }
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
            Text(grammarValidationMessage(for: form))
                .foregroundStyle(.secondary)
        }
    }
}

struct GrammarCardPreviews: View {
    let form: GrammarFormData

    var body: some View {
        if let content = try? form.validatedContent() {
            CardFacePreview(
                title: "语法形式 → 解释",
                front: [content.grammarForm],
                back: [
                    content.meaningZH,
                    content.connection,
                    content.usage,
                    content.example?.japanese,
                    content.example?.translationZH,
                    content.notes
                ].compactMap { $0 },
                identifier: "grammar-form-explanation"
            )
        } else {
            Text("填写必填内容后显示卡片预览。")
                .foregroundStyle(.secondary)
        }
    }
}

func grammarValidationMessage(for form: GrammarFormData) -> String {
    do {
        _ = try form.validatedContent()
        return "内容可用于正式保存。"
    } catch GrammarValidationError.grammarFormRequired {
        return "请填写语法形式。"
    } catch GrammarValidationError.meaningRequired {
        return "请填写中文含义。"
    } catch GrammarValidationError.exampleJapaneseRequired {
        return "填写例句翻译时，也需要填写日语例句。"
    } catch {
        return "内容格式不正确。"
    }
}
