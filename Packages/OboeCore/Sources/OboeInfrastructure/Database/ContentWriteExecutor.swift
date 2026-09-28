import Foundation
import GRDB
import OboeDomain

/// v0.7.0 S03：事务内内容写入执行器。
/// `GRDBContentCardRepository` 的公开方法只是 `pool.write` 的薄封装，
/// 真正的写逻辑全部沉淀在这里——导入执行（S17）、挖词（S11）、
/// Cloze 创建（S12/S13）等批量调用方在自己的 `pool.write` 事务内
/// 组合 `execute(_:capture:in:)` 与各自的域 receipt，保证
/// Note/Card/membership/SourceContext 同事务，且不在 async service
/// 内嵌套数据库事务。
public enum GRDBContentWriteExecutor {
    /// 在已存在的事务内执行一条 validated command。
    /// 带 capture 时先做 operationID+digest 回放检查；无既有 receipt
    /// 才执行写入，并在同事务记录 receipt。digest 冲突抛
    /// `InboxError.commitPayloadConflict`。
    public static func execute(
        _ command: ValidatedContentCommand,
        capture: CaptureCommitContext?,
        in db: Database
    ) throws -> ContentCommitResult {
        switch command {
        case let .vocabulary(commit):
            try commitVocabulary(commit, capture: capture, in: db)
        case let .grammar(commit):
            try commitGrammar(commit, capture: capture, in: db)
        case let .sentence(commit):
            try commitSentence(commit, capture: capture, in: db)
        }
    }

