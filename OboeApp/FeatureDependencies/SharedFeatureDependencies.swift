import Foundation
import OboeDomain
import OboeInfrastructure

/// 跨 Feature 共享的长生命周期依赖：语音与 OCR 不随数据库重建；
/// `inboxImageStore` 根目录稳定，实例随容器一起发布。
struct SharedFeatureDependencies {
    let speechService: any SpeechService
    let ocrService: any OCRRecognizing
    let inboxImageStore: InboxImageStore?
}
