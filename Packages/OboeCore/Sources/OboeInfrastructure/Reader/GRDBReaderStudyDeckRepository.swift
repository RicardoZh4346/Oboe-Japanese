import Foundation
import GRDB
import OboeDomain

/// v0.7.5 S18：Reader 文档 ↔ 学习牌组绑定的池级读/写门面 +
/// 文档 coverage v2 的活算投影。
///
/// 分工：
/// - 绑定写语义本身在 `GRDBReaderStudyDeckService`（S06，
///   caller-managed txn，ensureStudyDeck / 改名跟随 / 解绑随
///   FK SET NULL）。本仓储只补「池级」入口：绑/读绑/活算覆盖。
/// - coverage v2 的活算走
///   `GRDBReaderCoverageSnapshotStore.projectDocumentCoverage`——
///   纯持久态投影（occurrence + flags/links + 块计数），**不触发**
///   形态分析、AI 或全文分词。空分母 → `resolvedCoverage == nil`。
/// - 增量通知不独立建流：经 `GRDBLearningProgressRepository
///   .observeProgress()` 的知识指纹 + 绑定行去重发射，订阅方收到
///   ping 后按需调本仓储重投影。
public struct GRDBReaderStudyDeckRepository: Sendable {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public init(database: OboeDatabase) {
        self.pool = database.pool
    }

    // MARK: - 绑定读

    /// 文档当前绑定的学习牌组 id（未绑定/已解绑 → nil）。
    public func studyDeckID(
        forDocument documentID: UUID
    ) throws -> UUID? {
        try pool.read { db in
            guard let raw: String = try String.fetchOne(
                db,
                sql: """
                    SELECT study_deck_id FROM reader_documents WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            ) else { return nil }
            return try? DatabaseValueCodec.decodeUUID(raw)
        }
    }

    /// 牌组侧反查：绑定到该牌组的文档（至多一行，v24 UNIQUE）。
    /// 牌组未被任何文档绑定 → nil。
    public func boundDocumentID(
        forDeck deckID: UUID
    ) throws -> UUID? {
        try pool.read { db in
            guard let raw: String = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM reader_documents WHERE study_deck_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)]
            ) else { return nil }
            return try? DatabaseValueCodec.decodeUUID(raw)
        }
    }

    // MARK: - 绑定写

    /// 池级 `ensureStudyDeck`：同事务内建牌组+绑定（已绑定幂等）。
    /// 写 `decks`/`reader_documents` 两张 rowid 表——观察流正常
    /// 感知（不需要代理）。
    @discardableResult
    public func ensureStudyDeck(
        forDocument documentID: UUID,
        expectedContentRevision: Int? = nil,
        at date: Date = Date()
    ) async throws -> UUID {
        try await pool.write { db in
            try GRDBReaderStudyDeckService.ensureStudyDeck(
                documentID: documentID,
                expectedContentRevision: expectedContentRevision,
                at: date,
                in: db
            )
        }
    }

    // MARK: - 覆盖投影（v2 活算）

    /// 单文档 coverage v2 活算。文档不存在 → nil（reader 侧把
    /// 「文档消失」与「尚无分析」分开渲染）。
    public func documentCoverageResult(
        forDocument documentID: UUID
    ) async throws -> ReaderCoverageV2.Result? {
        try await pool.read { db in
            do {
                return try GRDBReaderCoverageSnapshotStore
                    .projectDocumentCoverage(
                        documentID: documentID, in: db
                    ).result
            } catch GRDBReaderCoverageSnapshotStore.StoreError.documentMissing {
                return nil
            }
        }
    }

    /// 批量 coverage v2 活算（Deck 详情文章覆盖区/Reader 列表按
    /// 需拉取）；不存在/投影失败的文档缺席结果字典。
    public func documentCoverageResults(
        forDocumentIDs documentIDs: [UUID]
    ) async throws -> [UUID: ReaderCoverageV2.Result] {
        guard !documentIDs.isEmpty else { return [:] }
        return try await pool.read { db in
            var output: [UUID: ReaderCoverageV2.Result] = [:]
            output.reserveCapacity(documentIDs.count)
            for documentID in documentIDs {
                guard let projection = try? GRDBReaderCoverageSnapshotStore
                    .projectDocumentCoverage(
                        documentID: documentID, in: db
                    )
                else { continue }
                output[documentID] = projection.result
            }
            return output
        }
    }
}
