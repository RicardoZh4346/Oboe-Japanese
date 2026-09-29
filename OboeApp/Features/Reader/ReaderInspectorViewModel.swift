import Foundation
import OboeDomain
import OboeInfrastructure
import Observation

/// S11 Reader Inspector 视图模型：token 点击 → lookup →
/// 候选/义项显式选择 → 挖词（直接提交或预填编辑器）/ 知识状态操作。
///
/// 不变量：
/// - `mine()` 构造的 `ReaderMiningRequest.expectedGeneration` 取容器
///   发布世代快照；写事务内再由 store 对活世代源复核——恢复窗口内
///   旧请求一律 `staleGeneration`，不写回也不更新 UI（本 VM 的
///   `guardGenerationAlive` 在结果应用前再查一次）。
/// - ambiguous 候选不自动关联：`ReaderMiningRequest.selection` 恒由
///   用户点击产生；本 VM 从不代选。
/// - 每次 Inspector 会话一个稳定 `mineOperationID`——重试复用
///   receipt 回放，不复制卡；换候选/义项后换新 opID（负载已变，
///   同 opID 重放会触发 `operationPayloadConflict`）。
@MainActor
@Observable
final class ReaderInspectorViewModel {

    // MARK: - 输入

    let tap: ReaderDocumentViewModel.TokenTap
    /// 挖词定位上下文（块/章定位 + 有界句快照）——构造时一次算好。
    let context: ReaderMiningContext
    private let deps: ReaderMiningDependencies
    /// S13「挖句成卡」：draft 装配闭包（捕获文档 VM 做句内 blank
    /// 坐标换算）；参数 = 用户显式选定候选的表形（lemma 预填）。
    /// nil = 入口隐藏。
    private let clozeDraftProvider: ((String?) -> ReaderClozeDraft?)?

    // MARK: - 展示状态

    private(set) var lookup: ReaderMiningLookup? {
        // lookup 结果换批（挖词/标记后重查）→ unit 归属证据可能变化，
        // 立即重解析而不是等下一次选择操作。
        didSet { scheduleUnitResolution() }
    }
    private(set) var isLoading = true
    var errorMessage: String?
    /// 所选候选（`lexicalKey.identityKey`）；nil = 未选。
    /// 任一负载字段变更都轮换 opID——负载不同的重试不得复用
    /// receipt（`operationPayloadConflict` 防线在 store，这里先行轮换
    /// 避免误撞）。
    var selectedCandidateKey: String? {
        didSet {
            selectedSenseID = nil
            mineOperationID = UUID()
            // pending 标记属于旧候选——换候选后不再回显。
            pendingMark = nil
            scheduleUnitResolution()
        }
    }
    var selectedSenseID: Int64? {
        didSet {
            mineOperationID = UUID()
            scheduleUnitResolution()
        }
    }
    /// 选择「已有 Note 只加来源」模式的目标。
    var selectedExistingNoteID: UUID? {
        didSet {
            mineOperationID = UUID()
            scheduleUnitResolution()
        }
    }
    /// 目标 home 牌组 + 追加成员牌组。
    var targetDeckID: UUID? {
        didSet { mineOperationID = UUID() }
    }
    var additionalDeckIDs: Set<UUID> = [] {
        didSet { mineOperationID = UUID() }
    }
    private(set) var decks: [DeckSummary] = []
    /// 挖词/知识操作进行中（按钮禁用，防重入——opID 幂等兜底）。
    private(set) var isBusy = false
    /// 提交/操作结果提示（成功的 cardCount、回放命中等）。
    private(set) var noticeMessage: String?
    /// 「编辑后挖词」载荷——view 侦测后弹 AddContentEditorView。
    private(set) var editorDraft: ReaderEditorDraft?
    /// S13「挖句成卡」sheet 载荷——nil = 关闭。
    private(set) var clozeDraft: ReaderClozeDraft?
    /// 标记完成后续状态行（known/ignored 写后的 lexeme id 回声）。
    private(set) var markedLexemeID: UUID?

    /// 本次 Inspector 会话的挖词 opID——同候选/义项的重试复用；
    /// 选择变更即轮换（见 `selectedCandidateKey.didSet` 链路）。
    private var mineOperationID = UUID()
    private var lookupTask: Task<Void, Never>?

    init(
        tap: ReaderDocumentViewModel.TokenTap,
        context: ReaderMiningContext,
        dependencies: ReaderMiningDependencies,
        clozeDraftProvider: ((String?) -> ReaderClozeDraft?)? = nil
    ) {
        self.tap = tap
        self.context = context
        self.deps = dependencies
        self.clozeDraftProvider = clozeDraftProvider
    }

