import Foundation
import OboeDomain
import OboeInfrastructure
import OboeSharedCapture

/// controller 自用的运行期句柄：与 `phase.ready` 容器同批构造、
/// 同批发布，专供替换安全与后台调度使用，不暴露给 Feature。
struct RuntimeServices {
    let adaptiveCardService: AdaptiveCardService
    let aiRepairService: AIRepairService
    let appearancePreferencesService: AppearancePreferencesService
    /// 统一附件引用查询（D09，设计 §6.3）：Inbox 删除回调与孤儿
    /// sweep 都经它判断「最后一个引用」，随数据库世代重建。
    let attachmentReferenceRepository: any AttachmentReferenceRepository
    let captureImportCoordinator: CaptureImportCoordinator
    let captureQueueStore: (any CaptureQueueStoring)?
    let inboxService: InboxService
    let inboxImageStore: InboxImageStore
    let jlptEnrichmentService: JLPTLibraryEnrichmentService
    /// S09：启动期把上个运行期遗留的 active 专项会话标 interrupted。
    let customStudyRepository: any CustomStudyRepository
}

/// `AppFeatureContainerFactory.makeServices` 的返回包：Feature 容器与
/// controller 运行期句柄必须来自同一次构造，不允许半个世代混装。
struct BuiltServices {
    let container: AppFeatureContainer
    let runtime: RuntimeServices
}
