import SwiftUI
import UIKit

/// 建卡表单的语言提示：日文字段聚焦时优先切到日语键盘，
/// 中文字段优先切到简体拼音。仅在系统已启用对应键盘时生效，
/// 否则回退当前键盘（与 RecallTextField 的 textInputMode 机制一致）。
enum TextInputLanguageHint {
    case japanese
    case chinesePinyin

    var matchedMode: UITextInputMode? {
        // UI 测试默认关闭提示：模拟器的拼音/日语键盘会让 typeText
        // 产生组词残留，且切换行为本身无法在自动化中可靠断言。
        let env = ProcessInfo.processInfo.environment
        if env["OBOE_UI_TEST_DATABASE_ID"] != nil,
           env["OBOE_UI_TEST_INPUT_HINTS"] != "1" {
            return nil
        }
        let modes = UITextInputMode.activeInputModes
        switch self {
        case .japanese:
            return modes.first { $0.primaryLanguage?.hasPrefix("ja") == true }
        case .chinesePinyin:
            // 简体拼音的 primaryLanguage 为 zh-Hans；繁体注音/仓颉不算，
            // 没有简体中文键盘时回退默认输入法。
            return modes.first { $0.primaryLanguage?.hasPrefix("zh-Hans") == true }
        }
    }
}

private final class LanguageHintTextFieldView: UITextField {
    var hint: TextInputLanguageHint?

    override var textInputMode: UITextInputMode? {
        hint?.matchedMode ?? super.textInputMode
    }
}

private final class LanguageHintTextView: UITextView {
    var hint: TextInputLanguageHint?

    override var textInputMode: UITextInputMode? {
        hint?.matchedMode ?? super.textInputMode
    }
}

/// 单行输入：外观与 SwiftUI `TextField` 在 Form 行内一致。
/// `.done` 返回键 + textFieldShouldReturn 收起键盘（先提交组词候选）。
struct LanguageHintTextField: UIViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var hint: TextInputLanguageHint
    var identifier: String

    func makeUIView(context: Context) -> UITextField {
        let field = LanguageHintTextFieldView()
        field.hint = hint
        field.borderStyle = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        field.accessibilityIdentifier = identifier.isEmpty ? nil : identifier
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        field.placeholder = placeholder
        field.accessibilityIdentifier = identifier.isEmpty ? nil : identifier
        if field.markedTextRange == nil, field.text != text {
            field.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func textChanged(_ field: UITextField) {
            text.wrappedValue = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            if field.markedTextRange != nil {
                field.unmarkText()
            } else {
                field.resignFirstResponder()
            }
            return false
        }
    }
}

/// 多行输入：对应 `TextField(axis: .vertical)`，带占位文本。
struct LanguageHintEditor: UIViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var hint: TextInputLanguageHint
    var identifier: String
    var minHeight: CGFloat = 40

    func makeUIView(context: Context) -> UITextView {
        let view = LanguageHintTextView()
        view.hint = hint
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.autocapitalizationType = .none
        view.returnKeyType = .default
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityIdentifier = identifier
        view.delegate = context.coordinator

        let placeholderLabel = UILabel()
        placeholderLabel.text = placeholder
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.tag = Self.placeholderTag
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8)
        ])
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.accessibilityIdentifier = identifier.isEmpty ? nil : identifier
        if view.markedTextRange == nil, view.text != text {
            view.text = text
        }
        view.viewWithTag(Self.placeholderTag)?.isHidden = !view.text.isEmpty
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        // 不使用 UIScreen.main 回退：proposal 没有宽度时返回 nil，
        // 交给 SwiftUI 默认布局（容器宽度由父视图/列决定）。
        guard let width = proposal.width else { return nil }
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: max(minHeight, fitting.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    private static let placeholderTag = 9001

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text ?? ""
            textView.viewWithTag(LanguageHintEditor.placeholderTag)?
                .isHidden = !textView.text.isEmpty
        }
    }
}
