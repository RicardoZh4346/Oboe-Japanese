import Foundation

/// v0.7.0 S02 冻结契约：词汇知识状态真值表（D05、§6.3）。
/// 冻结项：四态判定顺序、人工 override 优先、Note 关联语义、
/// 事件/receipt 形态。

/// 词汇知识状态（§6.3 判定顺序，自上而下首个命中生效）：
/// 1. override=ignored → ignored
/// 2. override=known → known
/// 3. 至少一条有效 `lexeme_note_links` → learning
/// 4. 否则 → unknown
/// paused/无启用 Card 的 Note 仍是 learning；删除最后一个 Note 且无
/// override 时回到 unknown。FSRS 成熟度不参与判定（D05）。
public enum VocabularyKnowledgeState: String, Codable, Sendable {
    case known
    case learning
    case unknown
    case ignored
}

/// 人工覆盖（vocabulary_knowledge_overrides）：只存 known/ignored
/// 两态。D19（v0.7.5）：该表退出运行态——仅供 v8 备份导入解码
/// 与学习单元 backfill 审计；运行态「已知」= unit tooEasy flag，
/// 「重置」= 清 flag，ignored 不再产生。
public enum KnowledgeOverride: String, Codable, Sendable {
    case known
    case ignored
}

/// `lexemes` 行的领域投影。`id` 是用户状态主键（内部 UUID），
/// `key` 是可解析外部身份（§6.3）。
public struct Lexeme: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let key: LexicalKey
    public let writtenForm: String
    public let reading: String?
    public let normalizedLemma: String
    public let posFamily: String?
    /// 解析时的词典 dataset 版本（provenance，不进 identity_key——
    /// 否则每次词典更新都让已知状态失效）。
    public let dictionaryVersionAtResolution: String?
    public let resolutionStatus: TokenResolutionStatus
    public let createdAt: Date

    public init(
        id: UUID,
        key: LexicalKey,
        writtenForm: String,
        reading: String?,
        normalizedLemma: String,
        posFamily: String?,
        dictionaryVersionAtResolution: String?,
        resolutionStatus: TokenResolutionStatus,
        createdAt: Date
    ) {
        self.id = id
        self.key = key
        self.writtenForm = writtenForm
        self.reading = reading
        self.normalizedLemma = normalizedLemma
        self.posFamily = posFamily
        self.dictionaryVersionAtResolution = dictionaryVersionAtResolution
        self.resolutionStatus = resolutionStatus
        self.createdAt = createdAt
    }
}

/// `lexeme_note_links`：lexeme 与 Note 的多对多关联。
public struct LexemeNoteLink: Equatable, Sendable {
    /// 关联来源（高置信自动 / 用户确认 / 导入回填），审计用。
    public enum AssociationOrigin: String, Codable, Sendable {
        case automaticHighConfidence
        case userConfirmed
        case backfill
        case imported
    }

    public let lexemeID: UUID
    public let noteID: UUID
    public let origin: AssociationOrigin
    public let createdAt: Date

    public init(lexemeID: UUID, noteID: UUID, origin: AssociationOrigin, createdAt: Date) {
        self.lexemeID = lexemeID
        self.noteID = noteID
        self.origin = origin
        self.createdAt = createdAt
    }
}

/// 知识状态仓储边界（v18）。关联写路径必须产生事件+receipt
/// （§11.2 reader_activity_events）；重复操作返回同 receipt，
/// 不新增事件（幂等）。
///
/// D19（v0.7.5）：`vocabulary_knowledge_overrides` 仅供 v8 导入
/// 与兼容审计——运行态不再提供 override 写 API，词级「已知」经
/// learning-unit flags（`GRDBLearningUnitRepository.setWordTooEasy`）
/// 表达；`state`/`states` 内部按 unit 聚合（ignored 不再产生）。
public protocol VocabularyKnowledgeRepository: Sendable {
    /// 按词级聚合规则解析当前状态（unit flags/links 推导）。
    func state(lexemeID: UUID) async throws -> VocabularyKnowledgeState
    /// 建立 Note 关联（同事务可随挖词命令执行）。
    func linkNote(lexemeID: UUID, noteID: UUID, origin: LexemeNoteLink.AssociationOrigin) async throws
    /// 解除关联；最后一条解除后词级态按 unit 聚合回落
    /// （无活 unit 信号 → unknown）。
    func unlinkNote(lexemeID: UUID, noteID: UUID) async throws
    func fetchLexeme(key: LexicalKey) async throws -> Lexeme?
    /// 按 identity_key upsert；已存在时返回既有行（不重建 UUID）。
    func resolveLexeme(key: LexicalKey, seed: Lexeme) async throws -> Lexeme
    /// 批量解析——覆盖率/渲染路径不允许逐 token SQL（§17）。
    func resolveLexemes(keys: [LexicalKey]) async throws -> [LexicalKey: Lexeme]
}

/// 旧真值表纯函数（override + 关联计数 → 四态）。
/// D19：运行态已切到 unit 聚合（`GRDBVocabularyKnowledgeRepository
/// .wordKnowledgeStates`）——本 resolver 仅保留给 v8 解码语义、
/// 迁移审计与测试对照，不得用于运行态状态判定。
public enum VocabularyKnowledgeResolver {
    public static func resolve(
        override: KnowledgeOverride?,
        linkedNoteCount: Int
    ) -> VocabularyKnowledgeState {
        switch override {
        case .ignored: return .ignored
        case .known: return .known
        case nil:
            return linkedNoteCount > 0 ? .learning : .unknown
        }
    }
}
