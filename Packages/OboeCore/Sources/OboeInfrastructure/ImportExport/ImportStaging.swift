import Foundation
import GRDB
import OboeDomain

/// v0.7.0 S16：导入预检的有界 staging（§10.1/§10.3）。
///
/// 全文件扫描产出的规范化逻辑行落盘到临时 SQLite，内存只保留一批；
/// 之后由 replay 迭代器按 batch 重放给映射/校验层。staging 文件可随 job
/// 保留以支持崩溃续传（§10.3「崩溃后有 staging+hash 才允许续传」）——
/// 文件内绝不持久化绝对路径，恢复靠 `fileHash` + 调用方重新定位文件。
///
/// 命名：`import-staging-<uuid>.sqlite`，置于 `OboeImportStaging` 受控目录
/// （默认 `NSTemporaryDirectory()`，可注入以便 job 级管理）。生命周期：
/// - `discard()`：关库并删除 sqlite/-wal/-shm；
/// - `preservesFileOnDeinit = true`：供续传场景，deinit 不删文件；
/// - 默认 deinit 清理，避免临时文件泄漏。
///
/// `@unchecked Sendable`：全部 SQLite 访问经 `DatabaseQueue` 串行化；
/// `rowCount`/`preservesFileOnDeinit` 只在所有者单线流程中读写
/// （UI 流程：intake → precheck → execute 顺序推进，无并发 append）。
public final class ImportStaging: @unchecked Sendable {

    public enum Error: Swift.Error, Equatable {
        case closed
    }

    private var database: DatabaseQueue?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// staging SQLite 文件位置（不持久化到库内——见头注释）。
    public let fileURL: URL
    /// deinit 时是否保留文件（续传场景置 true）。
    public var preservesFileOnDeinit = false

    /// 已写入的逻辑行数（进程内追加计数；重开既有文件时以表计数为准）。
    public private(set) var rowCount = 0

