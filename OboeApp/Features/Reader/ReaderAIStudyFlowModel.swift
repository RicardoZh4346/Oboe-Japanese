import Foundation
import OboeDomain
import OboeInfrastructure
import Observation
import os

/// v0.7.5 S15「AI 准备学习内容」流程模型——Reader 工具栏入口弹层
/// 的单一驱动点：
///
///   预检（范围/估算/Provider 就绪）→ 本地编排（token/manifest/Job）
///   → AI 分析（Runner 派发，可暂停/恢复/取消/重试）→ 预览选择
///   （策略 + 手工改判 + 低置信修正）→ 确认应用 → 摘要导航。
///
/// 不变量（与 `AIStudyPreparationService` 同口径）：
/// - 确认前不写 Note/Card/membership；只有证据链（Job/块/解析/
///   manifest/occurrence）。
/// - 凭据只在派发时读取（sendRequest 闭包内），不落任何状态字段。
/// - 取消只停后续派发；已提交证据/结果保留，Job 显式落 cancelled。
/// - 自动模式默认关；开启也只自动应用「无失败块」的推荐集，
///   待确认 occurrence 仍留待人工。
@MainActor
@Observable
final class ReaderAIStudyFlowModel {

    /// 进入流程时的 Reader 定位快照——范围解析参数来源。
    struct Context: Equatable, Sendable {
        let documentID: UUID
        let documentTitle: String
        /// `.currentChapter` 范围的锚（当前可见章）。
        let currentChapterID: UUID?
        /// `.currentText` 范围的锚（当前可见块）。
        let currentBlockID: UUID?
        /// 全书只一章时隐藏「当前章/未处理章」等章级选项。
        let chapterCount: Int
    }

    enum Phase: Equatable {
        /// 范围选择 + 预检报告展示。
        case preflight
        /// 本地编排（形态分析/manifest/Job 创建）——可取消。
        case preparing
        /// Runner 驱动 AI 请求——可暂停/恢复/取消/重试。
        case analyzing
        /// 预览 + 选择（确认前零业务写）。
        case preview
        /// 应用事务进行中。
        case applying
        /// 终态摘要。
        case summary
        /// 已取消（用户显式取消后的终止页）。
        case cancelled
    }

    /// 批量策略 UI 选择（映射 `AIStudySelectionStrategy`）。
    enum StrategyKind: String, CaseIterable {
        case recommended
        case all
        case jlpt
        case newItemsLimit

        var displayName: String {
            switch self {
            // D06：保留「AI 推荐」字样时必须标注消歧后本地筛选——
            // AI 只负责消歧，推荐排序是本地可解释规则。
            case .recommended: "AI 推荐（消歧后本地筛选）"
            case .all: "全部新增"
            case .jlpt: "按 JLPT 范围"
            case .newItemsLimit: "限制新内容数量"
            }
        }
    }

    /// 建卡方向预设（`AIStudyProposedAction.createNote` 载荷）。
    enum DirectionPreset: String, CaseIterable {
        case japaneseToChinese
        case chineseToJapanese
        case both
        case all

        var displayName: String {
            switch self {
            case .japaneseToChinese: "日 → 中"
            case .chineseToJapanese: "中 → 日"
            case .both: "双向"
            case .all: "全部（含听力）"
            }
        }

        var directions: Set<VocabularyCardDirection> {
            switch self {
            case .japaneseToChinese: [.japaneseToChinese]
            case .chineseToJapanese: [.chineseToJapanese]
            case .both: [.japaneseToChinese, .chineseToJapanese]
            case .all: Set(VocabularyCardDirection.allCases)
            }
        }
    }

    // MARK: - 依赖

    let dependencies: ReaderAIStudyDependencies
    let context: Context
    private var preparation: AIStudyPreparationService {
        // 装配缺席时入口已隐藏；此处 force unwrap 是装配契约。
        dependencies.preparation!
    }
    // Runner 走依赖级共享盒（`AIStudyRunnerBox`）——本模型析构
    // 不杀驱动；重进 adopt 对运行中 Job 幂等重驱动/接管。

    // MARK: - 可观测状态

