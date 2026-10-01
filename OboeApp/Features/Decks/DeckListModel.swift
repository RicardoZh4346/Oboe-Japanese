import Foundation
import Observation
import OboeDomain
import OboeInfrastructure

@MainActor
@Observable
final class DeckListModel {
    let service: DeckManagementService
    private let studyService: StudySessionService
    private let historyService: StudyHistoryService
    /// S18：学习进度投影 + 观察流门面（共享注入；nil → 进度行
    /// 隐藏，退化为无进度显示）。
    private let learningProgress: (any LearningProgressProviding)?
    /// S18：文档↔牌组绑定 + coverage v2 活算门面。
    private let studyDecks: (any StudyDeckSurfacing)?

    var decks: [DeckSummary] = []
    var todayStatistics: TodayReviewStatistics?
    var primaryDeckID: UUID?
    var deletionImpacts: [UUID: DeckDeletionImpact] = [:]
    var isLoading = true
    var errorMessage: String?
    private(set) var deckLoadErrorMessage: String?

    /// S18：deckID → 进度聚合（无覆盖 unit 的 deck `progress =
    /// nil`——UI 显示「—」而非 0%）。
    private(set) var progressByDeck: [UUID: DeckLearningProgress] = [:]
    /// S18：已绑定学习牌组的文档列表（Deck 详情文章覆盖区 +
    /// 跨 Feature 导航用）。
    private(set) var studyDeckLinks: [StudyDeckLink] = []
    /// S18：文档 → coverage v2 活算结果（只含当前在看的绑定文
    /// 档——经 `watchCoverage` 登记）。
    private(set) var coverageByDocument: [UUID: ReaderCoverageV2.Result] = [:]
    /// S18：学习表面内容签名——每次观察流发射 +1。Deck 详情页
    /// `.task(id:)` 据此重拉成员/卡片内容（评级、启用切换、撤销、
    /// 成员增删、跨窗口写都驱动它）。
    private(set) var contentSignature: Int = 0

    /// 正在展示其覆盖区的绑定文档集合（观察流发射时只重投影这
    /// 些，不为库内全部文档跑投影）。
    private var watchedCoverageDocumentIDs: Set<UUID> = []

    /// S18 观察任务：由 `startObserving()` 幂等启动、随 model
    /// 生命周期存续——详情页/二级目的地不再需要视图级 `.task`
    /// 反复建流，页面被栈保留期间跨窗口写也能持续同步。
    @ObservationIgnored private var deckObservationTask: Task<Void, Never>?
    @ObservationIgnored private var progressObservationTask: Task<Void, Never>?

    deinit {
        deckObservationTask?.cancel()
        progressObservationTask?.cancel()
    }

    /// 幂等启动 deck 摘要 + 学习表面两条观察流。宿主（Tab 页 /
    /// 详情页 / AI 摘要目的地）挂载即调——重复调用 no-op；观察
    /// 不随单个页面的 push/pop 中断（model 生命周期即观察生命
    /// 周期）。
    func startObserving() {
        if deckObservationTask == nil {
            deckObservationTask = Task { await observeDecks() }
        }
        if progressObservationTask == nil {
            progressObservationTask = Task { await observeLearningProgress() }
        }
    }

    init(
        service: DeckManagementService,
        studyService: StudySessionService,
        historyService: StudyHistoryService,
        learningProgress: (any LearningProgressProviding)? = nil,
        studyDecks: (any StudyDeckSurfacing)? = nil
    ) {
        self.service = service
        self.studyService = studyService
        self.historyService = historyService
        self.learningProgress = learningProgress
        self.studyDecks = studyDecks
    }

    func observeDecks() async {
        do {
            for try await decks in service.observeDecks() {
                guard !Task.isCancelled else {
                    return
                }
                self.decks = decks
                await refreshTodayStatistics()
                self.isLoading = false
            }
        } catch is CancellationError {
            // SwiftUI cancels this task with the view lifecycle.
        } catch {
            self.isLoading = false
            self.errorMessage = Self.message(for: error)
        }
    }

    /// S18：订阅共享学习表面流。发射即持久态已变——同步进度图、
    /// 绑定、内容签名，并对「正在看的绑定文档」重算 coverage v2；
    /// 全程只读投影，不触 AI/形态分析。
    func observeLearningProgress() async {
        guard let learningProgress else { return }
        do {
            for try await update in learningProgress.observeProgress() {
                guard !Task.isCancelled else { return }
                progressByDeck = update.progressByDeck
                studyDeckLinks = update.studyDeckLinks
                contentSignature += 1
                await refreshWatchedCoverage()
                await refreshTodayStatistics()
            }
        } catch is CancellationError {
            // View lifecycle cancellation.
        } catch {
            // 失流降级为手动刷新（不阻断列表本身）。
            errorMessage = Self.message(for: error)
        }
    }

    /// Deck 详情页登记其绑定文档——观察流发射时重算其覆盖率。
    func watchCoverage(for documentID: UUID) async {
        watchedCoverageDocumentIDs.insert(documentID)
        await refreshCoverage(for: [documentID])
    }

