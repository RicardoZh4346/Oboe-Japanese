import OboeDomain
import SwiftUI

struct GrammarRequiredSection: View {
    @Binding var form: GrammarFormData

    var body: some View {
        Section("必填") {
            TextField("语法形式", text: $form.grammarForm)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("grammar-form-field")
            TextField("中文含义", text: $form.meaningZH)
                .accessibilityIdentifier("grammar-meaning-field")
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
                TextField("使用说明", text: $form.usage, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("grammar-usage-field")
                TextField("接续方式", text: $form.connection, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("grammar-connection-field")
                Picker("JLPT", selection: $form.jlpt) {
                    Text("未设置").tag(nil as JLPTLevel?)
                    ForEach(JLPTLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level as JLPTLevel?)
                    }
                }
                .accessibilityIdentifier("grammar-jlpt-picker")
                TextField("日语例句", text: $form.exampleJapanese, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("grammar-example-field")
                TextField("例句翻译", text: $form.exampleTranslationZH, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("grammar-example-translation-field")
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
            TextField("使用说明", text: $form.usage, axis: .vertical)
            TextField("接续方式", text: $form.connection, axis: .vertical)
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
    let isEnabled: Bool

    var body: some View {
        if let content = try? form.validatedContent() {
            if isEnabled {
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
                Text("选择方向后显示卡片预览。")
                    .foregroundStyle(.secondary)
            }
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
