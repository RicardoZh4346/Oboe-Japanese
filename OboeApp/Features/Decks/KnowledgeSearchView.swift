import Foundation
import Observation
import OboeDomain
import SwiftUI

struct KnowledgeSearchView: View {
    let deckService: DeckManagementService
    let knowledgeService: KnowledgePointService
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let contentCardService: ContentCardService
    let historyService: StudyHistoryService
    let speechService: any SpeechService

    @State private var query = ""
    @State private var model: KnowledgeSearchModel

    init(
        searchService: KnowledgeSearchService,
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
        _model = State(
            initialValue: KnowledgeSearchModel(service: searchService, deckID: nil)
        )
    }

    var body: some View {
        Group {
            if SearchTextNormalizer.normalize(query).isEmpty {
                ContentUnavailableView(
                    "搜索知识点",
                    systemImage: "magnifyingglass",
                    description: Text("可输入日语原形、假名或中文释义。")
                )
                .accessibilityIdentifier("global-search-empty-state")
            } else if model.isLoading {
                ProgressView("正在搜索…")
            } else if model.items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(model.items) { item in
                        NavigationLink {
                            destination(for: item)
                        } label: {
                            KnowledgePointRow(item: item)
                        }
                        .accessibilityIdentifier("global-search-result-\(item.id.uuidString)")
                    }
                    if model.nextOffset != nil {
                        Button {
                            Task { await model.loadMore(query) }
                        } label: {
                            if model.isLoadingMore {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("载入更多")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(model.isLoadingMore)
                        .accessibilityIdentifier("global-search-load-more-button")
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .searchable(text: $query, prompt: "日语、假名或中文")
        .task(id: query) {
            await model.debouncedSearch(query)
        }
        .alert(
            "无法搜索",
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
                await model.refresh(query)
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
                await model.refresh(query)
            }
        }
    }
}

@MainActor
@Observable
final class KnowledgeSearchModel {
    private let service: KnowledgeSearchService
    private let deckID: UUID?
    private var generation = 0
    private var activeNormalizedQuery = ""

    var items: [KnowledgePointSummary] = []
    var nextOffset: Int?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    init(service: KnowledgeSearchService, deckID: UUID?) {
        self.service = service
        self.deckID = deckID
    }

    func debouncedSearch(_ query: String) async {
        generation += 1
        let currentGeneration = generation
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        activeNormalizedQuery = normalizedQuery
        errorMessage = nil
        isLoadingMore = false

        guard !normalizedQuery.isEmpty else {
            items = []
            nextOffset = nil
            isLoading = false
            return
        }

        isLoading = true
        do {
            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
            let page = try await service.search(query, deckID: deckID)
            guard currentGeneration == generation, !Task.isCancelled else { return }
            items = page.items
            nextOffset = page.nextOffset
            isLoading = false
        } catch is CancellationError {
            if currentGeneration == generation {
                isLoading = false
            }
        } catch {
            guard currentGeneration == generation else { return }
            items = []
            nextOffset = nil
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func refresh(_ query: String) async {
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        guard !normalizedQuery.isEmpty else { return }
        generation += 1
        let currentGeneration = generation
        activeNormalizedQuery = normalizedQuery
        errorMessage = nil
        isLoading = true
        do {
            let page = try await service.search(query, deckID: deckID)
            guard currentGeneration == generation else { return }
            items = page.items
            nextOffset = page.nextOffset
            isLoading = false
        } catch is CancellationError {
            if currentGeneration == generation { isLoading = false }
        } catch {
            guard currentGeneration == generation else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func loadMore(_ query: String) async {
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        guard normalizedQuery == activeNormalizedQuery,
              let offset = nextOffset,
              !isLoadingMore else { return }
        let currentGeneration = generation
        isLoadingMore = true
        do {
            let page = try await service.search(query, deckID: deckID, offset: offset)
            guard currentGeneration == generation,
                  normalizedQuery == activeNormalizedQuery else { return }
            items.append(contentsOf: page.items)
            nextOffset = page.nextOffset
            isLoadingMore = false
        } catch is CancellationError {
            if currentGeneration == generation { isLoadingMore = false }
        } catch {
            guard currentGeneration == generation else { return }
            isLoadingMore = false
            errorMessage = error.localizedDescription
        }
    }
}
