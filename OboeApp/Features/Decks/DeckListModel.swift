import Foundation
import Observation
import OboeDomain

@MainActor
@Observable
final class DeckListModel {
    let service: DeckManagementService
    private let studyService: StudySessionService
    private let historyService: StudyHistoryService

    var decks: [DeckSummary] = []
    var todayStatistics: TodayReviewStatistics?
    var primaryDeckID: UUID?
    var deletionImpacts: [UUID: DeckDeletionImpact] = [:]
    var isLoading = true
    var errorMessage: String?

    init(
        service: DeckManagementService,
        studyService: StudySessionService,
        historyService: StudyHistoryService
    ) {
        self.service = service
        self.studyService = studyService
        self.historyService = historyService
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

    func refreshDecks() async {
        do {
            decks = try await service.fetchDecks()
            await refreshTodayStatistics()
            isLoading = false
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func todayTasks(for deckID: UUID) -> DeckTodayTaskCount {
        todayStatistics?.tasks(for: deckID)
            ?? DeckTodayTaskCount(deckID: deckID, newCount: 0, reviewCount: 0)
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
