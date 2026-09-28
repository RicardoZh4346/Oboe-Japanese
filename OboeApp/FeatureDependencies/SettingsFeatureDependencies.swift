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
    /// S06：关于页「词典来源与许可」的事实源（sources()/metadata()）。
    let dictionaryQueryService: DictionaryQueryService
    /// v0.7.0 S18：CSV/TSV 导入向导 + 导出页直接使用库句柄
    /// （staging/precheck/execute 走 `ImportExecutor`）。
    let database: OboeDatabase
    /// 导入向导/导出页的牌组选项来源。
    let deckService: DeckManagementService
    /// S24 恢复屏障闸门：CSV 导入执行（confirmExecute/resume）登记，
    /// 恢复窗口内关门 → 登记即取消。
    let workGate: RestorationWorkGate
}
