import SwiftUI
import UIKit

/// Shared by Return and the visible confirmation button. Keep composition in
/// UIKit: copying a SwiftUI binding back while marked text exists breaks IMEs.
@MainActor
final class RecallInputController: NSObject, UITextFieldDelegate {
    weak var field: UITextField?
    var onInput: (String) -> Void = { _ in }
    var onConfirm: () -> Void = {}

    @objc func textChanged(_ sender: UITextField) {
        onInput(sender.text ?? "")
    }

    func confirm() {
        guard let field, field.isEnabled else { return }
        if field.markedTextRange != nil {
            // First Return/tap commits the Japanese candidate, never the answer.
            field.unmarkText()
            onInput(field.text ?? "")
            return
        }
        let text = field.text ?? ""
        onInput(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 200 else { return }
        field.resignFirstResponder()
        onConfirm()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        confirm()
        return false
    }

    func closeKeyboard() {
        field?.resignFirstResponder()
    }
}

private final class RecallTextField: UITextField {
    /// Recall answers are Japanese: prefer a Japanese keyboard when one is
    /// enabled on the device. Falls back to the user's keyboard when absent.
    ///
    /// 不自动聚焦：进入卡片时弹键盘会在页面转场中触发布局重排造成
    /// 明显卡顿；用户点输入框时再弹。
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first(where: {
            $0.primaryLanguage?.hasPrefix("ja") == true
        }) ?? super.textInputMode
    }
}

struct RecallTextInput: UIViewRepresentable {
    let text: String
    let isEnabled: Bool
    var prompt = "请用日语回答"
    let controller: RecallInputController
    let onInput: (String) -> Void
    let onConfirm: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = RecallTextField()
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = prompt
        field.accessibilityLabel = prompt
        field.accessibilityIdentifier = "review-recall-input"
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        // T19 (设计 §8.2): no suggestion surface may echo a previously typed
        // answer — inline predictions and smart substitutions are recall
        // aids the card face must not provide.
        field.inlinePredictionType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = controller
        field.addTarget(controller, action: #selector(RecallInputController.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        controller.field = field
        controller.onInput = onInput
        controller.onConfirm = onConfirm
        field.isEnabled = isEnabled
        if field.markedTextRange == nil, field.text != text {
            field.text = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: max(48, (uiView.font?.lineHeight ?? 22) + 20))
    }
}
