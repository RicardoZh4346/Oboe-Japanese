import OboeDomain
import SwiftUI

/// 全局搜索（S06）：「我的内容 / 词典」两 scope 的分段壳层。
/// 各 scope 视图保持自治——这里只持有 selection 与依赖转发。
struct GlobalSearchView: View {
    enum Scope: String, CaseIterable {
        case myContent = "我的内容"
        case dictionary = "词典"
    }

    @State private var scope = Scope.myContent

    let searchService: KnowledgeSearchService
    let deckService: DeckManagementService
    let knowledgeService: KnowledgePointService
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let contentCardService: ContentCardService
    let historyService: StudyHistoryService
    let speechService: any SpeechService
    let dictionaryQueryService: DictionaryQueryService
    /// S07 查词→制卡预填由宿主注入；nil 时词条详情不显示制卡按钮。
    let onCreateCard: ((DictionaryEntry) -> Void)?

    var body: some View {
        Group {
            switch scope {
            case .myContent:
                KnowledgeSearchView(
                    searchService: searchService,
                    deckService: deckService,
                    knowledgeService: knowledgeService,
                    vocabularyService: vocabularyService,
                    grammarService: grammarService,
                    contentCardService: contentCardService,
                    historyService: historyService,
                    speechService: speechService
                )
            case .dictionary:
                DictionarySearchView(
                    queryService: dictionaryQueryService,
                    onCreateCard: onCreateCard
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("搜索范围", selection: $scope) {
                ForEach(Scope.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("global-search-scope-picker")
        }
        .navigationTitle("搜索")
    }
}
