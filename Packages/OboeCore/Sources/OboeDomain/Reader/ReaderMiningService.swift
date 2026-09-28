import Foundation

/// S11 挖词事务写计划：服务层装配完毕、可直接落库的全部输入。
/// `ReaderMiningStore` 在一次 `pool.write` 内执行——不在 async 服务内
/// 嵌套数据库事务（S03 边界）。
public struct ReaderMiningWritePlan: Sendable {
    /// 写动作：新建 Note 走 `GRDBContentWriteExecutor`（Note/Card/
    /// membership/来源同事务）；既有 Note 只追加 membership + 来源。
    public enum Action: Sendable {
        /// `commit` 已含装配好的 `sourceContext`（Reader 定位+词典快照）。
        case createNote(VocabularyContentCommit)
        /// 命中既有 Note：`membershipDeckIDs` 是**追加**集合（含 home），
        /// 不删除既有成员；`sourceContext` 的 isPrimary 由 store 在事务内
        /// 按既有来源裁决（已有 primary 时降级）。
        case linkExisting(
            noteID: UUID,
            membershipDeckIDs: Set<UUID>,
            sourceContext: SourceContext
        )
    }

    public let operationID: UUID
    /// `reader_mining_receipts.payload_hash` 的规范负载（store 内 hash）。
    public let canonicalPayload: String
    public let action: Action
    /// lexeme upsert 种子（已存在则返回既有行，不重建 UUID）。
    public let lexemeSeed: Lexeme
    public let linkOrigin: LexemeNoteLink.AssociationOrigin
    public let eventKind: ReaderActivityKind
    /// `reader_activity_events.document_id`（FK 弱引用目标）。
    public let documentID: UUID
    /// 事件快照 JSON（表记/文档标题/来源句——限额内）。
    public let eventSnapshotJSON: String
    /// 请求发起时的数据库世代——写事务内复核。
    public let expectedGeneration: Int
    public let committedAt: Date

    public init(
        operationID: UUID,
        canonicalPayload: String,
        action: Action,
        lexemeSeed: Lexeme,
        linkOrigin: LexemeNoteLink.AssociationOrigin,
        eventKind: ReaderActivityKind,
        documentID: UUID,
        eventSnapshotJSON: String,
        expectedGeneration: Int,
        committedAt: Date
    ) {
        self.operationID = operationID
        self.canonicalPayload = canonicalPayload
        self.action = action
        self.lexemeSeed = lexemeSeed
        self.linkOrigin = linkOrigin
        self.eventKind = eventKind
        self.documentID = documentID
        self.eventSnapshotJSON = eventSnapshotJSON
        self.expectedGeneration = expectedGeneration
        self.committedAt = committedAt
    }
}

/// S13 Reader→Cloze 创建写计划：`commit` 是完整装配好的
/// `SentenceContentCommit`（含 Reader 定位来源）——store 在一次
/// `pool.write` 内完成世代复核 → receipt 回放 →
/// `GRDBContentWriteExecutor.execute(.sentence:)` → `createdCloze`
/// 事件 → `create_cloze` receipt。cloze 不建 lexeme 关联：句卡与
/// 词汇知识网络正交，create_cloze 事件也只挂 note/document 弱引用。
public struct ReaderClozeMiningWritePlan: Sendable {
    public let operationID: UUID
    /// `reader_mining_receipts.payload_hash` 的规范负载（store 内 hash）。
    public let canonicalPayload: String
    public let commit: SentenceContentCommit
    /// `reader_activity_events.document_id`（弱引用目标）。
    public let documentID: UUID
    /// 事件快照 JSON（表记/文档标题/来源句——限额内）。
    public let eventSnapshotJSON: String
    /// 请求发起时的数据库世代——写事务内复核。
    public let expectedGeneration: Int
    public let committedAt: Date

