import Foundation
import OboeDomain
import OboeInfrastructure

/// v0.7.5 S17 三模式译文的依赖包——与 `aiStudy` 同一「装配缺席
/// 约定」：`ReaderFeatureDependencies.translation == nil` 时 Reader
/// 隐藏全部译文入口（模式选择器/占位重试），原文阅读不受影响。
///
/// - `orchestrator`：水合（**零网络**——只读
///   `reader_translation_blocks` + 活块 hash 复核）与显式翻译/重译
///   派发的唯一出口。`contextProvider` 每次派发批取一次配置/凭据
///   快照：Key 只在发送时从 credentialStore 读、不缓存；配置变更
///   只产生新的 requestHash/新修订——既有译文行永不改写（§8.1
///   「provider/model/prompt 变化不覆盖旧译文」）。
/// - `sender` 复用 `AIStudyResolverClient` 的同一 wire 契约——
///   纯翻译块走 `tokens=[]` 请求形态（§6.3 words=[] 契约）。
/// - `language`：目标语言（study 管线同口径 `zho`）。
struct ReaderTranslationDependencies: Sendable {
    let orchestrator: ReaderTranslationOrchestrator
    var language: String = AIStudyPreparation.targetLanguage
}
