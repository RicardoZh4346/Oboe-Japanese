import Foundation

/// 跨世代共享的数据库世代读源（S11 挖词世代屏障的活读口）。
///
/// `AppRuntimeController.databaseGeneration` 是 @MainActor 状态——
/// `ReaderMiningService` 在 GRDB 写事务内要**同步**复核
/// `expectedGeneration`，不能 await 回主线程。控制器持有一只本盒，
/// 每次 `databaseGeneration` 变更（didSet）同步写入；服务拿到的
/// `currentGeneration` 闭包读这里，因而在「旧容器尚未拆、世代已先
/// 递增」的恢复窗口内也能拒写旧代请求。
final class DatabaseGenerationSource: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    /// 当前已发布/已取号的世代。恢复路径先 bump 后换库，本值随之提前。
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ newValue: Int) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }
}
