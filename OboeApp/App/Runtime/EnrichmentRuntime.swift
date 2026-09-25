import Foundation
import OboeDomain
import OboeInfrastructure
import OSLog

/// JLPT 回填运行期（技术文档 §10）：enrichment 任务生命周期的唯一
/// 持有者——合并调度、取消后等待、世代检查。状态经 `statusHandler`
/// 回传 controller 发布；日志只记计数与错误类别，不含用户正文。
@MainActor
final class EnrichmentRuntime {
    private var task: Task<Void, Never>?
    /// `makeServices` 完成时的 `databaseGeneration`——恢复流程中
    /// 服务已换新但操作标记未复位时仍允许调度，世代不一致（服务还
    /// 绑着旧库）则拒绝。
    private var serviceGeneration = -1

    /// 状态变化的唯一出口；controller 挂接它更新可观察的
    /// `jlptEnrichmentStatus`。
    var statusHandler: (@MainActor (JLPTEnrichmentStatus) -> Void)?

    /// 容器发布成功时登记服务世代。
    func servicePublished(generation: Int) {
        serviceGeneration = generation
    }

    /// T12 幂等回填调度（设计 §7.4）：启动、进入词库、备份恢复后触发，
    /// 全部合并到同一次后台运行。失败不阻塞主界面——状态经
    /// `statusHandler` 暴露给词库页做可重试提示。
    func schedule(
        service: JLPTLibraryEnrichmentService?,
        currentDatabaseGeneration: Int
    ) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_JLPT_ENRICHMENT_DISABLED"] != nil {
            return
        }
        #endif
        guard task == nil,
              serviceGeneration == currentDatabaseGeneration,
              let service else { return }
        statusHandler?(.running(processed: 0, total: 0))
        task = Task {
            defer { task = nil }
            do {
                let report = try await service.enrich { progress in
                    await MainActor.run { [weak self] in
                        self?.statusHandler?(.running(
                            processed: progress.processed,
                            total: progress.total
                        ))
                    }
                }
                statusHandler?(.idle)
                Self.enrichmentLogger.log(
                    "JLPT enrichment finished: candidates=\(report.candidateCount, privacy: .public) pitch=\(report.pitchFilled, privacy: .public) examples=\(report.examplesFilled, privacy: .public) missing=\(report.missingEntries, privacy: .public) skippedInconsistent=\(report.pitchSkippedInconsistent, privacy: .public)"
                )
            } catch is CancellationError {
                statusHandler?(.idle)
            } catch {
                statusHandler?(.failed(message: error.localizedDescription))
                Self.enrichmentLogger.error(
                    "JLPT enrichment failed: \(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }
    }

    /// 数据库替换前调用：取消在途回填并等它真正退出——不能让批次
    /// 写进已关闭的旧库。
    func cancelAndWait() async {
        task?.cancel()
        await task?.value
        task = nil
        statusHandler?(.idle)
    }

    private static let enrichmentLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oboe.app",
        category: "JLPTEnrichment"
    )
}