    public init(
        operationID: UUID,
        canonicalPayload: String,
        commit: SentenceContentCommit,
        documentID: UUID,
        eventSnapshotJSON: String,
        expectedGeneration: Int,
        committedAt: Date
    ) {
        self.operationID = operationID
        self.canonicalPayload = canonicalPayload
        self.commit = commit
        self.documentID = documentID
        self.eventSnapshotJSON = eventSnapshotJSON
        self.expectedGeneration = expectedGeneration
        self.committedAt = committedAt
    }
}

/// 挖词持久化边界（GRDB 实现）。
public protocol ReaderMiningStore: Sendable {
    /// 按 id 批量取词汇 Note 摘要（已关联 Note 列表）。
    func noteSummaries(ids: [UUID]) async throws -> [ReaderLinkedNote]
    /// 内容重名探测：vocabulary Note 中 headword 相等且
    /// （两侧 reading 同值或候选 reading 为空）的既有 Note。
    func findDuplicateVocabularyNotes(
        headword: String,
        reading: String?
    ) async throws -> [ReaderLinkedNote]
    /// 单次挖词的原子写：`currentGeneration()` 在事务内复核
    /// `plan.expectedGeneration`（不等即 `staleGeneration`）；
    /// receipt 命中即解码回放；其余路径见各 action 注释。
    func commit(
        _ plan: ReaderMiningWritePlan,
        currentGeneration: @Sendable () -> Int
    ) async throws -> ReaderMiningOutcome
    /// S13：Reader→Cloze 创建的原子写——与 `commit` 同一世代屏障
    /// 与 receipt 幂等语义；无 lexeme 关联/无 sourceRef 去重。
    func commitCloze(
        _ plan: ReaderClozeMiningWritePlan,
        currentGeneration: @Sendable () -> Int
    ) async throws -> ReaderClozeMiningOutcome
}

/// S11 Reader 挖词服务：lookup 编排 + 请求装配 + 世代屏障 + 批量调度。
///
/// - `lookup`：token 候选（morphology 给出 entryID 序）→ 词典详情 →
///   每候选 `LexicalIdentityKey` + lexeme 解析 + 知识态 + 已关联 Note；
///   无词典候选时给 OOV local 候选。全部读路径批量，无逐 token SQL。
/// - `mine`：`selection` 必须显式给出（nil → `selectionRequired`）；
///   世代不符 → `staleGeneration`；其余装配成 `ReaderMiningWritePlan`
///   交给 store 原子提交。
/// - `mineBatch`：逐项独立提交（已提交保留、取消项丢弃），未勾选项
///   只计入 skipped 不写任何行。
public struct ReaderMiningService: Sendable {
    private let dictionary: any DictionaryRepository
    private let deinflector: (any Deinflecting)?
    private let knowledge: any VocabularyKnowledgeRepository
    private let linking: (any VocabularyKnowledgeLinking)?
    private let store: any ReaderMiningStore
    /// 当前数据库世代（恢复/迁移后递增）；写路径在事务内复核。
    private let currentGeneration: @Sendable () -> Int
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let sourceContextService = SourceContextService()

    /// 句截取的字符预算（Inspector 从块文本截句的上限）。
    public static let sentenceCharacterLimit = 300

    public init(
        dictionary: any DictionaryRepository,
        deinflector: (any Deinflecting)? = nil,
        knowledge: any VocabularyKnowledgeRepository,
        linking: (any VocabularyKnowledgeLinking)? = nil,
        store: any ReaderMiningStore,
        currentGeneration: @escaping @Sendable () -> Int = { 0 },
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.dictionary = dictionary
        self.deinflector = deinflector
        self.knowledge = knowledge
        self.linking = linking
        self.store = store
        self.currentGeneration = currentGeneration
        self.now = now
        self.makeID = makeID
    }

    // MARK: - lookup

