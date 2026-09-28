import Foundation
import NaturalLanguage
import OboeDomain

/// 系统 tokenizer/tag 能力 seam（S07）。
///
/// 日语 word 级在实测平台上只有 `Language`/`Script`/`TokenType` 三个
/// scheme（无 lemma/lexicalClass/nameType，见 docs/v0.7/morphology-spike.md
/// §1.1）——lemma 只能靠 Deinflector+词典侧补出。本 seam 把 NLTokenizer/
/// NLTagger 的非线程安全实例收进 actor 内串行调用点；值全部以 rawValue
/// String 传递，避免把 NL 类型带进协议并要求 Sendable。
///
/// 测试可注入 fake：返回空 schemes 触发 `MorphologyError.capabilityMissing`，
/// 或提供确定性的边界序列覆盖系统分词差异（OS build 相关）。
public protocol MorphologySystemTokenizer: Sendable {
    /// `NLTagger.availableTagSchemes(for:.word, language:.japanese)`
    /// 的 rawValue 集。
    func availableWordTagSchemes() -> [String]

    /// word 级 token 枚举（渲染原文 UTF-16 坐标）。
    func wordTokens(in text: String) -> [MorphologySystemToken]
}

/// 单个系统 token：原文 UTF-16 范围 + 表面 + 系统判别信息。
public struct MorphologySystemToken: Sendable, Equatable {
    /// `NLTagScheme.tokenType` 的 rawValue（"Word"/"Punctuation"/
    /// "Whitespace"/"Other"）；scheme 缺失时为 nil。
    public let tokenType: String?
    /// `NLTagScheme.script` 的 rawValue（"Jpan"/"Hans"/"Latn"…）；缺失为 nil。
    public let script: String?
    public let rangeUTF16: Range<Int>
    public let surface: String

    public init(
        tokenType: String?,
        script: String?,
        rangeUTF16: Range<Int>,
        surface: String
    ) {
        self.tokenType = tokenType
        self.script = script
        self.rangeUTF16 = rangeUTF16
        self.surface = surface
    }
}

/// 生产实现：`NLTokenizer(.word)` 枚举边界，`NLTagger` 取
/// tokenType/script（只在 `availableTagSchemes` 报有的 scheme 下查询）。
/// **非线程安全——必须由 actor 串行使用**（NLJapaneseMorphologyService 是
/// actor，所有调用在 actor 隔离内完成）。
public struct NaturalLanguageMorphologyTokenizer: MorphologySystemTokenizer {
    public init() {}

    public func availableWordTagSchemes() -> [String] {
        NLTagger.availableTagSchemes(for: .word, language: .japanese)
            .map(\.rawValue)
    }

    public func wordTokens(in text: String) -> [MorphologySystemToken] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [MorphologySystemToken] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let start = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
            let length = text[range].utf16.count
            tokens.append(MorphologySystemToken(
                tokenType: nil, script: nil,
                rangeUTF16: start..<(start + length), surface: String(text[range])
            ))
            return true
        }
        guard !tokens.isEmpty else { return tokens }

        // 补 tokenType/script tag（可用 scheme 才查）。tag(at:unit:scheme:)
        // 以字符位置取标签；token 起点落在对应 tag range 内。
        let schemes = Set(availableWordTagSchemes())
        let wantTokenType = schemes.contains(NLTagScheme.tokenType.rawValue)
        let wantScript = schemes.contains(NLTagScheme.script.rawValue)
        if !wantTokenType && !wantScript { return tokens }

        var tagSchemes: [NLTagScheme] = []
        if wantTokenType { tagSchemes.append(.tokenType) }
        if wantScript { tagSchemes.append(.script) }
        let tagger = NLTagger(tagSchemes: tagSchemes)
        tagger.string = text

        return tokens.map { token in
            var copy = token
            guard let index = text.utf16.index(
                text.utf16.startIndex,
                offsetBy: token.rangeUTF16.lowerBound,
                limitedBy: text.utf16.endIndex
            ) else { return copy }
            if wantTokenType {
                copy = MorphologySystemToken(
                    tokenType: tagger.tag(at: index, unit: .word, scheme: .tokenType)
                        .0?.rawValue,
                    script: copy.script,
                    rangeUTF16: copy.rangeUTF16,
                    surface: copy.surface
                )
            }
            if wantScript {
                copy = MorphologySystemToken(
                    tokenType: copy.tokenType,
                    script: tagger.tag(at: index, unit: .word, scheme: .script)
                        .0?.rawValue,
                    rangeUTF16: copy.rangeUTF16,
                    surface: copy.surface
                )
            }
            return copy
        }
    }
}
