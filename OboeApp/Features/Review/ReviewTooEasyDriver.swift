import Foundation
import Observation
import OboeDomain

/// S16（设计 §12.2/§12.3）：Too Easy 的会话态——同 unit sibling
/// 驱逐集、typed Undo 锚点与跨窗口 flag 观察，全部按会话生命周期
/// 走；`ReviewViewModel` 以计算属性转发，与评分提交互不干扰。
///
/// 语义要点：
/// - Too Easy 不是评分——不写 ReviewLog、不动 FSRS、不消耗额度。
/// - 驱逐集（evictedNoteIDs/unitIDs）在应用 flag 成功后建立，
///   `resetPresentedSession` 清空；**撤销不复活已驱逐卡**——下个
///   学习会话按持久化资格重新纳入。
/// - Undo 凭 eventID+afterRevision 作 CAS；约 10 秒的横幅窗口是
///   UI 层的短期 affordance，窗口冻结常量见
///   `ReviewViewModel.tooEasyUndoWindowSeconds`。
@MainActor
@Observable
final class ReviewTooEasyCoordinator {
    /// typed Undo 锚点：本窗口刚提交的 tooEasySet 事件 + CAS 期望
    /// revision。`expiresAt` 之后横幅隐藏、栈内条目失效。
    struct PendingUndo: Equatable {
        let unitID: UUID
        let eventID: UUID
        let beforeValue: Bool
        /// 提交后的 flag revision（`expectedFlagRevision`）。
        let afterRevision: Int64
        /// 应用时的当前卡 id（诊断/展示用——撤销不把它塞回会话）。
        let evictedCardID: UUID
        let expiresAt: Date
    }

    /// 本会话被 flag 驱逐的 Note/Unit——跨 refresh/resize 存活；
    /// `scopedNowItems`/`scopedLaterItems` 与 custom 队列的惰性跳卡
    /// 都消费这两个集合。
    var evictedNoteIDs: Set<UUID> = []
    var evictedUnitIDs: Set<UUID> = []
    var pendingUndo: PendingUndo?
    /// 撤销成功/过期等短提示（横幅不带按钮形态）。
    var noticeMessage: String?
    var isApplying = false
    var errorMessage: String?
    var expiryTask: Task<Void, Never>?
    /// flag/link 观察订阅（跨窗口实时同步）；会话只建一次。
    var observationTask: Task<Void, Never>?
}

extension ReviewViewModel {
    /// 技术文档 §12.3：「成功后显示约 10 秒 Undo」的冻结窗口常量。
    static let tooEasyUndoWindowSeconds: TimeInterval = 10

    // MARK: - 转发状态（ReviewTooEasyCoordinator）

    var pendingTooEasyUndo: ReviewTooEasyCoordinator.PendingUndo? {
        tooEasy.pendingUndo
    }
    var isApplyingTooEasy: Bool {
        get { tooEasy.isApplying }
        set { tooEasy.isApplying = newValue }
    }
    var tooEasyErrorMessage: String? {
        get { tooEasy.errorMessage }
        set { tooEasy.errorMessage = newValue }
    }
    var tooEasyNoticeMessage: String? {
        get { tooEasy.noticeMessage }
        set { tooEasy.noticeMessage = newValue }
    }
    var evictedTooEasyNoteIDs: Set<UUID> {
        tooEasy.evictedNoteIDs
    }

    // MARK: - Too Easy 应用

    /// Too Easy 按钮可用性：仅词汇三方向卡（`SchedulingEligibility`
    /// .vocabularyTemplateKinds 冻结集合——cloze/grammar 恒 false）。
    /// 问题面同样可用——看到题面就确认「太简单」是合法操作；听力卡
    /// 应用时先停音频再走驱逐。
    var canApplyTooEasy: Bool {
        learningUnits != nil
            && card.map {
                SchedulingEligibility.vocabularyTemplateKinds
                    .contains($0.content.templateKind)
            } == true
            && !isMutating && !isApplyingTooEasy && !isLoading
            && !hasCommittedCurrentCard && pendingSubmission == nil
    }

