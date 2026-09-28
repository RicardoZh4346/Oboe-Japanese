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
}
