import Foundation
import OboeDomain
import OboeInfrastructure
import Observation

/// Reader 库列表视图模型（S10）。
///
/// 职责：文档列表（lastOpened 倒序）、导入编排（file/paste）、
/// 删除（文档行+文件目录同事务外两步）、missing 探测与重链。
///
/// missing 判定口径（§4.2/§14）：登记为 `.installed` 的源资产行
/// `fileURL(documentID:relativePath:)` 解析不到文件 → 文档降级
/// `.missing`（行保留，书单可重链）；`.available` 但文件实际缺失的
/// 在 refresh 时同步降级。可移植备份不携带本地源文件——这是设计
/// 上的预期降级，不是错误。
@MainActor
@Observable
final class ReaderLibraryViewModel {
    /// 行模型：文档元数据 + 覆盖率徽章（可选快照）+ 学习牌组
    /// 绑定（v0.7.5 S18——有绑定即可跳「学习牌组」）。
    struct Row: Identifiable, Equatable {
        let document: ReaderDocumentMetadata
        /// unique 口径「已知或学习中」覆盖率（0…1）；nil = 无快照。
        let coverageFraction: Double?
        /// 快照是 partial（analyzed < total）时徽章弱化显示。
        let coverageIsPartial: Bool
        /// 绑定的学习牌组 id（`reader_documents.study_deck_id`；
        /// nil = 未绑定）。
        var studyDeckID: UUID?
        /// S22：活跃 AI 分析 Job 进度投影；nil = 无进行中 Job。
        var aiProgress: AIStudyJobProgress?
        var id: UUID { document.id }
    }

    private(set) var rows: [Row] = []
    private(set) var isLoading = false
    /// 非致命错误（view alert）。
    private(set) var errorMessage: String?
    /// 导入进行中（fileImporter 回调 → ingest 期间禁用按钮）。
    private(set) var isImporting = false
    /// 正在 relink 的文档（sheet 绑定：非 nil 即呈现文件选择器）。
    var relinkTarget: ReaderDocumentMetadata?

    /// 覆盖率分析进度提示：正在跑 analyze 的文档 id 集。
    private(set) var analyzingDocumentIDs = Set<UUID>()

    private let repository: any ReaderDocumentStore
    private let fileStore: any ReaderFileStore
    private let ingest: any ReaderImporting
    private let coverage: (any ReaderCoverageProviding)?
    /// S24 恢复屏障：导入/重链/覆盖率长任务登记点。
    private let workGate: RestorationWorkGate?
    /// S24 缺原文重链服务（hash 确认 + 稳定 ID 重建在包内）。
    private let relinkService: (any ReaderRelinking)?
    /// v0.7.5 S18：学习表面观察流——绑定增删/文档集合变化驱动
    /// 行级同步（不重跑分析）。
    private let learningProgress: (any LearningProgressProviding)?
    /// S22：文档级 AI 进度投影口（库行「分析中 x/y」展示）。
    private let aiStudyProgress: (any ReaderAIStudyProgressProviding)?
    private let now: @Sendable () -> Date

    /// documentID → 绑定的学习牌组 id（观察流载荷直接落盘）。
    private(set) var studyDeckByDocument: [UUID: UUID] = [:]
    /// documentID → 活跃 AI Job 进度（观察流载荷）。
    private var aiProgressByDocument: [UUID: AIStudyJobProgress] = [:]

    init(
        repository: any ReaderDocumentStore,
        fileStore: any ReaderFileStore,
        ingest: any ReaderImporting,
        coverage: (any ReaderCoverageProviding)? = nil,
        workGate: RestorationWorkGate? = nil,
        relink: (any ReaderRelinking)? = nil,
        learningProgress: (any LearningProgressProviding)? = nil,
        aiStudyProgress: (any ReaderAIStudyProgressProviding)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.fileStore = fileStore
        self.ingest = ingest
        self.coverage = coverage
        self.workGate = workGate
        self.relinkService = relink
        self.learningProgress = learningProgress
        self.aiStudyProgress = aiStudyProgress
        self.now = now
    }

