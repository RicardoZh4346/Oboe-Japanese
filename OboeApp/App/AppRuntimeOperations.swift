import Foundation
import OboeDomain
import OboeInfrastructure

/// 根组合以外允许触达的运行期操作集合。Feature 只拿到这组具名闭包，
/// 不再持有整个 runtime controller——能做什么在类型层面一目了然。
struct AppRuntimeOperations: Sendable {
    let drainSharedCaptures: @Sendable () async -> Void
    let clearPendingContinueItem: @Sendable () async -> Void
    let importAwaitingSharedCaptures: @Sendable () async -> Void
    let scheduleJLPTEnrichment: @Sendable @MainActor () -> Void
    let applyPreparedRestoration: @Sendable (PreparedRestoration) async throws -> Void
    let localSnapshots: @Sendable () async throws -> [DatabaseSnapshot]
    let createLocalSnapshot: @Sendable () async throws -> DatabaseSnapshot?
    let restoreLocalSnapshot: @Sendable (DatabaseSnapshot) async throws -> Void
    let pendingSharedCaptureCount: @Sendable @MainActor () -> Int?
    let setAppearancePreference: @Sendable (AppAppearance) async throws -> Void
    let currentAppearancePreference: @Sendable @MainActor () -> AppAppearance
    /// S11：Settings「检查备份」与 onOpenURL/AirDrop 同一入口——
    /// 投递外部备份文件到统一导入协调器（串行校验+preview）。
    let submitBackupFile: @Sendable (URL) -> Void
}
