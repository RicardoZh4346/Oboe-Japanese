import Foundation

/// 本地日语词典只读仓储契约（S06 / 技术文档 §3、§4.4、冻结协议 §2.4）。
///
/// 实现要求：
/// - 只读连接、lazy open：init 只存路径，首次查询才打开并校验
///   `dictionary_metadata`（schema_version == "1" 且 dataset_version 非空，
///   否则抛 `DictionaryError.incompatibleSchema`，不崩溃）；
/// - 搜索语义见 `DictionarySearchRequest`/`DictionarySearchPage`：
///   normalize → exact（`normalized_text`/`normalized_reading == q`，按
///   common_rank、entryID）→ deinflected（候选原形规范化精确命中，按
///   common_rank、候选 cost、entryID）→ prefix（`>= q AND < 上界` 的
///   BINARY 范围，按 (normalized, entryID)）；
/// - keyset 分页：同一 (normalizedQuery, candidates) 连续翻页不重不漏；
///   跨 entry 去重——同一 entry 在多个通道/多个表面/多个候选命中时只在
///   其首个命中位置出现一次，并保留各匹配表面与变形链。
public protocol DictionaryRepository: Sendable {
    /// 打开即校验后的元数据（schema/dataset 版本、条目计数、许可修订等）。
    func metadata() async throws -> DictionaryMetadata

    /// 规范化精确 + 变形候选 + 前缀的三阶段分页搜索。
    /// `request.cursor` 的 datasetVersion 与当前库不一致时视为 nil 从头查。
    /// 空 `normalizedQuery` 直接返回空页（不扫全库）。
    func search(_ request: DictionarySearchRequest) async throws -> DictionarySearchPage

    /// 按输入 `ids` 顺序返回存在的词条详情（缺失 id 静默跳过、重复 id
    /// 只返回一次）。调用方负责按需重排——变形候选等场景请先用 hit 顺序
    /// 排好 id 再传入。
    func entries(ids: [Int64]) async throws -> [DictionaryEntry]

    /// 单条详情聚合：forms（含 form_type/priority）、readings（含
    /// no_kanji/表记限定）、senses 按 sense_order、每 sense 的 POS codes、
    /// 按 category 的 tags、按 gloss_order 的分语言 glosses、表记/读音限定、
    /// entry 级 overlays。不存在返回 nil。
    func entry(id: Int64) async throws -> DictionaryEntry?

    /// Sources/Licenses UI 的事实源（D03）：名称、版本、许可、归属说明、
    /// 消费表清单、修改说明、上游摘要与获取时间。
    func sources() async throws -> [DictionarySourceInfo]
}

public extension DictionaryRepository {
    /// 便捷重载：无变形候选的字面量搜索（exact + prefix 两段）。
    /// 等价于 `search(DictionarySearchRequest(query:cursor:limit:))`。
    func search(
        query: String,
        cursor: DictionarySearchCursor? = nil,
        limit: Int = DictionarySearchRequest.defaultLimit
    ) async throws -> DictionarySearchPage {
        try await search(
            DictionarySearchRequest(query: query, limit: limit, cursor: cursor)
        )
    }
}
