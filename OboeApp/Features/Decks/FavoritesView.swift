import Observation
import OboeDomain
import SwiftUI

struct FavoritesView: View {
    let deckService: DeckManagementService
    let knowledgeService: KnowledgePointService
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let contentCardService: ContentCardService
    let historyService: StudyHistoryService
    let speechService: any SpeechService

    @State private var model: FavoritesViewModel

    init(
        deckService: DeckManagementService,
        knowledgeService: KnowledgePointService,
        vocabularyService: VocabularyService,
        grammarService: GrammarService,
        contentCardService: ContentCardService,
        historyService: StudyHistoryService,
        speechService: any SpeechService
    ) {
        self.deckService = deckService
        self.knowledgeService = knowledgeService
        self.vocabularyService = vocabularyService
        self.grammarService = grammarService
        self.contentCardService = contentCardService
        self.historyService = historyService
        self.speechService = speechService
        _model = State(initialValue: FavoritesViewModel(service: knowledgeService))
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("正在载入收藏…")
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "还没有收藏",
                    systemImage: "star",
                    description: Text("可以在单词或语法详情页点击星标收藏。")
                )
                .accessibilityIdentifier("favorites-empty-state")
            } else {
                List(model.items) { item in
                    NavigationLink {
                        destination(for: item)
                    } label: {
                        KnowledgePointRow(item: item)
                    }
                    .accessibilityIdentifier("favorite-row-\(item.id.uuidString)")
                }
            }
        }
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .task {
            await model.load()
        }
        .alert(
            "无法载入收藏",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { model.errorMessage = nil }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private func destination(for item: KnowledgePointSummary) -> some View {
        switch item.kind {
        case .vocabulary:
            VocabularyDetailView(
                noteID: item.id,
                service: vocabularyService,
                knowledgeService: knowledgeService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService
            ) {
                await model.load()
            }
        case .grammar:
            GrammarDetailView(
                noteID: item.id,
                service: grammarService,
                knowledgeService: knowledgeService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService
            ) {
                await model.load()
            }
        }
    }
}

@MainActor
@Observable
final class FavoritesViewModel {
    private let service: KnowledgePointService

    var items: [KnowledgePointSummary] = []
    var isLoading = true
    var errorMessage: String?

    init(service: KnowledgePointService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        do {
            items = try await service.fetchFavorites()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
