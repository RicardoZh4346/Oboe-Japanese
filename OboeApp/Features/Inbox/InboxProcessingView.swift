import OboeDomain
import SwiftUI

/// Services the capture editor needs beyond the inbox. Bundled so InboxView
/// and its detail view only carry one extra parameter.
struct InboxProcessingServices {
    let deckService: DeckManagementService
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let knowledgePointService: KnowledgePointService
    let contentCardService: ContentCardService
    let aiCardGenerationService: AICardGenerationService
    let sentenceAnalysisService: SentenceAnalysisService
    let sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService
    let historyService: StudyHistoryService
    let speechService: any SpeechService
}

/// Pushed from the inbox detail view. Ensures a processing context exists,
/// resumes the persisted session, and hosts the shared content editor inside
/// the current navigation stack.
struct InboxProcessingView: View {
    private let itemID: UUID
    private let preferredMode: CaptureProcessingMode?
    private let inboxService: InboxService
    private let services: InboxProcessingServices

    @State private var session: CaptureEditorSession?
    @State private var errorMessage: String?
    @State private var invalidResumePayload = false

    init(
        itemID: UUID,
        preferredMode: CaptureProcessingMode?,
        inboxService: InboxService,
        services: InboxProcessingServices
    ) {
        self.itemID = itemID
        self.preferredMode = preferredMode
        self.inboxService = inboxService
        self.services = services
    }

    var body: some View {
        Group {
            if let session {
                AddContentEditorView(
                    deckService: services.deckService,
                    vocabularyService: services.vocabularyService,
                    grammarService: services.grammarService,
                    knowledgePointService: services.knowledgePointService,
                    contentCardService: services.contentCardService,
                    aiCardGenerationService: services.aiCardGenerationService,
                    sentenceAnalysisService: services.sentenceAnalysisService,
                    sentenceAnalysisCardCreationService: services.sentenceAnalysisCardCreationService,
                    historyService: services.historyService,
                    speechService: services.speechService,
                    captureSession: session,
                    title: "处理收集"
                )
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("无法打开处理", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
                .accessibilityIdentifier("capture-processing-error")
            } else {
                ProgressView("正在恢复处理现场…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("capture-processing-loading")
            }
        }
        .task {
            await load()
        }
        .alert(
            "续编数据无效",
            isPresented: $invalidResumePayload
        ) {
            Button("放弃续编，从头开始", role: .destructive) {
                Task { await restartFresh() }
            }
            .accessibilityIdentifier("capture-invalid-payload-restart")
            Button("取消", role: .cancel) {}
        } message: {
            Text("已保存的续编数据无法读取。原文未受影响，可以放弃旧续编后重新处理。")
        }
    }

    @MainActor
    private func load() async {
        do {
            if let preferredMode {
                _ = try await inboxService.beginProcessing(
                    itemID: itemID,
                    mode: preferredMode
                )
            }
            let resolved: CaptureProcessingSession?
            do {
                resolved = try await inboxService.resumeSession(inboxItemID: itemID)
            } catch is CaptureResumePayloadError {
                invalidResumePayload = true
                return
            }
            guard let resolved else {
                errorMessage = "这条内容不存在或尚未开始处理。"
                return
            }
            session = CaptureEditorSession(
                inboxService: inboxService,
                inboxItemID: itemID,
                context: resolved.context,
                payload: resolved.resumablePayload,
                isAnalysisStale: resolved.isAnalysisStale
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drops the corrupted context and starts a fresh session on the same item.
    @MainActor
    private func restartFresh() async {
        do {
            try await inboxService.deleteProcessingContext(inboxItemID: itemID)
            guard let item = try await inboxService.fetchItem(id: itemID) else {
                errorMessage = "这条内容不存在或尚未开始处理。"
                return
            }
            let mode = preferredMode
                ?? CaptureProcessingMode.suggested(forText: item.text)
            _ = try await inboxService.beginProcessing(itemID: itemID, mode: mode)
            guard let resolved = try await inboxService.resumeSession(
                inboxItemID: itemID
            ) else {
                errorMessage = "这条内容不存在或尚未开始处理。"
                return
            }
            session = CaptureEditorSession(
                inboxService: inboxService,
                inboxItemID: itemID,
                context: resolved.context,
                payload: resolved.resumablePayload,
                isAnalysisStale: resolved.isAnalysisStale
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
