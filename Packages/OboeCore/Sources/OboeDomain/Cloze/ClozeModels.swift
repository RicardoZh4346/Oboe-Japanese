import Foundation

/// v0.7.0 S02 冻结契约：Cloze / Sentence Card 内容模型。
/// 依据：详细技术实现文档 §9（模型/schema、Unicode 与独立快照、作答调度）。
/// 冻结项：单 blank、UTF-16 range + 快照 + hash、accepted answers、
/// 条件 meaning CHECK（vocabulary/grammar 非空、sentence 可空）、
/// 原子创建关联校验。
///
/// 决定（S02 冻结，D07）：一个 sentence Note 恰有一个 ClozeDefinition
/// 和一个 `sentence_cloze` Card；多挖空 = 多个 sentence Notes。
/// 本版不提供多 blank 联合判分。

// MARK: - 值对象

/// 挖空范围：针对 immutable `sentenceSnapshot` 的 UTF-16 range。
/// 创建时经 `Range(NSRange, in:)` 安全转换验证：边界合法、正长度、
/// 不拆分组合字符、截取结果 == `targetSurface`。
public struct ClozeRange: Equatable, Sendable {
    /// 存储编码版本——解码格式变更时升级（§9.1 range_version）。
    public static let currentVersion = 1

    public let version: Int
    public let utf16Start: Int
    public let utf16Length: Int

    public init(utf16Start: Int, utf16Length: Int) throws {
        guard utf16Start >= 0 else { throw ClozeError.invalidRange }
        guard utf16Length > 0 else { throw ClozeError.invalidRange }
        self.version = Self.currentVersion
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
    }

    /// S12：持久化回放。`version` 来自存储行——只识别当前编码版本；
    /// 未知版本拒绝解码而不是按 v1 语义误读未来的 range 编码。
    public init(persistedVersion: Int, utf16Start: Int, utf16Length: Int) throws {
        guard persistedVersion == Self.currentVersion else {
            throw ClozeError.unsupportedRangeVersion
        }
        try self.init(utf16Start: utf16Start, utf16Length: utf16Length)
    }

    public var utf16End: Int { utf16Start + utf16Length }
}

/// 单 blank Cloze 定义（§9.1 表 `cloze_definitions` 的领域投影）。
public struct ClozeDefinition: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 所属 sentence Note；与 `card` 的 noteID 必须一致（事务校验）。
    public let noteID: UUID
    public let cardID: UUID
    /// 来源上下文（可空；删除原文后 SET NULL，快照仍完整——§9.3）。
    public let sourceContextID: UUID?
    /// 原句快照：内容不可变；编辑句子 = 重建定义。
    public let sentenceSnapshot: String
    public let sentenceSHA256: String
    public let range: ClozeRange
    /// 填空处实际表记（如「見た」——非 lemma）。
    public let targetSurface: String
    public let targetLemma: String?
    /// 填空处实际活用读音（如「みた」——非 lemma 读音）。
    public let targetReading: String?
    /// 至少含 targetSurface；可含用户确认的活用假名与额外答案。
    /// 默认接受「みた」类实际读音，**不自动接受 lemma「見る」**（§9.3）。
    public let acceptedAnswers: [String]
    public let hint: String?
    /// 乐观并发：已打开旧内容的提交被版本校验拒绝（§9.2）。
    public let contentVersion: Int

    public init(
        id: UUID,
        noteID: UUID,
        cardID: UUID,
        sourceContextID: UUID?,
        sentenceSnapshot: String,
        sentenceSHA256: String,
        range: ClozeRange,
        targetSurface: String,
        targetLemma: String?,
        targetReading: String?,
        acceptedAnswers: [String],
        hint: String?,
        contentVersion: Int
    ) {
        self.id = id
        self.noteID = noteID
        self.cardID = cardID
        self.sourceContextID = sourceContextID
        self.sentenceSnapshot = sentenceSnapshot
        self.sentenceSHA256 = sentenceSHA256
        self.range = range
        self.targetSurface = targetSurface
        self.targetLemma = targetLemma
        self.targetReading = targetReading
        self.acceptedAnswers = acceptedAnswers
        self.hint = hint
        self.contentVersion = contentVersion
    }
}

// MARK: - 校验与渲染纯函数

public enum ClozeError: Error, Equatable, Sendable {
    case invalidRange
    /// 范围截取结果与 targetSurface 不一致（错位拒绝，不展示可评分的坏卡）。
    case rangeSurfaceMismatch
    case emptySentence
    case emptyAcceptedAnswers
    /// card.noteID/template/definition 组合不一致（§9.1 事务校验）。
    case inconsistentCardLink
    /// 已打开的旧版本内容提交被拒（contentVersion 冲突）。
    case staleContentVersion
    /// S12：acceptedAnswers 必须包含 targetSurface 本体（§9.3「至少含
    /// targetSurface」）——仅含读音/活用的集合不成立。
    case acceptedAnswersMissingSurface
    /// S12：持久化/恢复路径的句子快照 hash 与快照内容不符（§9.2/§14.2）。
    case snapshotHashMismatch
    /// S12：存储行的 range_version 不是当前可解码版本。
    case unsupportedRangeVersion
}

