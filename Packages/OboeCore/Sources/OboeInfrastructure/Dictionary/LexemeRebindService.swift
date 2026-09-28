import Foundation
import GRDB
import OboeDomain

/// S19 换库重绑服务：词典 dataset 切换后，把所有 jmdict lexeme 的
/// entry 绑定在**原匹配层级内**重解析一遍。
///
/// 语义（设计 §词典2.0「关联调整规则」）：
/// - 每个绑定按其 `match_tier` 只重跑同层匹配——
///   exactWritten 仍只查 forms 通道，绝不降级到 reading/deinflected；
/// - 同层唯一命中 == 旧值 → `current`（只刷新 dataset_version）；
///   唯一命中 ≠ 旧值 → `rebound`（同事务更新绑定与
///   `lexemes.entry_id`，detail 记 `rebound:<old>`）；
/// - 同层零命中 → `stale`；多候选消歧不出唯一 → `ambiguousAwaiting`
///   ——两者都**保留旧 entry_id** 并把 `dataset_version` 留在旧版，
///   使下一轮（更晚的词典版本）仍会重试，不静默换绑；
/// - `sourceContext`/`verifiedExisting`（v22 前无层级信息的存量绑定）
///   走原 entry 核验：仍存在且表记/读音相容 → current，
///   否则 stale（`entry_missing`/`surface_mismatch`）。
///
/// 运行模型：分批（lexeme_id 游标）、批间可取消、每批一事务；
/// 幂等——重跑已处理批次只会得到 `current` 回放。不写
/// `reader_mining_receipts`（kind CHECK 是本冻结集合，重绑不属于
/// 既有操作类别）；返回值 `LexemeRebindSummary` 即报告口径。
public actor LexemeRebindService {
    /// 重绑规则版本——报告引用；规则变更 bump。
    public static let rebindRulesVersion = "s19-rebind-1"
    public static let defaultBatchSize = 200

    private let pool: DatabasePool
    private let store: GRDBDictionaryKnowledgeRepository
    private let batchSize: Int
    private let now: @Sendable () -> Date

    public init(
        pool: DatabasePool,
        batchSize: Int = defaultBatchSize,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pool = pool
        self.store = GRDBDictionaryKnowledgeRepository(pool: pool)
        self.batchSize = batchSize
        self.now = now
    }

    /// 对 `lookup` 指向的（新）词典库做一轮重绑。
    /// `lookup.datasetVersion()` 为空/缺失视为词典不可用。
    @discardableResult
    public func rebind(
        lookup: any DictionaryTieredLookup
    ) async throws -> LexemeRebindSummary {
        guard let newVersion = try await lookup.datasetVersion(),
              !newVersion.isEmpty
        else {
            throw DictionaryError.unavailable("dataset version missing")
        }
        var summary = LexemeRebindSummary(datasetVersion: newVersion)
        try await rebindBoundLexemes(
            newVersion: newVersion, lookup: lookup, summary: &summary)
        try await rebindLegacyLexemes(
            newVersion: newVersion, lookup: lookup, summary: &summary)
        return summary
    }

    // MARK: - 有绑定行的 lexeme（v22 后建立——同层重解析）

    private func rebindBoundLexemes(
        newVersion: String,
        lookup: any DictionaryTieredLookup,
        summary: inout LexemeRebindSummary
    ) async throws {
        var cursor: UUID? = nil
        while true {
            try Task.checkCancellation()
            let page = try await store.bindingsNeedingReverify(
                currentDatasetVersion: newVersion,
                after: cursor, limit: batchSize)
            guard !page.isEmpty else { break }
            cursor = page.last?.binding.lexemeID

            for bound in page {
                let input = LexemeResolutionInput(
                    writtenForm: bound.writtenForm,
                    reading: bound.reading,
                    deinflectionLemmas:
                        bound.binding.tier == .deinflected
                            ? [bound.normalizedLemma] : [],
                    contextEntryID:
                        bound.binding.tier == .sourceContext
                            ? bound.binding.entryID : nil
                )
                let decision = try await DictionaryLexemeResolver.reresolve(
                    tier: bound.binding.tier,
                    currentEntryID: bound.binding.entryID,
                    input: input,
                    lookup: lookup)
                try await store.applyRebindDecision(
                    lexemeID: bound.binding.lexemeID,
                    decision: decision,
                    newDatasetVersion: newVersion,
                    at: now())
                summary.scanned += 1
                switch decision {
                case .current: summary.confirmedCurrent += 1
                case .rebound: summary.rebound += 1
                case .stale: summary.markedStale += 1
                case .ambiguous: summary.markedAmbiguous += 1
                }
            }
        }
    }

    // MARK: - 无绑定行的存量 jmdict lexeme（verifiedExisting）

    private func rebindLegacyLexemes(
        newVersion: String,
        lookup: any DictionaryTieredLookup,
        summary: inout LexemeRebindSummary
    ) async throws {
        var cursor: UUID? = nil
        while true {
            try Task.checkCancellation()
            let page = try await store.unboundJMDictLexemes(
                after: cursor, limit: batchSize)
            guard !page.isEmpty else { break }
            cursor = page.last?.binding.lexemeID

            for bound in page {
                let input = LexemeResolutionInput(
                    writtenForm: bound.writtenForm,
                    reading: bound.reading,
                    deinflectionLemmas: [bound.normalizedLemma]
                )
                let decision = try await DictionaryLexemeResolver.reresolve(
                    tier: .verifiedExisting,
                    currentEntryID: bound.binding.entryID,
                    input: input,
                    lookup: lookup)
                // 存量行无绑定记录——按决策直接落一行绑定：
                // current → 本次核验确认，dataset_version 记新版；
                // stale → dataset_version 记解析时版本（缺失记
                // "unknown"），保持可重试语义。
                let status: LexemeBindingStatus
                let detail: String?
                let version: String
                switch decision {
                case .current:
                    status = .current
                    detail = nil
                    version = newVersion
                    summary.confirmedCurrent += 1
                case .rebound(let entryID):
                    // verifiedExisting 核验路径不产生 rebound——
                    // 防御兜底：换绑需用户可见，记 ambiguous 待确认。
                    status = .ambiguousAwaiting
                    detail = "rebound_candidate:\(entryID)"
                    version = bound.binding.datasetVersion.isEmpty
                        ? "unknown" : bound.binding.datasetVersion
                    summary.markedAmbiguous += 1
                case .stale(let reason):
                    status = .stale
                    detail = reason
                    version = bound.binding.datasetVersion.isEmpty
                        ? "unknown" : bound.binding.datasetVersion
                    summary.markedStale += 1
                case .ambiguous(let ids):
                    status = .ambiguousAwaiting
                    detail = "ambiguous:\(ids.count):"
                        + ids.prefix(16).map(String.init).joined(separator: ",")
                    version = bound.binding.datasetVersion.isEmpty
                        ? "unknown" : bound.binding.datasetVersion
                    summary.markedAmbiguous += 1
                }
                summary.scanned += 1
                try await store.upsertBinding(LexemeBindingRecord(
                    lexemeID: bound.binding.lexemeID,
                    entryID: bound.binding.entryID,
                    tier: .verifiedExisting,
                    datasetVersion: version,
                    status: status,
                    detail: detail,
                    resolvedAt: bound.binding.resolvedAt,
                    updatedAt: now()
                ))
            }
        }
    }
}
