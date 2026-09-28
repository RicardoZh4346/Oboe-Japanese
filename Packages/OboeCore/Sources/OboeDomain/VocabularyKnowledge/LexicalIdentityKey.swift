import Foundation

/// S08：`LexicalKey` 的规范构造器（设计 §6.3 / D08）。
/// 冻结契约 `LexicalKey` 本身不改；本文件只提供唯一的 identity_key
/// 编码实现点——morphology service、backfill、用户确认改选都必须经
/// 这里生成，否则同一词条会产生多个 lexeme 行。
///
/// 编码约定：
/// - jmdict：`jmdict|<ent_seq>|<normalizedForm>|<normalizedReading>`
///   （provider + ent_seq + 规范化表记/读音——设计 §6.3；dataset version
///   一律不进 key，否则词典更新会冲掉已知状态）。
/// - local：`local|<normalizedWritten>|<normalizedReading>|<posFamily>`
///   （可得的 lemma+reading+POS；同形异音有读音时分开）。
public enum LexicalIdentityKey {
    /// 词典命中身份。`normalizedForm` 必须已经是
    /// `SearchTextNormalizer` 输出；`reading` 内部再规范一次以容忍
    /// 原始读音传入。
    public static func jmdict(
        entryID: Int64,
        normalizedForm: String,
        reading: String?
    ) -> LexicalKey {
        let normalizedReading = SearchTextNormalizer.normalize(reading ?? "")
        return LexicalKey(
            provider: .jmdict,
            externalID: String(entryID),
            identityKey: "jmdict|\(entryID)|\(normalizedForm)|\(normalizedReading)"
        )
    }

    /// 无词典条目（OOV / 歧义待确认）的本地身份。
    /// `writtenForm`/`reading` 接受原文——内部统一规范化。
    public static func local(
        writtenForm: String,
        reading: String?,
        posFamily: String?
    ) -> LexicalKey {
        let written = SearchTextNormalizer.normalize(writtenForm)
        let read = SearchTextNormalizer.normalize(reading ?? "")
        let pos = (posFamily ?? "").lowercased()
        let external = "\(written)|\(read)|\(pos)"
        return LexicalKey(
            provider: .local,
            externalID: external,
            identityKey: "local|\(external)"
        )
    }
}