    func unwatchCoverage(for documentID: UUID) {
        watchedCoverageDocumentIDs.remove(documentID)
    }

    private func refreshWatchedCoverage() async {
        await refreshCoverage(for: watchedCoverageDocumentIDs)
    }

    private func refreshCoverage(for documentIDs: Set<UUID>) async {
        guard let studyDecks, !documentIDs.isEmpty else { return }
        do {
            let results = try await studyDecks.documentCoverageResults(
                forDocumentIDs: Array(documentIDs)
            )
            for documentID in documentIDs {
                coverageByDocument[documentID] = results[documentID]
            }
        } catch is CancellationError {
        } catch {
            // 覆盖率投影失败不阻断主表面——保留下次发射重试。
        }
    }

    func createDeck(named name: String) async -> Bool {
        do {
            try await service.createDeck(named: name)
            await refreshDecks()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func renameDeck(id: UUID, to name: String) async -> Bool {
        do {
            guard try await service.renameDeck(id: id, to: name) else {
                errorMessage = "这个牌组已不存在。"
                return false
            }
            await refreshDecks()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func deleteEmptyDeck(id: UUID) async -> Bool {
        do {
            switch try await service.deleteEmptyDeck(id: id) {
            case .deleted:
                await refreshDecks()
                return true
            case .notFound:
                errorMessage = "这个牌组已不存在。"
            case let .notEmpty(noteCount, cardCount):
                errorMessage = "牌组包含 \(noteCount) 个知识点和 \(cardCount) 张卡片，请重新选择移动内容或连同内容删除。"
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
        return false
    }

    func deleteDeck(id: UUID, strategy: DeckDeletionStrategy) async -> Bool {
        do {
            switch try await service.deleteDeck(id: id, strategy: strategy) {
            case .deleted:
                await refreshDecks()
                return true
            case .sourceNotFound:
                errorMessage = "这个牌组已不存在。"
            case .destinationNotFound:
                errorMessage = "目标牌组已不存在。"
            case .destinationMatchesSource:
                errorMessage = "目标牌组不能与待删除牌组相同。"
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
        return false
    }

    /// 删除确认页预览：独占（将删除）/共享（仅解除关系）计数
    /// （设计 §4.8）。预览失败不阻断流程，文案回退为汇总计数。
    func loadDeletionImpact(for deckID: UUID) async {
        do {
            deletionImpacts[deckID] = try await service.previewDeletionImpact(id: deckID)
        } catch {}
    }

    @discardableResult
    func refreshDecks() async -> Bool {
        do {
            decks = try await service.fetchDecks()
            deckLoadErrorMessage = nil
            errorMessage = nil
            await refreshTodayStatistics()
            isLoading = false
            return true
        } catch {
            isLoading = false
            deckLoadErrorMessage = Self.message(for: error)
            errorMessage = deckLoadErrorMessage
            return false
        }
    }

    func todayTasks(for deckID: UUID) -> DeckTodayTaskCount {
        todayStatistics?.tasks(for: deckID)
            ?? DeckTodayTaskCount(deckID: deckID, newCount: 0, reviewCount: 0)
    }

    /// S18：某牌组的学习进度聚合；nil = 观察流尚未发射或依赖缺席。
    func learningProgress(for deckID: UUID) -> DeckLearningProgress? {
        progressByDeck[deckID]
    }

    /// S18：某牌组绑定的 Reader 文档（至多一个，v24 UNIQUE）。
    func studyDeckLink(for deckID: UUID) -> StudyDeckLink? {
        studyDeckLinks.first { $0.deckID == deckID }
    }

    /// S18：某文档当前的 coverage v2 活算缓存；nil = 未登记/文档
    /// 不存在/尚无投影。
    func coverage(forDocumentID documentID: UUID) -> ReaderCoverageV2.Result? {
        coverageByDocument[documentID]
    }

    /// 切换主牌组会立即重算当日新卡分配：额度先满足主牌组，剩余轮转其他牌组。
    func setPrimaryDeck(_ deckID: UUID?) async {
        do {
            _ = try await studyService.setPrimaryDeck(
                deckID,
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            primaryDeckID = deckID
            await refreshTodayStatistics()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func refreshTodayStatistics() async {
        do {
            let plan = try await studyService.buildTodayPlan(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            let settings = try await studyService.loadLearningSettings(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            primaryDeckID = settings.primaryDeckID
            todayStatistics = try await historyService.fetchTodayStatistics(
                studyDayID: plan.studyDay.id
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case DeckNameValidationError.empty:
            return "牌组名称不能为空。"
        case let DeckNameValidationError.tooLong(maximum):
            return "牌组名称不能超过 \(maximum) 个字符。"
        case DeckNameValidationError.containsLineBreakOrControlCharacter:
            return "牌组名称不能包含换行或控制字符。"
        default:
            return error.localizedDescription
        }
    }
}