    /// - Parameters:
    ///   - directory: staging 文件父目录；默认
    ///     `NSTemporaryDirectory()/OboeImportStaging`。
    ///   - fileName: 默认 `import-staging-<UUID>.sqlite`。
    public init(directory: URL? = nil, fileName: String? = nil) throws {
        let parent = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("OboeImportStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let name = fileName ?? "import-staging-\(UUID().uuidString).sqlite"
        fileURL = parent.appendingPathComponent(name)

        var configuration = Configuration()
        configuration.journalMode = .wal
        let queue = try DatabaseQueue(path: fileURL.path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS staging_rows (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    logical_row INTEGER NOT NULL,
                    line_start INTEGER NOT NULL,
                    line_end INTEGER NOT NULL,
                    fields TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS plan_rows (
                    logical_row INTEGER PRIMARY KEY,
                    verdict TEXT NOT NULL,
                    target_note_id TEXT,
                    expected_content_version INTEGER,
                    reason TEXT,
                    candidate_note_ids TEXT,
                    first_logical_row INTEGER
                ) WITHOUT ROWID;
                """)
        }
        database = queue
        // 重开既有 staging（崩溃续跑）时从表计数恢复。
        rowCount = (try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM staging_rows")
        }) ?? 0
    }

    deinit {
        if !preservesFileOnDeinit {
            try? discard()
        }
    }

    /// 追加一批逻辑行（单次事务）。调用方控制批大小以维持内存有界。
    public func append(_ rows: [ImportLogicalRow]) throws {
        guard let database else { throw Error.closed }
        guard !rows.isEmpty else { return }
        let encoder = self.encoder
        try database.write { db in
            for row in rows {
                let fieldsJSON = String(
                    decoding: try encoder.encode(row.fields),
                    as: UTF8.self
                )
                try db.execute(
                    sql: """
                        INSERT INTO staging_rows
                            (logical_row, line_start, line_end, fields)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        row.logicalRowNumber,
                        row.rawLineRange.lowerBound,
                        row.rawLineRange.upperBound,
                        fieldsJSON
                    ]
                )
            }
        }
        rowCount += rows.count
    }

    /// 顺序重放游标。每次 `nextBatch` 至多返回 `batchSize` 行，
    /// 保持内存有界；耗尽返回 nil。
    public struct ReplayCursor {
        fileprivate let database: DatabaseQueue
        fileprivate let batchSize: Int
        fileprivate let decoder: JSONDecoder
        fileprivate var lastSeq: Int64 = 0
        fileprivate var exhausted = false

        /// 返回 nil 表示重放完毕。
        public mutating func nextBatch() throws -> [ImportLogicalRow]? {
            if exhausted { return nil }
            let decoder = self.decoder
            let fetched = try database.read { db -> [(Int64, ImportLogicalRow)] in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT seq, logical_row, line_start, line_end, fields
                        FROM staging_rows WHERE seq > ? ORDER BY seq LIMIT ?
                        """,
                    arguments: [lastSeq, batchSize]
                ).map { row -> (Int64, ImportLogicalRow) in
                    let fieldsJSON: String = row["fields"]
                    let fields = (try? decoder.decode([String].self, from: Data(fieldsJSON.utf8))) ?? []
                    return (
                        row["seq"],
                        ImportLogicalRow(
                            logicalRowNumber: row["logical_row"],
                            rawLineRange: row["line_start"]..<row["line_end"],
                            fields: fields
                        )
                    )
                }
            }
            guard let last = fetched.last else {
                exhausted = true
                return nil
            }
            lastSeq = last.0
            return fetched.map(\.1)
        }
    }

    /// 创建顺序游标；`batchSize` 默认与 §10.3 的批上限一致。
    public func makeReplayCursor(batchSize: Int = ImportBatchPolicy.maximumRowsPerBatch) throws -> ReplayCursor {
        guard let database else { throw Error.closed }
        return ReplayCursor(database: database, batchSize: batchSize, decoder: decoder)
    }

    /// 便捷重放：逐 batch 回调，批间可检查取消。
    public func forEachBatch(
        batchSize: Int = ImportBatchPolicy.maximumRowsPerBatch,
        _ body: ([ImportLogicalRow]) throws -> Void
    ) throws {
        var cursor = try makeReplayCursor(batchSize: batchSize)
        while let batch = try cursor.nextBatch() {
            try Task.checkCancellation()
            try body(batch)
        }
    }

    // MARK: - S17：预检 verdict 持久化（plan_rows）

    /// 一行的预检结论。`verdict` 为稳定字符串码（见 `ImportExecutor`：
    /// create/update/conflict/invalid/inFileDuplicate）。
    public struct PlanRow: Equatable, Sendable {
        public let logicalRow: Int
        public let verdict: String
        public let targetNoteID: UUID?
        /// update 命中行在预检时的 `content_version`（§10.3 并发防线）。
        public let expectedContentVersion: Int?
        /// invalid 原因 / conflict 说明 / 其它提示。
        public let reason: String?
        /// conflict 候选 Note ID。
        public let candidateNoteIDs: [UUID]
        /// inFileDuplicate 的基准行号。
        public let firstLogicalRow: Int?

        public init(
            logicalRow: Int,
            verdict: String,
            targetNoteID: UUID? = nil,
            expectedContentVersion: Int? = nil,
            reason: String? = nil,
            candidateNoteIDs: [UUID] = [],
            firstLogicalRow: Int? = nil
        ) {
            self.logicalRow = logicalRow
            self.verdict = verdict
            self.targetNoteID = targetNoteID
            self.expectedContentVersion = expectedContentVersion
            self.reason = reason
            self.candidateNoteIDs = candidateNoteIDs
            self.firstLogicalRow = firstLogicalRow
        }
    }

    /// 清空 plan（重新预检时调用；行数据不动）。
    public func clearPlan() throws {
        guard let database else { throw Error.closed }
        try database.write { db in
            try db.execute(sql: "DELETE FROM plan_rows")
        }
    }

    /// 追加一批预检结论（单事务）。调用方按批调用保持内存有界。
    public func appendPlanRows(_ rows: [PlanRow]) throws {
        guard let database else { throw Error.closed }
        guard !rows.isEmpty else { return }
        try database.write { db in
            for row in rows {
                let candidatesJSON = String(
                    decoding: try encoder.encode(row.candidateNoteIDs.map(\.uuidString)),
                    as: UTF8.self
                )
                try db.execute(
                    sql: """
                        INSERT INTO plan_rows(
                            logical_row, verdict, target_note_id,
                            expected_content_version, reason,
                            candidate_note_ids, first_logical_row
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        row.logicalRow,
                        row.verdict,
                        row.targetNoteID?.uuidString.lowercased(),
                        row.expectedContentVersion,
                        row.reason,
                        candidatesJSON,
                        row.firstLogicalRow
                    ]
                )
            }
        }
    }

    /// plan 行数（执行器用它判断预检是否已跑过）。
    public func planRowCount() throws -> Int {
        guard let database else { throw Error.closed }
        return try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM plan_rows") ?? 0
        }
    }

    /// 按 logical_row 取预检结论（执行时逐批取）。
    public func planRows(logicalRows: some Sequence<Int>) throws -> [Int: PlanRow] {
        guard let database else { throw Error.closed }
        let keys = Array(logicalRows)
        guard !keys.isEmpty else { return [:] }
        let placeholders = keys.map { _ in "?" }.joined(separator: ",")
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM plan_rows WHERE logical_row IN (\(placeholders))",
                arguments: StatementArguments(keys)
            ).reduce(into: [:]) { result, row in
                let logicalRow: Int = row["logical_row"]
                let candidatesJSON: String = row["candidate_note_ids"]
                let candidates = (try? decoder.decode([String].self, from: Data(candidatesJSON.utf8)))?
                    .compactMap(UUID.init(uuidString:)) ?? []
                let target: String? = row["target_note_id"]
                result[logicalRow] = PlanRow(
                    logicalRow: logicalRow,
                    verdict: row["verdict"],
                    targetNoteID: target.flatMap(UUID.init(uuidString:)),
                    expectedContentVersion: row["expected_content_version"],
                    reason: row["reason"],
                    candidateNoteIDs: candidates,
                    firstLogicalRow: row["first_logical_row"]
                )
            }
        }
    }

    /// 关闭并删除 staging 文件（含 -wal/-shm 旁文件）。幂等。
    public func discard() throws {
        database = nil
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = fileURL.path + suffix
            if fm.fileExists(atPath: path) {
                try fm.removeItem(atPath: path)
            }
        }
    }
}
