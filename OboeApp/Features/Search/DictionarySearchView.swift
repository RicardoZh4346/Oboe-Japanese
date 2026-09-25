import OboeDomain
import SwiftUI

/// S06 词典搜索主页（技术文档 §4.4）。
///
/// 路由与依赖由 `AppFeatureContainer.dictionary` 装配；`onCreateCard`
/// 为 S07「制作成卡片」预填预留，host 注入后详情页才会显示该按钮。
///
/// 交互约定：
/// - `.searchable` 绑定 `model.query`，`.task(id:)` 驱动防抖搜索；
/// - 变形命中行显示「原形」chip 与原因链（`hit.matchedLemma` /
///   `hit.reasonChain`）；
/// - 词条无中文释义时回退英文并标「EN」徽章（D08）；
/// - `deinflectionWasTruncated` 时顶部横幅提示「结果可能不全」；
/// - `hasMore` 时底部哨兵行 `.onAppear` 触发 keyset 翻页。
struct DictionarySearchView: View {
    private let queryService: DictionaryQueryService
    private let onCreateCard: ((DictionaryEntry) -> Void)?
    /// 「制作成卡片/填入表单」按钮文案（随 onCreateCard 语义变化）。
    private let cardActionTitle: String

    @State private var model: DictionarySearchViewModel

    init(
        queryService: DictionaryQueryService,
        initialQuery: String = "",
        onCreateCard: ((DictionaryEntry) -> Void)? = nil,
        cardActionTitle: String = "制作成卡片"
    ) {
        self.queryService = queryService
        self.onCreateCard = onCreateCard
        self.cardActionTitle = cardActionTitle
        let model = DictionarySearchViewModel(service: queryService)
        model.query = initialQuery
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if model.isQueryEmpty {
                ContentUnavailableView(
                    "搜索词典",
                    systemImage: "character.book.closed",
                    description: Text("可输入日语原形、假名或活用形（如「食べた」）。")
                )
            } else if model.isUnavailable {
                unavailableState
            } else if model.isLoading && model.items.isEmpty {
                ProgressView("正在搜索…")
            } else if model.items.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                resultList
            }
        }
        .navigationTitle("词典")
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .searchable(text: $model.query, prompt: "日语、假名或活用形")
        .accessibilityIdentifier("dictionary-search-field")
        .task(id: model.query) {
            await model.debouncedSearch()
        }
        .alert(
            "无法搜索",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { model.clearError() }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    /// 词典包缺失/损坏/版本不符：非致命降级态，保留重试入口。
    private var unavailableState: some View {
        ContentUnavailableView {
            Label("词典不可用", systemImage: "book.closed")
        } description: {
            Text("内置词典文件缺失或损坏，查词暂不可用；其他功能不受影响。")
        } actions: {
            Button("重试") {
                Task { await model.retry() }
            }
            .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("dictionary-unavailable")
    }

    private var resultList: some View {
        List {
            if model.deinflectionTruncated {
                Section {
                    Label(
                        "变形匹配过多，结果可能不全。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(model.items, id: \.hit.entryID) { item in
                    NavigationLink {
                        DictionaryEntryDetailView(
                            entryID: item.hit.entryID,
                            prefetchedEntry: item.entry,
                            queryService: queryService,
                            onCreateCard: onCreateCard,
                            cardActionTitle: cardActionTitle
                        )
                    } label: {
                        DictionarySearchRow(item: item)
                    }
                    .accessibilityIdentifier("dictionary-result-row")
                }
            } footer: {
                if !model.effectiveQuery.isEmpty,
                   model.effectiveQuery != model.query {
                    Text("已按「\(model.effectiveQuery)」搜索")
                }
            }

            if model.hasMore {
                Section {
                    HStack {
                        Spacer()
                        if model.isLoadingMore {
                            ProgressView()
                        } else {
                            Text("载入更多")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .onAppear {
                        Task { await model.loadMore() }
                    }
                    .accessibilityIdentifier("dictionary-load-more")
                }
            }
        }
    }
}

/// 搜索结果行：命中表面 + 首选释义首行 + 变形原因链 chip。
private struct DictionarySearchRow: View {
    let item: DictionarySearchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.hit.matchedForm)
                    .font(.headline)
                if let entry = item.entry,
                   entry.primaryForm != item.hit.matchedForm {
                    Text(entry.primaryForm)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.hit.reason == .deinflected {
                    deinflectionChip
                }
            }
            glossLine
            if item.hit.reason == .deinflected,
               !item.hit.reasonChain.isEmpty {
                Text(item.hit.reasonChain.joined(separator: " → "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    /// zh→en 回退（D08）：优先中文，无覆盖时回退英文并加「EN」徽章；
    /// entry 聚合缺失时按「详情不可用」降级，不崩溃。
    @ViewBuilder
    private var glossLine: some View {
        if let entry = item.entry {
            if let preferred = entry.preferredGlosses() {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if preferred.language != DictionaryGlossLanguage.chinese {
                        languageBadge(languageBadgeText(preferred.language))
                    }
                    Text(preferred.glosses.map(\.text).joined(separator: "；"))
                        .font(.subheadline)
                        .foregroundStyle(
                            preferred.language != DictionaryGlossLanguage.chinese
                                ? .orange : .secondary
                        )
                        .lineLimit(2)
                }
            } else {
                Text("暂无释义")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("词条详情不可用")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    /// 变形命中 chip：显示还原出的原形（如 食べた → 食べる）。
    private var deinflectionChip: some View {
        Text(
            item.hit.matchedLemma.map { "原形 \($0)" } ?? "活用命中"
        )
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.secondary)
    }

    /// 语言徽章文案：eng → "EN"，其他未知语言如实显示大写语言码。
    private func languageBadgeText(_ language: String) -> String {
        language == DictionaryGlossLanguage.english ? "EN" : language.uppercased()
    }

    private func languageBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.orange)
    }
}
