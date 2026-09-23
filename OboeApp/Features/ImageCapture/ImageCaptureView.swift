import OboeDomain
import OboeInfrastructure
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Image capture: pick one image, store a normalized preview under a
/// controlled resource ID, run on-device OCR, and let the user select,
/// correct, and save the recognized text into the Inbox (or continue into
/// the unified processing context). The stored file only becomes an
/// attachment once an Inbox item links it — cancelling discards it.
struct ImageCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ImageCaptureModel
    private let processingServices: InboxProcessingServices?

    init(
        imageStore: InboxImageStore,
        ocrService: any OCRRecognizing,
        inboxService: InboxService?,
        processingServices: InboxProcessingServices?
    ) {
        self.processingServices = processingServices
        _model = State(
            initialValue: ImageCaptureModel(
                imageStore: imageStore,
                ocrService: ocrService,
                inboxService: inboxService
            )
        )
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(spacing: OboeTheme.Spacing.lg) {
                    sourceButtons
                    statusSection
                }
                .padding(OboeTheme.pageHorizontalPadding)
            }
            .background(OboeTheme.Colors.pageBackground)
            .navigationTitle("图片收集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("image-capture-cancel-button")
                }
            }
            .task {
                #if DEBUG
                await model.debugImportIfRequested()
                #endif
            }
            .navigationDestination(item: $model.processingItemID) { itemID in
                if let processingServices, let inboxService = model.inboxService {
                    InboxProcessingView(
                        itemID: itemID,
                        preferredMode: CaptureProcessingMode.suggested(
                            forText: model.editedText
                        ),
                        inboxService: inboxService,
                        services: processingServices
                    )
                }
            }
            .alert(
                "重新识别将放弃你修改的文本",
                isPresented: $model.isRerecognizeConfirmPresented
            ) {
                Button("放弃修改并重新识别", role: .destructive) {
                    model.confirmRerecognize()
                }
                .accessibilityIdentifier("ocr-rerecognize-confirm-button")
                Button("取消", role: .cancel) {}
            } message: {
                Text("识别结果会重新生成文本块和已选文本，你的手动修改将丢失。")
            }
            .alert(
                "无法保存",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { shown in if !shown { model.errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "未知错误")
            }
            .onChange(of: model.didRequestDismiss) { _, requested in
                if requested { dismiss() }
            }
        }
        .onDisappear {
            model.discard()
        }
    }

    private var sourceButtons: some View {
        HStack(spacing: OboeTheme.Spacing.sm) {
            PhotosPicker(
                selection: $model.photoSelection,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("从照片选择", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("image-capture-photos-button")

            Button {
                model.isFileImporterPresented = true
            } label: {
                Label("从文件选择", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("image-capture-file-button")
        }
        .fileImporter(
            isPresented: $model.isFileImporterPresented,
            allowedContentTypes: [.jpeg, .png, .heic],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                model.importFile(url)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.phase {
        case .idle:
            Text("选择一张 JPEG、PNG 或 HEIC 图片。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("image-capture-hint")
        case .importing:
            HStack(spacing: OboeTheme.Spacing.sm) {
                ProgressView()
                Text("正在读取图片…")
                    .font(.callout)
            }
            .accessibilityIdentifier("image-capture-importing")
        case .ready(let previewData):
            readyContent(previewData: previewData)
        case .failed(let message):
            VStack(spacing: OboeTheme.Spacing.sm) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("image-capture-error")
                Text("可以换一张图片重试。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func readyContent(previewData: Data) -> some View {
        if let image = UIImage(data: previewData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: OboeTheme.Radius.medium))
                .accessibilityIdentifier("image-capture-preview")
        }
        if let dimensions = model.pixelDimensions {
            Text(dimensions)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if model.isRecognizing {
            HStack(spacing: OboeTheme.Spacing.sm) {
                ProgressView()
                Text("正在识别文字…")
                    .font(.callout)
            }
            .accessibilityIdentifier("ocr-recognizing")
        } else {
            recognitionSection
            editingSection
            actionsSection
        }
    }

    /// Recognized blocks — the user picks which ones feed the merged text.
    /// Low-confidence blocks are flagged, never silently dropped.
    @ViewBuilder
    private var recognitionSection: some View {
        if !model.blocks.isEmpty {
            OboeCardSurface(padding: OboeTheme.Spacing.cardPaddingCompact) {
                VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
                    Text("识别到的文字块")
                        .font(.headline)
                        .accessibilityIdentifier("ocr-block-list")
                    ForEach(model.blocks) { block in
                        Button {
                            model.toggleBlock(block.id)
                        } label: {
                            HStack(alignment: .top, spacing: OboeTheme.Spacing.sm) {
                                Image(
                                    systemName: model.selectedBlockIDs.contains(block.id)
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .foregroundStyle(
                                    model.selectedBlockIDs.contains(block.id)
                                        ? OboeTheme.Colors.accent : .secondary
                                )
                                Text(block.text)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if block.confidence < 0.5 {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .accessibilityIdentifier(
                                            "ocr-low-confidence-\(block.id)"
                                        )
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ocr-block-\(block.id)")
                        .accessibilityValue(
                            model.selectedBlockIDs.contains(block.id)
                                ? "已选中" : "未选中"
                        )
                    }
                    if model.hasLowConfidenceBlocks {
                        Text("带警示标记的块置信度较低，请核对后再保存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if let issue = model.recognitionIssue {
            OboeCardSurface(padding: OboeTheme.Spacing.cardPaddingCompact) {
                VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("ocr-issue")
                    HStack(spacing: OboeTheme.Spacing.sm) {
                        Button("重试识别") { model.rerecognize() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("ocr-retry-button")
                        Text("也可以在下方直接手动输入。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var editingSection: some View {
        OboeCardSurface(padding: OboeTheme.Spacing.cardPaddingCompact) {
            VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
                HStack {
                    Text("保存的文本")
                        .font(.headline)
                    Spacer()
                    if model.selectionChangedSinceEdit {
                        Button("重新合并选中块") { model.remergeSelection() }
                            .font(.caption)
                            .accessibilityIdentifier("ocr-remerge-button")
                    }
                }
                TextEditor(
                    text: Binding(
                        get: { model.editedText },
                        set: { model.userSetText($0) }
                    )
                )
                .frame(minHeight: 120)
                .accessibilityIdentifier("ocr-edited-text")
                HStack {
                    if model.didEditText {
                        Text("已手动修改")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ocr-edited-badge")
                    }
                    Spacer()
                    Text("\(model.editedText.count)/\(InboxText.maximumCharacterCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            model.isOverLimit ? .red : .secondary
                        )
                        .accessibilityIdentifier("ocr-char-count")
                }
                if model.isOverLimit {
                    Text("已超出收集箱上限，请删减文本或取消勾选部分文字块，不会自动截断。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("ocr-over-limit")
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(spacing: OboeTheme.Spacing.sm) {
            if !model.blocks.isEmpty {
                Button {
                    model.requestRerecognize()
                } label: {
                    Label("重新识别", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isSaving)
                .accessibilityIdentifier("ocr-rerecognize-button")
            }

            Button {
                Task { await model.save() }
            } label: {
                Label("保存到收集箱", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.oboePrimary)
            .disabled(!model.canSave)
            .accessibilityIdentifier("ocr-save-button")

            if processingServices != nil {
                Button {
                    Task { await model.save(continueToProcessing: true) }
                } label: {
                    Label("保存并处理", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canSave)
                .accessibilityIdentifier("ocr-save-process-button")
            }

            if model.isSaving {
                ProgressView()
                    .accessibilityIdentifier("ocr-saving")
            }
        }
    }
}

@MainActor
@Observable
final class ImageCaptureModel {
    enum Phase {
        case idle
        case importing
        case ready(previewData: Data)
        case failed(message: String)
    }

    private let imageStore: InboxImageStore
    private let ocrService: any OCRRecognizing
    let inboxService: InboxService?

    var photoSelection: PhotosPickerItem? {
        didSet {
            guard let photoSelection else { return }
            importPhoto(photoSelection)
        }
    }
    var isFileImporterPresented = false
    private(set) var phase: Phase = .idle

    /// OCR outcome and the user's working text. `editedText` is the complete
    /// text being saved — the block selection feeds it until the user edits,
    /// after which only an explicit re-merge touches it.
    private(set) var blocks: [OCRTextBlock] = []
    private(set) var selectedBlockIDs: Set<Int> = []
    private(set) var editedText = ""
    private(set) var didEditText = false
    private(set) var selectionChangedSinceEdit = false
    private(set) var isRecognizing = false
    private(set) var recognitionIssue: String?
    private(set) var isSaving = false
    var processingItemID: UUID?
    var isRerecognizeConfirmPresented = false

    /// The stored resource this session owns; deleted on discard unless a
    /// saved Inbox item has linked it.
    private var currentResource: InboxImageResource?
    private var savedItemID: UUID?
    private(set) var didRequestDismiss = false
    var errorMessage: String?

    init(
        imageStore: InboxImageStore,
        ocrService: any OCRRecognizing,
        inboxService: InboxService?
    ) {
        self.imageStore = imageStore
        self.ocrService = ocrService
        self.inboxService = inboxService
    }

    var pixelDimensions: String? {
        currentResource.map {
            "\($0.pixelWidth) × \($0.pixelHeight) 像素"
        }
    }

    var hasLowConfidenceBlocks: Bool {
        blocks.contains { $0.confidence < 0.5 }
    }

    var isOverLimit: Bool {
        editedText.count > InboxText.maximumCharacterCount
            || editedText.utf8.count > InboxText.maximumUTF8ByteCount
    }

    var canSave: Bool {
        inboxService != nil
            && !isSaving
            && !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isOverLimit
    }

    /// PhotosPicker yields transferable data — a nil result means the asset
    /// could not be produced locally (e.g. iCloud-only and undownloadable).
    func importPhoto(_ item: PhotosPickerItem) {
        photoSelection = nil
        beginImport()
        Task {
            do {
                guard let data = try await item.loadTransferable(
                    type: Data.self
                ) else {
                    fail(.imageUnavailable)
                    return
                }
                try await storeImage(data)
            } catch let error as InboxImageError {
                fail(error)
            } catch {
                fail(.imageUnavailable)
            }
        }
    }

    /// Files from the document picker are security-scoped — the resource must
    /// be opened before reading and released immediately afterwards.
    func importFile(_ url: URL) {
        beginImport()
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                try await storeImage(data)
            } catch let error as InboxImageError {
                fail(error)
            } catch {
                fail(.imageUnavailable)
            }
        }
    }

    /// Block toggles feed the merged text only while the user hasn't edited;
    /// afterwards they just mark the selection dirty so an explicit re-merge
    /// can apply it — edits are never overwritten silently.
    func toggleBlock(_ id: Int) {
        if selectedBlockIDs.contains(id) {
            selectedBlockIDs.remove(id)
        } else {
            selectedBlockIDs.insert(id)
        }
        if didEditText {
            selectionChangedSinceEdit = true
        } else {
            editedText = mergedSelection
        }
    }

    /// Applies the current selection to the editable text, discarding the
    /// user's edits — reachable only through the explicit re-merge control.
    func remergeSelection() {
        editedText = mergedSelection
        didEditText = false
        selectionChangedSinceEdit = false
    }

    func userSetText(_ text: String) {
        editedText = text
        didEditText = true
    }

    func requestRerecognize() {
        if didEditText {
            isRerecognizeConfirmPresented = true
        } else {
            rerecognize()
        }
    }

    func confirmRerecognize() {
        didEditText = false
        selectionChangedSinceEdit = false
        rerecognize()
    }

    /// Re-runs OCR on the stored preview. A superseded in-flight call is
    /// cancelled by the service contract and its stale result dropped.
    func rerecognize() {
        guard case .ready(let previewData) = phase else { return }
        recognize(previewData)
    }

    /// Saves the confirmed text with the image attachment into the Inbox.
    /// The Inbox row stores the complete confirmed text; the per-analysis
    /// fragment selection is a separate concern recorded later in the
    /// processing context's resume payload.
    func save(continueToProcessing: Bool = false) async {
        guard let inboxService,
              let resource = currentResource else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let item = try await inboxService.capture(
                text: editedText,
                sourceType: .ocr,
                imageReference: resource.id
            )
            savedItemID = item.id
            if continueToProcessing {
                processingItemID = item.id
            } else {
                didRequestDismiss = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drops the stored preview when the sheet closes without a save. Once an
    /// Inbox item links the resource, deletion would orphan the attachment.
    func discard() {
        guard savedItemID == nil, let resource = currentResource else { return }
        try? imageStore.delete(resource.id)
        currentResource = nil
    }

    #if DEBUG
    /// UI-test seam: preload an image from a path instead of driving the
    /// system pickers (which XCUITest cannot operate reliably).
    func debugImportIfRequested() async {
        guard ProcessInfo.processInfo.environment["OBOE_UI_TEST_DATABASE_ID"] != nil,
              let path = ProcessInfo.processInfo.environment["OBOE_UI_TEST_IMAGE_FILE"],
              !path.isEmpty,
              case .idle = phase else { return }
        beginImport()
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try await storeImage(data)
        } catch let error as InboxImageError {
            fail(error)
        } catch {
            fail(.imageUnavailable)
        }
    }
    #endif

    private func beginImport() {
        // A re-pick abandons the previous unlinked resource immediately —
        // leaving it to the orphan sweep would leak it for the session.
        if savedItemID == nil, let resource = currentResource {
            try? imageStore.delete(resource.id)
        }
        currentResource = nil
        savedItemID = nil
        blocks = []
        selectedBlockIDs = []
        editedText = ""
        didEditText = false
        selectionChangedSinceEdit = false
        recognitionIssue = nil
        phase = .importing
    }

    private func storeImage(_ data: Data) async throws {
        let resource = try imageStore.importImage(data: data)
        let previewData = try imageStore.loadPreviewData(for: resource.id)
        currentResource = resource
        phase = .ready(previewData: previewData)
        recognize(previewData)
    }

    private func recognize(_ imageData: Data) {
        isRecognizing = true
        recognitionIssue = nil
        Task {
            do {
                let result = try await ocrService.recognize(imageData: imageData)
                blocks = result.blocks
                selectedBlockIDs = Set(result.blocks.map(\.id))
                recognitionIssue = result.blocks.isEmpty
                    ? "未识别到文字，可以换图、重试或直接手动输入。"
                    : nil
                // A user who typed while recognition ran keeps their text;
                // the fresh selection is offered via re-merge instead.
                if !didEditText {
                    editedText = mergedSelection
                    selectionChangedSinceEdit = false
                } else {
                    selectionChangedSinceEdit = true
                }
            } catch is CancellationError {
                return
            } catch let error as OCRError {
                recognitionIssue = Self.ocrMessage(for: error)
                blocks = []
                selectedBlockIDs = []
            } catch {
                recognitionIssue = Self.ocrMessage(for: .recognitionFailed(""))
                blocks = []
                selectedBlockIDs = []
            }
            isRecognizing = false
        }
    }

    private var mergedSelection: String {
        blocks
            .filter { selectedBlockIDs.contains($0.id) }
            .map(\.text)
            .joined(separator: "\n")
    }

    private func fail(_ error: InboxImageError) {
        phase = .failed(message: Self.message(for: error))
    }

    private static func ocrMessage(for error: OCRError) -> String {
        switch error {
        case .undecodableImage:
            "图片无法解码，无法识别文字。"
        case .languageUnavailable:
            "此设备暂不支持日语文字识别，请手动输入。"
        case .recognitionFailed(let detail):
            detail.isEmpty ? "文字识别失败，请重试或手动输入。" : "文字识别失败：\(detail)"
        }
    }

    private static func message(for error: InboxImageError) -> String {
        switch error {
        case .emptyFile:
            "文件是空的。"
        case .unsupportedFormat:
            "仅支持 JPEG、PNG 或 HEIC 图片。"
        case .fileTooLarge:
            "图片文件超过大小限制。"
        case .imageTooLarge:
            "图片像素过大，无法安全处理。"
        case .corruptImage:
            "图片已损坏或无法解码。"
        case .previewGenerationFailed:
            "无法生成图片预览。"
        case .storageFailure:
            "图片保存失败，请重试。"
        case .imageUnavailable:
            "图片暂不可用（可能仍在 iCloud，未下载到本机）。"
        }
    }
}