    /// 应用 Too Easy：flag CAS 置位 → 同 unit 全部 Note/卡入驱逐集
    /// → 冻结队列立即剔除 → 选下一张。失败只提示，不猜 unit。
    func applyTooEasy() async {
        guard canApplyTooEasy,
              let units = learningUnits,
              let card else { return }
        let content = card.content
        isApplyingTooEasy = true
        defer { isApplyingTooEasy = false }
        tooEasy.errorMessage = nil
        // 先停音频再驱逐——听力卡的题面播放/例句朗读；迟到的回调
        // 由 requestID/presentationID 轮换拦截，不会落到新卡。
        speechService.stop()
        listeningPromptRequestID = nil
        listeningPromptStatus = .idle
        do {
            // note → unit 必须经 link 定位；无 link 的 Note 无从
            // 推断 unit——拒绝操作而不是按词形猜测（§12.4）。
            guard let link = try await units.fetchLink(noteID: content.noteID)
            else {
                tooEasy.errorMessage = "这张卡没有可判定的学习单元，未标记。"
                return
            }
            let unitID = link.unitID
            let flagOps = LearningUnitFlagOperator(flags: units)
            let flag = try await flagOps.set(
                true, unitID: unitID, operationID: UUID(), at: Date()
            )
            guard flag.tooEasy else {
                tooEasy.errorMessage = "标记未生效，请重试。"
                return
            }
            // Undo 锚点从事件史取——同 operationID 幂等回放不新增
            // 事件时仍能找到最近未撤销的 tooEasySet。
            let anchor = try await flagOps.undoAnchor(unitID: unitID)

            // 同 unit sibling 全量驱逐（共享 unit 的其他 Note 在内）。
            let links = try await units.fetchLinks(unitID: unitID)
            tooEasy.evictedNoteIDs.formUnion(links.map(\.noteID))
            tooEasy.evictedUnitIDs.insert(unitID)
            if isCustomSession {
                await evictUnitCardsFromCustomQueue(unitID: unitID)
            }

            if let anchor {
                tooEasy.pendingUndo = ReviewTooEasyCoordinator.PendingUndo(
                    unitID: unitID,
                    eventID: anchor.eventID,
                    beforeValue: anchor.beforeValue,
                    afterRevision: anchor.afterRevision,
                    evictedCardID: content.cardID,
                    expiresAt: Date().addingTimeInterval(
                        Self.tooEasyUndoWindowSeconds
                    )
                )
                submission.undoActions.append(.tooEasy(eventID: anchor.eventID))
                scheduleTooEasyUndoExpiry(eventID: anchor.eventID)
            }
            // flag 已生效——在途的失败评分失去意义（提交复核会因
            // 资格拒绝），清掉重试态。
            pendingSubmission = nil
            submissionErrorMessage = nil
            await loadNextCard()
        } catch {
            tooEasy.errorMessage = LearningUnitFlagOperator.message(for: error)
        }
    }

    /// typed Undo（不走 FSRS review undo）：凭锚点 CAS 撤销 flag。
    /// 卡不回塞会话——驱逐集保持到会话重置。
    func undoTooEasyFlag() async {
        guard let pending = tooEasy.pendingUndo,
              let units = learningUnits,
              !isMutating, !isLoading else { return }
        guard pending.expiresAt > Date() else {
            tooEasy.pendingUndo = nil
            return
        }
        isUndoing = true
        defer { isUndoing = false }
        do {
            _ = try await LearningUnitFlagOperator(flags: units).undo(
                LearningUnitFlagOperator.UndoAnchor(
                    unitID: pending.unitID,
                    eventID: pending.eventID,
                    beforeValue: pending.beforeValue,
                    afterRevision: pending.afterRevision
                ),
                operationID: UUID(),
                at: Date()
            )
            tooEasy.pendingUndo = nil
            submission.undoActions.removeAll {
                $0 == .tooEasy(eventID: pending.eventID)
            }
            showTooEasyNotice(
                "已撤销「太简单」——这些卡从下次学习会话起恢复排期。"
            )
        } catch {
            tooEasy.errorMessage = LearningUnitFlagOperator
                .message(for: error)
            // CAS 类失败（revision 不符/事件已撤销/事件缺失）说明
            // 状态已被其他窗口改动——锚点失效，不再提供撤销。
            switch error as? LearningUnitRepositoryError {
            case .flagRevisionConflict, .eventAlreadyUndone,
                 .eventNotFound, .unitNotFound:
                tooEasy.pendingUndo = nil
            default:
                break
            }
        }
    }

