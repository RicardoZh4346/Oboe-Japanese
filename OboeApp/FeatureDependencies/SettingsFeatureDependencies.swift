import Foundation
import OboeDomain
import OboeInfrastructure

/// 设置页所需的窄依赖包。运行期操作（恢复、快照、外观偏好）不放在这里，
/// 由 `AppRuntimeOperations` 的具名闭包单独传入——设置页不再持有
/// 全局容器。
struct SettingsFeatureDependencies {
    let studyService: StudySessionService
    let speechPreferencesService: SpeechPreferencesService
    let adaptivePreferencesService: AdaptivePreferencesService
    let aiConfigurationService: AIConfigurationService
    let aiConnectionTestService: AIConnectionTestService
    let aiModelCatalogService: AIModelCatalogService
    let speechService: any SpeechService
    let exporter: PortableBackupPackageExporter
    let restorationPreparer: PortableBackupRestorationPreparer
}
