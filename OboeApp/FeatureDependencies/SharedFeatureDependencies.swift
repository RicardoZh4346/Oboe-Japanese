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
    /// v0.7.5 S18：deck/单元学习进度的批量投影 + 全库观察流。
    /// 每世代一只实例注入各 Feature；nil = 装配缺席 → UI 隐藏
    /// 进度行，仅退化为「无进度显示」，不阻塞页面。
    let learningProgress: (any LearningProgressProviding)?
    /// v0.7.5 S18：Reader 文档↔学习牌组绑定读 + coverage v2
    /// 活算投影门面。nil = 装配缺席 → Deck 详情隐藏文章覆盖区、
    /// Reader 行隐藏「打开牌组」。
    let studyDecks: (any StudyDeckSurfacing)?
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
    /// D19 词级标记：lexeme 的全部活 unit → tooEasy（词条绑定
    /// current 义项 ∪ note 链路载体，与词级状态推导同规则）。
    /// 返回实际写入 flag 变更的 unit 数；0 = 无可标记 unit——
    /// 调用方如实提示，绝不臆造义项归属。
    @discardableResult
    func setWordTooEasy(
        lexemeID: UUID, value: Bool, operationID: UUID, at date: Date
    ) async throws -> Int
    /// CAS 撤销（凭 eventID + revision——覆盖另一窗口新设置被拒）。
    @discardableResult
    func undoTooEasy(
        _ command: TooEasyUndoCommand, at date: Date
    ) async throws -> LearningUnitFlag
    /// unit 事件史（Undo 锚点：最近未撤销的 tooEasySet 事件）。
    func fetchEvents(unitID: UUID) async throws -> [LearningUnitEventRecord]
}

extension GRDBLearningUnitRepository: LearningUnitFlagProviding {}

/// v0.7.5 S18：牌组学习进度的投影 + 观察流门面——具体实现是
/// `GRDBLearningProgressRepository`。订阅流发射即「持久态可能已
/// 变」，订阅方再按需重投影，绝不反向触发 AI/morphology/全文
/// 分词。`LearningProgressUpdate` 已含全库 deck 进度、文档↔牌组
/// 绑定与知识指纹（Equatable 去重——无内容变化不发射）。
protocol LearningProgressProviding: Sendable {
    /// 全库学习表面更新流（`observeProgress()`——
    /// WITHOUT ROWID 表经 rowid 审计代理触发，payload 内容去重）。
    func observeProgress()
        -> AsyncThrowingStream<LearningProgressUpdate, Error>
    /// 指定牌组集合的进度投影（首轮/失流重取用）。
    func deckProgress(
        deckIDs: [UUID]
    ) async throws -> [UUID: DeckLearningProgress]
    /// unit 知识三态批量投影（文章 coverage 表面等场景按
    /// `LearningKnowledgeState` 归约）。
    func knowledgeStates(
        unitIDs: [UUID]
    ) async throws -> [UUID: LearningKnowledgeState]
}

extension GRDBLearningProgressRepository: LearningProgressProviding {}

/// v0.7.5 S18：Reader 文档 ↔ 学习牌组绑定的窄读面 + 文档级
/// coverage v2 活算——具体实现是 `GRDBReaderStudyDeckRepository`
/// （绑定写语义仍在 `GRDBReaderStudyDeckService` 的单事务内）。
protocol StudyDeckSurfacing: Sendable {
    /// 文档 → 绑定牌组（nil = 未绑定/文档已不存在）。
    func studyDeckID(forDocument documentID: UUID) async throws -> UUID?
    /// 牌组 → 绑定文档（v24 UNIQUE 保证至多一行）。
    func boundDocumentID(forDeck deckID: UUID) async throws -> UUID?
    /// 文档 coverage v2 活算；文档不存在 → nil，空分母经
    /// `Result.resolvedCoverage == nil` 表达（不展示 0%/100%）。
    func documentCoverageResult(
        forDocument documentID: UUID
    ) async throws -> ReaderCoverageV2.Result?
    /// 批量活算（Deck 详情文章覆盖区/Reader 列表行）。
    func documentCoverageResults(
        forDocumentIDs documentIDs: [UUID]
    ) async throws -> [UUID: ReaderCoverageV2.Result]
}

extension GRDBReaderStudyDeckRepository: StudyDeckSurfacing {}