    /// 卡是否被本会话驱逐（tooEasy）：词汇三方向卡中，本窗口驱逐集
    /// 或**另一窗口/界面**新写入的 flag 都算——后者按
    /// `SchedulingEligibility.isEligible` 依当前会话模式复核（D15：
    /// practiceOnly+includeMastered 的会话不因外部 flag 踢卡）。
    func isSessionEvicted(content: ReviewCardContent) async -> Bool {
        guard SchedulingEligibility.vocabularyTemplateKinds
            .contains(content.templateKind),
              let units = learningUnits else { return false }
        if tooEasy.evictedNoteIDs.contains(content.noteID) { return true }
        guard let link = try? await units.fetchLink(noteID: content.noteID),
              let flag = try? await units.fetchFlag(unitID: link.unitID),
              flag.tooEasy else { return false }
        let mode = custom.session?.mode ?? scope.customMode ?? .scheduled
        let includeMastered = custom.session?.filter.includeMastered ?? false
        let eligible = SchedulingEligibility.isEligible(
            templateKind: content.templateKind,
            isEnabled: true,
            unitTooEasy: true,
            mode: mode,
            includeMastered: includeMastered
        )
        if !eligible {
            tooEasy.evictedNoteIDs.insert(content.noteID)
            tooEasy.evictedUnitIDs.insert(link.unitID)
        }
        return !eligible
    }

    /// 冻结队列立即剔除同 unit 卡（S16：custom 队列是内存冻结集，
    /// 不能只等惰性跳过）。优先走批量映射；桩件缺映射时逐卡解析
    /// noteID 兜底（队列有界）。
    private func evictUnitCardsFromCustomQueue(unitID: UUID) async {
        if let mapping = learningUnits as? any LearningUnitCardMapping {
            let siblingCardIDs =
                (try? await mapping.fetchLinkedCardIDs(unitID: unitID)) ?? []
            custom.remainingCardIDs.removeAll {
                siblingCardIDs.contains($0)
            }
            return
        }
        var evictedCardIDs = Set<UUID>()
        for cardID in custom.remainingCardIDs {
            guard let content = try? await service
                .loadReviewCard(cardID: cardID).content,
                  tooEasy.evictedNoteIDs.contains(content.noteID)
            else { continue }
            evictedCardIDs.insert(cardID)
        }
        custom.remainingCardIDs.removeAll { evictedCardIDs.contains($0) }
    }

    // MARK: - 横幅/观察

    /// 约 10 秒窗口后撤销横幅失效——栈内对应条目一并清除
    /// （过期锚点不再响应 toolbar/横幅撤销）。
    private func scheduleTooEasyUndoExpiry(eventID: UUID) {
        tooEasy.expiryTask?.cancel()
        tooEasy.expiryTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(Self.tooEasyUndoWindowSeconds)
            )
            guard let self, !Task.isCancelled else { return }
            if self.tooEasy.pendingUndo?.eventID == eventID {
                self.tooEasy.pendingUndo = nil
            }
            self.submission.undoActions.removeAll {
                $0 == .tooEasy(eventID: eventID)
            }
        }
    }

    private func showTooEasyNotice(_ message: String) {
        tooEasy.noticeMessage = message
        let notice = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            if self.tooEasy.noticeMessage == notice {
                self.tooEasy.noticeMessage = nil
            }
        }
    }

    /// flag/link 观察订阅（§14.3）：同 pool 的其他窗口/界面（另一
    /// Review、Note 详情、Inspector）提交 flag 或变更 link 即触发
    /// 一次 preserving-refresh——计划重算自然驱逐当前卡；custom
    /// 会话由惰性跳卡复核。会话级单订阅，会话重置时取消。
    func startUnitChangeObservationIfNeeded() {
        guard tooEasy.observationTask == nil,
              let observing =
                learningUnits as? any LearningUnitFlagObserving
        else { return }
        tooEasy.observationTask = Task { [weak self] in
            do {
                for try await _ in observing.observeChanges() {
                    guard let self, !Task.isCancelled else { return }
                    await self.refresh(preservingCurrentCard: true)
                }
            } catch {
                // 流失败即停——下一次 refresh 仍会重新建立。
            }
            self?.tooEasy.observationTask = nil
        }
    }
}
