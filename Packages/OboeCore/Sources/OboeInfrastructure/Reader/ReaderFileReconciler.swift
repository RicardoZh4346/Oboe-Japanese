import Foundation
import OboeDomain

/// 换库后 ReaderFiles/ 与新库 `reader_documents` 的运行时对账
/// 结果（S24 §14.2 对账语义）。
public struct ReaderReconcileReport: Equatable, Sendable {
    /// 新库 reader_documents 行数。
    public var documentCount = 0
    /// `available`/`processing` 但文件侧无法证明存在 → 降级 missing。
    public var markedMissing: [UUID] = []
    /// `missing` 且文件侧能证明同一文件在场（asset 路径命中或
    /// 目录内文件 SHA-256 == source_sha256）→ 自动恢复 available。
    public var restoredAvailable: [UUID] = []
    /// `ReaderFiles/` 下存在但新库无对应文档行的目录——只报告
    /// 不删除：旧 UUID 不自动接管新 metadata（§4.3-6），清理决策
    /// 归用户/后续收敛流程。
    public var orphanDirectoryIDs: [UUID] = []

    public init() {}
}

/// 对账只读的持久化面（GRDBReaderRepository 天然满足）。
public protocol ReaderReconcileStore: Sendable {
    func fetchDocumentSummaries() async throws -> [ReaderDocumentMetadata]
    func fetchAssets(documentID: UUID) async throws -> [ReaderAssetRecord]
    func updateAvailability(
        id: UUID,
        availability: ReaderDocumentAvailability
    ) async throws
    func registerAsset(
        documentID: UUID,
        relativePath: String,
        sourceSHA256: String,
        installState: ReaderAssetInstallState
    ) async throws
}

/// 恢复屏障的 Reader 文件对账器（S24）。
///
/// 何时跑：每次数据库替换（备份恢复/本地快照恢复）的提交窗口内
/// ——`OboeDatabaseLifecycle.replaceDatabase` 的 `beforeCommit`，
/// 对账失败则整个恢复回滚到旧库（无法证明文件侧一致时不提交
/// 半恢复态）。
///
/// 规则（与 `ReaderLibraryViewModel.auditAvailability` 同口径，
/// 但跑在恢复链路、不需要 UI 在场）：
/// - `available`/`processing` + 登记的 installed 源资产解析不到
///   文件（目录缺失/路径无效/文件被删）→ `missing`；
/// - `missing` + 源文件可证在场 → `available`：
///   a) installed 资产行解析出真实文件；
///   b) 无资产行（v8 恢复——reader_assets 不导出）但
///      `ReaderFiles/<documentID>/` 内存在 SHA-256 ==
///      `source_sha256` 的常规文件 → 顺手补登记 installed 资产，
///      原设备保留文件的备份恢复自动回到可读态；
/// - 目录存在但无文档行 → 只入 `orphanDirectoryIDs` 报告，
///   绝不替用户删文件（§4.3-6：旧 UUID 不自动接到新 metadata）。
///
/// 不触碰 `InboxImages/`、附件 swap journal 与任何非 ReaderFiles
/// 目录——隔离由「本类型只读写 fileStore 管辖目录 + reader_ 表」
/// 的结构保证。
public struct ReaderFileReconciler: Sendable {
    /// 具体类型注入：对账要枚举文档目录内容（协议面只到
    /// `installedDocumentIDs`/`fileURL`，目录枚举是本服务专属需求）。
    private let fileStore: LocalReaderFileStore
    private let repository: any ReaderReconcileStore
    /// 计算目录内文件 SHA-256 的注入口（测试可替换；生产为流式度量）。
    private let digestFile: @Sendable (URL) throws -> ReaderFileDigest

    public init(
        fileStore: LocalReaderFileStore,
        repository: any ReaderReconcileStore,
        digestFile: @escaping @Sendable (URL) throws -> ReaderFileDigest
            = { try ReaderHashing.digestFile(at: $0) }
    ) {
        self.fileStore = fileStore
        self.repository = repository
        self.digestFile = digestFile
    }

    /// 全量对账。逐文档最多一次 UPDATE——只在状态变化时写
    /// （与 auditAvailability 同纪律）。
    @discardableResult
    public func reconcileAfterDatabaseReplacement() async throws
        -> ReaderReconcileReport
    {
        var report = ReaderReconcileReport()
        let documents = try await repository.fetchDocumentSummaries()
        report.documentCount = documents.count
        let documentIDs = Set(documents.map(\.id))

        let installed = Set(fileStore.installedDocumentIDs())
        report.orphanDirectoryIDs = installed
            .subtracting(documentIDs)
            .sorted { $0.uuidString < $1.uuidString }

        for document in documents {
            switch document.availability {
            case .available, .processing:
                if await sourceFileExists(document) == false {
                    try await repository.updateAvailability(
                        id: document.id, availability: .missing
                    )
                    report.markedMissing.append(document.id)
                }
            case .missing, .failed:
                if await healIfSourcePresent(document) {
                    report.restoredAvailable.append(document.id)
                }
            }
        }
        return report
    }

    /// `available` 文档的源文件在场证明：installed 资产 →
    /// fileURL 解析成功且文件存在。无 installed 源资产行
    /// （v8 恢复不导出 reader_assets）→ 视为无法证明 → false。
    private func sourceFileExists(
        _ document: ReaderDocumentMetadata
    ) async -> Bool {
        guard let assets = try? await repository.fetchAssets(
            documentID: document.id
        ) else {
            return false
        }
        for asset in assets where asset.installState == .installed {
            if let url = fileStore.fileURL(
                documentID: document.id,
                relativePath: asset.relativePath
            ), FileManager.default.fileExists(atPath: url.path) {
                return true
            }
        }
        return false
    }

    /// `missing` 文档的自动恢复：
    /// 1. installed 资产路径能解析出文件 → 直接置 available；
    /// 2. 无资产行但文档目录内有 SHA-256 命中 `source_sha256` 的
    ///    文件 → 补登记 installed 资产再置 available。
    /// 任一成立返回 true。哈希比对保证了「不会把无关文件接到
    /// 这个文档名下」——§4.2 hash-relink 的确认语义。
    private func healIfSourcePresent(
        _ document: ReaderDocumentMetadata
    ) async -> Bool {
        if await sourceFileExists(document) {
            try? await repository.updateAvailability(
                id: document.id, availability: .available
            )
            return true
        }
        let directory = fileStore.documentDirectoryURL(
            documentID: document.id
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return false
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return false
        }
        for entry in entries {
            let name = entry.lastPathComponent
            guard !name.hasPrefix("."),
                  ReaderControlledPath.isValid(name),
                  (try? entry.resourceValues(
                      forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true,
                  let digest = try? digestFile(entry),
                  digest.sha256 == document.sourceSHA256
            else {
                continue
            }
            try? await repository.registerAsset(
                documentID: document.id,
                relativePath: name,
                sourceSHA256: document.sourceSHA256,
                installState: .installed
            )
            try? await repository.updateAvailability(
                id: document.id, availability: .available
            )
            return true
        }
        return false
    }
}

extension GRDBReaderRepository: ReaderReconcileStore {}