    /// Inspector 数据源：优先按 morphology 候选的 entryID 序取详情；
    /// 无候选/全部 OOV 时回退表面搜索（exact/deinflect/prefix 三段）。
    /// 末尾始终可追加 local 候选（OOV 自建词身份由调用方决定展示）。
    public func lookup(
        surface: String,
        reading: String? = nil,
        morphologyCandidates: [MorphologyCandidate] = [],
        tokenWasAmbiguous: Bool = false
    ) async throws -> ReaderMiningLookup {
        var orderedEntryIDs: [Int64] = []
        var seen = Set<Int64>()
        for candidate in morphologyCandidates {
            if let id = candidate.entryID, seen.insert(id).inserted {
                orderedEntryIDs.append(id)
            }
        }
        var entries = orderedEntryIDs.isEmpty
            ? []
            : try await dictionary.entries(ids: orderedEntryIDs)
        var candidateReasons: [Int64: [String]] = [:]
        for candidate in morphologyCandidates {
            if let id = candidate.entryID {
                candidateReasons[id, default: []] += candidate.reasons
            }
        }
        var datasetVersion: String? = nil
        if entries.isEmpty {
            // 回退：表面搜索（变形链去截断标记后下传）。
            var deinflections: [DeinflectionCandidate] = []
            if let deinflector {
                deinflections = deinflector.candidates(for: surface)
                    .filter { !$0.isTruncationMarker }
            }
            let page = try await dictionary.search(
                DictionarySearchRequest(
                    query: surface, candidates: deinflections, limit: 20)
            )
            datasetVersion = page.nextCursor?.datasetVersion
            var searchSeen = Set<Int64>()
            let ids = page.items.map(\.entryID)
                .filter { searchSeen.insert($0).inserted }
            entries = try await dictionary.entries(ids: ids)
        }

        var candidates: [ReaderMiningCandidate] = []
        var keys: [LexicalKey] = []
        for entry in entries {
            let preferredReading = entry.readings.first?.reading
            let key = LexicalIdentityKey.jmdict(
                entryID: entry.id,
                normalizedForm: SearchTextNormalizer.normalize(entry.primaryForm),
                reading: preferredReading
            )
            let senses = entry.senses.map { sense in
                let preferred = sense.preferredGlosses()
                return ReaderMiningSense(
                    id: sense.id,
                    posCodes: sense.posCodes,
                    glossText: preferred?.glosses.map(\.text)
                        .joined(separator: "；") ?? "",
                    glossLanguage: preferred?.language,
                    senseKey: "\(entry.id):\(sense.id)"
                )
            }
            candidates.append(
                ReaderMiningCandidate(
                    lexicalKey: key,
                    lexemeID: nil,  // 下方批量回填
                    knowledgeState: .unknown,
                    writtenForm: entry.primaryForm,
                    reading: preferredReading,
                    posCodes: Array(entry.partOfSpeechCodes).sorted(),
                    entryID: entry.id,
                    senses: senses,
                    linkedNotes: [],
                    reasons: candidateReasons[entry.id] ?? [],
                    dictionaryVersion: datasetVersion
                )
            )
            keys.append(key)
        }

        // 批量解析 lexeme + 状态 + 已关联 Note（无逐候选 SQL）。
        let lexemes = try await knowledge.resolveLexemes(keys: keys)
        var statesByLexeme: [UUID: VocabularyKnowledgeState] = [:]
        var notesByLexeme: [LexicalKey: [ReaderLinkedNote]] = [:]
        for (key, lexeme) in lexemes {
            statesByLexeme[lexeme.id] = try await knowledge.state(
                lexemeID: lexeme.id
            )
            if let linking {
                let noteIDs = try await linking.linkedNoteIDs(
                    lexemeID: lexeme.id
                )
                notesByLexeme[key] = try await store.noteSummaries(
                    ids: noteIDs
                )
            }
        }
        candidates = candidates.map { candidate in
            guard let lexeme = lexemes[candidate.lexicalKey] else {
                return candidate
            }
            return ReaderMiningCandidate(
                lexicalKey: candidate.lexicalKey,
                lexemeID: lexeme.id,
                knowledgeState: statesByLexeme[lexeme.id] ?? .unknown,
                writtenForm: candidate.writtenForm,
                reading: candidate.reading,
                posCodes: candidate.posCodes,
                entryID: candidate.entryID,
                senses: candidate.senses,
                linkedNotes: notesByLexeme[candidate.lexicalKey] ?? [],
                reasons: candidate.reasons,
                dictionaryVersion: candidate.dictionaryVersion
            )
        }

        // 重名 Note 探测（headword 精确 + reading 匹配）——
        // 「已有 Note 只加来源」入口。
        var duplicateNotes = try await store.findDuplicateVocabularyNotes(
            headword: surface, reading: reading
        )
        for candidate in candidates {
            let extra = try await store.findDuplicateVocabularyNotes(
                headword: candidate.writtenForm, reading: candidate.reading
            )
            for note in extra where !duplicateNotes.contains(note) {
                duplicateNotes.append(note)
            }
        }

        // OOV：无词典候选时补一个 local 候选供自建词挖词。
        if candidates.isEmpty {
            let key = LexicalIdentityKey.local(
                writtenForm: surface, reading: reading, posFamily: nil
            )
            let lexeme = try await knowledge.fetchLexeme(key: key)
            var state: VocabularyKnowledgeState = .unknown
            var linked: [ReaderLinkedNote] = []
            if let lexeme {
                state = try await knowledge.state(lexemeID: lexeme.id)
                if let linking {
                    let noteIDs = try await linking.linkedNoteIDs(
                        lexemeID: lexeme.id
                    )
                    linked = try await store.noteSummaries(ids: noteIDs)
                }
            }
            candidates.append(
                ReaderMiningCandidate(
                    lexicalKey: key,
                    lexemeID: lexeme?.id,
                    knowledgeState: state,
                    writtenForm: surface,
                    reading: reading,
                    posCodes: [],
                    entryID: nil,
                    senses: [],
                    linkedNotes: linked,
                    reasons: ["outOfVocabulary"]
                )
            )
        }

        return ReaderMiningLookup(
            surface: surface,
            reading: reading,
            candidates: candidates,
            duplicateNotes: duplicateNotes,
            requiresSelection: tokenWasAmbiguous || candidates.count > 1
        )
    }

