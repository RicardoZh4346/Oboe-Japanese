import OboeSharedCapture
import SwiftUI

/// The share sheet's single screen: pick a candidate (when several providers
/// delivered independent texts), edit within the 1,000-character contract,
/// then save or save-and-continue. All copy stays inside the share-extension
/// contract — no learning actions, no AI, no deck choice here.
struct ShareCaptureView: View {
    @Bindable var model: ShareCaptureModel
    let onComplete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("保存到收集箱")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: onCancel)
                    }
                }
        }
        .onAppear {
            model.onPublishSucceeded = onComplete
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("正在读取…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .urlOnly(let urls):
            messageView(
                systemImage: "link",
                title: "只收到了链接",
                detail: "请在原文中选中要收集的文本后再分享。\(urls.first.map { "\n\($0)" } ?? "")"
            )
        case .empty:
            messageView(
                systemImage: "text.quote",
                title: "没有可保存的文本",
                detail: "请分享选中的文本内容。"
            )
        case .ready:
            editorView
        }
    }

    private func messageView(
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.candidates.count > 1 {
                candidatePicker
            }
            textEditor
            if let sourceURL = model.sourceURL,
               let host = URL(string: sourceURL)?.host {
                Label(host, systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.saveErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let diagnostics = model.signingDiagnostics {
                VStack(alignment: .leading, spacing: 4) {
                    Label("共享存储不可用", systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(diagnostics)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            saveButtons
        }
        .padding()
    }

    private var candidatePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("收到 \(model.candidates.count) 段文本，选择要保存的一段")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("文本", selection: $model.selectedCandidateIndex) {
                ForEach(
                    Array(model.candidates.enumerated()),
                    id: \.offset
                ) { index, candidate in
                    Text("第 \(index + 1) 段（\(candidate.text.count) 字）")
                        .tag(index)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var textEditor: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: $model.draftText)
                .frame(minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3))
                )
            Text("\(model.characterCount)/\(CaptureEnvelopeFormat.maximumTextCharacters)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.isOverLimit ? .red : .secondary)
            if model.isOverLimit {
                Text("超出字数上限，请删减后再保存")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var saveButtons: some View {
        VStack(spacing: 10) {
            Button {
                model.save(action: .continueInApp)
            } label: {
                Label("保存并在 App 中继续", systemImage: "arrow.right.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSave)

            Button {
                model.save(action: .save)
            } label: {
                Text("仅保存到收集箱")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canSave)
        }
    }
}
