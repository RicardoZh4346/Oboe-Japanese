import Foundation
import OboeInfrastructure
import OSLog

/// 备份/恢复运行期（技术文档 §10）：v7 附件目录交换的 journal、
/// staged 安装、同步回滚与启动期收敛。数据库替换本身不由这里编排——
/// 附件先于库安装、库失败时按 journal 回滚，序列由
/// `AppRuntimeController.applyPreparedRestoration` 驱动。
final class BackupRuntime {
    /// v7 附件交换日志：恢复提交窗口期崩溃时据此把 InboxImages 收敛回
    /// 一致状态（设计 §11.3 阶段 9）。
    let journalStore: AttachmentRestoreJournalStore

    init(baseURL: URL) {
        journalStore = AttachmentRestoreJournalStore(
            fileURL: baseURL.appendingPathComponent(
                "RestoreJournals/attachment-swap.json",
                isDirectory: false
            )
        )
    }

    /// 启动期恢复：上次恢复若在附件 swap 窗口期被杀，按 journal 把
    /// InboxImages 收敛到一致状态。必须在打开数据库之前运行——镜像
    /// 服务一启动就可能读附件目录。返回 `nil` 表示无 journal 或现场
    /// 无需动作；返回值为恢复后线上目录是否来自 staged 数据。
    /// 失败显式抛出：无法证明附件一致时不允许吞错继续（§8.4）。
    @discardableResult
    func recoverInterruptedSwap() throws -> Bool? {
        do {
            let installed = try AttachmentDirectorySwap.recoverInterruptedSwap(
                journalStore: journalStore
            )
            if let installed {
                Self.swapLogger.notice(
                    "Recovered interrupted attachment swap: installedStaged=\(installed, privacy: .public)"
                )
            }
            return installed
        } catch {
            Self.swapLogger.error(
                "Attachment swap recovery failed: \(String(describing: type(of: error)), privacy: .public)"
            )
            throw error
        }
    }

    /// 附件目录原子替换：现有目录移到 aside，staged 目录 rename 就位，
    /// 每个阶段都写 journal——进程在窗口期被杀由下次启动的
    /// `recoverInterruptedSwap` 收敛。
    func installStagedAttachments(
        from stagedURL: URL,
        targetURL: URL
    ) throws -> AttachmentRestoreJournal {
        let asideURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".rollback-\(targetURL.lastPathComponent)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        return try AttachmentDirectorySwap.installStagedDirectory(
            stagedURL: stagedURL,
            at: targetURL,
            asideURL: asideURL,
            journalStore: journalStore
        )
    }

    /// 库替换失败后的同步回滚：新目录挪走、aside 移回原位、清 journal。
    /// 只能用于"install 已返回但库还没换"的窗口——completeSwap 之后旧目录
    /// 已删，journal 语义不再可回滚。
    func rollbackSwap(journal: AttachmentRestoreJournal) {
        let fileManager = FileManager.default
        let targetURL = URL(fileURLWithPath: journal.targetPath)
        let trashURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".swap-rollback-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        if fileManager.fileExists(atPath: targetURL.path) {
            try? fileManager.moveItem(at: targetURL, to: trashURL)
        }
        if !journal.oldPath.isEmpty {
            let asideURL = URL(fileURLWithPath: journal.oldPath)
            if fileManager.fileExists(atPath: asideURL.path) {
                try? fileManager.moveItem(at: asideURL, to: targetURL)
            }
        }
        try? fileManager.removeItem(at: trashURL)
        try? journalStore.clear()
    }

    /// 收尾：删 aside 旧目录并把 journal 标为 completed 后清文件。
    func completeSwap(journal: AttachmentRestoreJournal) throws {
        try AttachmentDirectorySwap.completeSwap(
            journal: journal,
            journalStore: journalStore
        )
    }

    private static let swapLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oboe.app",
        category: "AttachmentSwap"
    )
}
