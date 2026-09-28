import Foundation
import GRDB
import OboeDomain

/// 「Oboe 学习进度」的牌组聚合结果（契约 §5.1 / 技术文档 §13 /
/// D13）。`progress` 为 nil 时空 deck / 全非词汇 deck ——UI 显示
/// 「—」而不是 0%。
public struct DeckLearningProgress: Equatable, Sendable {
    /// `mean(DISTINCT unitID 的 unitProgress)`；空集 → nil。
    public let progress: Double?
    /// 该牌组经成员 Note 覆盖到的去重 unit 数（0 = 未覆盖任何单元）。
    public let unitCount: Int
    /// 覆盖的 unit 中是否存在任一启用词汇方向卡——false 即 D13
    /// 「无启用方向」标记（全停用/仅 Cloze 的牌组）。
    public let hasEnabledVocabularyCards: Bool
    /// 覆盖 unit 的 stability 非有限卡总数——D13「待修复」标记。
    public let anomalousCardCount: Int

    public init(
        progress: Double?,
        unitCount: Int,
        hasEnabledVocabularyCards: Bool,
        anomalousCardCount: Int
    ) {
        self.progress = progress
        self.unitCount = unitCount
        self.hasEnabledVocabularyCards = hasEnabledVocabularyCards
        self.anomalousCardCount = anomalousCardCount
    }
}

/// v0.7.5 S14（角色 C 持久层部分）：牌组/单元学习进度的批量投影
/// 仓储。依据：contracts-frozen §5.1、技术文档 §13.1/§13.2、D08/D13。
///
/// 口径（全部经 `LearningProgressMath` 纯函数计算，本仓储只做投影）：
/// - `note_decks → learning_unit_note_links` 得出「deck → DISTINCT
///   unitID」；同一 unit 经多条 Note 出现在同 deck 只计一票，同一
///   unit 跨多个 deck 各自计一票——不同 deck 共享同一全局 unit
///   进度值（§13.1）。
/// - `learning_unit_note_links → cards` 取该 unit 名下全部词汇
///   方向卡（primary + legacy secondary Note 都算）；Cloze/
///   Grammar 模板在 SQL 白名单处就排除，不进分子也不进分母。
/// - `learning_unit_flags` 批量取 tooEasy；缺行按 false（与 S08
///   排程资格的 LEFT JOIN 语义一致）。
/// - 不做逐 token/per-card SQL：三条批量 IN 查询（deck→units、
///   units→cards、units→flags），IN 列表按 400 分块——与
///   `GRDBLearningUnitRepository` 既有口径相同。
///
/// 与其它 agent 的分工：unit/link/flag 的存在性与写路径归 S05 的
/// `GRDBLearningUnitRepository`（本仓储复用其
/// `linkedVocabularyUnitIDs` 静态读，不复制 v23 访问逻辑）；
/// document/occurrence 级覆盖归 S05 输出，本仓储不重复实现。
public struct GRDBLearningProgressRepository: Sendable {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    // MARK: - 牌组进度（S16 deck 列表/S18 deck 详情共用）

    /// 批量 deck 进度：一次读事务内完成三段投影。
    /// 返回每个请求 deckID 的条目——无覆盖 unit 的 deck 得到
    /// `progress = nil, unitCount = 0`（不是缺键）。
    public func deckProgress(
        deckIDs: [UUID]
    ) async throws -> [UUID: DeckLearningProgress] {
        try await pool.read { db in
            try Self.deckProgress(deckIDs: deckIDs, in: db)
        }
    }

    /// 值便捷版：只关心进度数值的调用方（等价于
    /// `deckProgress(...).mapValues(\.progress)`）。
    public func deckProgressValues(
        deckIDs: [UUID]
    ) async throws -> [UUID: Double?] {
        try await deckProgress(deckIDs: deckIDs).mapValues(\.progress)
    }

