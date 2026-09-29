import Foundation
import OboeDomain
import OboeInfrastructure
import Observation

/// v0.7.5 S17 三模式译文 VM（§14.2）：水合零网络、双语折叠、
/// 缺失/失败占位、显式翻译/重译。
///
/// # 渲染语义
///
/// - `outcomes`：`ReaderTranslationAssembly.assemble` 的块级装配结果
///   ——`source_hash` 与活动原文不符的行在水合阶段已过滤，**译文永不
///   出现在不匹配原文下**（旧译文留在库里但取不到）。
/// - 原文坐标只来自 `ReaderDocumentViewModel` 的块/序数：译文层不改写
///   任何原文锚点，阅读位置始终按源块记。
/// - 显式翻译/重译走 `orchestrator.translate`：失败块记归因码（行内
///   占位 + 重试），成功块经 publish 原子翻转后重新水合——**旧译文在
///   新结果成功落库前恒为 current**。
@MainActor
@Observable
final class ReaderTranslationViewModel {

    /// 三显示模式。
    enum DisplayMode: String, CaseIterable, Sendable {
        /// 只显示原文（现状行为不变）。
        case original
        /// 原文 + 译文逐段对照（译文可折叠）。
        case bilingual
        /// 只显示译文（按原文 locator 排序；缺译给占位 + 看原文）。
        case translatedOnly
    }

    /// 单块译文渲染态（双语注入段与译文行共用——`ready` 时正文取
    /// `outcomes`；占位态渲染由调用侧决定文案）。
    enum BlockRender: Equatable, Sendable {
        /// 无可用译文（无行/source_hash 不符被过滤）。
        case missing
        /// 请求在途（派发/收束间）。
        case requesting
        /// 上次显式派发失败——占位 + 重试。
        case failed(code: String)
        /// 有装配结果（complete 全译 / partial 缺段见 outcomes）。
        case ready
    }

    /// `ReaderTranslationSegment` 的 VM 侧别名（视图共享类型）。
    typealias Segment = ReaderTranslationSegment

    var mode: DisplayMode = .original
    /// blockID → 装配结果（无条目 = 无可用译文）。
    private(set) var outcomes: [UUID: ReaderTranslationAssembly.Outcome] =
        [:]
    /// blockID → 上次显式派发的归因码（成功/换章即清）。
    private(set) var failedCodes: [UUID: String] = [:]
    /// 派发在途的块。
    private(set) var inFlight: Set<UUID> = []
    /// 双语模式折叠的块。
    private(set) var collapsed: Set<UUID> = []
    /// 整章翻译进行中（入口禁用）。
    private(set) var chapterTranslating = false
    private(set) var errorMessage: String?

    private let dependencies: ReaderTranslationDependencies
    private var document: ReaderDocumentMetadata?
    private var chapterOrdinal = 0
    private var blocks: [ReaderBlock] = []
    /// 水合代次：切章后的旧水合结果不得覆盖新章。
    private var hydrateGeneration = 0

