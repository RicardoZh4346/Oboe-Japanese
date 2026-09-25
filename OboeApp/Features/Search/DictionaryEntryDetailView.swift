import OboeDomain
import SwiftUI

/// S06 词条详情页：表记 / 读音 / 释义 / 补充释义全量展示。
///
/// 数据来源：
/// - 搜索行已带入聚合详情（`prefetchedEntry`）时直接渲染；
/// - 聚合缺失（并发换库等）时按 `entryID` 走 `service.entry(id:)`
///   补拉一次；仍失败则降级为「词条不可用」，不崩溃。
///
/// `onCreateCard` 为 S07 制卡预填入口：host 注入非 nil 时才显示
/// 「制作成卡片」按钮。
struct DictionaryEntryDetailView: View {
    let entryID: Int64
    let queryService: DictionaryQueryService
    let onCreateCard: ((DictionaryEntry) -> Void)?
    /// 按钮文案：词典搜索流为「制作成卡片」；编辑器内查词为「填入表单」。
    let cardActionTitle: String

    @State private var entry: DictionaryEntry?
    @State private var isLoading: Bool
    @State private var isUnavailable = false
    @State private var errorMessage: String?

    init(
        entryID: Int64,
        prefetchedEntry: DictionaryEntry?,
        queryService: DictionaryQueryService,
        onCreateCard: ((DictionaryEntry) -> Void)? = nil,
        cardActionTitle: String = "制作成卡片"
    ) {
        self.entryID = entryID
        self.queryService = queryService
        self.onCreateCard = onCreateCard
        self.cardActionTitle = cardActionTitle
        _entry = State(initialValue: prefetchedEntry)
        _isLoading = State(initialValue: prefetchedEntry == nil)
    }