    /// UI 世代闸：`expected`（容器发布快照）是否仍是活世代——
    /// 恢复后旧 VM 用它拒收自己发出的结果（不写回、不更新 UI）。
    public func isExpectedGenerationAlive(_ expected: Int) -> Bool {
        currentGeneration() == expected
    }

    // MARK: - mine

    /// 单次挖词：显式选择 + 世代校验 + 装配写计划 → store 原子提交。
    @discardableResult
    public func mine(
        _ request: ReaderMiningRequest
    ) async throws -> ReaderMiningOutcome {
        guard let selection = request.selection else {
            throw ReaderMiningError.selectionRequired
        }
        let current = currentGeneration()
        guard current == request.expectedGeneration else {
            throw ReaderMiningError.staleGeneration(
                expected: request.expectedGeneration, current: current
            )
        }
        let plan = try makePlan(request: request, selection: selection)
        return try await store.commit(
            plan, currentGeneration: currentGeneration
        )
    }

    /// 批量挖词：逐项独立提交——任一取消点前的已提交项保留、
    /// 剩余项丢弃；行级失败记入 failures 后继续。`isCancelled`
    /// 默认 `Task.isCancelled`；每项开始前检查。
    public func mineBatch(
        _ items: [ReaderMiningBatchItem],
        isCancelled: (@Sendable () -> Bool)? = nil,
        progress: (@Sendable (ReaderMiningBatchSummary) -> Void)? = nil
    ) async -> ReaderMiningBatchSummary {
        var summary = ReaderMiningBatchSummary()
        summary.totalCount = items.count
        let cancelled = isCancelled ?? { Task.isCancelled }
        for (index, item) in items.enumerated() {
            if cancelled() {
                summary.cancelledCount = items.count - index
                break
            }
            guard item.isSelected else {
                summary.skippedCount += 1
                continue
            }
            do {
                let outcome = try await mine(item.request)
                if outcome.wasReplayed {
                    summary.replayedCount += 1
                } else {
                    summary.committedCount += 1
                }
            } catch ReaderMiningError.selectionRequired {
                summary.requiresSelectionCount += 1
            } catch {
                summary.failures.append(
                    ReaderMiningBatchFailure(
                        operationID: item.request.operationID,
                        label: item.label,
                        errorDescription: String(describing: error)
                    )
                )
            }
            progress?(summary)
        }
        return summary
    }