    /// 装配方便捷入口。
    convenience init(
        dependencies: ReaderFeatureDependencies,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            repository: dependencies.repository,
            fileStore: dependencies.fileStore,
            ingest: dependencies.ingest,
            coverage: dependencies.coverage,
            workGate: dependencies.workGate,
            relink: dependencies.relink,
            learningProgress: dependencies.learningProgress,
            aiStudyProgress: dependencies.aiStudyProgress,
            now: now
        )
    }

    /// S18：订阅共享学习表面流——发射即「绑定/文档集合可能变」，
    /// 仅按载荷差异更新行（绑定变化 → 就地补 studyDeckID；文档
    /// 集合变化 → 重新拉取行）。不触发任何分析/写路径。
    func observeLearningSurface() async {
        guard let learningProgress else { return }
        do {
            for try await update in learningProgress.observeProgress() {
                guard !Task.isCancelled else { return }
                let links = Dictionary(
                    uniqueKeysWithValues: update.studyDeckLinks.map {
                        ($0.documentID, $0.deckID)
                    }
                )
                if links != studyDeckByDocument {
                    studyDeckByDocument = links
                    patchStudyDeckIDs()
                }
                let currentIDs = Set(rows.map(\.document.id))
                if update.readerDocumentIDs != currentIDs {
                    await refresh()
                }
            }
        } catch is CancellationError {
        } catch {
            // 失流降级为手动刷新（refreshable 仍在）。
        }
    }

    /// 把最新绑定映射写回已渲染行（不重建 document/覆盖率字段）。
    private func patchStudyDeckIDs() {
        rows = rows.map { row in
            var patched = row
            patched.studyDeckID = studyDeckByDocument[row.document.id]
            return patched
        }
    }

    /// S22：订阅文档级 AI 分析进度——Runner 每块收束即发射，
    /// 退出分析页后台续跑时库行仍实时推进。终态（completed/
    /// cancelled/failed）从投影消失 → 行徽标同步撤下。
    func observeAIStudyProgress() async {
        guard let aiStudyProgress else { return }
        do {
            for try await update in aiStudyProgress
                .observeActiveJobProgress() {
                guard !Task.isCancelled else { return }
                if update != aiProgressByDocument {
                    aiProgressByDocument = update
                    patchAIProgress()
                }
            }
        } catch is CancellationError {
        } catch {
            // 失流降级为手动刷新（refreshable 仍在）。
        }
    }

    /// 把最新 AI 进度写回已渲染行（行不在投影内 → 清零）。
    private func patchAIProgress() {
        rows = rows.map { row in
            var patched = row
            patched.aiProgress = aiProgressByDocument[row.document.id]
            return patched
        }
    }

    /// 恢复屏障登记（S24）：把长任务交给闸门。闸门开着 → 登记后
    /// 等任务自然结束并退籍；闸门已关（恢复窗口）→ 任务被立即
    /// 取消，仍等它退出让 isImporting/analyzing 状态复位，再给
    /// 用户提示。无闸门（测试桩）→ 直接跑。
    private func runEnrolled(_ task: Task<Void, Never>) async {
        guard let workGate else {
            await task.value
            return
        }
        guard let token = await workGate.enroll(task) else {
            await task.value
            errorMessage = "正在恢复备份，请稍后再试。"
            return
        }
        await task.value
        await workGate.release(token)
    }

    // MARK: - 列表

    /// `.task` 入口：取摘要 → 排序 → 覆盖率徽章 → missing 体检。
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            var documents = try await repository.fetchDocumentSummaries()
            // 最近打开优先；从未打开的按创建时间倒序。
            documents.sort {
                ($0.lastOpenedAt ?? .distantPast)
                    > ($1.lastOpenedAt ?? .distantPast)
            }
            var rows: [Row] = []
            rows.reserveCapacity(documents.count)
            var assets: [UUID: ReaderAssetRecord] = [:]
            for document in documents {
                if let list = try? await repository.fetchAssets(
                    documentID: document.id
                ) {
                    assets[document.id] = list.first {
                        $0.installState == .installed
                    }
                }
            }
            sourceAssets = assets
            for document in documents {
                var row = Row(
                    document: document,
                    coverageFraction: nil,
                    coverageIsPartial: false,
                    studyDeckID: studyDeckByDocument[document.id],
                    aiProgress: aiProgressByDocument[document.id]
                )
                if let snapshot = try? await coverage?
                    .documentSnapshot(documentID: document.id) {
                    row = Row(
                        document: document,
                        coverageFraction: snapshot
                            .uniqueKnownOrLearningCoverage,
                        coverageIsPartial: snapshot.isPartial,
                        studyDeckID: studyDeckByDocument[document.id],
                        aiProgress: aiProgressByDocument[document.id]
                    )
                }
                rows.append(row)
            }
            self.rows = rows
            await auditAvailability()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 文件体检：installed 源资产解析不到 → 文档标 missing
    /// （幂等）；missing 但文件回来了 → 自动恢复 available。
    /// 逐文档最多一次 UPDATE——只在状态变化时写。
    private func auditAvailability() async {
        for document in rows.map(\.document) {
            guard let sourceURL = sourceFileURL(for: document.id) else {
                continue
            }
            let exists = FileManager.default
                .fileExists(atPath: sourceURL.path)
            switch (document.availability, exists) {
            case (.available, false):
                try? await repository.updateAvailability(
                    id: document.id, availability: .missing
                )
                patchRow(document.id) {
                    ReaderDocumentMetadata(
                        id: $0.id, title: $0.title, format: $0.format,
                        createdAt: $0.createdAt,
                        lastOpenedAt: $0.lastOpenedAt,
                        sourceFileName: $0.sourceFileName,
                        sourceSHA256: $0.sourceSHA256,
                        canonicalTextHash: $0.canonicalTextHash,
                        parserVersion: $0.parserVersion,
                        contentRevision: $0.contentRevision,
                        progressBasisPoints: $0.progressBasisPoints,
                        availability: .missing
                    )
                }
            case (.missing, true):
                try? await repository.updateAvailability(
                    id: document.id, availability: .available
                )
                patchRow(document.id) {
                    ReaderDocumentMetadata(
                        id: $0.id, title: $0.title, format: $0.format,
                        createdAt: $0.createdAt,
                        lastOpenedAt: $0.lastOpenedAt,
                        sourceFileName: $0.sourceFileName,
                        sourceSHA256: $0.sourceSHA256,
                        canonicalTextHash: $0.canonicalTextHash,
                        parserVersion: $0.parserVersion,
                        contentRevision: $0.contentRevision,
                        progressBasisPoints: $0.progressBasisPoints,
                        availability: .available
                    )
                }
            default:
                break
            }
        }
    }

    /// refresh 期填充的源资产缓存（documentID → 首个 installed 行）。
    private var sourceAssets: [UUID: ReaderAssetRecord] = [:]

    /// 已装源文件的沙盒 URL（installed 资产 → fileURL 解析）。
    func sourceFileURL(for documentID: UUID) -> URL? {
        guard let asset = sourceAssets[documentID] else { return nil }
        return fileStore.fileURL(
            documentID: documentID, relativePath: asset.relativePath
        )
    }

    private func patchRow(
        _ documentID: UUID, mutate: (ReaderDocumentMetadata) -> ReaderDocumentMetadata
    ) {
        guard let index = rows.firstIndex(where: { $0.id == documentID })
        else { return }
        rows[index] = Row(
            document: mutate(rows[index].document),
            coverageFraction: rows[index].coverageFraction,
            coverageIsPartial: rows[index].coverageIsPartial,
            studyDeckID: rows[index].studyDeckID,
            aiProgress: rows[index].aiProgress
        )
    }

    func clearError() { errorMessage = nil }

    // MARK: - 导入

    /// document picker 回调：扩展名 → format，安全域内完成导入。
    /// 不在 VM 里做扩展名校验——parser 的 notRecognized 是诚实错误。
    /// S24：导入任务登记进恢复闸门——恢复开始即被取消抽干。
    func importPickedFile(_ url: URL) async {
        guard let format = Self.format(for: url) else {
            errorMessage = "不支持的文件类型（支持 txt/epub/srt/vtt）。"
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let task = Task<Void, Never> { [weak self] in
            await self?.performFileImport(url, format: format)
        }
        await runEnrolled(task)
    }

    private func performFileImport(
        _ url: URL, format: ReaderDocumentFormat
    ) async {
        isImporting = true
        defer { isImporting = false }
        do {
            _ = try await ingest.importFile(
                fileURL: url,
                format: format,
                encodingOverride: nil,
                limits: .default,
                documentID: UUID(),
                progress: nil
            )
            await refresh()
        } catch let error as ReaderParserError {
            if case .cancelled = error { return }
            errorMessage = Self.describe(error)
        } catch is CancellationError {
            // 恢复闸门取消——静默。
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 粘贴导入：importPaste 内部已规范化并落 UTF-8 TXT。
    func importPastedText(_ text: String) async {
        let task = Task<Void, Never> { [weak self] in
            await self?.performPasteImport(text)
        }
        await runEnrolled(task)
    }

    private func performPasteImport(_ text: String) async {
        isImporting = true
        defer { isImporting = false }
        do {
            _ = try await ingest.importPaste(
                text,
                limits: .default,
                documentID: UUID(),
                progress: nil
            )
            await refresh()
        } catch let error as ReaderParserError {
            if case .cancelled = error { return }
            errorMessage = Self.describe(error)
        } catch is CancellationError {
            // 恢复闸门取消——静默。
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 扩展名 → ReaderDocumentFormat；未知返回 nil。
    static func format(for url: URL) -> ReaderDocumentFormat? {
        switch url.pathExtension.lowercased() {
        case "txt": .txt
        case "epub": .epub
        case "srt": .srt
        case "vtt": .vtt
        default: nil
        }
    }

    // MARK: - 删除 / missing / relink

    /// 确认后的删除：文档行（级联章/块/位置/书签/资产行）+ 文件目录。
    /// 两步非原子——文件目录清理失败仅留孤儿文件，collectOrphans
    /// 启动期会收敛；文档行删除失败则整个动作报错。
    func delete(_ document: ReaderDocumentMetadata) async {
        do {
            try await repository.deleteDocument(id: document.id)
            try await fileStore.removeFiles(documentID: document.id)
            await refresh()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    /// relink 第一阶段：要求选择文件 → view 呈现 fileImporter，
    /// 回调进 `relinkPickedFile`。
    func beginRelink(_ document: ReaderDocumentMetadata) {
        relinkTarget = document
    }

    /// relink 执行（S24）：完整流程收进 `ReaderRelinkService`——
    /// stage → SHA-256/canonical 二段确认 → 目录换新安装 →
    /// 稳定 ID 章/块重建 → 单事务提交（进度/书签/位置保留）。
    /// VM 只负责 security-scope 生命周期与错误文案。
    func relinkPickedFile(_ url: URL) async {
        guard let document = relinkTarget else { return }
        relinkTarget = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let task = Task<Void, Never> { [weak self] in
            await self?.performRelink(document: document, url: url)
        }
        await runEnrolled(task)
    }

    private func performRelink(
        document: ReaderDocumentMetadata, url: URL
    ) async {
        guard let relinkService else {
            errorMessage = "重链服务不可用。"
            return
        }
        do {
            _ = try await relinkService.relink(
                documentID: document.id,
                preparedFileURL: url,
                format: Self.format(for: url),
                encodingOverride: nil,
                limits: .default,
                displayName: url.lastPathComponent,
                progress: nil
            )
            await refresh()
        } catch ReaderRelinkError.contentMismatch {
            errorMessage = "所选文件与「\(document.title)」内容不一致，未重链。"
        } catch ReaderRelinkError.documentNotFound {
            errorMessage = "文档已不存在。"
        } catch ReaderRelinkError.cancelled {
            // 恢复闸门取消——静默。
        } catch is CancellationError {
        } catch let error as ReaderParserError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = "重链失败：\(error.localizedDescription)"
        }
    }

    /// 「计算覆盖率」动作（badge 为空时的入口）。S24：登记进恢复
    /// 闸门——分析写 token/覆盖率相关缓存，恢复窗口内不得写旧库。
    func runCoverage(for documentID: UUID) async {
        guard coverage != nil else { return }
        let task = Task<Void, Never> { [weak self] in
            await self?.performCoverage(documentID: documentID)
        }
        await runEnrolled(task)
    }

    private func performCoverage(documentID: UUID) async {
        guard let coverage else { return }
        analyzingDocumentIDs.insert(documentID)
        defer { analyzingDocumentIDs.remove(documentID) }
        do {
            _ = try await coverage.analyze(documentID: documentID)
            await refresh()
        } catch is CancellationError {
            // 用户离开/下拉刷新/恢复闸门打断——静默。
        } catch {
            errorMessage = "覆盖率分析失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 文案

    /// ReaderParserError → 用户可读短文案（不泄露内部 enum 形态）。
    static func describe(_ error: ReaderParserError) -> String {
        switch error {
        case .notRecognized:
            "文件格式无法识别。"
        case .malformedContainer(let reason):
            "容器结构损坏（\(reason)）。"
        case .missingContainerXML:
            "EPUB 缺少 container.xml。"
        case .malformedOPF(let reason):
            "EPUB 目录信息损坏（\(reason)）。"
        case .encryptedContent:
            "文档包含加密/DRM 内容，无法读取。"
        case .fixedLayoutUnsupported:
            "固定布局 EPUB 暂不支持。"
        case .unsupportedVariant(let variant):
            "不支持的压缩/封装形态（\(variant)）。"
        case .limitExceeded(let metric, _, _):
            "文件超出限制（\(metric)）。"
        case .unsafeEntryPath(let path):
            "包内路径不安全（\(path)）。"
        case .undeterminedEncoding:
            "无法确定文件编码。"
        case .malformedCue(let line, let reason):
            "第 \(line) 行字幕格式错误（\(reason)）。"
        case .emptyContent:
            "内容为空。"
        case .cancelled:
            "已取消。"
        }
    }
}