    init(dependencies: ReaderTranslationDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - 章上下文与水合（零网络）

    /// 章上下文刷新：document/blocks 变化后调用——本地行重锚 +
    /// 装配，永不触发网络。
    func refresh(
        document: ReaderDocumentMetadata?,
        chapterOrdinal: Int,
        blocks: [ReaderBlock]
    ) async {
        self.document = document
        self.chapterOrdinal = chapterOrdinal
        self.blocks = blocks
        inFlight = []
        failedCodes = [:]
        collapsed = []
        await hydrate()
    }

    private func hydrate() async {
        hydrateGeneration += 1
        let generation = hydrateGeneration
        guard let document, !blocks.isEmpty else {
            outcomes = [:]
            return
        }
        do {
            let hydrated = try await dependencies.orchestrator.hydrate(
                documentID: document.id,
                language: dependencies.language,
                chapterOrdinal: chapterOrdinal,
                blocks: blocks)
            guard generation == hydrateGeneration else { return }
            outcomes = hydrated
        } catch {
            guard generation == hydrateGeneration else { return }
            outcomes = [:]
        }
    }

    // MARK: - 渲染态

    /// 块渲染态（双语/译文两路共用）。
    func renderState(for blockID: UUID) -> BlockRender {
        if inFlight.contains(blockID) { return .requesting }
        if let outcome = outcomes[blockID], outcome != .none {
            return .ready
        }
        if let code = failedCodes[blockID] { return .failed(code: code) }
        return .missing
    }

    /// 双语模式注入段（折叠置占位；ready 取装配文本——partial
    /// 拼已覆盖片段，缺段由译文行侧占位提示）。
    func segment(for blockID: UUID) -> Segment {
        switch renderState(for: blockID) {
        case .requesting: return .requesting
        case .missing: return .missing
        case .failed: return .failed
        case .ready:
            if collapsed.contains(blockID) { return .collapsed }
            switch outcomes[blockID] {
            case let .complete(text, _): return .text(text)
            case let .partial(segments, _):
                return .partial(text: segments.map(\.text).joined())
            default: return .missing
            }
        }
    }

    /// 全部当前块的渲染段表（`ReaderTextView.translations` 入参）。
    var bilingualSegments: [UUID: Segment] {
        var map: [UUID: Segment] = [:]
        map.reserveCapacity(blocks.count)
        for block in blocks {
            map[block.id] = segment(for: block.id)
        }
        return map
    }

    func toggleCollapse(_ blockID: UUID) {
        if collapsed.contains(blockID) {
            collapsed.remove(blockID)
        } else {
            collapsed.insert(blockID)
        }
    }

    // MARK: - 显式翻译 / 重译

    /// 整章补译：只补缺失/不完整块——已有完整译文的块不重发。
    func translateChapter() async {
        guard !chapterTranslating, document != nil else { return }
        chapterTranslating = true
        defer { chapterTranslating = false }
        await runTargets(blocks.map(\.id), onlyMissing: true)
    }

    /// 全章重译（显式覆盖——旧译文在新结果成功前仍 current）。
    func retranslateChapter() async {
        guard !chapterTranslating, document != nil else { return }
        chapterTranslating = true
        defer { chapterTranslating = false }
        await runTargets(blocks.map(\.id), onlyMissing: false)
    }

    /// 单块翻译（缺失/失败/部分缺段路径——已有完整覆盖则跳过）。
    func translate(_ blockID: UUID) async {
        await runTargets([blockID], onlyMissing: true)
    }

    /// 单块显式重译（强制重发——旧译文在新结果成功前原样保留）。
    func retranslate(_ blockID: UUID) async {
        await runTargets([blockID], onlyMissing: false)
    }

    private func runTargets(
        _ blockIDs: [UUID], onlyMissing: Bool
    ) async {
        guard let document else { return }
        var targets: [ReaderTranslationOrchestrator.Target] = []
        targets.reserveCapacity(blockIDs.count)
        for id in blockIDs {
            guard let index = blocks.firstIndex(where: { $0.id == id })
            else { continue }
            // 上块尾 400 Character——与 AIStudyPreparationService 的
            // planner 上下文口径一致。
            let previous = index > 0 ? blocks[index - 1].text : ""
            targets.append(.init(
                block: blocks[index],
                chapterOrdinal: chapterOrdinal,
                context: String(previous.suffix(400))))
        }
        guard !targets.isEmpty else { return }
        let outcomes = await dependencies.orchestrator.translate(
            document: document,
            targets: targets,
            language: dependencies.language,
            onlyMissing: onlyMissing
        ) { [weak self] blockID, state in
            Task { @MainActor in
                switch state {
                case .requesting: self?.inFlight.insert(blockID)
                case .settled: self?.inFlight.remove(blockID)
                }
            }
        }
        for outcome in outcomes {
            if outcome.skipped { continue }
            if let code = outcome.errorCode {
                failedCodes[outcome.blockID] = code
            } else {
                failedCodes[outcome.blockID] = nil
            }
        }
        // 归因提示：整批 contextUnavailable → 给设置入口提示。
        if outcomes.contains(where: {
            $0.errorCode
                == ReaderTranslationOrchestrator.FailureCode
                    .contextUnavailable
        }) {
            errorMessage = "AI 未启用或未配置模型——请在设置中完成 AI 配置后再翻译。"
        }
        await hydrate()
    }

    func clearError() { errorMessage = nil }
}
