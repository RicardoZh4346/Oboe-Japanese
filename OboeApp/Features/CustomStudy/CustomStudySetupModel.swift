import Foundation
import OboeDomain
import Observation

/// S09 专项学习设置页模型（v0.6.0，设计 §7.1/§7.3）。
///
/// 职责与约定：
/// - 维护表单状态并组装 `CustomStudyFilter`：随机序预览固定
///   `previewRandomSeed`（同条件反复预览可重放）；
///   `earlyReviewWindowDays` 仅 `preset == .earlyReview` 时随 filter
///   生效，其余 preset 回落默认值；
/// - `refreshPreview`：先过 `CustomStudyService.validate`，再用与
///   `buildQueue` 同一 WHERE 编译的 `countQueueCandidates` 计数；
///   单调递增世代号丢弃乱序/过期响应（与
///   `DictionarySearchViewModel` 同构）；
/// - `start`：随机序换成新 seed（毫秒时间戳）——每次会话队列不同，
///   但 seed 冻结进 `filter_json` 仍可重放；随后 validate →
///   `buildQueue` → `CustomStudyQueue.ordered` 冻结 → `makeSession`
///   （计入调度 → `.scheduled`，否则 `.practiceOnly`）→
///   `createSession` 原子落库（同事务打断现存 active）。
@MainActor
@Observable
final class CustomStudySetupModel {
    /// nil = 自定义范围（纯属性过滤，不套用规则型 preset）。
    var preset: CustomStudyPreset?
    /// 空集 = 不限制牌组（EXISTS 维度不编译）。
    var deckIDs: Set<UUID>
    var favoriteOnly = false
    /// 空集 = 不限制 JLPT 等级。
    var jlptLevels: Set<JLPTLevel> = []
    var earlyReviewWindowDays = CustomStudyService.defaultEarlyReviewWindowDays
    var limit = CustomStudyService.defaultQueueLimit
    var order: CustomStudyOrder = .due
    /// 「计入调度」开关：默认关 = practiceOnly（不写 FSRS/新词额度/
    /// 复习统计）；开 = scheduled（评分走真实 FSRS 提交）。
    var includeInSchedule = false

    private(set) var decks: [DeckSummary] = []
    /// nil = 尚未取得预览（载入中/校验或查询失败）。
    private(set) var candidateCount: Int?
    private(set) var isLoadingPreview = false
    private(set) var isStarting = false
    private(set) var errorMessage: String?

    private let customStudyService: CustomStudyService
    private let customStudyRepository: any CustomStudyRepository
    private let deckService: DeckManagementService
    /// 预览用固定 seed：同 seed + 同候选集必须完全可复现；
    /// `start` 时会换成本次会话专属的新 seed。
    private static let previewRandomSeed: Int64 = 1
    /// 预览响应世代号：被取代的迟到响应直接丢弃。
    private var previewGeneration = 0

    init(
        customStudyService: CustomStudyService,
        customStudyRepository: any CustomStudyRepository,
        deckService: DeckManagementService,
        initialDeckID: UUID? = nil
    ) {
        self.customStudyService = customStudyService
        self.customStudyRepository = customStudyRepository
        self.deckService = deckService
        // 入口带入的牌组（如牌组详情页）在 init 即预选，首个预览即
        // 按该范围计数；`load` 只负责填充可选列表。
        self.deckIDs = initialDeckID.map { [$0] } ?? []
    }

    /// 当前表单组装的过滤条件（Hashable，可作 `.task(id:)` 驱动预览）。
    var filter: CustomStudyFilter {
        CustomStudyFilter(
            preset: preset,
            deckIDs: deckIDs,
            jlptLevels: jlptLevels,
            favoriteOnly: favoriteOnly,
            earlyReviewWindowDays: preset == .earlyReview
                ? earlyReviewWindowDays
                : CustomStudyService.defaultEarlyReviewWindowDays,
            limit: limit,
            order: order,
            randomSeed: order == .random ? Self.previewRandomSeed : nil
        )
    }

    /// 开始按钮可用性：已知候选 > 0 且未在启动中。
    var canStart: Bool {
        (candidateCount ?? 0) > 0 && !isStarting
    }

