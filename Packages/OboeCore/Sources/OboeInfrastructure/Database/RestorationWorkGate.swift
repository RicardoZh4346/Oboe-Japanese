import Foundation

/// 恢复屏障工作闸门（S24，设计 §14.2）：恢复开始前列队登记的
/// 长任务（Reader 导入/覆盖率分析/CSV 导入执行）必须可取消且
/// 可等待——数据库替换窗口内绝不允许旧任务回写旧库。
///
/// 语义：
/// - `enroll` 登记已启动的任务句柄。闸门关闭后登记即拒绝并
///   **立即取消该任务**——登记与关门在 actor 上串行，晚到的
///   登记不可能漏出取消名单（enroll-then-close 或
///   close-then-enroll 两序皆安全）。
/// - `closeAndWait` 幂等：关门 → 取消全部 → 逐句柄 `await value`
///   等任务真正退出（合作式取消，各服务在批/块边界检查
///   `Task.isCancelled`）。
/// - 闸门**单向**：关闭后不重开。恢复完成后由新世代容器注入
///   新实例——恢复完成前新任务天然不启动。
///
/// 本类型无 DB 依赖：它是运行期协调原语，可靠性由任务自身
/// 的合作式取消决定（与 `EnrichmentRuntime.cancelAndWait`、
/// `CaptureImportCoordinator.pauseAndWait` 同一纪律）。
public actor RestorationWorkGate {
    /// 登记的活任务；key 为内部 token。
    private var running: [UUID: Task<Void, Never>] = [:]
    /// 关门后 `enroll` 拒绝并取消来件。
    public private(set) var isClosed = false

    public init() {}

    /// 登记在途任务。返回 nil 表示闸门已关——任务已被取消，
    /// 调用方据此给用户一个「恢复中」提示。
    @discardableResult
    public func enroll(_ task: Task<Void, Never>) -> UUID? {
        guard !isClosed else {
            task.cancel()
            return nil
        }
        let token = UUID()
        running[token] = task
        return token
    }

    /// 任务自然结束退籍（可选——`closeAndWait` 不依赖它收敛，
    /// 只为常驻运行期保持字典干净）。
    public func release(_ token: UUID) {
        running.removeValue(forKey: token)
    }

    /// 恢复入口：关门 → 取消全部登记任务 → 等全部退出。幂等。
    /// 等的是 `Task.value` 而非退籍回调——即便任务忘了 release
    /// 也不会挂起恢复。
    public func closeAndWait() async {
        isClosed = true
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        running.removeAll()
    }
}
