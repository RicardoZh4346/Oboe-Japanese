import Foundation
import OboeDomain
import OboeInfrastructure

/// 跨 Feature 共享的长生命周期依赖：语音与 OCR 不随数据库重建；
/// `inboxImageStore` 根目录稳定，实例随容器一起发布。
struct SharedFeatureDependencies {
    let speechService: any SpeechService
    let ocrService: any OCRRecognizing
    let inboxImageStore: InboxImageStore?
    /// S05/S07：Note 来源链查询（复习背面展示、详情页溯源用）。
    let sourceContextRepository: any SourceContextRepository
    /// v0.7.0 S12：cloze_definitions 读取——sentence Note 详情页展示
    /// 挖空定义（遮罩句/答案/提示）用，复习链路另有独立 join。
    let clozeRepository: any ClozeRepository
    /// S09：专项学习持久层与领域协调（setup 预览、Review 驱动、
    /// 启动期打断遗留 active 会话共用同一实例）。
    let customStudyRepository: any CustomStudyRepository
    let customStudyService: CustomStudyService
    /// v0.7.5 S16：learning_unit_flags 的读/写/撤销 CAS 门面——
    /// Review 按钮、Note 详情开关、Inspector 三态共用。nil =
    /// 装配缺席（测试容器）→ UI 隐藏 Too Easy 入口。
    let learningUnits: (any LearningUnitFlagProviding)?
}

/// v0.7.5 S16 Too Easy UI 的窄依赖面——只暴露 UI 实际用到的方法，
/// ViewModel 测试用内存桩件即可跑通（与 Reader 依赖包同一惯例）。
/// 具体实现是 `GRDBLearningUnitRepository`（pool 门面已含
/// CAS/幂等/事件审计），协议成员与其方法一一对应。
protocol LearningUnitFlagProviding: Sendable {
    /// 读 flag；无行返回 nil（语义 = revision 0 / tooEasy false）。
    func fetchFlag(unitID: UUID) async throws -> LearningUnitFlag?
    /// 批量取 unit（Inspector/详情页三态展示用）。
    func fetchUnits(ids: [UUID]) async throws -> [UUID: LearningUnit]
    /// identity key → unit（卡片→unit 归属解析用）。
    func fetchUnit(identityKey: String) async throws -> LearningUnit?
    /// 某 Note 的唯一有效关联（note_id UNIQUE——判定卡/词归属）。
    func fetchLink(noteID: UUID) async throws -> LearningUnitNoteLink?
    /// unit 的全部关联（同 unit sibling 批量判定/移出用）。
    func fetchLinks(unitID: UUID) async throws -> [LearningUnitNoteLink]
    /// 一批 unit 中「有 vocabulary Note 关联」的子集——三态
    /// hasVocabularyNoteLink 的批量输入。
    func linkedVocabularyUnitIDs(unitIDs: [UUID]) async throws -> Set<UUID>
    /// CAS 置 flag（含 operation_id 幂等 + 事件审计）。
    @discardableResult
    func setFlagTooEasy(
        _ command: TooEasyCommand, at date: Date
    ) async throws -> LearningUnitFlag
    /// CAS 撤销（凭 eventID + revision——覆盖另一窗口新设置被拒）。
    @discardableResult
    func undoTooEasy(
        _ command: TooEasyUndoCommand, at date: Date
    ) async throws -> LearningUnitFlag
    /// unit 事件史（Undo 锚点：最近未撤销的 tooEasySet 事件）。
    func fetchEvents(unitID: UUID) async throws -> [LearningUnitEventRecord]
}

extension GRDBLearningUnitRepository: LearningUnitFlagProviding {}
