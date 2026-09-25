import Foundation
import OboeDomain
import OboeInfrastructure

/// 数据库运行期（技术文档 §10）：打开/迁移/关闭、快照与替换接口的
/// 唯一持有者。不直接改 UI phase——发布与世代由 `AppRuntimeController`
/// 编排，这里只提供原语。
struct DatabaseRuntime {
    let lifecycle: OboeDatabaseLifecycle

    init(baseURL: URL) {
        lifecycle = OboeDatabaseLifecycle(
            databaseURL: baseURL.appendingPathComponent("oboe.sqlite"),
            snapshotDirectoryURL: baseURL.appendingPathComponent(
                "Snapshots",
                isDirectory: true
            )
        )
    }

    func open() async throws -> OboeDatabase {
        try await lifecycle.open()
    }

    /// 当前打开的库；替换窗口期返回 nil——回退路径据此决定能否
    /// 重新发布旧容器。
    func currentDatabase() async -> OboeDatabase? {
        await lifecycle.currentDatabase()
    }

    /// 原子替换当前库（rollback snapshot + candidate install + marker）。
    /// `beforeCommit` 在替换库验证后、提交前执行（当前用于预热 TodayPlan）。
    func replaceDatabase(
        with sourceURL: URL,
        beforeCommit: @escaping @Sendable (OboeDatabase) async throws -> Void
    ) async throws -> OboeDatabase {
        try await lifecycle.replaceDatabase(with: sourceURL, beforeCommit: beforeCommit)
    }

    func snapshots() async throws -> [DatabaseSnapshot] {
        try await lifecycle.snapshotService.snapshots()
    }

    @discardableResult
    func createDailySnapshotIfNeeded(hasChanges: Bool) async throws -> DatabaseSnapshot? {
        try await lifecycle.createDailySnapshotIfNeeded(hasChanges: hasChanges)
    }
}