    private(set) var phase: Phase = .preflight
    var scopeChoice: AIStudyScopeChoice = .currentChapter
    private(set) var report: AIStudyPrecheckReport?
    private(set) var isLoadingPreflight = false
    /// 本地编排进度（块数 done/total）。
    private(set) var prepareProgress: (done: Int, total: Int)?

    private(set) var job: AIStudyJob?
    /// 分析期块级计数（轮询 store 刷新）。
    private(set) var blockCounts:
        (total: Int, resolved: Int, failed: Int, pending: Int) =
            (0, 0, 0, 0)

    /// 预览快照（decision 可编辑，确认时冻结）。
    private(set) var preview: AIStudyPreview?
    /// 确认锚用的词典快照版本（改判 selection 的 datasetVersion）。
    private var manifestDatasetVersion = "unknown"

    var strategyKind: StrategyKind = .recommended
    var jlptLevels: Set<JLPTLevel> = Set(JLPTLevel.allCases)
    var newItemLimit: Int = 50
    /// D17：沿用三方向默认（非管线建卡路径 `allCases` 一致）；
    /// 快照的是用户实际选择，不是单方向硬默认。
    var directionPreset: DirectionPreset = .all
    /// 「自动建立学习牌组」——默认关闭（spec §42 默认建议关闭）。
    var automaticApply = false
    /// 准备载荷：是否生成段落译文（默认开——关闭时请求只消歧）。
    var wantsTranslation = true

    private(set) var summary: AIStudyJobSummary?
    private(set) var isBusy = false
    var errorMessage: String?

    /// 轮询任务——`deinit` 非隔离可达故标 `nonisolated(unsafe)`；
    /// 写点全部在 MainActor 上，取消/置空语义安全。
    nonisolated(unsafe) private var watchTask: Task<Void, Never>?

    // MARK: - 构造

    init(context: Context, dependencies: ReaderAIStudyDependencies) {
        self.context = context
        self.dependencies = dependencies
        // 章数 ≥2 才有章级范围意义；单章默认当前章（=全文同覆盖）。
        if context.chapterCount <= 1 { scopeChoice = .currentChapter }
    }

    deinit { watchTask?.cancel() }

    // MARK: - 派生状态

    var currentJobID: UUID? { job?.id }
    var jobStatus: AIStudyJobStatus? { job?.status }
    var isPaused: Bool { job?.status == .paused }
    var hasFailedBlocks: Bool { blockCounts.failed > 0 }
    /// 可开始：无 fatal 问题 + 有 resolved 配置（missingKey 仍可
    /// 开始——派发期 authFailed → Job 落 paused(missingKey)，修好
    /// Key 后 resume 续跑；disabled/missingModel 无 resolved →
    /// 不可开始）。
    var canStart: Bool {
        report?.canStart == true && report?.provider.resolved != nil
            && !isBusy && phase == .preflight
    }

    var progressFraction: Double? {
        switch phase {
        case .preparing:
            guard let p = prepareProgress, p.total > 0 else {
                return nil
            }
            return Double(p.done) / Double(p.total)
        case .analyzing:
            guard blockCounts.total > 0 else { return nil }
            let finished = blockCounts.total - blockCounts.pending
            return Double(finished) / Double(blockCounts.total)
        default:
            return nil
        }
    }

    /// 预览页头部计数（互不重叠——与 spec §42 展示口径一致）。
    var previewCounts:
        (reused: Int, created: Int, tooEasy: Int, skipped: Int,
         undecided: Int, pending: Int) {
        guard let preview else { return (0, 0, 0, 0, 0, 0) }
        var reused = 0, created = 0, easy = 0, skipped = 0, open = 0
        for item in preview.items {
            switch item.decision {
            case .reuse: reused += 1
            case .create: created += 1
            case .tooEasy: easy += 1
            case .skip: skipped += 1
            case .pending, nil: open += 1
            }
        }
        return (reused, created, easy, skipped, open,
                preview.pending.count)
    }

    /// 摘要导航目标（deckID 取自 summary.studyDeckID）。
    var studyDeckID: UUID? { summary?.studyDeckID }

    // MARK: - 预检

