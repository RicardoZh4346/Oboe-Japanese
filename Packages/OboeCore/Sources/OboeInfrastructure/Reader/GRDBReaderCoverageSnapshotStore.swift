import Foundation
import GRDB
import OboeDomain

/// `reader_learning_coverage_snapshots` 的一行（v26，S20）。
///
/// `documentID` 弱引用（SET NULL）+ `documentIDSnapshot` 原文快照
/// 并存：文档删除后历史快照仍可解释（D09 分段语义）。
public struct ReaderCoverageSnapshotRow: Equatable, Sendable {
    public let id: UUID
    /// 文档删除后为 nil（SET NULL）；`documentIDSnapshot` 恒定。
    public let documentID: UUID?
    public let documentIDSnapshot: String
    public let scopeHash: String
    public let contentRevision: Int
    public let knowledgeRevision: Int64
    public let metricVersion: String
    public let dictionaryVersion: String
    public let morphologyVersion: String
    public let resolvedUnique: Int
    public let unknownUnique: Int
    public let learningUnique: Int
    public let masteredUnique: Int
    public let pendingOccurrences: Int
    public let oovOccurrences: Int
    public let analyzedBlocks: Int
    public let totalBlocks: Int
    public let calculatedAt: Date

    public init(
        id: UUID,
        documentID: UUID?,
        documentIDSnapshot: String,
        scopeHash: String,
        contentRevision: Int,
        knowledgeRevision: Int64,
        metricVersion: String,
        dictionaryVersion: String,
        morphologyVersion: String,
        resolvedUnique: Int,
        unknownUnique: Int,
        learningUnique: Int,
        masteredUnique: Int,
        pendingOccurrences: Int,
        oovOccurrences: Int,
        analyzedBlocks: Int,
        totalBlocks: Int,
        calculatedAt: Date
    ) {
        self.id = id
        self.documentID = documentID
        self.documentIDSnapshot = documentIDSnapshot
        self.scopeHash = scopeHash
        self.contentRevision = contentRevision
        self.knowledgeRevision = knowledgeRevision
        self.metricVersion = metricVersion
        self.dictionaryVersion = dictionaryVersion
        self.morphologyVersion = morphologyVersion
        self.resolvedUnique = resolvedUnique
        self.unknownUnique = unknownUnique
        self.learningUnique = learningUnique
        self.masteredUnique = masteredUnique
        self.pendingOccurrences = pendingOccurrences
        self.oovOccurrences = oovOccurrences
        self.analyzedBlocks = analyzedBlocks
        self.totalBlocks = totalBlocks
        self.calculatedAt = calculatedAt
    }
}

