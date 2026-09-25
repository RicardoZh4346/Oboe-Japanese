import Foundation
import Observation
import OboeDomain
import OboeInfrastructure

/// S11 统一备份导入入口（设计 §9）：Files/AirDrop/`onOpenURL` 与
/// Settings 的「检查备份」按钮都汇到这里——security scope → 私有
/// staging 副本 → `prepareAutomatically` 全量校验 → preview → 确认
/// → `applyPreparedRestoration`。接收事件串行处理，同源 URL 去重，
/// 不并行两个恢复流程；冷启动到达的 URL 暂存到容器就绪后重放。
@MainActor
@Observable
final class BackupImportCoordinator {
    /// 全量校验通过的恢复包——非 nil 时根视图呈现 preview sheet；
    /// 确认/取消分别走 `confirmPrepared`/`discardPrepared`。
    private(set) var prepared: PreparedRestoration?
    /// 校验进行中（「正在验证」可据此展示轻量进度）。
    private(set) var isVerifying = false
    var errorMessage: String?

    private var preparer: PortableBackupRestorationPreparer?
    private var applyHandler: ((PreparedRestoration) async throws -> Void)?
    private var discardHandler: ((PreparedRestoration) async throws -> Void)?

    /// 串行接收队列：unconfigured（冷启动）与 busy（校验/预览中）
    /// 到达的 URL 都先进这里，drain 逐个消化。
    private var pendingURLs: [URL] = []
    private var intakeTask: Task<Void, Never>?
    /// 同源 URL 去重——系统对同一文件可能重复投递 openURL。
    private var inFlightSourceKeys: Set<String> = []

    private let stagingDirectoryURL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("OboeBackupImport-\(UUID().uuidString)", isDirectory: true)

    /// 容器就绪后配置真实依赖并重放暂存队列。重复调用只刷新闭包，
    /// 不清空进行中的 prepared/队列（恢复自身会触发重新发布）。
    func configure(
        preparer: PortableBackupRestorationPreparer,
        apply: @escaping @MainActor (PreparedRestoration) async throws -> Void,
        discard: @escaping @MainActor (PreparedRestoration) async throws -> Void
    ) {
        self.preparer = preparer
        self.applyHandler = apply
        self.discardHandler = discard
        kickIntake()
    }

    /// 接收入口：`file` scheme 才受理；正在处理/校验/预览时入队
    /// 串行消化，同一来源 URL 重复投递去重。
    func submit(_ url: URL) {
        guard url.isFileURL else {
            errorMessage = "不支持的备份来源：仅接受本地文件。"
            return
        }
        let key = url.standardizedFileURL.absoluteString
        guard !inFlightSourceKeys.contains(key),
              !pendingURLs.contains(where: {
                  $0.standardizedFileURL.absoluteString == key
              })
        else { return }
        pendingURLs.append(url)
        kickIntake()
    }

    /// 用户取消当前/排队的校验（Settings 与根 overlay 共用）。
    func cancelPending() {
        pendingURLs.removeAll()
        intakeTask?.cancel()
        intakeTask = nil
        isVerifying = false
    }

    /// preview 「完整替换恢复」确认：只作用于已验证的 preparation——
    /// 成功后清场并释放临时区；apply 失败向上抛给 preview 自身
    /// alert（保留现场可重试），不额外写 errorMessage 避免双提示。
    func confirmPrepared() async throws {
        guard let prepared, let applyHandler else { return }
        try await applyHandler(prepared)
        self.prepared = nil
        try? await discardHandler?(prepared)
        kickIntake()
    }

    /// preview 取消：释放 staging 临时区，不改库。
    func discardPrepared() {
        guard let prepared else { return }
        self.prepared = nil
        Task { [discardHandler] in
            try? await discardHandler?(prepared)
        }
        kickIntake()
    }

    private func kickIntake() {
        guard intakeTask == nil else { return }
        intakeTask = Task { [weak self] in
            await self?.drainPending()
        }
    }

    private func drainPending() async {
        defer { intakeTask = nil }
        while let url = pendingURLs.first {
            pendingURLs.removeFirst()
            guard preparer != nil else {
                // 容器未就绪（冷启动）——塞回队列等 configure 重放。
                pendingURLs.insert(url, at: 0)
                return
            }
            let key = url.standardizedFileURL.absoluteString
            inFlightSourceKeys.insert(key)
            await stageAndPrepare(url)
            inFlightSourceKeys.remove(key)
            if Task.isCancelled { return }
        }
    }

    /// security scope → 私有 staging 副本 → 全量校验。源 URL 的
    /// scope 只在拷贝期间持有；拷贝失败报告真实读取错误，不静默。
    private func stageAndPrepare(_ sourceURL: URL) async {
        guard let preparer else { return }
        isVerifying = true
        defer { isVerifying = false }
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        let stagedURL: URL
        do {
            stagedURL = try stageCopy(of: sourceURL)
        } catch {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
            errorMessage = "无法读取备份文件：\(error.localizedDescription)"
            return
        }
        if hasSecurityScope {
            sourceURL.stopAccessingSecurityScopedResource()
        }
        do {
            let preparation = try await preparer.prepareAutomatically(
                fileURL: stagedURL
            )
            guard !Task.isCancelled else {
                try? await preparer.discard(preparation)
                return
            }
            prepared = preparation
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stageCopy(of sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )
        let destination = stagingDirectoryURL.appendingPathComponent(
            "incoming-\(UUID().uuidString).\(sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension)"
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }
}