public enum ClozeValidator {
    /// 创建前校验：句非空、range 合法、截取 == surface、answers 非空、
    /// 归一化后不重拆组合字符。创建后不再对原句做 NFKC 改写（§9.2）。
    ///
    /// 注意 `Range(NSRange, in:)` **不**保证 Character 边界对齐：
    /// UTF-16 坐标落在代理对/组合字符内部时会静默截断或扩展
    /// （`{0,1}` 对「か\u{3099}」截取出「か」、emoji 内部 `{1,1}` 扩展成
    /// 整个 emoji）。只查「非空 + 截取 == surface」会让劈开 grapheme 的
    /// blank 通过——渲染成「＿゙」这类残字。因此这里显式要求：解析出的
    /// UTF-16 span 与持久化坐标逐位相等，且两个端点都落在 Character
    /// 边界上。
    public static func validate(
        sentence: String,
        range: ClozeRange,
        targetSurface: String,
        acceptedAnswers: [String]
    ) throws {
        // 与 notes 的 `length(trim(headword)) > 0` CHECK 同判据——空白句
        // 在持久化前就拒掉，而不是让 commit 撞表约束回滚（S13）。
        guard !sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        else { throw ClozeError.emptySentence }
        guard !acceptedAnswers.isEmpty else { throw ClozeError.emptyAcceptedAnswers }
        guard let swiftRange = resolveUTF16Range(range, in: sentence),
              !swiftRange.isEmpty
        else { throw ClozeError.invalidRange }
        guard String(sentence[swiftRange]) == targetSurface else {
            throw ClozeError.rangeSurfaceMismatch
        }
    }

    /// 正面渲染：按 range 把目标替换为 blank（§9.2 不做全局替换——
    /// 句中相同词只遮一次）。blank 样式由 UI 决定。
    ///
    /// range 无法解析出 grapheme 对齐的非空 span 时返回 `blank` 本身——
    /// 该路径只可能由损坏行触发（写侧一律过 `validate`），此时返回原句
    /// 会在正面泄露答案，绝不发生。
    public static func maskedSentence(
        _ sentence: String,
        range: ClozeRange,
        blank: String
    ) -> String {
        guard let swiftRange = resolveUTF16Range(range, in: sentence),
              !swiftRange.isEmpty else {
            return blank
        }
        return sentence.replacingCharacters(in: swiftRange, with: blank)
    }

    /// S13：枚举 `targetSurface` 在句中所有可作 blank 的出现点
    /// （编辑器「第 N 处」选择器与创建预览共用）。`String.range(of:)`
    /// 本身按 grapheme 对齐匹配且大小写等价（canonical equivalence），
    /// 命中的仍是完整 Character——这里再过一道 `resolveUTF16Range`
    /// 防御：任何劈开代理对/组合序列的命中一律丢弃而不是沿用坐标。
    /// 返回按 UTF-16 位置升序；surface 为空或句中不出现时为空数组。
    public static func surfaceRanges(
        of targetSurface: String,
        in sentence: String
    ) -> [ClozeRange] {
        guard !targetSurface.isEmpty, !sentence.isEmpty else { return [] }
        var results: [ClozeRange] = []
        var searchRange = sentence.startIndex..<sentence.endIndex
        while let match = sentence.range(of: targetSurface, range: searchRange) {
            let nsRange = NSRange(match, in: sentence)
            if let range = try? ClozeRange(
                utf16Start: nsRange.location,
                utf16Length: nsRange.length
            ), resolveUTF16Range(range, in: sentence) != nil {
                results.append(range)
            }
            searchRange = match.upperBound..<sentence.endIndex
        }
        return results
    }

    /// 把持久化 UTF-16 坐标解析成 String range，并拒绝三类损坏：
    /// 越界（nil）、截断/扩展导致 span 与坐标不符、端点不在 Character
    /// 边界上（劈开代理对/组合字符/ZWJ 序列）。
    private static func resolveUTF16Range(
        _ range: ClozeRange,
        in sentence: String
    ) -> Range<String.Index>? {
        let nsRange = NSRange(
            location: range.utf16Start,
            length: range.utf16Length
        )
        guard let swiftRange = Range(nsRange, in: sentence),
              NSRange(swiftRange, in: sentence) == nsRange,
              isCharacterBoundary(swiftRange.lowerBound, in: sentence),
              isCharacterBoundary(swiftRange.upperBound, in: sentence)
        else { return nil }
        return swiftRange
    }

    private static func isCharacterBoundary(
        _ index: String.Index,
        in sentence: String
    ) -> Bool {
        index == sentence.endIndex || sentence.indices.contains(index)
    }
}
