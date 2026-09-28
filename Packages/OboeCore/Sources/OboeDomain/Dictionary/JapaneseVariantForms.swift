import Foundation

/// 日语音形异体表记折叠表（v0.7.0 S07）。
///
/// `SearchTextNormalizer` 的 NFKC/compatibility 折叠不处理汉字异体
/// （髙→高 等字形变体在 Unicode 中是不同码位且不互相折叠）。
/// 词典产物 `normalized_text`/`normalized_reading` 使用标准字形（高橋），
/// 渲染原文若用异体（髙橋）将查不到。本表提供**查询侧**补充键：
/// 原样 `normalized_*` 查询照常进行，另对每个变体字符生成折叠串作为
/// 追加查询键——不改 `SearchTextNormalizer` 本身（词典构建侧规范化
/// 契约不变），命中时给候选 reason 附 `variant.fold`。
///
/// 只收录确定方向的字形异体（旧字形/异体→正字）；**不**收录
/// 音读互换（踊/躍 类语义同义词）或简体/旧字体全集（那是字形表工程，
/// 不是本表职责）。新增条目必须是单向安全折叠：折叠串本身就是
/// 正字写法，不会因折叠把合法异体词并入错词。
public enum JapaneseVariantForms {
    /// 异体→正字（查询侧折叠）。
    /// - 髙 U+9AD9 → 高 U+9AD8（はしご高；人名/印刷体常见异体）
    public static let replacements: [Character: Character] = [
        "髙": "高",
    ]

    /// 折叠后串：把 `text` 中每个变体字符替换为正字。
    /// 无变体字符时返回原串。
    public static func folded(_ text: String) -> String {
        var result = ""
        var changed = false
        for ch in text {
            if let folded = replacements[ch] {
                result.append(folded)
                changed = true
            } else {
                result.append(ch)
            }
        }
        return changed ? result : text
    }

    /// 查询侧补充键集：`SearchTextNormalizer.normalize` 输出之外，
    /// 先折叠异体再规范化所得的等价键（不含与原串重复的键）。
    public static func additionalNormalizedKeys(of surface: String) -> [String] {
        let foldedSurface = folded(surface)
        guard foldedSurface != surface else { return [] }
        let normalized = SearchTextNormalizer.normalize(foldedSurface)
        let plain = SearchTextNormalizer.normalize(surface)
        return normalized == plain ? [] : [normalized]
    }
}