    var body: some View {
        Group {
            if let entry {
                entryList(entry)
            } else if isLoading {
                ProgressView("正在读取词条…")
            } else if isUnavailable {
                ContentUnavailableView {
                    Label("词典不可用", systemImage: "book.closed")
                } description: {
                    Text("内置词典文件缺失或损坏。")
                } actions: {
                    Button("重试") {
                        Task { await loadEntry() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .accessibilityIdentifier("dictionary-unavailable")
            } else {
                ContentUnavailableView(
                    "找不到词条",
                    systemImage: "questionmark.folder",
                    description: Text("词条可能已在词典更新中移除。")
                )
            }
        }
        .navigationTitle("词条详情")
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .task { await loadEntry() }
        .alert(
            "无法读取词条",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented { errorMessage = nil }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    // MARK: - 词条内容

    @ViewBuilder
    private func entryList(_ entry: DictionaryEntry) -> some View {
        List {
            Section {
                Text(entry.primaryForm)
                    .font(.largeTitle.bold())
                let mainReadings = entry.readings
                    .filter { $0.restrictedFormIDs.isEmpty }
                    .map(\.reading)
                if !mainReadings.isEmpty {
                    Text(mainReadings.joined(separator: "、"))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                if entry.commonRank != nil {
                    Text("常用词")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
            }

            formsSection(entry)
            readingsSection(entry)
            sensesSection(entry)
            overlaySection(entry)

            if let onCreateCard {
                Section {
                    Button {
                        onCreateCard(entry)
                    } label: {
                        Text(cardActionTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("dictionary-create-card")
                }
            }

            Section {
                LabeledContent("词条 ID", value: "\(entry.id)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 全部表记；非 standard 类型（sK 检索专用等）加类型徽章。
    private func formsSection(_ entry: DictionaryEntry) -> some View {
        Section("表记") {
            ForEach(entry.forms, id: \.id) { form in
                HStack(spacing: 8) {
                    Text(form.text)
                    Spacer()
                    if form.formType != "standard" {
                        Text(form.formType)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 全部读音；表记限定（re_restr）渲染为「仅用于：…」，
    /// `noKanji`（re_nokanji）标注非真实表记。
    private func readingsSection(_ entry: DictionaryEntry) -> some View {
        Section("读音") {
            ForEach(entry.readings, id: \.id) { reading in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(reading.reading)
                        Spacer()
                        if reading.noKanji {
                            Text("非表记")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !reading.restrictedForms.isEmpty {
                        Text("仅用于：\(reading.restrictedForms.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 按 sense_order 的释义列表：POS codes + zh 释义（无中文时回退
    /// 英文并加 EN 徽章）+ 表记/读音限定 + 参见/反义等 tags。
    private func sensesSection(_ entry: DictionaryEntry) -> some View {
        Section("释义") {
            ForEach(Array(entry.senses.enumerated()), id: \.element.id) { index, sense in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if !sense.posCodes.isEmpty {
                            Text(sense.posCodes.joined(separator: "·"))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let preferred = sense.preferredGlosses() {
                        HStack(alignment: .top, spacing: 6) {
                            if preferred.language != DictionaryGlossLanguage.chinese {
                                Text(languageBadgeText(preferred.language))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        .orange.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 3)
                                    )
                                    .foregroundStyle(.orange)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(
                                    Array(preferred.glosses.enumerated()),
                                    id: \.offset
                                ) { _, gloss in
                                    Text(gloss.text)
                                        .font(.body)
                                }
                            }
                        }
                    } else {
                        Text("暂无释义")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }

                    if !sense.restrictedForms.isEmpty {
                        Text("仅限表记：\(sense.restrictedForms.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !sense.restrictedReadings.isEmpty {
                        Text("仅限读音：\(sense.restrictedReadings.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    senseTagsView(sense)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// sense_tags：xref/ant 渲染为「参见」「反义」；其余类别
    /// （field/misc/dialect/s_inf/lsource）合并为说明性 caption。
    @ViewBuilder
    private func senseTagsView(_ sense: DictionarySense) -> some View {
        let xrefs = sense.tags.filter { $0.category == "xref" }.map(\.code)
        let antonyms = sense.tags.filter { $0.category == "ant" }.map(\.code)
        let others = sense.tags
            .filter { $0.category != "xref" && $0.category != "ant" }
            .map(\.code)
        if !xrefs.isEmpty {
            Text("参见：\(xrefs.joined(separator: "、"))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !antonyms.isEmpty {
            Text("反义：\(antonyms.joined(separator: "、"))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !others.isEmpty {
            Text(others.joined(separator: "·"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// entry 级补充释义（entry_gloss_overlays；当前产物为空表）。
    @ViewBuilder
    private func overlaySection(_ entry: DictionaryEntry) -> some View {
        if !entry.overlayGlosses.isEmpty {
            Section("补充释义") {
                ForEach(
                    Array(entry.overlayGlosses.enumerated()),
                    id: \.offset
                ) { _, overlay in
                    HStack(alignment: .top, spacing: 6) {
                        Text(
                            overlay.language == DictionaryGlossLanguage.chinese
                                ? "中" : languageBadgeText(overlay.language)
                        )
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                .orange.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 3)
                            )
                            .foregroundStyle(.orange)
                        Text(overlay.text)
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    /// 语言徽章文案：eng → "EN"，其他未知语言如实显示大写语言码。
    private func languageBadgeText(_ language: String) -> String {
        language == DictionaryGlossLanguage.english ? "EN" : language.uppercased()
    }

    // MARK: - 加载

    /// 已有聚合详情时跳过；否则按 id 补拉一次。
    private func loadEntry() async {
        guard entry == nil else { return }
        isLoading = true
        do {
            entry = try await queryService.entry(id: entryID)
            isLoading = false
        } catch {
            isLoading = false
            switch error {
            case DictionaryError.unavailable, DictionaryError.incompatibleSchema:
                isUnavailable = true
            default:
                errorMessage = error.localizedDescription
            }
        }
    }
}