    /// 载入可选牌组列表（`initialDeckID` 预选已在 init 完成）。
    func load() async {
        do {
            decks = try await deckService.fetchDecks()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "无法载入牌组列表：\(error.localizedDescription)"
        }
    }

    /// 预览计数：校验失败只显示本地文案（UI 控件已约束边界，这里
    /// 是防御兜底）；查询失败同样收敛为 errorMessage。
    func refreshPreview() async {
        previewGeneration += 1
        let generation = previewGeneration
        let currentFilter = filter
        do {
            try customStudyService.validate(currentFilter)
        } catch {
            guard generation == previewGeneration else { return }
            candidateCount = nil
            errorMessage = Self.message(for: error)
            return
        }
        isLoadingPreview = true
        do {
            let count = try await customStudyRepository.countQueueCandidates(
                filter: currentFilter,
                context: CustomStudyQueueContext(now: Date())
            )
            guard generation == previewGeneration, !Task.isCancelled else { return }
            candidateCount = count
            isLoadingPreview = false
        } catch is CancellationError {
            if generation == previewGeneration { isLoadingPreview = false }
        } catch {
            guard generation == previewGeneration else { return }
            candidateCount = nil
            isLoadingPreview = false
            errorMessage = "无法计算候选数量：\(error.localizedDescription)"
        }
    }

    /// 启动会话：成功返回冻结的 session 由调用方推进复习页；
    /// 失败置 `errorMessage` 返回 nil。
    func start() async -> CustomStudySession? {
        guard !isStarting else { return nil }
        var startFilter = filter
        if startFilter.order == .random {
            // 每次会话换新 seed：队列呈现不同，但 seed 随 filter 冻结
            // 进 filter_json，回放/恢复仍完全可复现。
            startFilter.randomSeed = Int64(Date().timeIntervalSince1970 * 1_000)
        }
        do {
            try customStudyService.validate(startFilter)
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
        isStarting = true
        defer { isStarting = false }
        do {
            let now = Date()
            let context = CustomStudyQueueContext(now: now)
            let cardIDs = try await customStudyRepository.buildQueue(
                filter: startFilter,
                context: context
            )
            guard !cardIDs.isEmpty else {
                errorMessage = "当前筛选条件下没有可学习的卡片。"
                return nil
            }
            let queue = CustomStudyQueue.ordered(
                cardIDs: cardIDs,
                order: startFilter.order,
                randomSeed: startFilter.randomSeed,
                generatedAt: now
            )
            let session = try customStudyService.makeSession(
                filter: startFilter,
                queue: queue,
                mode: includeInSchedule ? .scheduled : .practiceOnly,
                now: now
            )
            try await customStudyRepository.createSession(session)
            return session
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    func toggleDeckSelection(_ deckID: UUID) {
        if deckIDs.contains(deckID) {
            deckIDs.remove(deckID)
        } else {
            deckIDs.insert(deckID)
        }
    }

    func toggleJLPTLevel(_ level: JLPTLevel) {
        if jlptLevels.contains(level) {
            jlptLevels.remove(level)
        } else {
            jlptLevels.insert(level)
        }
    }

    /// alert 关闭时清掉非致命错误。
    func clearError() {
        errorMessage = nil
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let CustomStudyError.invalidQueueLimit(limit):
            return "队列上限需在 1 至 \(CustomStudyService.maximumQueueLimit) 张之间，当前为 \(limit) 张。"
        case let CustomStudyError.invalidEarlyReviewWindow(days):
            return "提前复习窗口需在 \(CustomStudyService.earlyReviewWindowDaysRange.lowerBound) 至 \(CustomStudyService.earlyReviewWindowDaysRange.upperBound) 天之间，当前为 \(days) 天。"
        case CustomStudyError.missingRandomSeed:
            return "随机顺序缺少固定种子，请重新选择排序方式。"
        case CustomStudyError.queueExceedsLimit:
            return "候选数量超过队列上限，请调整筛选后重试。"
        case CustomStudyError.queueFilterMismatch:
            return "队列与筛选条件不一致，请重试。"
        case CustomStudyError.sessionNotActive:
            return "这次专项学习已结束。"
        case CustomStudyRepositoryError.sessionAlreadyExists:
            return "会话标识冲突，请重试。"
        default:
            return error.localizedDescription
        }
    }
}
