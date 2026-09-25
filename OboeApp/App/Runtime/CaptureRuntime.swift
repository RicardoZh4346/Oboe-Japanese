import Foundation
import OboeDomain
import OboeInfrastructure
import OboeSharedCapture

/// 采集运行期（技术文档 §10）：App Group 共享队列 drain、
/// `pauseAndWait`、待处理计数与附件引用安全清理。所有方法都是
/// 每代服务句柄的纯委托——句柄本身随容器世代更换，这里不缓存。
@MainActor
struct CaptureRuntime {

    /// Shared-queue consumption is triggered by hints (cold start, returning
    /// to foreground, entering the Inbox) — the pending directory is the
    /// source of truth, and the coordinator coalesces duplicate drains.
    /// 返回最新一条 `continueInApp` 导入的 itemID（无则 nil）。
    func drainPendingCaptures(
        using coordinator: CaptureImportCoordinator
    ) async -> UUID? {
        guard let report = try? await coordinator.drainPendingCaptures()
        else { return nil }
        return report.imported.last(where: {
            $0.requestedAction == .continueInApp
        })?.itemID
    }

    /// 数据库替换前调用：暂停导入并等在途 drain 结束——pending 文件
    /// 留在磁盘上，由新容器里的 coordinator 恢复续传。
    func pauseAndWait(using coordinator: CaptureImportCoordinator) async {
        await coordinator.pauseAndWait()
    }

    /// 恢复后仍躺在共享队列里的文件数；0 也返回 nil（调用方把 nil
    /// 当"没有待导入"）。App Group 不可用时同样 nil——调用方不得
    /// 把它误报为零。
    func pendingFileCount(using store: (any CaptureQueueStoring)?) -> Int? {
        try? store?.pendingFileURLs().count
    }

    /// Reclaims attachment files no persisted owner references — abandoned
    /// picks, items removed before the cleanup hook existed, restore-orphaned
    /// resources. keep 集合来自统一引用查询（D09）：`inbox_items ∪
    /// source_contexts`——被 Note 来源引用的图片不被误删。
    /// A creation-time buffer protects files still being attached.
    func sweepOrphanedInboxImages(
        attachmentReferences: any AttachmentReferenceRepository,
        inboxImageStore: InboxImageStore
    ) async {
        guard let referenced = try? await attachmentReferences.referencedResourceIDs(),
              let orphans = try? inboxImageStore.orphanedResourceIDs(
                  keeping: referenced,
                  olderThan: 60
              ) else { return }
        for resourceID in orphans {
            try? inboxImageStore.delete(resourceID)
        }
    }
}