/// v0.7.5 S20（v26 `reader_learning_coverage_snapshots` 运行时）：
/// `coverage-resolved-sense-2.0.0` 文档级快照的投影与写入。
///
/// 语义（contracts §6/§13.3、D09）：
/// - **文档级快照**：投影恒覆盖整文档当前 `content_revision` 的
///   `reader_study_occurrences`；`scope_hash` 固定为
///   `AIStudyScope.fullDocument.scopeHash`——章节级快照需要按章
///   过滤投影，本服务明确不提供（唯一键已留 scope 维度）。
/// - **分母** = `resolution_status IN ('aiResolved','userConfirmed')`
///   且 `unit_id` 非空的 occurrence 的 distinct unit；
///   `pendingOccurrences` = status ∈ pending/lowConfidence/rejected/
///   skipped（身份未确认或未采纳，§13.3「待确认」展示口径——
///   rejected/skipped 身份仍属未消歧）；`oovOccurrences` =
///   `unresolved`（无候选/未解析）。
/// - **knowledge_revision** = 本文档已解析 unit 集合上
///   `SUM(flags.revision) + COUNT(links) + MAX(flags.updated_at_ms)`
///   ——flag/link 任一变更即改值（唯一键去重的知识语境分量；
///   非单调时钟语义，仅作指纹）。
/// - **幂等**：唯一键命中即不重插（同度量上下文重复计算是
///   无害回放）；返回值报告实际插入与否。
/// - 空分母仍落快照（pending/oov/块计数有展示价值）；
///   `resolvedUnique == 0` 时 three-coverage 列均为 0——展示层按
///   `Result.resolvedCoverage == nil` 口径处理。
public enum GRDBReaderCoverageSnapshotStore {
    /// 计算整文档 coverage v2 并**幂等**落一行快照。
    ///
    /// - Returns: 计算出的 `ReaderCoverageV2.Result` 与是否实际插行。
    ///   `document` 不存在时抛 `ReaderTranslationError` 风格错误？
    ///   不——抛 `DatabaseError`/`documentMissing` 见下。
    @discardableResult
    public static func recordDocumentSnapshot(
        documentID: UUID,
        dictionaryVersion: String,
        morphologyVersion: String,
        at date: Date = Date(),
        in db: Database
    ) throws -> (result: ReaderCoverageV2.Result, inserted: Bool) {
        let documentIDValue = DatabaseValueCodec.encode(documentID)
        guard let document = try Row.fetchOne(
            db,
            sql: """
                SELECT content_revision FROM reader_documents
                WHERE id = ?
                """,
            arguments: [documentIDValue]
        ) else {
            throw StoreError.documentMissing
        }
        let contentRevision: Int = document["content_revision"]

        // 投影：本文档本修订的 occurrence 分组计数。
        let statusRows = try Row.fetchAll(
            db,
            sql: """
                SELECT resolution_status AS status,
                       unit_id AS unitID, COUNT(*) AS n
                FROM reader_study_occurrences
                WHERE document_id = ? AND content_revision = ?
                GROUP BY resolution_status, unit_id
                """,
            arguments: [documentIDValue, contentRevision]
        )
        var resolvedUnitIDs = Set<UUID>()
        var pending = 0
        var oov = 0
        for row in statusRows {
            let status: String = row["status"]
            let count: Int = row["n"]
            switch status {
            case "aiResolved", "userConfirmed":
                if let raw: String = row["unitID"],
                   let unitID = try? DatabaseValueCodec.decodeUUID(raw)
                {
                    resolvedUnitIDs.insert(unitID)
                } else {
                    // 已解析状态却无 unit/非法 id——投影异常归入
                    // 待确认，不静默丢失（§13.3 计数不许凭空消失）。
                    pending += count
                }
            case "pending", "lowConfidence", "rejected", "skipped":
                pending += count
            case "unresolved":
                oov += count
            default:
                // 未知枚举值未来引入——不猜归属，按待确认计。
                pending += count
            }
        }

        let unitIDs = Array(resolvedUnitIDs)
        let states = try GRDBLearningProgressRepository.knowledgeStates(
            unitIDs: unitIDs, in: db
        )
        let units = unitIDs.map { unitID in
            ReaderCoverageV2.ResolvedUnit(
                unitID: unitID,
                state: states[unitID] ?? .unknown
            )
        }

        // 块覆盖：有 occurrence 的块 = 已分析；分母 = 文档全部块。
        let analyzedBlocks: Int = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(DISTINCT json_extract(
                           locator_json, '$.blockOrdinal')
                           || '@' ||
                           json_extract(
                               locator_json, '$.chapterOrdinal'))
                FROM reader_study_occurrences
                WHERE document_id = ? AND content_revision = ?
                """,
            arguments: [documentIDValue, contentRevision]
        ) ?? 0
        let totalBlocks: Int = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM reader_blocks WHERE document_id = ?
                """,
            arguments: [documentIDValue]
        ) ?? 0

        let result = ReaderCoverageV2.compute(
            units: units,
            occurrenceStats: ReaderCoverageV2.OccurrenceStats(
                pendingOccurrences: pending,
                oovOccurrences: oov,
                analyzedBlocks: analyzedBlocks,
                totalBlocks: totalBlocks
            )
        )

        let knowledgeRevision = try Self.knowledgeRevision(
            unitIDs: unitIDs, in: db)
        let scopeHash = AIStudyScope.fullDocument.scopeHash

