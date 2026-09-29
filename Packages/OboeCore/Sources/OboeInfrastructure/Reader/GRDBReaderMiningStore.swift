import Foundation
import GRDB
import OboeDomain

/// v0.7.0 S11：`ReaderMiningStore` 的 GRDB 实现。
///
/// 单次挖词 = 一次 `pool.write`，顺序固定：
/// 1. **世代复核**——`currentGeneration() != expectedGeneration` 即
///    `staleGeneration` 抛错；恢复/迁移递增世代后，旧代请求不写回。
/// 2. **receipt 回放**——`reader_mining_receipts` 命中：
///    payload_hash 一致 → 解码 result_json 直接返回（零写入）；
///    不一致 → `operationPayloadConflict`。
/// 3. **内容写入**——`createNote` 走 `GRDBContentWriteExecutor`
///    （Note/Card/membership/来源同事务，来源已在 commit 内装配）；
///    `linkExisting` 校验 Note 存在且为 vocabulary → 追加 membership
///    （`INSERT OR IGNORE`，不动既有成员）→ 来源行（既有 primary
///    时本行降级）→ `notes.updated_at_ms`。
/// 4. **lexeme upsert + 关联**——identity_key 命中返回既有行
///    （§6.3 稳定主键），否则按 seed 插入；`lexeme_note_links`
///    `userConfirmed` upsert。
/// 5. **事件**——`reader_activity_events`（`minedNewNote` /
///    `linkedExistingNote`），operation_id 即挖词 opID。
/// 6. **receipt 记录**——kind ∈ {mine_vocabulary, link_existing_note}。
///
/// 任一步失败整事务回滚：不留半截 Note/关联/事件。
public struct GRDBReaderMiningStore: ReaderMiningStore, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    /// v0.7.5 S16：同 pool 的 learning-unit flag 门面派生点——
    /// Reader Inspector 经 `ReaderMiningService.miningStore` 直达
    /// flag CAS/事件 API，无需改动 Reader 依赖装配文件。
    public var learningUnitFlags: GRDBLearningUnitRepository {
        GRDBLearningUnitRepository(pool: pool)
    }

    // MARK: - 读

    public func noteSummaries(
        ids: [UUID]
    ) async throws -> [ReaderLinkedNote] {
        guard !ids.isEmpty else { return [] }
        let encoded = ids.map { DatabaseValueCodec.encode($0) }
        return try await pool.read { db in
            var result: [UUID: ReaderLinkedNote] = [:]
            for chunk in encoded.chunked(400) {
                let placeholders = Array(
                    repeating: "?", count: chunk.count
                ).joined(separator: ",")
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, headword, reading, meaning_zh, deck_id
                        FROM notes WHERE id IN (\(placeholders))
                        """,
                    arguments: StatementArguments(Array(chunk))
                ) {
                    let id = try DatabaseValueCodec.decodeUUID(row["id"])
                    result[id] = ReaderLinkedNote(
                        noteID: id,
                        headword: row["headword"],
                        reading: row["reading"],
                        meaningZH: row["meaning_zh"] ?? "",
                        deckID: try DatabaseValueCodec.decodeUUID(
                            row["deck_id"]
                        )
                    )
                }
            }
            return ids.compactMap { result[$0] }
        }
    }

    public func findDuplicateVocabularyNotes(
        headword: String,
        reading: String?
    ) async throws -> [ReaderLinkedNote] {
        try await pool.read { db in
            let rows: [Row]
            if let reading {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, headword, reading, meaning_zh, deck_id
                        FROM notes
                        WHERE kind = 'vocabulary' AND headword = ?
                              AND (reading = ? OR reading IS NULL)
                        ORDER BY created_at_ms, id
                        """,
                    arguments: [headword, reading]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, headword, reading, meaning_zh, deck_id
                        FROM notes
                        WHERE kind = 'vocabulary' AND headword = ?
                        ORDER BY created_at_ms, id
                        """,
                    arguments: [headword]
                )
            }
            return try rows.map { row in
                ReaderLinkedNote(
                    noteID: try DatabaseValueCodec.decodeUUID(row["id"]),
                    headword: row["headword"],
                    reading: row["reading"],
                    meaningZH: row["meaning_zh"] ?? "",
                    deckID: try DatabaseValueCodec.decodeUUID(row["deck_id"])
                )
            }
        }
    }

    // MARK: - 原子写

    public func commit(
        _ plan: ReaderMiningWritePlan,
        currentGeneration: @Sendable () -> Int
    ) async throws -> ReaderMiningOutcome {
        try await pool.write { db in
            // 1) 世代屏障：恢复后旧代请求整事务拒写。
            let generation = currentGeneration()
            guard generation == plan.expectedGeneration else {
                throw ReaderMiningError.staleGeneration(
                    expected: plan.expectedGeneration, current: generation
                )
            }

            let payloadHash = GRDBReaderActivityStore.payloadHash(
                plan.canonicalPayload
            )
            // 2) receipt 回放：同 opID 重试返回既有结果，不复制卡。
            if let receipt = try GRDBReaderActivityStore.fetchReceipt(
                operationID: plan.operationID, in: db
            ) {
                guard receipt.payloadHash == payloadHash else {
                    throw ReaderMiningError.operationPayloadConflict(
                        plan.operationID
                    )
                }
                guard let outcome = Self.decodeOutcome(
                    receipt.resultJSON, operationID: plan.operationID
                ) else {
                    throw ReaderMiningError.receiptCorrupt(plan.operationID)
                }
                return outcome
            }

            // 3) 内容写入 + 4) lexeme 关联 + 5) 事件。
            let noteID: UUID
            let cardCount: Int
            let wasExistingNote: Bool
            switch plan.action {
            case let .createNote(commit):
                let result = try GRDBContentWriteExecutor.execute(
                    .vocabulary(commit), capture: nil, in: db
                )
                noteID = result.noteID
                cardCount = result.cardCount
                wasExistingNote = false
            case let .linkExisting(existingNoteID, membershipDeckIDs,
                                  sourceContext):
                guard try Self.vocabularyNoteExists(
                    existingNoteID, in: db
                ) else {
                    throw ReaderMiningError.noteNotFound(existingNoteID)
                }
                for deckID in membershipDeckIDs {
                    try GRDBContentCardRepository.requireDeck(deckID, in: db)
                }
                let atMs = try DatabaseValueCodec.encode(plan.committedAt)
                for deckID in membershipDeckIDs {
                    try db.execute(
                        sql: """
                            INSERT INTO note_decks(
                                note_id, deck_id, added_at_ms
                            ) VALUES (?, ?, ?)
                            ON CONFLICT(note_id, deck_id) DO NOTHING
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(existingNoteID),
                            DatabaseValueCodec.encode(deckID),
                            atMs
                        ]
                    )
                }
                try db.execute(
                    sql: "UPDATE notes SET updated_at_ms = ? WHERE id = ?",
                    arguments: [atMs, DatabaseValueCodec.encode(existingNoteID)]
                )
                // 既有 Note 的 primary 裁决在事务内做（并发安全）：
                // 已有 primary 来源时新来源降级，不撞部分唯一索引。
                let resolvedContext = try Self.resolvePrimary(
                    sourceContext, noteID: existingNoteID, in: db
                )
                try GRDBSourceContextRepository.insert(
                    resolvedContext, in: db
                )
                // S06：既有 Note 可能尚无 unit 链接（旧数据/并发窗口）
                // ——同事务兜底绑定；selection 带验证过的词典义项时
                // 直接绑 dictionarySense unit。
                let noteRow = try Row.fetchOne(
                    db,
                    sql: "SELECT headword, reading FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(existingNoteID)]
                )
                try LearningUnitWriteBridge.ensureUnit(
                    noteID: existingNoteID,
                    headword: noteRow?["headword"] ?? "",
                    reading: noteRow?["reading"],
                    binding: plan.dictionaryBinding,
                    linkOrigin: .userConfirmed,
                    atMilliseconds: atMs,
                    in: db
                )
                noteID = existingNoteID
                cardCount = 0
                wasExistingNote = true
            }

            let lexeme = try Self.upsertLexeme(plan.lexemeSeed, in: db)
            try db.execute(
                sql: """
                    INSERT INTO lexeme_note_links(
                        lexeme_id, note_id, association_origin,
                        confidence, created_at_ms
                    ) VALUES (?, ?, ?, NULL, ?)
                    ON CONFLICT(lexeme_id, note_id) DO UPDATE SET
                        association_origin = excluded.association_origin
                    """,
                arguments: [
                    DatabaseValueCodec.encode(lexeme.id),
                    DatabaseValueCodec.encode(noteID),
                    plan.linkOrigin.rawValue,
                    DatabaseValueCodec.encode(plan.committedAt)
                ]
            )
            try GRDBReaderActivityStore.insertEvent(
                ReaderActivityEvent(
                    id: UUID(),
                    operationID: plan.operationID,
                    kind: plan.eventKind,
                    lexemeID: lexeme.id,
                    noteID: noteID,
                    documentID: plan.documentID,
                    snapshotJSON: plan.eventSnapshotJSON,
                    createdAt: plan.committedAt,
                    undoneAt: nil
                ),
                in: db
            )

            let outcome = ReaderMiningOutcome(
                noteID: noteID,
                lexemeID: lexeme.id,
                cardCount: cardCount,
                wasExistingNote: wasExistingNote,
                wasReplayed: false
            )
            // 6) receipt：回放可解码的最小结果集。
            try GRDBReaderActivityStore.recordReceipt(
                operationID: plan.operationID,
                kind: wasExistingNote
                    ? "link_existing_note" : "mine_vocabulary",
                payloadHash: payloadHash,
                resultJSON: GRDBVocabularyKnowledgeRepository.jsonObject([
                    "note_id": noteID.uuidString.lowercased(),
                    "lexeme_id": lexeme.id.uuidString.lowercased(),
                    "card_count": cardCount,
                    "was_existing_note": wasExistingNote,
                ]),
                at: plan.committedAt,
                in: db
            )
            return outcome
        }
    }

    /// S13 Reader→Cloze：sentence Note + `sentence_cloze` 卡 +
    /// `cloze_definitions` + Reader 定位来源的原子写，顺序与
    /// `commit` 同构——世代屏障 → receipt 回放 → executor 写内容 →
    /// `createdCloze` 事件 → `create_cloze` receipt。
    /// 与挖词的差异：无 lexeme upsert/关联（句卡不进词汇知识网），
    /// 无 sourceRef 去重——同一句挖两次就是两张卡（多 blank 由
    /// 多个 sentence Note 表达，§9.1）。
    public func commitCloze(
        _ plan: ReaderClozeMiningWritePlan,
        currentGeneration: @Sendable () -> Int
    ) async throws -> ReaderClozeMiningOutcome {
        try await pool.write { db in
            // 1) 世代屏障：恢复后旧代请求整事务拒写。
            let generation = currentGeneration()
            guard generation == plan.expectedGeneration else {
                throw ReaderMiningError.staleGeneration(
                    expected: plan.expectedGeneration, current: generation
                )
            }

            let payloadHash = GRDBReaderActivityStore.payloadHash(
                plan.canonicalPayload
            )
            // 2) receipt 回放：同 opID 重试返回既有结果，不复制卡。
            if let receipt = try GRDBReaderActivityStore.fetchReceipt(
                operationID: plan.operationID, in: db
            ) {
                guard receipt.payloadHash == payloadHash else {
                    throw ReaderMiningError.operationPayloadConflict(
                        plan.operationID
                    )
                }
                guard let outcome = Self.decodeClozeOutcome(
                    receipt.resultJSON, operationID: plan.operationID
                ) else {
                    throw ReaderMiningError.receiptCorrupt(
                        plan.operationID
                    )
                }
                return outcome
            }

            // 3) 内容写入：Note/Card/membership/来源/definition 在
            //    executor 内同事务；任一步失败（牌组缺失、来源
            //    noteID 不符、cloze 复核不过）整事务回滚。
            let result = try GRDBContentWriteExecutor.execute(
                .sentence(plan.commit), capture: nil, in: db
            )

            // 4) 活动事件（document_id 是弱引用——原文删除后
            //    SET NULL，事件仍成立）。
            try GRDBReaderActivityStore.insertEvent(
                ReaderActivityEvent(
                    id: UUID(),
                    operationID: plan.operationID,
                    kind: .createdCloze,
                    lexemeID: nil,
                    noteID: result.noteID,
                    documentID: plan.documentID,
                    snapshotJSON: plan.eventSnapshotJSON,
                    createdAt: plan.committedAt,
                    undoneAt: nil
                ),
                in: db
            )

            let outcome = ReaderClozeMiningOutcome(
                noteID: result.noteID,
                cardCount: result.cardCount,
                wasReplayed: false
            )
            // 5) receipt：回放可解码的最小结果集。
            try GRDBReaderActivityStore.recordReceipt(
                operationID: plan.operationID,
                kind: "create_cloze",
                payloadHash: payloadHash,
                resultJSON: GRDBVocabularyKnowledgeRepository.jsonObject([
                    "note_id": result.noteID.uuidString.lowercased(),
                    "card_count": result.cardCount,
                ]),
                at: plan.committedAt,
                in: db
            )
            return outcome
        }
    }

    // MARK: - 内部

    /// receipt result_json → outcome（回放置 `wasReplayed`）。
    private static func decodeOutcome(
        _ resultJSON: String, operationID: UUID
    ) -> ReaderMiningOutcome? {
        guard let data = resultJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let noteIDString = dict["note_id"] as? String,
              let noteID = UUID(uuidString: noteIDString),
              let lexemeIDString = dict["lexeme_id"] as? String,
              let lexemeID = UUID(uuidString: lexemeIDString),
              let cardCount = dict["card_count"] as? Int,
              let wasExistingNote = dict["was_existing_note"] as? Bool
        else { return nil }
        return ReaderMiningOutcome(
            noteID: noteID,
            lexemeID: lexemeID,
            cardCount: cardCount,
            wasExistingNote: wasExistingNote,
            wasReplayed: true
        )
    }

    /// `create_cloze` receipt 的 result_json → outcome
    /// （回放置 `wasReplayed`）。
    private static func decodeClozeOutcome(
        _ resultJSON: String, operationID: UUID
    ) -> ReaderClozeMiningOutcome? {
        guard let data = resultJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let noteIDString = dict["note_id"] as? String,
              let noteID = UUID(uuidString: noteIDString),
              let cardCount = dict["card_count"] as? Int
        else { return nil }
        return ReaderClozeMiningOutcome(
            noteID: noteID,
            cardCount: cardCount,
            wasReplayed: true
        )
    }

    /// linkExisting 的 Note 前置校验：存在且 kind = 'vocabulary'
    /// （真值表只把 vocabulary 关联计入 learning——grammar/sentence
    /// Note 的关联存在但不驱动知识态，本路径不接受它们）。
    private static func vocabularyNoteExists(
        _ noteID: UUID, in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM notes
                    WHERE id = ? AND kind = 'vocabulary')
                """,
            arguments: [DatabaseValueCodec.encode(noteID)]
        ) ?? false
    }

    /// 同事务 primary 裁决：目标 Note 已有 primary 来源时，本行降级。
    private static func resolvePrimary(
        _ context: SourceContext,
        noteID: UUID,
        in db: Database
    ) throws -> SourceContext {
        guard context.isPrimary else { return context }
        let hasPrimary = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM source_contexts
                    WHERE note_id = ? AND is_primary = 1)
                """,
            arguments: [DatabaseValueCodec.encode(noteID)]
        ) ?? false
        guard hasPrimary else { return context }
        return SourceContext(
            id: context.id,
            noteID: context.noteID,
            sourceType: context.sourceType,
            originalSentence: context.originalSentence,
            surroundingText: context.surroundingText,
            sourceTitle: context.sourceTitle,
            sourceURL: context.sourceURL,
            sourceApp: context.sourceApp,
            imageReference: context.imageReference,
            dictionaryEntryID: context.dictionaryEntryID,
            dictionaryVersion: context.dictionaryVersion,
            dictionarySenseKey: context.dictionarySenseKey,
            selectedGlossLanguage: context.selectedGlossLanguage,
            isPrimary: false,
            createdAt: context.createdAt,
            readerDocumentID: context.readerDocumentID,
            readerChapterID: context.readerChapterID,
            readerLocation: context.readerLocation,
            selectedSurface: context.selectedSurface
        )
    }

    /// identity_key upsert：命中返回既有行（不重建 UUID），否则按
    /// seed 插入——与 `GRDBVocabularyKnowledgeRepository.resolveLexeme`
    /// 同事务内联版（async 仓储方法不能嵌套进 `pool.write`）。
    private static func upsertLexeme(
        _ seed: Lexeme, in db: Database
    ) throws -> Lexeme {
        let identityKey = seed.key.identityKey
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, provider, external_id, entry_id,
                       written_form, reading, normalized_lemma,
                       pos_family, identity_key,
                       dictionary_version_at_resolution,
                       resolution_status, created_at_ms
                FROM lexemes WHERE identity_key = ?
                """,
            arguments: [identityKey]
        ) {
            return try decodeLexeme(row)
        }
        do {
            try db.execute(
                sql: """
                    INSERT INTO lexemes(
                        id, provider, external_id, entry_id,
                        written_form, reading, normalized_lemma,
                        pos_family, identity_key,
                        dictionary_version_at_resolution,
                        resolution_status, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(seed.id),
                    seed.key.provider.rawValue,
                    seed.key.externalID,
                    seed.key.provider == .jmdict
                        ? Int64(seed.key.externalID) : nil,
                    seed.writtenForm,
                    seed.reading,
                    seed.normalizedLemma,
                    seed.posFamily,
                    identityKey,
                    seed.dictionaryVersionAtResolution,
                    seed.resolutionStatus.rawValue,
                    DatabaseValueCodec.encode(seed.createdAt)
                ]
            )
            return seed
        } catch {
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT id FROM lexemes WHERE identity_key = ?",
                arguments: [identityKey]
            ), let id = try? DatabaseValueCodec.decodeUUID(row["id"]) {
                return Lexeme(
                    id: id,
                    key: seed.key,
                    writtenForm: seed.writtenForm,
                    reading: seed.reading,
                    normalizedLemma: seed.normalizedLemma,
                    posFamily: seed.posFamily,
                    dictionaryVersionAtResolution:
                        seed.dictionaryVersionAtResolution,
                    resolutionStatus: seed.resolutionStatus,
                    createdAt: seed.createdAt
                )
            }
            throw error
        }
    }

    private static func decodeLexeme(_ row: Row) throws -> Lexeme {
        let providerRaw: String = row["provider"]
        guard let provider = LexicalKey.Provider(rawValue: providerRaw) else {
            throw VocabularyKnowledgeError.inconsistentStorage(
                "lexemes.provider=\(providerRaw)"
            )
        }
        let statusRaw: String = row["resolution_status"]
        guard let status = TokenResolutionStatus(rawValue: statusRaw) else {
            throw VocabularyKnowledgeError.inconsistentStorage(
                "lexemes.resolution_status=\(statusRaw)"
            )
        }
        return Lexeme(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            key: LexicalKey(
                provider: provider,
                externalID: row["external_id"],
                identityKey: row["identity_key"]
            ),
            writtenForm: row["written_form"],
            reading: row["reading"],
            normalizedLemma: row["normalized_lemma"],
            posFamily: row["pos_family"],
            dictionaryVersionAtResolution:
                row["dictionary_version_at_resolution"],
            resolutionStatus: status,
            createdAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["created_at_ms"]
            )
        )
    }
}

private extension Array {
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