    // MARK: - mineCloze（S13 Reader→Cloze）

    /// Reader 选段/点词 → sentence Note + `sentence_cloze` 卡的原子
    /// 创建。与 `mine` 同一世代屏障与 receipt 幂等；差异：
    /// - 内容侧是 `ValidatedClozeContent`（表单已验证——本层不再
    ///   重验 range/surface，executor 事务内仍复核持久化一致性）；
    /// - 不建 lexeme 关联、无义项选择概念（单 blank 句卡）；
    /// - `origin = .reader`、`sourceText` = 截取句快照（不落整篇
    ///   正文，§11.2）；来源记录走同一 `reader_*` 定位字段。
    @discardableResult
    public func mineCloze(
        _ request: ReaderClozeMiningRequest
    ) async throws -> ReaderClozeMiningOutcome {
        let current = currentGeneration()
        guard current == request.expectedGeneration else {
            throw ReaderMiningError.staleGeneration(
                expected: request.expectedGeneration, current: current
            )
        }
        let createdAt = now()
        let noteID = makeID()
        // 新 Note 的首条来源恒为 primary（resolvePrimary 只对追加
        // 路径有意义——这里 Note 尚不存在，无并发裁决必要）。
        let sourceContext = sourceContextService.makeContext(
            from: SourceContextDraft(
                sourceType: .reader,
                originalSentence: request.context.sentence,
                surroundingText: request.context.surroundingText,
                sourceTitle: request.context.sourceTitle,
                readerDocumentID: request.context.documentID,
                readerChapterID: request.context.chapterID,
                readerLocation: request.context.location,
                selectedSurface: request.context.selectedSurface,
                isPrimary: true
            ),
            noteID: noteID,
            now: createdAt,
            makeID: makeID
        )
        let commit = SentenceContentCommit(
            noteID: noteID,
            clozeID: makeID(),
            deckID: request.deckID,
            cloze: request.cloze,
            card: NewCardSeed(id: makeID(), templateKind: .sentenceCloze),
            schedulerProfileID: makeID(),
            createdAt: createdAt,
            meaningZH: request.meaningZH,
            notes: request.notes,
            tags: request.tags,
            origin: .reader,
            sourceText: request.context.sentence,
            deckIDs: Set([request.deckID]).union(request.additionalDeckIDs),
            sourceContext: sourceContext
        )
        let plan = ReaderClozeMiningWritePlan(
            operationID: request.operationID,
            canonicalPayload: canonicalClozePayload(request),
            commit: commit,
            documentID: request.context.documentID,
            eventSnapshotJSON: Self.eventSnapshot(
                writtenForm: request.cloze.targetSurface,
                documentTitle: request.context.sourceTitle,
                sentence: request.cloze.sentenceSnapshot
            ),
            expectedGeneration: request.expectedGeneration,
            committedAt: createdAt
        )
        return try await store.commitCloze(
            plan, currentGeneration: currentGeneration
        )
    }

    // MARK: - 装配