        let inserted = try Self.insertSnapshot(
            documentID: documentID,
            documentIDSnapshot: documentIDValue,
            scopeHash: scopeHash,
            contentRevision: contentRevision,
            knowledgeRevision: knowledgeRevision,
            metricVersion: ReaderCoverageV2.metricVersion,
            dictionaryVersion: dictionaryVersion,
            morphologyVersion: morphologyVersion,
            result: result,
            at: date,
            in: db
        )
        return (result, inserted)
    }

    /// 文档快照史（新→旧）；`documentID` 传 nil 匹配孤儿快照
    /// （document SET NULL 后 `document_id` 为 NULL——用
    /// `document_id_snapshot` 查见 `fetchSnapshots(snapshotOf:)`）。
    public static func fetchSnapshots(
        documentID: UUID,
        in db: Database
    ) throws -> [ReaderCoverageSnapshotRow] {
        try rows(
            Row.fetchAll(
                db,
                sql: """
                    SELECT \(columnList)
                    FROM reader_learning_coverage_snapshots
                    WHERE document_id = ?
                    ORDER BY calculated_at_ms DESC
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            )
        )
    }

    /// 按原文快照 id 查史——文档删除（SET NULL）后仍可按
    /// `document_id_snapshot` 追溯（D09）。
    public static func fetchSnapshots(
        snapshotOf documentIDSnapshot: String,
        in db: Database
    ) throws -> [ReaderCoverageSnapshotRow] {
        try rows(
            Row.fetchAll(
                db,
                sql: """
                    SELECT \(columnList)
                    FROM reader_learning_coverage_snapshots
                    WHERE document_id_snapshot = ?
                    ORDER BY calculated_at_ms DESC
                    """,
                arguments: [documentIDSnapshot]
            )
        )
    }

    /// 文档最新快照（统计页/详情页当前覆盖展示）。
    public static func latestSnapshot(
        documentID: UUID,
        in db: Database
    ) throws -> ReaderCoverageSnapshotRow? {
        try rows(
            Row.fetchAll(
                db,
                sql: """
                    SELECT \(columnList)
                    FROM reader_learning_coverage_snapshots
                    WHERE document_id = ?
                    ORDER BY calculated_at_ms DESC LIMIT 1
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            )
        ).first
    }

    // MARK: - 私有

    enum StoreError: Error, Equatable {
        case documentMissing
    }

    private static let columnList = """
        id, document_id, document_id_snapshot, scope_hash,
        content_revision, knowledge_revision, metric_version,
        dictionary_version, morphology_version, resolved_unique,
        unknown_unique, learning_unique, mastered_unique,
        pending_occurrences, oov_occurrences, analyzed_blocks,
        total_blocks, calculated_at_ms
        """

    /// 已解析 unit 集合的知识指纹（唯一键分量——非单调语义）。
    private static func knowledgeRevision(
        unitIDs: [UUID], in db: Database
    ) throws -> Int64 {
        guard !unitIDs.isEmpty else { return 0 }
        var flagsRevision: Int64 = 0
        var flagsMaxMs: Int64 = 0
        var linksCount: Int64 = 0
        for chunk in unitIDs.chunked(400) {
            let keys = chunk.map { DatabaseValueCodec.encode($0) }
            let placeholders = Array(repeating: "?", count: keys.count)
                .joined(separator: ",")
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(revision), 0) AS revSum,
                           COALESCE(MAX(updated_at_ms), 0) AS maxMs
                    FROM learning_unit_flags
                    WHERE unit_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(keys)
            ) {
                flagsRevision += row["revSum"]
                flagsMaxMs = max(flagsMaxMs, row["maxMs"])
            }
            linksCount += Int64(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM learning_unit_note_links
                        WHERE unit_id IN (\(placeholders))
                        """,
                    arguments: StatementArguments(keys)
                ) ?? 0
            )
        }
        return flagsRevision + flagsMaxMs + linksCount
    }

    /// 幂等插入——唯一键命中视作同上下文回放，不重插。
    private static func insertSnapshot(
        documentID: UUID,
        documentIDSnapshot: String,
        scopeHash: String,
        contentRevision: Int,
        knowledgeRevision: Int64,
        metricVersion: String,
        dictionaryVersion: String,
        morphologyVersion: String,
        result: ReaderCoverageV2.Result,
        at date: Date,
        in db: Database
    ) throws -> Bool {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO reader_learning_coverage_snapshots(
                    id, document_id, document_id_snapshot, scope_hash,
                    content_revision, knowledge_revision, metric_version,
                    dictionary_version, morphology_version,
                    resolved_unique, unknown_unique, learning_unique,
                    mastered_unique, pending_occurrences,
                    oov_occurrences, analyzed_blocks, total_blocks,
                    calculated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(UUID()),
                DatabaseValueCodec.encode(documentID),
                documentIDSnapshot,
                scopeHash,
                contentRevision,
                knowledgeRevision,
                metricVersion,
                dictionaryVersion,
                morphologyVersion,
                result.resolvedUnique,
                result.unlearnedUnique,
                result.learningUnique,
                result.masteredUnique,
                result.pendingOccurrences,
                result.oovOccurrences,
                result.analyzedBlocks,
                result.totalBlocks,
                DatabaseValueCodec.encode(date),
            ]
        )
        return db.changesCount > 0
    }

    private static func rows(_ rows: [Row]) throws -> [ReaderCoverageSnapshotRow] {
        try rows.map { row in
            ReaderCoverageSnapshotRow(
                id: try DatabaseValueCodec.decodeUUID(row["id"]),
                documentID: try (row["document_id"] as String?)
                    .map { try DatabaseValueCodec.decodeUUID($0) },
                documentIDSnapshot: row["document_id_snapshot"],
                scopeHash: row["scope_hash"],
                contentRevision: row["content_revision"],
                knowledgeRevision: row["knowledge_revision"],
                metricVersion: row["metric_version"],
                dictionaryVersion: row["dictionary_version"],
                morphologyVersion: row["morphology_version"],
                resolvedUnique: row["resolved_unique"],
                unknownUnique: row["unknown_unique"],
                learningUnique: row["learning_unique"],
                masteredUnique: row["mastered_unique"],
                pendingOccurrences: row["pending_occurrences"],
                oovOccurrences: row["oov_occurrences"],
                analyzedBlocks: row["analyzed_blocks"],
                totalBlocks: row["total_blocks"],
                calculatedAt: DatabaseValueCodec.decodeDate(
                    milliseconds: row["calculated_at_ms"])
            )
        }
    }
}

private extension Array {
    /// IN 列表分块（与本模块其它仓储同一口径：≤400/批，避开
    /// SQLite 变量上限）。
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [] }
        var result: [ArraySlice<Element>] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(
                index, offsetBy: size, limitedBy: endIndex
            ) ?? endIndex
            result.append(self[index..<next])
            index = next
        }
        return result
    }
}
