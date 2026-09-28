import Foundation
import GRDB
import OboeDomain

/// v0.7.0 S12：`cloze_definitions` 表（schema v19，设计 §9.1）的 GRDB
/// 实现。读取即快照回放——`sentence_snapshot`/`accepted_answers_json`
/// 原样解码，不触碰 Reader 表也不做规范化改写（D07/§9.2）。
/// 落库行在写入侧已过 `ClozeValidator.validatePersisted`；读侧解码失败
/// （非法 JSON/range）按数据损坏处理：抛 `ClozeError`，不静默降级。
///
/// S13：`updateSentence` 手动编辑——单事务内复核 note/definition/卡链
/// 与乐观版本，更新 definition 全字段（`content_version+1`）并同步
/// `notes.headword`/`meaning_zh`/`notes`（`content_version+1`——复习
/// 提交守卫读它）；Card 行与 FSRS 不动，`source_context_id` 不动。
public struct GRDBClozeRepository: ClozeEditingRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func fetchDefinition(noteID: UUID) async throws -> ClozeDefinition? {
        try await pool.read { db in
            try Self.fetchDefinition(noteID: noteID, in: db)
        }
    }

    public func fetchDefinition(cardID: UUID) async throws -> ClozeDefinition? {
        try await pool.read { db in
            try Self.fetchDefinition(cardID: cardID, in: db)
        }
    }

    /// definition + notes 编辑/展示字段的聚合读。
    public func fetchSentence(noteID: UUID) async throws -> SentenceNote? {
        try await pool.read { db in
            try Self.fetchSentence(noteID: noteID, in: db)
        }
    }

    /// §9.2 编辑语义：快照可换（range 已随新句重验），Card/FSRS 保留。
    /// `expectedContentVersion` 是 `cloze_definitions.content_version`
    /// 的乐观锁——并发编辑/恢复写入导致失配时抛
    /// `ClozeError.staleContentVersion`，什么都不写。
    public func updateSentence(
        noteID: UUID,
        update: SentenceContentUpdate,
        at date: Date
    ) async throws -> SentenceNote? {
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            // 目标必须是 sentence Note；definition 缺失按 §9.1 不变量
            // 视为数据损坏而不是「可更新的空态」。
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM notes
                        WHERE id = ? AND kind = 'sentence'
                    )
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            ) == true else {
                return nil
            }
            guard let existing = try Self.fetchDefinition(
                noteID: noteID,
                in: db
            ) else {
                throw ClozeError.inconsistentCardLink
            }
            guard existing.contentVersion == update.expectedContentVersion
            else {
                throw ClozeError.staleContentVersion
            }
            // 卡链复核：definition.card_id 必须仍指向本 note 的
            // sentence_cloze 卡（外部裸 UPDATE 破坏的链接不得借编辑
            // 路径写回一个看似合法的新版本）。
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM cards
                        WHERE id = ? AND note_id = ?
                          AND template_kind = 'sentence_cloze'
                    )
                    """,
                arguments: [
                    DatabaseValueCodec.encode(existing.cardID),
                    DatabaseValueCodec.encode(noteID)
                ]
            ) == true else {
                throw ClozeError.inconsistentCardLink
            }
            // 写侧复核与 commit 同判据——绕过 ValidatedClozeContent 构造
            // 的载荷（手工组装/未来恢复路径）也被同一规则拒绝。
            try ClozeValidator.validatePersisted(
                sentence: update.cloze.sentenceSnapshot,
                sentenceSHA256: update.cloze.sentenceSHA256,
                range: update.cloze.range,
                targetSurface: update.cloze.targetSurface,
                acceptedAnswers: update.cloze.acceptedAnswers
            )

            let answersJSON = String(
                decoding: try JSONEncoder().encode(
                    update.cloze.acceptedAnswers
                ),
                as: UTF8.self
            )
            try db.execute(
                sql: """
                    UPDATE cloze_definitions SET
                        sentence_snapshot = ?,
                        sentence_sha256 = ?,
                        range_version = ?,
                        range_utf16_start = ?,
                        range_utf16_length = ?,
                        target_surface = ?,
                        target_lemma = ?,
                        target_reading = ?,
                        accepted_answers_json = ?,
                        hint = ?,
                        content_version = content_version + 1
                    WHERE note_id = ?
                    """,
                arguments: [
                    update.cloze.sentenceSnapshot,
                    update.cloze.sentenceSHA256,
                    update.cloze.range.version,
                    update.cloze.range.utf16Start,
                    update.cloze.range.utf16Length,
                    update.cloze.targetSurface,
                    update.cloze.targetLemma,
                    update.cloze.targetReading,
                    answersJSON,
                    update.cloze.hint,
                    DatabaseValueCodec.encode(noteID)
                ]
            )
            // notes：headword 承载原句快照；content_version 抬升让已打开
            // 的复习提交（读 notes.content_version）被拒（§9.2/review
            // §4「编辑 cloze 内容须同步抬 notes.content_version」）。
            try db.execute(
                sql: """
                    UPDATE notes SET
                        headword = ?,
                        meaning_zh = ?,
                        notes = ?,
                        content_version = content_version + 1,
                        updated_at_ms = ?
                    WHERE id = ? AND kind = 'sentence'
                    """,
                arguments: [
                    update.cloze.sentenceSnapshot,
                    update.meaningZH,
                    update.notes,
                    updatedAtMilliseconds,
                    DatabaseValueCodec.encode(noteID)
                ]
            )
            return try Self.fetchSentence(noteID: noteID, in: db)
        }
    }

    // MARK: - 共享实现（commit/测试事务内可复用）

    static let columns = """
        id, note_id, card_id, source_context_id, sentence_snapshot,
        sentence_sha256, range_version, range_utf16_start, range_utf16_length,
        target_surface, target_lemma, target_reading, accepted_answers_json,
        hint, content_version
        """

    static func fetchDefinition(noteID: UUID, in db: Database) throws -> ClozeDefinition? {
        try Row.fetchOne(
            db,
            sql: "SELECT \(columns) FROM cloze_definitions WHERE note_id = ?",
            arguments: [DatabaseValueCodec.encode(noteID)]
        ).map(decode)
    }

    static func fetchDefinition(cardID: UUID, in db: Database) throws -> ClozeDefinition? {
        try Row.fetchOne(
            db,
            sql: "SELECT \(columns) FROM cloze_definitions WHERE card_id = ?",
            arguments: [DatabaseValueCodec.encode(cardID)]
        ).map(decode)
    }

    /// S13：sentence Note 聚合读——`notes` 行 JOIN `cloze_definitions`
    /// + `note_decks` 成员集。note 存在但非 sentence / 缺 definition
    /// 返回 nil（由调用侧区分「不存在」与「损坏」——编辑写路径对损坏
    /// 单独抛错，读路径沿用 nil 语义）。
    static func fetchSentence(
        noteID: UUID,
        in db: Database
    ) throws -> SentenceNote? {
        guard let noteRow = try Row.fetchOne(
            db,
            sql: """
                SELECT id, deck_id, meaning_zh, notes,
                       content_version, created_at_ms, updated_at_ms
                FROM notes
                WHERE id = ? AND kind = 'sentence'
                """,
            arguments: [DatabaseValueCodec.encode(noteID)]
        ), let definition = try fetchDefinition(noteID: noteID, in: db)
        else {
            return nil
        }
        let noteIDValue: String = noteRow["id"]
        let deckIDValue: String = noteRow["deck_id"]
        let createdAtMilliseconds: Int64 = noteRow["created_at_ms"]
        let updatedAtMilliseconds: Int64 = noteRow["updated_at_ms"]
        let deckIDs = try Set(
            (GRDBNoteDeckMemberships.fetchDeckIDMap(
                noteIDs: [noteIDValue],
                in: db
            )[noteIDValue] ?? [deckIDValue]).map {
                try DatabaseValueCodec.decodeUUID($0)
            }
        )
        return SentenceNote(
            id: try DatabaseValueCodec.decodeUUID(noteIDValue),
            deckID: try DatabaseValueCodec.decodeUUID(deckIDValue),
            deckIDs: deckIDs,
            definition: definition,
            meaningZH: noteRow["meaning_zh"],
            notes: noteRow["notes"],
            noteContentVersion: noteRow["content_version"],
            createdAt: DatabaseValueCodec.decodeDate(
                milliseconds: createdAtMilliseconds
            ),
            updatedAt: DatabaseValueCodec.decodeDate(
                milliseconds: updatedAtMilliseconds
            )
        )
    }

    static func decode(_ row: Row) throws -> ClozeDefinition {
        let idValue: String = row["id"]
        let noteIDValue: String = row["note_id"]
        let cardIDValue: String = row["card_id"]
        let sourceContextIDValue: String? = row["source_context_id"]
        let rangeVersion: Int = row["range_version"]
        let utf16Start: Int = row["range_utf16_start"]
        let utf16Length: Int = row["range_utf16_length"]
        let answersJSON: String = row["accepted_answers_json"]
        guard let answers = try? JSONDecoder().decode(
            [String].self,
            from: Data(answersJSON.utf8)
        ) else {
            throw ClozeError.emptyAcceptedAnswers
        }
        return ClozeDefinition(
            id: try DatabaseValueCodec.decodeUUID(idValue),
            noteID: try DatabaseValueCodec.decodeUUID(noteIDValue),
            cardID: try DatabaseValueCodec.decodeUUID(cardIDValue),
            sourceContextID: try sourceContextIDValue.map {
                try DatabaseValueCodec.decodeUUID($0)
            },
            sentenceSnapshot: row["sentence_snapshot"],
            sentenceSHA256: row["sentence_sha256"],
            range: try ClozeRange(
                persistedVersion: rangeVersion,
                utf16Start: utf16Start,
                utf16Length: utf16Length
            ),
            targetSurface: row["target_surface"],
            targetLemma: row["target_lemma"],
            targetReading: row["target_reading"],
            acceptedAnswers: answers,
            hint: row["hint"],
            contentVersion: row["content_version"]
        )
    }
}