    private func makePlan(
        request: ReaderMiningRequest,
        selection: ReaderMiningSelection
    ) throws -> ReaderMiningWritePlan {
        let createdAt = now()
        let documentID = request.context.documentID
        let eventSnapshotJSON = Self.eventSnapshot(
            writtenForm: selection.writtenForm,
            documentTitle: request.context.sourceTitle,
            sentence: request.context.sentence
        )
        let payload = canonicalPayload(request: request, selection: selection)
        let lexemeSeed = Lexeme(
            id: makeID(),
            key: selection.lexicalKey,
            writtenForm: selection.writtenForm,
            reading: selection.reading,
            normalizedLemma: selection.normalizedLemma,
            posFamily: selection.posFamily,
            dictionaryVersionAtResolution: selection.dictionaryVersion,
            resolutionStatus: .resolved,
            createdAt: createdAt
        )

        let action: ReaderMiningWritePlan.Action
        let eventKind: ReaderActivityKind
        if let existingNoteID = request.existingNoteID {
            eventKind = .linkedExistingNote
            let sourceContext = sourceContextService.makeContext(
                from: sourceContextDraft(
                    request: request, selection: selection, isPrimary: true
                ),
                noteID: existingNoteID,
                now: createdAt,
                makeID: makeID
            )
            action = .linkExisting(
                noteID: existingNoteID,
                membershipDeckIDs: Set([request.deckID])
                    .union(request.additionalDeckIDs),
                sourceContext: sourceContext
            )
        } else {
            eventKind = .minedNewNote
            let noteID = makeID()
            let form = resolvedFormData(
                request: request, selection: selection
            )
            let requestFields = try NewVocabularyCommitRequest(
                noteID: noteID,
                deckID: request.deckID,
                formData: form,
                directions: request.cardDirections
            )
            let sourceContext = sourceContextService.makeContext(
                from: sourceContextDraft(
                    request: request, selection: selection, isPrimary: true
                ),
                noteID: noteID,
                now: createdAt,
                makeID: makeID
            )
            action = .createNote(
                VocabularyContentCommit(
                    noteID: noteID,
                    exampleID: makeID(),
                    draftID: nil,
                    deckID: request.deckID,
                    content: requestFields.content,
                    tags: [],
                    cards: request.cardDirections
                        .map(\.templateKind)
                        .sorted { $0.rawValue < $1.rawValue }
                        .map { NewCardSeed(id: makeID(), templateKind: $0) },
                    schedulerProfileID: makeID(),
                    createdAt: createdAt,
                    origin: .reader,
                    deckIDs: Set([request.deckID])
                        .union(request.additionalDeckIDs),
                    sourceContext: sourceContext
                )
            )
        }
        return ReaderMiningWritePlan(
            operationID: request.operationID,
            canonicalPayload: payload,
            action: action,
            lexemeSeed: lexemeSeed,
            linkOrigin: .userConfirmed,
            eventKind: eventKind,
            documentID: documentID,
            eventSnapshotJSON: eventSnapshotJSON,
            expectedGeneration: request.expectedGeneration,
            committedAt: createdAt
        )
    }

    /// 预填默认值 + 用户修订的合并（新建路径）。
    private func resolvedFormData(
        request: ReaderMiningRequest,
        selection: ReaderMiningSelection
    ) -> VocabularyFormData {
        let overrides = request.fieldOverrides
        return VocabularyFormData(
            headword: overrides?.headword ?? selection.writtenForm,
            reading: overrides?.reading ?? selection.reading ?? "",
            meaningZH: overrides?.meaningZH ?? selection.meaningZH,
            partOfSpeech: overrides?.partOfSpeech ?? selection.posFamily ?? "",
            exampleJapanese: overrides?.exampleJapanese
                ?? request.context.sentence,
            exampleTranslationZH: overrides?.exampleTranslationZH ?? "",
            notes: overrides?.notes ?? ""
        )
    }