    /// 载入/刷新预检（范围切换后重跑）。
    func loadPreflight() async {
        guard !isLoadingPreflight else { return }
        isLoadingPreflight = true
        defer { isLoadingPreflight = false }
        do {
            let provider = await providerReadiness()
            report = try await preparation.preflight(
                documentID: context.documentID,
                request: scopeRequest(),
                provider: provider)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func scopeRequest() -> AIStudyScopeRequest {
        AIStudyScopeRequest(
            choice: scopeChoice,
            chapterID: scopeChoice == .currentChapter
                ? context.currentChapterID : nil,
            blockID: scopeChoice == .currentText
                ? context.currentBlockID : nil)
    }

    /// Provider 就绪态：配置只读，凭据存在性读 `hasAPIKey`
    /// （不取明文——发送时才 `readCredential`）。
    private func providerReadiness() async -> AIStudyProviderReadiness {
        guard let status = try? await dependencies.aiConfiguration.load(
            defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier)
        else {
            return AIStudyProviderReadiness(
                state: .disabled, isEnabled: false, serviceName: "—",
                serviceKind: .deepSeek, modelID: nil, resolved: nil)
        }
        let config = status.configuration
        // 停用态不算 resolved——`ResolvedAIConfiguration` 只验
        // modelID，不验 isEnabled；此处把「可执行」口径收紧到
        // enabled+model 双条件（canStart 依赖 resolved != nil）。
        let resolved = config.isEnabled
            ? ResolvedAIConfiguration(configuration: config) : nil
        let state: AIStudyProviderReadiness.State
        if !config.isEnabled {
            state = .disabled
        } else if resolved == nil {
            state = .missingModel
        } else if !status.hasAPIKey {
            state = .missingKey
        } else {
            state = .ready
        }
        return AIStudyProviderReadiness(
            state: state, isEnabled: config.isEnabled,
            serviceName: config.serviceName,
            serviceKind: config.serviceKind,
            modelID: config.modelID,
            resolved: resolved)
    }

    /// 接管同 (document,revision) 的既有活跃 Job（预检冲突分支的
    /// 「继续/查看预览」入口——部分唯一索引下不能并发第二个 Job）。
    func adopt(job existing: AIStudyJob) async {
        job = existing
        manifestDatasetVersion = (try? await preparation
            .loadManifest(jobID: existing.id))?
            .dictionaryDatasetVersion ?? "unknown"
        if let blocks = try? await dependencies.store
            .fetchBlocks(jobID: existing.id) {
            updateBlockCounts(blocks)
        }
        switch existing.status {
        case .awaitingConfirmation, .partiallyCompleted:
            await finalizeBestEffort(jobID: existing.id)
            await loadPreview()
        case .paused:
            phase = .analyzing   // 显示「恢复/取消」
        case .pending, .analyzing, .waitingForAI:
            phase = .analyzing
            watch(jobID: existing.id)
            // 重驱动屏障：共享 Runner 驱动仍在 → `start` 幂等
            // no-op；驱动已消亡（重启/上次 FlowModel 异常）→ 按
            // 块 checkpoint 续跑，不让孤儿 analyzing 永久停摆。
            let runner = ensureRunner()
            Task { [runner] in
                try? await runner.start(jobID: existing.id)
            }
        case .applying:
            phase = .applying
        default:
            phase = .preflight
        }
    }

    // MARK: - 开始 → 本地编排 → AI 分析

    /// 预检通过后的主按钮：manifest/Job 原子创建 + Runner 启动。
    func startAnalysis() async {
        guard let report, report.canStart,
              let resolved = report.provider.resolved else { return }
        isBusy = true
        defer { isBusy = false }
        phase = .preparing
        prepareProgress = (0, max(1, report.estimate.blockCount))
        do {
            let job = try await preparation.prepare(
                documentID: context.documentID,
                report: report,
                configuration: resolved,
                wantsTranslation: wantsTranslation
            ) { [weak self] done, total in
                Task { @MainActor in
                    self?.prepareProgress = (done, total)
                }
            }
            self.job = job
            manifestDatasetVersion = (try? await preparation
                .loadManifest(jobID: job.id))?
                .dictionaryDatasetVersion ?? "unknown"
            phase = .analyzing
            prepareProgress = nil
            let runner = ensureRunner()
            let jobID = job.id
            Task { [runner] in
                do { try await runner.start(jobID: jobID) }
                catch { /* 状态经 watch 轮询回流 */ }
            }
            watch(jobID: jobID)
        } catch {
            phase = .preflight
            prepareProgress = nil
            errorMessage = Self.message(for: error)
        }
    }

    /// Runner 延迟装配：planner = manifest 确定性 replan；
    /// sendRequest = 配置/凭据**当次**快照 → resolver。
    /// 实例存依赖级共享盒——多 FlowModel/重进共用同一驱动面。
    private func ensureRunner() -> AIStudyRunner {
        if let runner = dependencies.runnerBox.runner { return runner }
        let preparation = preparation
        let aiConfiguration = dependencies.aiConfiguration
        let credentialStore = dependencies.credentialStore
        let resolver = dependencies.resolver
        let runner = AIStudyRunner(
            store: dependencies.store,
            // §9.2 上限 4——默认 2 对几十块的长任务太慢；限流由
            // 退避+jitter+failed 重试自调节，不超协议上限。
            configuration: .init(maxConcurrentRequests: 4),
            planner: { job in
                try await preparation.plannedBlocks(for: job)
            },
            sendRequest: { request in
                let status = try await aiConfiguration.load(
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent
                        .identifier)
                guard status.configuration.isEnabled,
                      let resolved = ResolvedAIConfiguration(
                          configuration: status.configuration)
                else {
                    throw AIStudyResolverError.unsupportedConfiguration(
                        "AI 未启用或未选择模型——请在设置中完成配置。")
                }
                guard let credential = try await credentialStore
                    .readCredential(for: resolved.credentialReference),
                      !credential.isEmpty
                else { throw AIStudyResolverError.authFailed }
                return try await resolver.resolve(
                    request,
                    configuration: resolved,
                    credential: credential)
            })
        dependencies.runnerBox.runner = runner
        return runner
    }

    /// Job 轮询：active 期间每 250ms 刷块计数，落定后进入收尾。
    private func watch(jobID: UUID) {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.watchTask = nil }
            while !Task.isCancelled {
                do {
                    let current = try await self.dependencies.store
                        .fetchJob(id: jobID)
                    let blocks = try await self.dependencies.store
                        .fetchBlocks(jobID: jobID)
                    self.job = current
                    self.updateBlockCounts(blocks)
                    // Runner 驱动态才继续轮询：paused 走 resume/cancel
                    // 显式动作；awaitingConfirmation/partiallyCompleted
                    // 收束进预览；终态直接呈现。
                    switch current?.status {
                    case .pending?, .analyzing?, .waitingForAI?:
                        break   // 继续轮询
                    default:
                        await self.analysisDidSettle(jobID: jobID)
                        return
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    break
                }
            }
        }
    }

    private func updateBlockCounts(_ blocks: [AIStudyJobBlock]) {
        var resolved = 0, failed = 0, pending = 0
        var failureCode: String?
        for block in blocks {
            switch block.status {
            case .resolved, .awaitingConfirmation, .applying, .applied:
                resolved += 1
            case .failed:
                failed += 1
                failureCode = failureCode ?? block.lastErrorCode
            case .cancelled: break
            default: pending += 1
            }
        }
        blockCounts = (
            total: blocks.count, resolved: resolved,
            failed: failed, pending: pending)
        lastFailureCode = failureCode
    }

    /// 最近一个失败块的归因码（rateLimited/retryExhausted/…）——
    /// 分析页给用户看「为什么慢/为什么失败」，不止给计数。
    private(set) var lastFailureCode: String?

    /// 驱动收束后的相位推进：awaitingConfirmation/partiallyCompleted
    /// → 预览；paused → 留在 analyzing（显示恢复原因）；failed/
    /// cancelled → 错误/取消呈现。
    private func analysisDidSettle(jobID: UUID) async {
        guard phase == .analyzing else { return }
        let current = try? await dependencies.store.fetchJob(id: jobID)
        guard let current else { return }
        job = current
        switch current.status {
        case .awaitingConfirmation, .partiallyCompleted:
            await finalizeBestEffort(jobID: jobID)
            await loadPreview()
            if automaticApply, phase == .preview,
               let preview,
               preview.failedBlockCount == 0,
               preview.pending.isEmpty {
                applyStrategy(.recommended)
                await confirm()
            }
        case .cancelled:
            await finalizeBestEffort(jobID: jobID)
            phase = .cancelled
        case .failed:
            await finalizeBestEffort(jobID: jobID)
            errorMessage = "分析失败——可在预览页查看失败块后重试。"
            await loadPreview()
        case .paused:
            // paused(missingKey/background/manual) 停留本页，
            // UI 依 resumeReason 给「恢复/取消」。
            break
        default:
            break
        }
    }

    /// S20 集成点：Runner 收束/接管即 finalize——occurrence 状态
    /// 回填 + 译文发布（服务内随即 best-effort 落 Coverage v2
    /// 快照）。finalize 幂等，重试/恢复路径会再次调用；失败不拦
    /// 相位推进——预览仍可读证据链，occurrence/译文由下次
    /// finalize 补齐。
    private func finalizeBestEffort(jobID: UUID) async {
        do {
            try await preparation.finalizeResults(jobID: jobID)
        } catch {
            Self.logger.error(
                "finalizeResults failed for \(jobID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func loadPreview() async {
        guard let job else { return }
        do {
            preview = try await preparation.buildPreview(jobID: job.id)
            phase = .preview
            // 默认策略立即应用——预览页打开即按「AI 推荐」填决策。
            applyStrategy(strategy)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - 分析期控制

    func pause() async {
        guard let job else { return }
        do {
            try await ensureRunner().pause(
                jobID: job.id, reason: .manualPause)
            await refreshJob()
        } catch { errorMessage = Self.message(for: error) }
    }

    func resume() async {
        guard let job else { return }
        do {
            try await ensureRunner().resume(jobID: job.id)
            watch(jobID: job.id)
        } catch { errorMessage = Self.message(for: error) }
    }

    /// 取消：停派 + 在途任务取消 + Job/块落 cancelled（已提交
    /// 证据保留——cancelled ≠ 回滚）。
    func cancel() async {
        guard let job else { phase = .cancelled; return }
        do {
            try await ensureRunner().cancel(jobID: job.id)
        } catch { /* cancel 幂等——失败仍按取消呈现 */ }
        watchTask?.cancel()
        await refreshJob()
        phase = .cancelled
    }

    /// 预览页「重试失败块」——Runner 回 analyzing 续跑；
    /// 回到 analyzing 相位直到再次收束。
    func retryFailedBlocks() async {
        guard let job else { return }
        do {
            phase = .analyzing
            try await ensureRunner().retryFailedBlocks(jobID: job.id)
            watch(jobID: job.id)
        } catch {
            errorMessage = Self.message(for: error)
            await loadPreview()
        }
    }

    private func refreshJob() async {
        guard let job else { return }
        self.job = try? await dependencies.store.fetchJob(id: job.id)
        if let blocks = try? await dependencies.store
            .fetchBlocks(jobID: job.id) {
            updateBlockCounts(blocks)
        }
    }

    // MARK: - 选择

    /// 当前策略映射（JLPT/上限取 UI 参数）。
    var strategy: AIStudySelectionStrategy {
        switch strategyKind {
        case .recommended: .recommended
        case .all: .all
        case .jlpt: .jlpt(jlptLevels)
        case .newItemsLimit: .newItemsLimit(newItemLimit)
        }
    }

    /// 策略应用：就地重写 items 的决策（幂等——切换策略先清
    /// 非跳过项再按规则填；不含策略覆盖集的项保持人工决策）。
    func applyStrategy(_ strategy: AIStudySelectionStrategy) {
        guard var items = preview?.items else { return }
        strategy.apply(
            to: &items,
            studyDeckID: job?.studyDeckID,
            directions: directionPreset.directions)
        preview?.items = items
    }

    /// 单项决策（create/reuse/skip/tooEasy）。reuse 需指定 Note——
    /// 默认取首个 linked Note，无则用 duplicate 首个。
    func setDecision(
        for itemID: String,
        decision: AISelectionDecision,
        reuseNoteID: UUID? = nil
    ) {
        guard var preview,
              let index = preview.items.firstIndex(where: {
                  $0.id == itemID })
        else { return }
        var item = preview.items[index]
        switch decision {
        case .create:
            item.decision = .create
            item.proposedAction =
                .createNote(
                    directions: directionPreset.directions,
                    senseIDs: item.mergedSenseIDs)
        case .reuse:
            let noteID = reuseNoteID
                ?? item.linkedNotes.first?.noteID
                ?? item.duplicateNotes.first?.noteID
            guard let noteID else { return }
            item.decision = .reuse
            item.proposedAction = .reuseNote(
                noteID: noteID, addMembershipTo: job?.studyDeckID)
        case .skip:
            item.decision = .skip
            item.proposedAction = .recordSkip
        case .tooEasy:
            item.decision = .tooEasy
            item.proposedAction = .setTooEasy
        case .pending:
            item.decision = nil
            item.proposedAction = nil
        }
        preview.items[index] = item
        self.preview = preview
    }

    /// 低置信 occurrence 改判：选定替代候选 → `correctedSelection`。
    /// `nil` 撤销改判。
    func correctPending(
        _ pendingID: String,
        to alternative: AIStudyPreviewPendingItem.Alternative?
    ) {
        guard var preview,
              let index = preview.pending.firstIndex(where: {
                  $0.id == pendingID })
        else { return }
        preview.pending[index].correctedSelection = alternative.map {
            AIStudySelection(
                provider: "jmdict",
                entryID: $0.entryID,
                senseID: $0.senseID,
                datasetVersion: manifestDatasetVersion)
        }
        self.preview = preview
    }

    /// 待确认队列里 AI 首选仍可采纳的行数（有 `aiSuggested`
    /// 且未改判）——「一键采纳」按钮的计数与可用性依据。
    var acceptableAISuggestionCount: Int {
        preview?.pending.filter {
            $0.aiSuggested != nil && $0.correctedSelection == nil
        }.count ?? 0
    }

    /// C5：一键采纳全部 AI 首选——低置信行的合法选定批量写
    /// `correctedSelection`（走同一改判落库路径：origin=user 新
    /// revision + occurrence 换指）。已手动改判的行不动；
    /// 无 AI 首选的行（unresolved/被拒/缺 confidence）保持待确认。
    /// 返回采纳数。
    @discardableResult
    func acceptAllAISuggestions() -> Int {
        guard var preview else { return 0 }
        var adopted = 0
        for index in preview.pending.indices {
            guard let suggested = preview.pending[index].aiSuggested,
                  preview.pending[index].correctedSelection == nil
            else { continue }
            preview.pending[index].correctedSelection = AIStudySelection(
                provider: "jmdict",
                entryID: suggested.entryID,
                senseID: suggested.senseID,
                datasetVersion: manifestDatasetVersion)
            adopted += 1
        }
        self.preview = preview
        return adopted
    }

    // MARK: - 确认 → 应用 → 摘要

    /// 「生成学习牌组」：不可变 selection revision 落库 →
    /// `applyConfirmedJob` 逐 unit 事务 → 摘要。
    func confirm() async {
        guard let job, let preview, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // 未决策 unit / 未改判 pending 的计数在应用前冻结（摘要口径）。
        let unselected = preview.items.filter {
            $0.decision == nil || $0.decision == .pending
        }.count
        let unresolvedPending = preview.pending.filter {
            $0.correctedSelection == nil
        }.count
        phase = .applying
        do {
            _ = try await preparation.recordSelections(
                jobID: job.id,
                preview: preview,
                items: preview.items,
                correctedPending: preview.pending)
            let report = try await dependencies.applier
                .applyConfirmedJob(jobID: job.id)
            summary = try await preparation.summary(
                jobID: job.id,
                report: report,
                unselectedCount: unselected,
                pendingCount: unresolvedPending)
            phase = .summary
            await refreshJob()
        } catch let error
            as AIStudyPreparationService.PreparationError {
            // stalePreview/staleContent：重建预览请用户重确认，
            // 不静默沿用旧锚。
            phase = .preview
            if case .stalePreview = error {
                errorMessage = "分析状态已更新——请重新核对后再次确认。"
                await loadPreview()
            } else if case .staleContent = error {
                errorMessage = "文档内容已变更——本次分析作废，请重新准备。"
            } else {
                errorMessage = Self.message(for: error)
            }
        } catch {
            phase = .preview
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - 工具

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oboe.app",
        category: "AIStudyFlow")

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