    /// 创建表单的依赖包（`mineCloze` 走同一 mining service）。
    var miningDependencies: ReaderMiningDependencies { deps }

    // MARK: - 派生

    var selectedCandidate: ReaderMiningCandidate? {
        lookup?.candidates.first {
            $0.lexicalKey.identityKey == selectedCandidateKey
        }
    }

    var selectedSense: ReaderMiningSense? {
        selectedCandidate?.senses.first { $0.id == selectedSenseID }
    }

    /// 已选中的既有 Note（「只加来源」模式）。
    var selectedExistingNote: ReaderLinkedNote? {
        guard let id = selectedExistingNoteID else { return nil }
        return (lookup?.duplicateNotes ?? []).first { $0.noteID == id }
            ?? selectedCandidate?.linkedNotes.first { $0.noteID == id }
    }

    /// 当前可提交的显式选择（nil = ambiguous 未选/词典无候选）。
    private var currentSelection: ReaderMiningSelection? {
        guard let candidate = selectedCandidate else { return nil }
        let sense = selectedSense
        return ReaderMiningSelection(
            lexicalKey: candidate.lexicalKey,
            writtenForm: candidate.writtenForm,
            normalizedLemma: SearchTextNormalizer.normalize(
                candidate.writtenForm
            ),
            reading: candidate.reading,
            posFamily: candidate.posCodes.first,
            posCodes: candidate.posCodes,
            entryID: candidate.entryID,
            senseID: sense?.id,
            senseKey: sense?.senseKey,
            selectedGlossLanguage: sense?.glossLanguage,
            meaningZH: sense?.glossText ?? "",
            dictionaryVersion: candidate.dictionaryVersion
        )
    }

    /// 「挖词」可用性：显式候选选中且（有义项必须选义项）且目标
    /// 牌组就位。已有 Note 模式下同样需候选选定（关联落在候选
    /// lexeme 上）。
    var canMine: Bool {
        guard !isBusy, let candidate = selectedCandidate,
              targetDeckID != nil else { return false }
        if !candidate.senses.isEmpty && selectedSenseID == nil {
            return false
        }
        return true
    }

    var canEditThenMine: Bool {
        canMine && deps.editorFactory != nil
            && selectedExistingNoteID == nil
    }

    // MARK: - 载入

