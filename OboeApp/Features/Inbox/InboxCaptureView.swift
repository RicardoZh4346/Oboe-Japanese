import OboeDomain
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct InboxCaptureView: View {
    private let service: InboxService
    private let onSaved: () -> Void

    @State private var text = ""
    @State private var didPaste = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(service: InboxService, onSaved: @escaping () -> Void) {
        self.service = service
        self.onSaved = onSaved
    }

    private var isSaveDisabled: Bool {
        isSaving
            || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || text.count > InboxText.maximumCharacterCount
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .accessibilityIdentifier("inbox-capture-text-editor")
                HStack {
                    PasteButton { pasted in
                        if !text.isEmpty, !text.hasSuffix("\n") {
                            text += "\n"
                        }
                        text += pasted
                        didPaste = true
                    }
                    Spacer()
                    Text("\(text.count)/\(InboxText.maximumCharacterCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            text.count > InboxText.maximumCharacterCount
                                ? .red : .secondary
                        )
                        .accessibilityIdentifier("inbox-capture-count")
                }
            } header: {
                Text("收集内容")
            } footer: {
                Text("手动输入或粘贴日语文本，先收进收集箱，稍后再统一处理。")
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("保存到收集箱")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isSaveDisabled)
                .accessibilityIdentifier("inbox-capture-save-button")
            }
        }
        .navigationTitle("手动添加")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
                    .accessibilityIdentifier("inbox-capture-cancel-button")
            }
        }
        .alert(
            "无法保存",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { shown in
                    if !shown {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await service.capture(
                text: text,
                sourceType: didPaste ? .paste : .manual
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// System-sanctioned paste control: tapping it is an explicit user action, so
/// iOS grants pasteboard access without showing a permission banner.
private struct PasteButton: UIViewRepresentable {
    let onPaste: @MainActor @Sendable (String) -> Void

    func makeUIView(context: Context) -> PasteTargetView {
        let view = PasteTargetView()
        view.onPaste = onPaste
        view.pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.plainText.identifier]
        )
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor(OboeTheme.Colors.accent)
        let control = UIPasteControl(configuration: configuration)
        control.frame = CGRect(x: 0, y: 0, width: 96, height: 36)
        control.target = view
        control.accessibilityIdentifier = "inbox-capture-paste-button"
        view.addSubview(control)
        return view
    }

    func updateUIView(_ uiView: PasteTargetView, context: Context) {
        uiView.onPaste = onPaste
    }

    /// UIPasteControl delivers `paste(itemProviders:)` to its target, which must
    /// be a UIResponder in the view hierarchy — plain NSObject targets are
    /// ignored.
    @MainActor
    final class PasteTargetView: UIView {
        var onPaste: (@MainActor @Sendable (String) -> Void)?

        override var intrinsicContentSize: CGSize {
            CGSize(width: 96, height: 36)
        }

        override func paste(itemProviders: [NSItemProvider]) {
            if let text = UIPasteboard.general.string, !text.isEmpty {
                onPaste?(text)
            }
        }
    }
}
