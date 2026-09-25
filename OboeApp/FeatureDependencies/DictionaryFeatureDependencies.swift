import Foundation
import OboeDomain

/// 词典 feature 依赖（S06）。`queryService` 是无状态协调器——词典包
/// 缺失/损坏只在查询时抛错，由 UI 降级为「词典不可用」，不影响其他
/// feature（设计 §3：坏包只影响查词）。
struct DictionaryFeatureDependencies {
    let queryService: DictionaryQueryService
}
