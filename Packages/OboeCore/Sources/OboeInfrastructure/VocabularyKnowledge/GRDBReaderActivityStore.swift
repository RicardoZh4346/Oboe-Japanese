import CryptoKit
import Foundation
import GRDB
import OboeDomain

/// v18 Reader 域事件 + operation receipt 的共享写入口（§11.2）。
/// `reader_activity_events` / `reader_mining_receipts` 的增删查全部
/// 经这里——知识写路径（本目录 `GRDBVocabularyKnowledgeRepository`）
/// 与后续挖词/导入（S11/S17）复用同一套幂等原语：
/// 先在事务内 `fetchReceipt`，命中即回放；未命中才执行写并在同事务
/// `recordReceipt`。
public enum GRDBReaderActivityStore {

    /// 确定性 operation id（UUIDv5 风格）：SHA-256 前 16 字节 +
    /// version/variant 位修正。知识域内部操作用「语义指纹」派生
    /// opID——同一逻辑操作（同 lexeme/同目标态/同关联）无论点几次
    /// 都落到同一 receipt，是实现「重复操作返回同 receipt」的关键。
    static func deterministicOperationID(_ parts: String...) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data("oboe.v18.\(parts.joined(separator: "|"))".utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// 负载稳定 hash（小写 hex）——receipt 冲突检测与审计用。
    static func payloadHash(_ canonical: String) -> String {
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - reader_activity_events

    /// 同事务写入事件。`operation_id` UNIQUE：同一 opID 已有事件时
    /// 本行不产生（ON CONFLICT DO NOTHING）——调用方在 replay 检查
    /// 之后调用，冲突只可能来自同 opID 的并发/跨操作写，此时保留
    /// 先写者即符合「重复不新增事件」。
    /// - Returns: 实际插入的事件 id；冲突复用时为 nil。
    @discardableResult
    static func insertEvent(
        _ event: ReaderActivityEvent,
        in db: Database
    ) throws -> UUID? {
        try db.execute(
            sql: """
                INSERT INTO reader_activity_events(
                    id, operation_id, kind, lexeme_id, note_id,
                    document_id, snapshot_json, created_at_ms, undone_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(operation_id) DO NOTHING
                """,
            arguments: [
                DatabaseValueCodec.encode(event.id),
                DatabaseValueCodec.encode(event.operationID),
                event.kind.rawValue,
                event.lexemeID.map(DatabaseValueCodec.encode),
                event.noteID.map(DatabaseValueCodec.encode),
                event.documentID.map(DatabaseValueCodec.encode),
                event.snapshotJSON,
                try DatabaseValueCodec.encode(event.createdAt),
                try event.undoneAt.map(DatabaseValueCodec.encode)
            ]
        )
        return db.changesCount > 0 ? event.id : nil
    }

    // MARK: - reader_mining_receipts

    /// 按 operation_id 取 receipt 行（含 payload_hash 供冲突检测）。
    static func fetchReceipt(
        operationID: UUID,
        in db: Database
    ) throws -> (payloadHash: String, resultJSON: String)? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT payload_hash, result_json FROM reader_mining_receipts
                WHERE operation_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(operationID)]
        ) else { return nil }
        return (payloadHash: row["payload_hash"], resultJSON: row["result_json"])
    }

    /// 查询 receipt 的领域投影。
    static func fetchKnowledgeReceipt(
        operationID: UUID,
        in db: Database
    ) throws -> KnowledgeOperationReceipt? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT operation_id, kind, payload_hash, result_json,
                       committed_at_ms
                FROM reader_mining_receipts WHERE operation_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(operationID)]
        ) else { return nil }
        return KnowledgeOperationReceipt(
            operationID: try DatabaseValueCodec.decodeUUID(row["operation_id"]),
            kind: row["kind"],
            payloadHash: row["payload_hash"],
            resultJSON: row["result_json"],
            committedAt: DatabaseValueCodec.decodeDate(milliseconds: row["committed_at_ms"])
        )
    }

    /// 写 receipt。`INSERT OR REPLACE`：同一确定性 opID 的状态迁移
    /// 重放（例：known→reset→known 的第二次 known）会用最新结果
    /// 覆盖旧行——receipt 永远指向「到达该状态的最近一次」；真正
    /// 的同 opID 回放由调用方在写前 `fetchReceipt` 拦截。
    /// 若 receipt 已存在但 payloadHash 不同 → `operationPayloadConflict`。
    static func recordReceipt(
        operationID: UUID,
        kind: String,
        payloadHash: String,
        resultJSON: String,
        at date: Date,
        in db: Database
    ) throws {
        if let existing = try fetchReceipt(operationID: operationID, in: db),
           existing.payloadHash != payloadHash {
            throw VocabularyKnowledgeError.operationPayloadConflict(operationID)
        }
        try db.execute(
            sql: """
                INSERT INTO reader_mining_receipts(
                    operation_id, kind, payload_hash, result_json, committed_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(operation_id) DO UPDATE SET
                    result_json = excluded.result_json,
                    committed_at_ms = excluded.committed_at_ms
                """,
            arguments: [
                DatabaseValueCodec.encode(operationID),
                kind,
                payloadHash,
                resultJSON,
                try DatabaseValueCodec.encode(date)
            ]
        )
    }
}