    static func commitVocabulary(
        _ commit: VocabularyContentCommit,
        capture: CaptureCommitContext?,
        in db: Database
    ) throws -> ContentCommitResult {
        let timestamp = try DatabaseValueCodec.encode(commit.createdAt)
        if let capture {
            let digest = CaptureCommitDigest.vocabulary(commit)
            if let receipt = try GRDBInboxRepository.fetchCommitReceiptRow(
                operationID: capture.operationID,
                in: db
            ) {
                return try GRDBContentCardRepository.replayCommitReceipt(
                    receipt,
                    expectedPayloadHash: digest
                )
            }
        }
        if let sourceRef = commit.sourceRef,
           let existing = try Row.fetchOne(
               db,
               sql: """
                   SELECT notes.id, COUNT(cards.id) AS card_count
                   FROM notes
                   LEFT JOIN cards ON cards.note_id = notes.id
                   WHERE notes.origin = 'builtin_jlpt' AND notes.source_ref = ?
                   GROUP BY notes.id
                   """,
               arguments: [sourceRef]
           ) {
            return ContentCommitResult(
                noteID: try DatabaseValueCodec.decodeUUID(existing["id"]),
                cardCount: existing["card_count"],
                wasCreated: false
            )
        }
        for memberDeckID in commit.deckIDs {
            try GRDBContentCardRepository.requireDeck(memberDeckID, in: db)
        }
        let profileID = try GRDBSchedulerProfileStore.ensureConfiguredProfile(
            candidateID: commit.schedulerProfileID,
            createdAtMilliseconds: timestamp,
            in: db
        )
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, reading, meaning_zh,
                    part_of_speech, jlpt, notes, origin, source_ref, source_text,
                    pitch_accent, content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(commit.noteID),
                DatabaseValueCodec.encode(commit.deckID),
                commit.content.headword,
                commit.content.reading,
                commit.content.meaningZH,
                commit.content.partOfSpeech,
                commit.content.jlpt?.rawValue,
                commit.content.notes,
                commit.origin.rawValue,
                commit.sourceRef,
                commit.sourceText,
                commit.content.pitchAccent?.rawValue,
                timestamp,
                timestamp
            ]
        )
        try GRDBContentCardRepository.insertMemberships(
            noteID: commit.noteID,
            deckIDs: commit.deckIDs,
            atMilliseconds: timestamp,
            in: db
        )
        if let example = commit.content.example {
            try GRDBContentCardRepository.insertExample(
                id: commit.exampleID,
                noteID: commit.noteID,
                japanese: example.japanese,
                translationZH: example.translationZH,
                in: db
            )
        }
        try GRDBContentCardRepository.insertTags(commit.tags, noteID: commit.noteID, in: db)
        for card in commit.cards {
            guard card.templateKind.knowledgePointKind == .vocabulary else {
                throw ContentCardError.invalidTemplateForKnowledgePoint
            }
            try GRDBContentCardRepository.insertOrEnableCard(
                card,
                noteID: commit.noteID,
                profileID: profileID,
                dueAtMilliseconds: timestamp,
                in: db
            )
        }
        // 来源记录与 Note/Card 同事务（设计 §6.2）：事务回滚则
        // 来源、Note、capture receipt 一起消失，无半截来源。
        // builtin_jlpt 去重提前返回的路径不补来源——既有 Note 的
        // 来源追加走 SourceContextRepository，不经 commit。
        if let sourceContext = commit.sourceContext {
            guard sourceContext.noteID == commit.noteID else {
                throw ContentCardError.sourceContextNoteMismatch
            }
            try GRDBSourceContextRepository.insert(sourceContext, in: db)
        }
        if let draftID = commit.draftID {
            try GRDBContentCardRepository.deleteDraft(id: draftID, kind: "vocabulary", in: db)
        }
        let result = ContentCommitResult(
            noteID: commit.noteID,
            cardCount: commit.cards.count
        )
        if let capture {
            try GRDBContentCardRepository.recordCaptureCommit(
                capture,
                payloadHash: CaptureCommitDigest.vocabulary(commit),
                resultJSON: GRDBContentCardRepository.encodeCommitResult(result),
                inboxItemID: capture.inboxItemID,
                at: commit.createdAt,
                in: db
            )
        }
        return result
    }

    static func commitGrammar(
        _ commit: GrammarContentCommit,
        capture: CaptureCommitContext?,
        in db: Database
    ) throws -> ContentCommitResult {
        let timestamp = try DatabaseValueCodec.encode(commit.createdAt)
        if let capture {
            let digest = CaptureCommitDigest.grammar(commit)
            if let receipt = try GRDBInboxRepository.fetchCommitReceiptRow(
                operationID: capture.operationID,
                in: db
            ) {
                return try GRDBContentCardRepository.replayCommitReceipt(
                    receipt,
                    expectedPayloadHash: digest
                )
            }
        }
        for memberDeckID in commit.deckIDs {
            try GRDBContentCardRepository.requireDeck(memberDeckID, in: db)
        }
        guard commit.card.templateKind == .grammarFormToExplanation else {
            throw ContentCardError.invalidTemplateForKnowledgePoint
        }
        let profileID = try GRDBSchedulerProfileStore.ensureConfiguredProfile(
            candidateID: commit.schedulerProfileID,
            createdAtMilliseconds: timestamp,
            in: db
        )
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, meaning_zh, usage,
                    connection, jlpt, notes, origin, source_text,
                    content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'grammar', ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(commit.noteID),
                DatabaseValueCodec.encode(commit.deckID),
                commit.content.grammarForm,
                commit.content.meaningZH,
                commit.content.usage,
                commit.content.connection,
                commit.content.jlpt?.rawValue,
                commit.content.notes,
                commit.origin.rawValue,
                commit.sourceText,
                timestamp,
                timestamp
            ]
        )
        try GRDBContentCardRepository.insertMemberships(
            noteID: commit.noteID,
            deckIDs: commit.deckIDs,
            atMilliseconds: timestamp,
            in: db
        )
        if let example = commit.content.example {
            try GRDBContentCardRepository.insertExample(
                id: commit.exampleID,
                noteID: commit.noteID,
                japanese: example.japanese,
                translationZH: example.translationZH,
                in: db
            )
        }
        try GRDBContentCardRepository.insertTags(commit.tags, noteID: commit.noteID, in: db)
        try GRDBContentCardRepository.insertOrEnableCard(
            commit.card,
            noteID: commit.noteID,
            profileID: profileID,
            dueAtMilliseconds: timestamp,
            in: db
        )
        if let sourceContext = commit.sourceContext {
            guard sourceContext.noteID == commit.noteID else {
                throw ContentCardError.sourceContextNoteMismatch
            }
            try GRDBSourceContextRepository.insert(sourceContext, in: db)
        }
        if let draftID = commit.draftID {
            try GRDBContentCardRepository.deleteDraft(id: draftID, kind: "grammar", in: db)
        }
        let result = ContentCommitResult(noteID: commit.noteID, cardCount: 1)
        if let capture {
            try GRDBContentCardRepository.recordCaptureCommit(
                capture,
                payloadHash: CaptureCommitDigest.grammar(commit),
                resultJSON: GRDBContentCardRepository.encodeCommitResult(result),
                inboxItemID: capture.inboxItemID,
                at: commit.createdAt,
                in: db
            )
        }
        return result
    }

    /// v0.7.0 S12（设计 §9.1–9.3）：sentence Note + `sentence_cloze` Card +
    /// `cloze_definitions` + 来源记录的原子写入。`ValidatedClozeContent`
    /// 在构造期已完成 blank 校验；这里仍复核持久化一致性（snapshot hash、
    /// range、surface ∈ answers）——绕过 init 的路径（手工组装、回放）
    /// 也在同一判据下被拒绝，且任一步失败整事务回滚，不留半截关联。
    static func commitSentence(
        _ commit: SentenceContentCommit,
        capture: CaptureCommitContext?,
        in db: Database
    ) throws -> ContentCommitResult {
        let timestamp = try DatabaseValueCodec.encode(commit.createdAt)
        if let capture {
            let digest = CaptureCommitDigest.sentence(commit)
            if let receipt = try GRDBInboxRepository.fetchCommitReceiptRow(
                operationID: capture.operationID,
                in: db
            ) {
                return try GRDBContentCardRepository.replayCommitReceipt(
                    receipt,
                    expectedPayloadHash: digest
                )
            }
        }
        for memberDeckID in commit.deckIDs {
            try GRDBContentCardRepository.requireDeck(memberDeckID, in: db)
        }
        guard commit.card.templateKind == .sentenceCloze else {
            throw ContentCardError.invalidTemplateForKnowledgePoint
        }
        if let sourceContext = commit.sourceContext,
           sourceContext.noteID != commit.noteID {
            throw ContentCardError.sourceContextNoteMismatch
        }
        try ClozeValidator.validatePersisted(
            sentence: commit.cloze.sentenceSnapshot,
            sentenceSHA256: commit.cloze.sentenceSHA256,
            range: commit.cloze.range,
            targetSurface: commit.cloze.targetSurface,
            acceptedAnswers: commit.cloze.acceptedAnswers
        )
        let profileID = try GRDBSchedulerProfileStore.ensureConfiguredProfile(
            candidateID: commit.schedulerProfileID,
            createdAtMilliseconds: timestamp,
            in: db
        )
        // sentence Note 的 headword 承载原句快照；meaning_zh 可空
        // （v19 条件 CHECK：sentence 允许 NULL 或非空译文）。
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, meaning_zh, notes, origin,
                    source_text, content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'sentence', ?, ?, ?, ?, ?, 1, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(commit.noteID),
                DatabaseValueCodec.encode(commit.deckID),
                commit.cloze.sentenceSnapshot,
                commit.meaningZH,
                commit.notes,
                commit.origin.rawValue,
                commit.sourceText,
                timestamp,
                timestamp
            ]
        )
        try GRDBContentCardRepository.insertMemberships(
            noteID: commit.noteID,
            deckIDs: commit.deckIDs,
            atMilliseconds: timestamp,
            in: db
        )
        try GRDBContentCardRepository.insertTags(
            commit.tags,
            noteID: commit.noteID,
            in: db
        )
        try GRDBContentCardRepository.insertOrEnableCard(
            commit.card,
            noteID: commit.noteID,
            profileID: profileID,
            dueAtMilliseconds: timestamp,
            in: db
        )
        // `insertOrEnableCard` 的 ON CONFLICT 分支只翻转 is_enabled——
        // 若同 Note 已有 cloze 卡，行 id 仍是旧值而非 commit.card.id；
        // definition.card_id 必须指向真实持久化行，否则就是错位关联。
        guard let persistedCardID: String = try String.fetchOne(
            db,
            sql: """
                SELECT id FROM cards
                WHERE note_id = ? AND template_kind = 'sentence_cloze'
                """,
            arguments: [DatabaseValueCodec.encode(commit.noteID)]
        ), persistedCardID == DatabaseValueCodec.encode(commit.card.id) else {
            throw ClozeError.inconsistentCardLink
        }
        // 来源记录先于 definition 写入（FK 引用）；noteID 一致性已在
        // 上面复核——同事务内任一步失败来源、Note、卡一起回滚。
        var sourceContextID: UUID?
        if let sourceContext = commit.sourceContext {
            try GRDBSourceContextRepository.insert(sourceContext, in: db)
            sourceContextID = sourceContext.id
        }
        let answersJSON = String(
            decoding: try JSONEncoder().encode(commit.cloze.acceptedAnswers),
            as: UTF8.self
        )
        try db.execute(
            sql: """
                INSERT INTO cloze_definitions(
                    id, note_id, card_id, source_context_id, sentence_snapshot,
                    sentence_sha256, range_version, range_utf16_start,
                    range_utf16_length, target_surface, target_lemma,
                    target_reading, accepted_answers_json, hint, content_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(commit.clozeID),
                DatabaseValueCodec.encode(commit.noteID),
                persistedCardID,
                sourceContextID.map { DatabaseValueCodec.encode($0) },
                commit.cloze.sentenceSnapshot,
                commit.cloze.sentenceSHA256,
                commit.cloze.range.version,
                commit.cloze.range.utf16Start,
                commit.cloze.range.utf16Length,
                commit.cloze.targetSurface,
                commit.cloze.targetLemma,
                commit.cloze.targetReading,
                answersJSON,
                commit.cloze.hint
            ]
        )
        let result = ContentCommitResult(noteID: commit.noteID, cardCount: 1)
        if let capture {
            try GRDBContentCardRepository.recordCaptureCommit(
                capture,
                payloadHash: CaptureCommitDigest.sentence(commit),
                resultJSON: GRDBContentCardRepository.encodeCommitResult(result),
                inboxItemID: capture.inboxItemID,
                at: commit.createdAt,
                in: db
            )
        }
        return result
    }
}