    /// 来源草稿：reader 定位 + 词典快照（义项/语言/entry/dataset）；
    /// `originalSentence` 用截取的挖词句，`surroundingText` 受界。
    private func sourceContextDraft(
        request: ReaderMiningRequest,
        selection: ReaderMiningSelection,
        isPrimary: Bool
    ) -> SourceContextDraft {
        SourceContextDraft(
            sourceType: .reader,
            originalSentence: request.context.sentence,
            surroundingText: request.context.surroundingText,
            sourceTitle: request.context.sourceTitle,
            dictionaryEntryID: selection.entryID,
            dictionaryVersion: selection.dictionaryVersion,
            dictionarySenseKey: selection.senseKey,
            selectedGlossLanguage: selection.selectedGlossLanguage,
            readerDocumentID: request.context.documentID,
            readerChapterID: request.context.chapterID,
            readerLocation: request.context.location,
            selectedSurface: request.context.selectedSurface,
            isPrimary: isPrimary
        )
    }

    /// receipt payload 的规范串：字段定序拼接——同一逻辑内容必同串。
    /// operationID 不进负载（它是 receipt 键）；时间/内部 UUID 也不进。
    private func canonicalPayload(
        request: ReaderMiningRequest,
        selection: ReaderMiningSelection
    ) -> String {
        let loc = request.context.location
        var parts: [String] = [
            "v11_mining",
            selection.lexicalKey.identityKey,
            selection.senseKey ?? "-",
            selection.meaningZH,
            selection.selectedGlossLanguage ?? "-",
            request.existingNoteID?.uuidString.lowercased() ?? "-",
            request.deckID.uuidString.lowercased(),
            request.additionalDeckIDs
                .map { $0.uuidString.lowercased() }
                .sorted().joined(separator: ","),
            request.context.documentID.uuidString.lowercased(),
            request.context.chapterID.uuidString.lowercased(),
            "\(loc.chapterOrdinal)", "\(loc.blockOrdinal)",
            "\(loc.utf16Offset)", loc.blockTextHash,
            request.context.selectedSurface,
            request.cardDirections
                .map(\.rawValue).sorted().joined(separator: ","),
        ]
        if let overrides = request.fieldOverrides {
            parts.append(contentsOf: [
                overrides.headword ?? "-", overrides.reading ?? "-",
                overrides.meaningZH ?? "-", overrides.partOfSpeech ?? "-",
                overrides.exampleJapanese ?? "-",
                overrides.exampleTranslationZH ?? "-",
                overrides.notes ?? "-",
            ])
        }
        return parts.joined(separator: "|")
    }

    /// cloze receipt 的规范负载：字段定序拼接——同一逻辑内容必同串。
    /// operationID/时间/生成 UUID 不进负载；句快照以 sha256 参与
    /// （content 已自证一致），文档/章/块定位与挖词同口径。
    private func canonicalClozePayload(
        _ request: ReaderClozeMiningRequest
    ) -> String {
        let loc = request.context.location
        let cloze = request.cloze
        return [
            "v13_cloze",
            request.deckID.uuidString.lowercased(),
            request.additionalDeckIDs
                .map { $0.uuidString.lowercased() }
                .sorted().joined(separator: ","),
            cloze.sentenceSHA256,
            "\(cloze.range.utf16Start)", "\(cloze.range.utf16Length)",
            cloze.targetSurface,
            cloze.targetLemma ?? "-",
            cloze.targetReading ?? "-",
            cloze.acceptedAnswers.joined(separator: "\u{1F}"),
            cloze.hint ?? "-",
            request.meaningZH ?? "-",
            request.context.documentID.uuidString.lowercased(),
            request.context.chapterID.uuidString.lowercased(),
            "\(loc.chapterOrdinal)", "\(loc.blockOrdinal)",
            "\(loc.utf16Offset)", loc.blockTextHash,
            request.context.selectedSurface,
        ].joined(separator: "|")
    }

    private static func eventSnapshot(
        writtenForm: String,
        documentTitle: String?,
        sentence: String
    ) -> String {
        var pairs: [String: String] = ["written_form": writtenForm]
        if let documentTitle { pairs["document_title"] = documentTitle }
        if !sentence.isEmpty {
            pairs["sentence"] = String(sentence.prefix(
                ReaderMiningService.sentenceCharacterLimit
            ))
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: pairs, options: [.sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