    /// 事务内形态：deck → DISTINCT unitID → unit 进度 → 牌组平均。
    /// `LearningProgressMath.deckProgress` 内部按 unitID 去重——
    /// 投影阶段保持「每 (deck, unit) 一行」即可，去重不外泄。
    public static func deckProgress(
        deckIDs: [UUID],
        in db: Database
    ) throws -> [UUID: DeckLearningProgress] {
        let uniqueDeckIDs = Array(Set(deckIDs))
        guard !uniqueDeckIDs.isEmpty else { return [:] }

        // 段 1：note_decks → links，deck → DISTINCT unitID。
        var unitIDsByDeck: [UUID: Set<UUID>] = [:]
        var allUnitIDs = Set<UUID>()
        for chunk in uniqueDeckIDs.chunked(400) {
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ",")
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT nd.deck_id AS deck_id,
                                    lul.unit_id AS unit_id
                    FROM note_decks nd
                    JOIN learning_unit_note_links lul
                      ON lul.note_id = nd.note_id
                    WHERE nd.deck_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(
                    chunk.map(DatabaseValueCodec.encode))
            ) {
                let deckID: String = row["deck_id"]
                let unitID: String = row["unit_id"]
                let deck = try DatabaseValueCodec.decodeUUID(deckID)
                let unit = try DatabaseValueCodec.decodeUUID(unitID)
                unitIDsByDeck[deck, default: []].insert(unit)
                allUnitIDs.insert(unit)
            }
        }

        let unitResults = try unitProgresses(
            unitIDs: Array(allUnitIDs),
            in: db
        )

        var result: [UUID: DeckLearningProgress] = [:]
        for deckID in uniqueDeckIDs {
            let unitIDs = unitIDsByDeck[deckID] ?? []
            let inputs = unitIDs.map {
                DeckUnitProgressInput(
                    unitID: $0,
                    progress: unitResults[$0]?.value
                )
            }
            result[deckID] = DeckLearningProgress(
                progress: LearningProgressMath.deckProgress(units: inputs),
                unitCount: unitIDs.count,
                hasEnabledVocabularyCards: unitIDs.contains {
                    (unitResults[$0]?.enabledCardCount ?? 0) > 0
                },
                anomalousCardCount: unitIDs.reduce(0) {
                    $0 + (unitResults[$1]?.anomalousCardCount ?? 0)
                }
            )
        }
        return result
    }

    // MARK: - 单元进度（S18 deck 详情/单元列表可用）

    /// 批量 unit 进度：links→cards 投影词汇方向卡 + flags 批量读，
    /// 经 `LearningProgressMath.cardProgress/unitProgress` 出值。
    /// 请求的每个 id 都有条目：无词汇卡且未标 tooEasy →
    /// `UnitProgressResult(value: 0, enabledCardCount: 0, ...)`，
    /// 便于调用方直接下标。
    public func unitProgresses(
        unitIDs: [UUID]
    ) async throws -> [UUID: UnitProgressResult] {
        try await pool.read { db in
            try Self.unitProgresses(unitIDs: unitIDs, in: db)
        }
    }

    /// 事务内形态。两条批量 IN 查询（≤400/块）：
    /// 1. `links ⋈ cards` → (unitID, templateKind, isEnabled, stability)
    ///    模板白名单在 SQL 侧过滤——停用卡照读出（其
    ///    `countsTowardUnitMean` 由纯函数判），非词汇模板不进投影。
    /// 2. `learning_unit_flags` → tooEasy（缺行 false）。
    public static func unitProgresses(
        unitIDs: [UUID],
        in db: Database
    ) throws -> [UUID: UnitProgressResult] {
        let unique = Array(Set(unitIDs))
        guard !unique.isEmpty else { return [:] }

        var cardProgressesByUnit: [UUID: [CardProgressResult]] = [:]
        let templateList = SchedulingEligibilitySQL.vocabularyTemplateList
        for chunk in unique.chunked(400) {
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ",")
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT lul.unit_id AS unit_id,
                           cards.is_enabled AS is_enabled,
                           cards.stability AS stability
                    FROM learning_unit_note_links lul
                    JOIN cards ON cards.note_id = lul.note_id
                    WHERE lul.unit_id IN (\(placeholders))
                      AND cards.template_kind IN (\(templateList))
                    """,
                arguments: StatementArguments(
                    chunk.map(DatabaseValueCodec.encode))
            ) {
                let unitIDRaw: String = row["unit_id"]
                let isEnabled: Bool = row["is_enabled"]
                let stability: Double = row["stability"]
                let unitID = try DatabaseValueCodec.decodeUUID(unitIDRaw)
                cardProgressesByUnit[unitID, default: []].append(
                    LearningProgressMath.cardProgress(
                        stabilityDays: stability,
                        enabled: isEnabled
                    )
                )
            }
        }

        let tooEasyByUnit = try fetchTooEasyFlags(unitIDs: unique, in: db)

        var result: [UUID: UnitProgressResult] = [:]
        for unitID in unique {
            result[unitID] = LearningProgressMath.unitProgress(
                tooEasy: tooEasyByUnit[unitID] ?? false,
                cardProgresses: cardProgressesByUnit[unitID] ?? []
            )
        }
        return result
    }

    // MARK: - 三态批量（契约 §2.1 真值表；§13.2）

    /// `unitStates`：flags + links 两条批量查询后统一走
    /// `LearningKnowledgeResolver.state`——三态判定不在 SQL 里复制。
    /// 链接集合复用 S05 `GRDBLearningUnitRepository` 的
    /// `linkedVocabularyUnitIDs`（只数 vocabulary Note 的有效关联）。
    /// 请求的每个 id 都有条目：无 link 且无 flag → `unknown`。
    public func knowledgeStates(
        unitIDs: [UUID]
    ) async throws -> [UUID: LearningKnowledgeState] {
        try await pool.read { db in
            try Self.knowledgeStates(unitIDs: unitIDs, in: db)
        }
    }

    public static func knowledgeStates(
        unitIDs: [UUID],
        in db: Database
    ) throws -> [UUID: LearningKnowledgeState] {
        let unique = Array(Set(unitIDs))
        guard !unique.isEmpty else { return [:] }
        let tooEasyByUnit = try fetchTooEasyFlags(unitIDs: unique, in: db)
        let linked = try GRDBLearningUnitRepository
            .linkedVocabularyUnitIDs(unitIDs: unique, in: db)
        var result: [UUID: LearningKnowledgeState] = [:]
        for unitID in unique {
            result[unitID] = LearningKnowledgeResolver.state(
                tooEasy: tooEasyByUnit[unitID] ?? false,
                hasVocabularyNoteLink: linked.contains(unitID)
            )
        }
        return result
    }

    // MARK: - 内部

    /// 批量 flag 读（IN ≤400/块）：只取 `too_easy`；无行 = false。
    private static func fetchTooEasyFlags(
        unitIDs: [UUID],
        in db: Database
    ) throws -> [UUID: Bool] {
        var result: [UUID: Bool] = [:]
        for chunk in unitIDs.chunked(400) {
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ",")
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT unit_id, too_easy FROM learning_unit_flags
                    WHERE unit_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(
                    chunk.map(DatabaseValueCodec.encode))
            ) {
                let unitIDRaw: String = row["unit_id"]
                let tooEasy: Bool = row["too_easy"]
                result[try DatabaseValueCodec.decodeUUID(unitIDRaw)] = tooEasy
            }
        }
        return result
    }
}

private extension Array {
    /// IN 列表分块（与本模块其它仓储同一口径：≤400/批，避开
    /// SQLite 变量上限同时保持批量而非逐条）。
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [] }
        var result: [ArraySlice<Element>] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(
                index,
                offsetBy: size,
                limitedBy: endIndex
            ) ?? endIndex
            result.append(self[index..<next])
            index = next
        }
        return result
    }
}
