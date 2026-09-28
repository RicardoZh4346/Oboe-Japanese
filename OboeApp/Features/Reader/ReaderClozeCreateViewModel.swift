import Foundation
import OboeDomain
import OboeInfrastructure
import Observation

/// v0.7.0 S13：Reader → Cloze 创建表单视图模型（设计 §9.1–9.3 +
/// 分步计划 S13「Reader 选段→单 blank 预览→accepted answers/hint→
/// 保存；独立快照；原文删除仍可编辑/复习」）。
///
/// 不变量：
/// - 预填：句 = 截取句快照；blank = 选段/token 的**句内** UTF-16
///   坐标；accepted answers 预填表记 + 活用读音（如「見た」「みた」）
///   ——lemma（如「見る」）不自动入答案集（§9.3）。
/// - 句子可编辑：任何文本变更即 `invalidateRangeSelection`，blank
///   必须经「第 N 处」重选（与编辑路径同一判据）。
/// - 幂等：本会话一个稳定 `operationID`——任一负载字段（表单/
///   答案/牌组）变更即轮换；同负载的重试复用 receipt 回放，
///   不复制 sentence Note。
/// - 世代：请求携带容器发布世代快照；结果应用前再向活世代源
///   复核——恢复窗口内旧请求不写回、不更新 UI。
@MainActor
@Observable
final class ReaderClozeCreateViewModel {

    /// 装配输入（上下文 + 句内 blank 坐标 + 表记/原形/读音预填）。
    let draft: ReaderClozeDraft
    private let deps: ReaderMiningDependencies

    /// 表单（句/范围/目标/答案域字段）。负载变更即轮换 opID——
    /// 同 Inspector 的 didSet 防线：负载不同的重试不复用 receipt。
    var form: SentenceFormData {
        didSet { operationID = UUID() }
    }
    /// 答案编辑器原文（每行一条）。
    var answersText: String {
        didSet { operationID = UUID() }
    }
    /// 目标 home 牌组 + 追加成员牌组。
    var targetDeckID: UUID? {
        didSet { operationID = UUID() }
    }
    var additionalDeckIDs: Set<UUID> = [] {
        didSet { operationID = UUID() }
    }
    private(set) var decks: [DeckSummary] = []
    /// 提交进行中（按钮禁用防重入——opID 幂等兜底）。
    private(set) var isSaving = false
    var errorMessage: String?
    /// 提交成功后的 noteID——view 侦测后 dismiss。
    private(set) var committedNoteID: UUID?

    private var operationID = UUID()

    init(
        draft: ReaderClozeDraft,
        dependencies: ReaderMiningDependencies
    ) {
        self.draft = draft
        self.deps = dependencies
        // 答案预填：表记 + 活用读音（与表记不同才入）——lemma
        // 不自动接受（§9.3 見た/みた/見る 判据）。
        var answers = [draft.surface]
        if let reading = draft.reading,
           !reading.isEmpty, reading != draft.surface {
            answers.append(reading)
        }
        var form = SentenceFormData(
            sentence: draft.context.sentence,
            utf16Start: draft.blankUTF16Range.lowerBound,
            utf16Length: draft.blankUTF16Range.count,
            targetSurface: draft.surface,
            targetLemma: draft.lemma ?? "",
            targetReading: draft.reading ?? "",
            acceptedAnswers: answers
        )
        // 防御：预填坐标不在候选里（理论上截取即合法）→ 清空，
        // 强制用户经「第 N 处」重选，坏坐标不带病进表单。
        if form.selectedOccurrenceOrdinal == nil {
            form.invalidateRangeSelection()
        }
        self.form = form
        self.answersText = answers.joined(separator: "\n")
    }

    // MARK: - 载入

    /// 牌组目录 + 主牌组预填（与挖词同一默认口径）。
    func load() {
        Task { [deps] in
            let fetched = (try? await deps.decks.fetchDecks()) ?? []
            let primaryID = await deps.primaryDeckIDProvider?()
            decks = fetched
            targetDeckID = targetDeckID ?? primaryID ?? fetched.first?.id
        }
    }

    // MARK: - 派生

    /// 正面预览串——未选中范围时不显示（预览即考点形态，绝不
    /// 展示未遮罩的整句）。`maskedSentence` 只遮选中那一处——
    /// 句中相同词的其它出现保持原样（§9.2）。
    var maskedPreview: String? {
        guard let start = form.utf16Start,
              let length = form.utf16Length,
              let range = try? ClozeRange(
                  utf16Start: start, utf16Length: length
              )
        else { return nil }
        return ClozeValidator.maskedSentence(
            form.sentence, range: range, blank: "＿"
        )
    }

    /// 可保存 = 域校验通过（`ValidatedClozeContent` 构造成功）+
    /// 目标牌组就位。
    var canSave: Bool {
        guard !isSaving, targetDeckID != nil else { return false }
        return (try? submittedContent()) != nil
    }

    // MARK: - 保存

    /// 装配 `ReaderClozeMiningRequest` → `mineCloze`：一次原子
    /// 提交（sentence Note/卡/definition/Reader 来源/事件/receipt）。
    func save() {
        guard !isSaving, let deckID = targetDeckID else { return }
        let content: ValidatedClozeContent
        do {
            content = try submittedContent()
        } catch let error as ClozeError {
            errorMessage = Self.describe(error)
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isSaving = true
        let request = ReaderClozeMiningRequest(
            operationID: operationID,
            expectedGeneration: deps.generation,
            deckID: deckID,
            additionalDeckIDs: additionalDeckIDs,
            cloze: content,
            meaningZH: form.meaningZH
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            notes: form.notes
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            context: draft.context
        )
        Task { [deps] in
            defer { isSaving = false }
            do {
                let outcome = try await deps.service.mineCloze(request)
                guard deps.service.isExpectedGenerationAlive(
                    deps.generation
                ) else { return }
                committedNoteID = outcome.noteID
            } catch ReaderMiningError.staleGeneration {
                // 恢复后旧代请求：不写回、不更新 UI（sheet 随壳层
                // 重建）。
            } catch {
                guard deps.service.isExpectedGenerationAlive(
                    deps.generation
                ) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 表单 → 已验证内容：答案文本框按行拆分并入，表记自动并入
    /// 答案集（域约束——编辑器并入而非要求用户手写重复一遍）。
    private func submittedContent() throws -> ValidatedClozeContent {
        var submitted = form
        var answers = answersText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let surface = form.targetSurface
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !surface.isEmpty && !answers.contains(surface) {
            answers.insert(surface, at: 0)
        }
        submitted.acceptedAnswers = answers
        submitted.targetSurface = surface
        return try submitted.validatedContent()
    }

    static func describe(_ error: ClozeError) -> String {
        switch error {
        case .invalidRange:
            return "挖空位置无效——请重新选择表记在句中的出现位置。"
        case .rangeSurfaceMismatch:
            return "所选范围与表记不一致——请重选出现位置。"
        case .emptySentence:
            return "原句不能为空。"
        case .emptyAcceptedAnswers:
            return "至少需要一个可接受答案。"
        case .acceptedAnswersMissingSurface:
            return "可接受答案必须包含挖空表记。"
        case .staleContentVersion:
            return "内容版本冲突，请关闭后重试。"
        case .inconsistentCardLink:
            return "卡片关联已损坏，未写入。"
        case .snapshotHashMismatch:
            return "快照校验失败——数据不一致，未写入。"
        case .unsupportedRangeVersion:
            return "范围编码版本不受支持，未写入。"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