    /// 进入：lookup（候选/义项/知识态/重名 Note）+ 牌组目录。
    /// 代数不预先选任何候选——ambiguous 语义要求用户显式点选。
    func load() {
        lookupTask?.cancel()
        // S16：观察订阅在面板存活期内建立一次（观察句柄独立于
        // 具体 lookup 任务）。
        startUnitObservationIfNeeded()
        lookupTask = Task { [deps, tap] in
            do {
                async let lookupResult = deps.service.lookup(
                    surface: tap.surface,
                    reading: tap.reading,
                    morphologyCandidates: tap.candidates,
                    tokenWasAmbiguous: tap.resolutionStatus == .ambiguous
                )
                async let decksResult = deps.decks.fetchDecks()
                let primaryID = await deps.primaryDeckIDProvider?()
                let lookup = try await lookupResult
                guard !Task.isCancelled, generationAlive(deps) else {
                    return
                }
                self.lookup = lookup
                self.decks = (try? await decksResult) ?? []
                self.targetDeckID = primaryID
                    ?? self.decks.first?.id
                isLoading = false
            } catch is CancellationError {
                // 面板关闭/重发——静默。
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// 关闭：在途 lookup/挖掘/标记全部取消（层叠 UI 不接收陈旧结果）。
    func dismiss() {
        lookupTask?.cancel()
        markTask?.cancel()
        // S16：unit 解析与观察句柄随面板生命周期结束。
        unitResolveTask?.cancel()
        unitObservationTask?.cancel()
    }

    // MARK: - S16 学习单元（太简单）

    /// unit 定位结果（§12.4：只有 resolved 才允许 Too Easy 操作；
    /// 其余三态一律展示「待确认」，绝不按表形/lemma 猜 unit）。
    enum LearningUnitResolution: Equatable {
        /// 未选候选/义项，或所选义项尚无持久 unit——待确认。
        case unresolved
        /// 关联笔记分属多个 unit（同 lemma 多义独立）——拒绝合并。
        case ambiguous
        /// `unitContext` 有效——展示三态并可操作。
        case resolved
    }

    /// flag 门面——由 mining service 同 pool 派生（依赖装配文件
    /// 冻结时的受控通路）；nil = 入口隐藏。
    private var learningUnits: (any LearningUnitFlagProviding)? {
        deps.service.learningUnitFlags
    }

    private(set) var unitContext: LearningUnitContext?
    private(set) var unitResolution: LearningUnitResolution = .unresolved
    private(set) var isApplyingUnitFlag = false
    /// flag 操作的幂等键——按「当前 resolved unit」轮换：换义项/
    /// 候选产生新 opID，同 unit 的重试复用 receipt。
    private var unitFlagOperationID = UUID()
    private var unitResolveTask: Task<Void, Never>?
    private var unitObservationTask: Task<Void, Never>?

    var canApplyUnitTooEasy: Bool {
        unitResolution == .resolved && unitContext != nil
            && learningUnits != nil && !isBusy && !isApplyingUnitFlag
    }

    /// 三态显示文案（复用 `LearningKnowledgeResolver` 的结果，
    /// 不引入第二份判定）。
    var unitStateLabel: String {
        switch unitResolution {
        case .resolved:
            guard let unitContext else { return "待确认" }
            return switch unitContext.knowledgeState {
            case .unknown: "未知"
            case .learning: "学习中"
            case .mastered: "已掌握"
            }
        case .ambiguous: return "待确认（该词关联多个学习单元）"
        case .unresolved: return "待确认"
        }
    }

    /// 选择/lookup 变化 → 重新解析。取消在途任务保证只应用最新
    /// 一次解析（快速连点候选/义项不交错落盘）。
    private func scheduleUnitResolution() {
        unitResolveTask?.cancel()
        unitResolveTask = Task { [weak self] in
            await self?.resolveUnitContext()
        }
    }

    /// unit 定位优先级：显式「既有 Note」 > 显式「候选+义项」
    /// （dictionarySense identityKey）> 无义项候选的关联 Note 链接。
    /// 任一环节证据不足 → unresolved；同 lemma 多 unit → ambiguous。
    private func resolveUnitContext() async {
        guard let units = learningUnits else {
            unitContext = nil
            unitResolution = .unresolved
            return
        }
        let ops = LearningUnitFlagOperator(flags: units)
        do {
            // 1) 「只加来源」显式目标：note→link→unit。
            if let noteID = selectedExistingNoteID {
                if let context = try await ops.context(forNoteID: noteID) {
                    applyUnitContext(context)
                } else {
                    applyUnitContext(nil)
                }
                return
            }
            guard let candidate = selectedCandidate else {
                applyUnitContext(nil)
                return
            }
            // 2) 有义项的词典候选：必须显式选义项，按
            //    dictionarySense identityKey 定位——持久证据来自
            //    义项快照指纹，不经表形/lemma 推断。
            if !candidate.senses.isEmpty {
                guard let selection = currentSelection,
                      selection.senseID != nil,
                      let key = try await deps.service
                        .unitIdentityKey(for: selection),
                      let unit = try await units
                        .fetchUnit(identityKey: key)
                else {
                    applyUnitContext(nil)
                    return
                }
                applyUnitContext(try await ops.context(for: unit))
                return
            }
            // 3) 无义项候选（OOV/自建）：经关联 Note 的真实 link
            //    定位；>1 个 unit = 歧义拒绝，不做 lemma 级合并。
            let unitIDs = try await ops.unitIDs(
                linkedToNoteIDs: candidate.linkedNotes.map(\.noteID)
            )
            guard unitIDs.count <= 1,
                  let unitID = unitIDs.first,
                  let unit = try await units
                    .fetchUnits(ids: [unitID])[unitID]
            else {
                applyUnitContext(
                    nil,
                    resolution: unitIDs.count > 1 ? .ambiguous : .unresolved
                )
                return
            }
            applyUnitContext(try await ops.context(for: unit))
        } catch is CancellationError {
            // 被更新的解析取代。
        } catch {
            // 解析失败保守处理——不显示陈旧/可疑状态。
            applyUnitContext(nil)
        }
    }

    private func applyUnitContext(
        _ context: LearningUnitContext?,
        resolution: LearningUnitResolution? = nil
    ) {
        let previousUnitID = unitContext?.unit.id
        unitContext = context
        unitResolution = resolution
            ?? (context != nil ? .resolved : .unresolved)
        // unit 变了 → opID 轮换（幂等键与操作负载绑定）。
        if context?.unit.id != previousUnitID {
            unitFlagOperationID = UUID()
        }
    }

    /// Too Easy 置位/清除（§12.3）：CAS 读当前 revision——另一窗口
    /// 先改过则冲突报错并重解析；清 flag 随时允许（不限于复习页
    /// 撤销窗口）。入口只在 `unitResolution == .resolved` 时开放。
    func setUnitTooEasy(_ value: Bool) {
        guard canApplyUnitTooEasy, let units = learningUnits,
              let unitContext else { return }
        isBusy = true
        isApplyingUnitFlag = true
        let operationID = unitFlagOperationID
        Task { [deps] in
            defer {
                isBusy = false
                isApplyingUnitFlag = false
            }
            do {
                _ = try await LearningUnitFlagOperator(flags: units).set(
                    value,
                    unitID: unitContext.unit.id,
                    operationID: operationID,
                    at: Date()
                )
                guard generationAlive(deps) else { return }
                noticeMessage = value
                    ? "已标记「太简单」——学习计划不再排入该词条的卡。"
                    : "已取消「太简单」标记。"
                await resolveUnitContext()
            } catch {
                guard generationAlive(deps) else { return }
                errorMessage = LearningUnitFlagOperator.message(for: error)
                await resolveUnitContext()
            }
        }
    }

    /// 跨窗口观察（§14.3）：flags/links 变更 → 重解析当前选定的
    /// unit 三态——复习页/详情页/另一窗口的写入实时反映。
    private func startUnitObservationIfNeeded() {
        guard unitObservationTask == nil,
              let observing =
                learningUnits as? any LearningUnitFlagObserving
        else { return }
        unitObservationTask = Task { [weak self] in
            do {
                for try await _ in observing.observeChanges() {
                    guard let self, !Task.isCancelled else { return }
                    await self.resolveUnitContext()
                }
            } catch {
                // 流失败即停——面板重开会重建。
            }
        }
    }

    // MARK: - 知识状态操作

    /// Picker 的乐观选择：`.auto` 对应 override=nil。保留 pending
    /// 值让分段控件立即回显——不等 DB 写+重查跑完。
    enum KnowledgeMark: Equatable {
        case auto, known, ignored

        init(_ override: KnowledgeOverride?) {
            switch override {
            case .known: self = .known
            case .ignored: self = .ignored
            case nil: self = .auto
            }
        }

        var override: KnowledgeOverride? {
            switch self {
            case .auto: nil
            case .known: .known
            case .ignored: .ignored
            }
        }
    }

    /// 最近一次用户选择（尚未被 lookup 刷新覆盖前优先显示）。
    private(set) var pendingMark: KnowledgeMark?
    private var markTask: Task<Void, Never>?

    /// 标为已知/忽略/重置（auto）。乐观更新：picker 立即回显；
    /// 快速连点时取消前一次标记任务，最新值生效。候选未落库时先
    /// ensureLexeme（OOV 也可标记）；完成后只内联重跑 lookup，
    /// 不再顺带重查牌组目录。
    func mark(_ override: KnowledgeOverride?) {
        guard let candidate = selectedCandidate else { return }
        let choice = KnowledgeMark(override)
        pendingMark = choice
        markTask?.cancel()
        isBusy = true
        markTask = Task { [deps] in
            defer { isBusy = false }
            do {
                let lexemeID: UUID
                if let existing = candidate.lexemeID {
                    lexemeID = existing
                } else {
                    lexemeID = try await deps.knowledge.ensureLexeme(
                        key: candidate.lexicalKey,
                        seed: lexemeSeed(
                            writtenForm: candidate.writtenForm,
                            reading: candidate.reading,
                            lexicalKey: candidate.lexicalKey,
                            posFamily: candidate.posCodes.first,
                            dictionaryVersion: candidate.dictionaryVersion
                        )
                    ).id
                }
                switch choice.override {
                case .known:
                    _ = try await deps.knowledge.markKnown(
                        lexemeID: lexemeID)
                case .ignored:
                    _ = try await deps.knowledge.markIgnored(
                        lexemeID: lexemeID)
                case nil:
                    _ = try await deps.knowledge.resetKnowledge(
                        lexemeID: lexemeID)
                }
                try Task.checkCancellation()
                markedLexemeID = lexemeID
                noticeMessage = switch choice {
                case .known: "已标记为已知"
                case .ignored: "已忽略该词"
                case .auto: "已重置知识状态"
                }
                // 内联重查 lookup：徽章回到真值表结果后才撤乐观态，
                // 避免「写完成→旧解析态闪回→新态」的抖动。
                let fresh = try await deps.service.lookup(
                    surface: tap.surface,
                    reading: tap.reading,
                    morphologyCandidates: tap.candidates,
                    tokenWasAmbiguous: tap.resolutionStatus == .ambiguous
                )
                try Task.checkCancellation()
                lookup = fresh
                if pendingMark == choice { pendingMark = nil }
            } catch is CancellationError {
                // 被更新的标记取代——pendingMark 由新任务接管。
            } catch {
                guard generationAlive(deps) else { return }
                if pendingMark == choice { pendingMark = nil }
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 挖词

    /// 直接挖词：一次原子提交（Note/Card/membership/来源/lexeme 关联/
    /// 活动事件/receipt）。重试复用 `mineOperationID`——回放不产生
    /// 重复卡。
    func mine() {
        guard let selection = currentSelection,
              let deckID = targetDeckID else {
            errorMessage = ReaderMiningError.selectionRequired
                .localizedDescription
            return
        }
        isBusy = true
        let request = makeRequest(selection: selection, deckID: deckID)
        Task { [deps] in
            defer { isBusy = false }
            do {
                let outcome = try await deps.service.mine(request)
                guard generationAlive(deps) else { return }
                noticeMessage = outcome.wasReplayed
                    ? "该词已挖过（本次为重试回放）。"
                    : outcome.wasExistingNote
                        ? "已把该词记到既有笔记上（仅追加来源）。"
                        : "已挖词，生成 \(outcome.cardCount) 张卡片。"
                load()
            } catch ReaderMiningError.staleGeneration {
                // 恢复后旧代请求：不写回、不更新 UI（面板随壳层重建）。
            } catch {
                guard generationAlive(deps) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 「编辑后挖词」：产出编辑器载荷（预填表单 + 来源草稿 +
    /// 关联种子），view 负责呈现 `deps.editorFactory` 的视图。
    func openEditor() {
        guard canEditThenMine, let selection = currentSelection else {
            return
        }
        let candidate = selectedCandidate!
        editorDraft = ReaderEditorDraft(
            form: VocabularyFormData(
                headword: candidate.writtenForm,
                reading: candidate.reading ?? "",
                meaningZH: selection.meaningZH,
                partOfSpeech: DictionaryCardPrefill.mapPartOfSpeech(
                    Set(candidate.posCodes)
                ) ?? "",
                exampleJapanese: context.sentence
            ),
            source: SourceContextDraft(
                sourceType: .reader,
                originalSentence: context.sentence,
                surroundingText: context.surroundingText,
                sourceTitle: context.sourceTitle,
                dictionaryEntryID: selection.entryID,
                dictionaryVersion: selection.dictionaryVersion,
                dictionarySenseKey: selection.senseKey,
                selectedGlossLanguage: selection.selectedGlossLanguage,
                readerDocumentID: context.documentID,
                readerChapterID: context.chapterID,
                readerLocation: context.location,
                selectedSurface: context.selectedSurface,
                isPrimary: false
            ),
            requiredDeckID: targetDeckID,
            association: ReaderEditorDraft.Association(
                key: selection.lexicalKey,
                seed: lexemeSeed(
                    writtenForm: selection.writtenForm,
                    reading: selection.reading,
                    lexicalKey: selection.lexicalKey,
                    posFamily: selection.posFamily,
                    dictionaryVersion: selection.dictionaryVersion
                )
            )
        )
    }

    /// 编辑器提交成功后由 sheet 调用：补 lexeme↔Note 关联
    /// （best-effort，独立事务——编辑器提交本身不可嵌外部写）。
    func editorCommitted(noteID: UUID) async {
        guard let association = editorDraft?.association else { return }
        do {
            _ = try await deps.knowledge.confirmAssociation(
                key: association.key,
                seed: association.seed,
                noteID: noteID
            )
            guard generationAlive(deps) else { return }
            noticeMessage = "已保存并关联到该词。"
            load()
        } catch {
            guard generationAlive(deps) else { return }
            errorMessage = "笔记已保存，但词汇关联写入失败："
                + error.localizedDescription
        }
    }

    func clearEditorDraft() { editorDraft = nil }

    // MARK: - S13 挖句成卡

    /// 「挖句成卡」：blank = 点中的 token；lemma 取用户显式选定的
    /// 候选表形（未选候选时留空，表单里可手填——歧义 token 不
    /// 自动取首候选）。装配失败（陈旧 tap/块已切换）静默忽略。
    func openClozeCreate() {
        guard let provider = clozeDraftProvider else { return }
        clozeDraft = provider(selectedCandidate?.writtenForm)
    }

    func clearClozeDraft() { clozeDraft = nil }

    /// 编辑器 sheet 装配：工厂注入提交回调——编辑器词汇提交成功
    /// 后回传 noteID，`editorCommitted` 补 lexeme 关联。
    func makeEditorPresentation()
        -> ReaderInspectorView.EditorPresentation? {
        guard let draft = editorDraft,
              let factory = deps.editorFactory else { return nil }
        return ReaderInspectorView.EditorPresentation(
            view: factory(draft) { [weak self] noteID in
                Task { await self?.editorCommitted(noteID: noteID) }
            }
        )
    }

    private func makeRequest(
        selection: ReaderMiningSelection,
        deckID: UUID
    ) -> ReaderMiningRequest {
        ReaderMiningRequest(
            operationID: mineOperationID,
            expectedGeneration: deps.generation,
            deckID: deckID,
            additionalDeckIDs: additionalDeckIDs,
            selection: selection,
            existingNoteID: selectedExistingNoteID,
            context: context
        )
    }

    private func lexemeSeed(
        writtenForm: String,
        reading: String?,
        lexicalKey: LexicalKey,
        posFamily: String?,
        dictionaryVersion: String?
    ) -> Lexeme {
        Lexeme(
            id: UUID(),
            key: lexicalKey,
            writtenForm: writtenForm,
            reading: reading,
            normalizedLemma: SearchTextNormalizer.normalize(writtenForm),
            posFamily: posFamily,
            dictionaryVersionAtResolution: dictionaryVersion,
            resolutionStatus: .resolved,
            createdAt: Date()
        )
    }

    /// 世代活性闸：VM 结果应用前对活世代源复核——请求发出的
    /// 世代与容器世代一致只是必要条件，恢复后这里立即失败。
    private func generationAlive(_ deps: ReaderMiningDependencies) -> Bool {
        deps.service.isExpectedGenerationAlive(deps.generation)
    }
}

// MARK: - 批量挖词队列

/// 批量模式视图模型：点词逐个入队 → sheet 展示候选 → 用户勾选/
/// 改选 → `mineBatch` 顺序提交；取消保留已提交、丢弃未处理项。
@MainActor
@Observable
final class ReaderBatchMiningViewModel {

    /// 队列项：tap 原文 + lookup 结果 + 用户勾选/候选选择。
    struct Item: Identifiable {
        let id = UUID()
        let tap: ReaderDocumentViewModel.TokenTap
        let context: ReaderMiningContext
        /// 该队列项的稳定 opID（重试复用 receipt）。
        let operationID = UUID()
        var lookup: ReaderMiningLookup?
        var isLoading = true
        var lookupFailed = false
        var isSelected = true
        var selectedCandidateKey: String?
        var selectedSenseID: Int64?
    }

    /// ForEach 展示的是值拷贝——行内勾选/改选经 `itemBinding`
    /// 直接写回本数组，故必须是可写 var。
    var items: [Item] = []
    private(set) var isRunning = false
    private(set) var summary: ReaderMiningBatchSummary?
    /// 目标牌组（批量共用）。
    var targetDeckID: UUID?
    private(set) var decks: [DeckSummary] = []
    var errorMessage: String?

    private let document: ReaderDocumentViewModel
    private let deps: ReaderMiningDependencies
    private var batchTask: Task<Void, Never>?

    init(
        document: ReaderDocumentViewModel,
        dependencies: ReaderMiningDependencies
    ) {
        self.document = document
        self.deps = dependencies
    }

    /// 批量选择态下的 token 点击入队；同块同范围去重。
    func enqueue(_ tap: ReaderDocumentViewModel.TokenTap) {
        guard !items.contains(where: {
            $0.tap.blockID == tap.blockID
                && $0.tap.utf16Range == tap.utf16Range
        }), let context = document.miningContext(for: tap) else { return }
        items.append(Item(tap: tap, context: context))
        let index = items.count - 1
        Task { [deps] in
            do {
                let lookup = try await deps.service.lookup(
                    surface: tap.surface,
                    reading: tap.reading,
                    morphologyCandidates: tap.candidates,
                    tokenWasAmbiguous: tap.resolutionStatus == .ambiguous
                )
                guard !Task.isCancelled, items.indices.contains(index)
                else { return }
                items[index].lookup = lookup
                items[index].isLoading = false
                // 单候选且 token 已解析 → 预选（非 ambiguous 场景允许）；
                // ambiguous/多候选保留 nil，行内由用户显式选择。
                if lookup.candidates.count == 1, !lookup.requiresSelection,
                   let only = lookup.candidates.first {
                    items[index].selectedCandidateKey =
                        only.lexicalKey.identityKey
                    items[index].selectedSenseID = only.senses.count == 1
                        ? only.senses.first?.id : nil
                }
            } catch {
                guard items.indices.contains(index) else { return }
                items[index].isLoading = false
                items[index].lookupFailed = true
            }
        }
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
    }

    func load() {
        Task { [deps] in
            let fetched = (try? await deps.decks.fetchDecks()) ?? []
            let primaryID = await deps.primaryDeckIDProvider?()
            decks = fetched
            targetDeckID = primaryID ?? fetched.first?.id
        }
    }

    /// 启动批量挖词：逐行装配请求（无选择项照传——服务层计
    /// `requiresSelection`，不自动补选），`mineBatch` 顺序提交。
    func start() {
        guard !isRunning, let deckID = targetDeckID else { return }
        isRunning = true
        let requests = items.map { item in
            ReaderMiningBatchItem(
                request: ReaderMiningRequest(
                    operationID: item.operationID,
                    expectedGeneration: deps.generation,
                    deckID: deckID,
                    selection: selection(for: item),
                    context: item.context
                ),
                isSelected: item.isSelected,
                label: item.tap.surface
            )
        }
        batchTask = Task { [deps] in
            let result = await deps.service.mineBatch(requests)
            guard !Task.isCancelled else { return }
            summary = result
            isRunning = false
        }
    }

    /// 取消：已提交项保留、剩余项丢弃，`mineBatch` 走默认
    /// `Task.isCancelled` 判定。
    func cancel() { batchTask?.cancel(); isRunning = false }

    private func selection(for item: Item) -> ReaderMiningSelection? {
        guard let lookup = item.lookup, let key = item.selectedCandidateKey,
              let candidate = lookup.candidates.first(where: {
                  $0.lexicalKey.identityKey == key
              })
        else { return nil }
        let sense = candidate.senses.first { $0.id == item.selectedSenseID }
        return ReaderMiningSelection(
            lexicalKey: candidate.lexicalKey,
            writtenForm: candidate.writtenForm,
            normalizedLemma: SearchTextNormalizer.normalize(
                candidate.writtenForm
            ),
            reading: candidate.reading,
            posFamily: candidate.posCodes.first,
            posCodes: candidate.posCodes,
            entryID: candidate.entryID,
            senseID: sense?.id,
            senseKey: sense?.senseKey,
            selectedGlossLanguage: sense?.glossLanguage,
            meaningZH: sense?.glossText ?? "",
            dictionaryVersion: candidate.dictionaryVersion
        )
    }
}

// MARK: - TokenTap → 挖词上下文

extension ReaderDocumentViewModel {
    /// TokenTap → `ReaderMiningContext`：块/章定位（ReaderLocation）+
    /// 句截取（句界符展开、300 字符上限）+ 前后文（各 500 字符，
    /// `SourceContextDraft` 归一化再收敛到 2000）。
    /// 块已不在当前章（切章后陈旧的 tap）→ nil，不静默落错章。
    func miningContext(for tap: TokenTap) -> ReaderMiningContext? {
        readerSlice(
            blockID: tap.blockID, utf16Range: tap.utf16Range,
            selectedSurface: tap.surface
        )?.context
    }

    /// S13：TokenTap → Cloze 创建草稿。blank = token 在截取句内的
    /// UTF-16 范围（`ReaderClozeDraft.blankUTF16Range` 坐标系是
    /// `context.sentence`，不是块坐标）。`lemma` 只在用户显式选定
    /// 候选后由调用方填入——歧义 token 不自动取首候选（§6.2）。
    func clozeDraft(
        for tap: TokenTap, lemma: String? = nil
    ) -> ReaderClozeDraft? {
        guard let slice = readerSlice(
            blockID: tap.blockID, utf16Range: tap.utf16Range,
            selectedSurface: tap.surface
        ) else { return nil }
        return ReaderClozeDraft(
            context: slice.context,
            blankUTF16Range: slice.blankRangeInSentence,
            surface: tap.surface,
            lemma: lemma,
            reading: tap.reading
        )
    }

    /// S13：正文选段（系统选择菜单「挖句成卡」）→ 草稿。
    /// 选段不经形态解析——lemma/reading 留空，由用户在表单里补；
    /// blank = 选段在截取句内的 UTF-16 范围。
    func clozeDraft(
        forSelectionIn blockID: UUID, utf16Range: Range<Int>
    ) -> ReaderClozeDraft? {
        guard let block = blocks.first(where: { $0.id == blockID }),
              let startIndex = textIndex(
                  in: block.text, utf16Offset: utf16Range.lowerBound
              ),
              let endIndex = textIndex(
                  in: block.text, utf16Offset: utf16Range.upperBound
              ),
              endIndex > startIndex
        else { return nil }
        let surface = String(block.text[startIndex..<endIndex])
        guard let slice = readerSlice(
            blockID: blockID, utf16Range: utf16Range,
            selectedSurface: surface
        ) else { return nil }
        return ReaderClozeDraft(
            context: slice.context,
            blankUTF16Range: slice.blankRangeInSentence,
            surface: surface
        )
    }

    /// 共享截取：块定位 → 句截取 → 句内 blank 坐标换算。
    /// `sentence` 经 trim——blank 换算按 trim 后真实起点
    /// （`sentenceRange.lowerBound` 的块内 UTF-16 偏移）对齐；
    /// 选区被句截取裁掉（理论不可能：句以选区为中心展开，防御
    /// trim 边界）→ nil，不静默落错坐标。
    private func readerSlice(
        blockID: UUID, utf16Range: Range<Int>, selectedSurface: String
    ) -> (
        context: ReaderMiningContext, blankRangeInSentence: Range<Int>
    )? {
        guard let block = blocks.first(where: { $0.id == blockID }),
              chapters.indices.contains(currentChapterIndex),
              let startIndex = textIndex(
                  in: block.text, utf16Offset: utf16Range.lowerBound
              ),
              let endIndex = textIndex(
                  in: block.text, utf16Offset: utf16Range.upperBound
              )
        else { return nil }
        let chapter = chapters[currentChapterIndex]
        let text = block.text
        let slice = extractSentenceSlice(
            in: text, around: startIndex..<endIndex,
            limit: ReaderMiningService.sentenceCharacterLimit
        )
        guard startIndex >= slice.range.lowerBound,
              endIndex <= slice.range.upperBound
        else { return nil }
        let sentenceStartUTF16 = text[..<slice.range.lowerBound]
            .utf16.count
        let blankStart = utf16Range.lowerBound - sentenceStartUTF16
        let blankRange = blankStart..<(blankStart + utf16Range.count)
        let surrounding = surroundingText(
            in: text, around: startIndex..<endIndex,
            radius: 500
        )
        return (
            ReaderMiningContext(
                documentID: block.documentID,
                chapterID: block.chapterID,
                location: ReaderLocation(
                    chapterOrdinal: chapter.ordinal,
                    blockOrdinal: block.ordinal,
                    utf16Offset: utf16Range.lowerBound,
                    blockTextHash: block.textHash,
                    prefix: String(text[..<startIndex].suffix(
                        ReaderLocation.contextCharacterLimit
                    )),
                    suffix: String(text[endIndex...].prefix(
                        ReaderLocation.contextCharacterLimit
                    ))
                ),
                sentence: slice.sentence,
                surroundingText: surrounding,
                selectedSurface: selectedSurface,
                sourceTitle: document?.title
            ),
            blankRange
        )
    }

    /// utf16 偏移 → String.Index（非边界即失败——宁可不挖也不落错位）。
    private func textIndex(
        in text: String, utf16Offset: Int
    ) -> String.Index? {
        guard utf16Offset <= text.utf16.count,
              let utf16Index = text.utf16.index(
                  text.utf16.startIndex, offsetBy: utf16Offset,
                  limitedBy: text.utf16.endIndex
              )
        else { return nil }
        return String.Index(utf16Index, within: text)
    }

    /// 以选区为中心向两侧展开至句界符（。！？!? 换行 引号闭合），
    /// 总量受 `limit` 字符约束（超限自右侧截断——句首优先保留）。
    /// 返回 trim 后的句子文本 **及其在原串中的 String range**——
    /// cloze 的句内 blank 坐标换算需要这个起点。
    private func extractSentenceSlice(
        in text: String,
        around range: Range<String.Index>,
        limit: Int
    ) -> (sentence: String, range: Range<String.Index>) {
        let boundary: Set<Character> = [
            "。", "！", "？", "!", "?", "\n", "…"
        ]
        var start = range.lowerBound
        while start > text.startIndex {
            let prev = text.index(before: start)
            if boundary.contains(text[prev]) { break }
            if text.distance(from: prev, to: range.upperBound) > limit {
                break
            }
            start = prev
        }
        var end = range.upperBound
        while end < text.endIndex {
            if boundary.contains(text[end]) {
                end = text.index(after: end)
                break
            }
            if text.distance(from: range.lowerBound, to: end) >= limit {
                break
            }
            end = text.index(after: end)
        }
        // trim 与前实现（trimmingCharacters）同判据：剥掉首尾全部
        // 落在 whitespaceAndNewlines 里的 Character——indices 仍在
        // 原串坐标系，调用方据此换算 blank 偏移。
        let limited = text[start..<end].prefix(limit)
        var lower = limited.startIndex
        while lower < limited.endIndex,
              limited[lower].unicodeScalars.allSatisfy({
                  CharacterSet.whitespacesAndNewlines.contains($0)
              }) {
            lower = limited.index(after: lower)
        }
        var upper = limited.endIndex
        while upper > lower,
              limited[limited.index(before: upper)]
                  .unicodeScalars.allSatisfy({
                      CharacterSet.whitespacesAndNewlines.contains($0)
                  }) {
            upper = limited.index(before: upper)
        }
        return (String(limited[lower..<upper]), lower..<upper)
    }

    /// 句前后文（前后各 `radius` 字符——不含选区本身）。
    private func surroundingText(
        in text: String,
        around range: Range<String.Index>,
        radius: Int
    ) -> String? {
        let before = String(text[..<range.lowerBound].suffix(radius))
        let after = String(text[range.upperBound...].prefix(radius))
        let merged = before.isEmpty && after.isEmpty
            ? nil : before + "‖" + after
        return merged
    }
}
