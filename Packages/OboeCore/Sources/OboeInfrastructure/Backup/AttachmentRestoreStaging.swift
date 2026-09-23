import Foundation

/// 附件目录原子替换的恢复日志阶段（设计 §11.3 的 Commit 阶段）。
/// 每一步先落盘再改文件系统，进程在任意点崩溃都能按 journal
/// 恢复到一致状态。
public enum AttachmentRestorePhase: String, Codable, Sendable {
    /// staged 目录就绪，线上目录尚未被触碰。
    case stagedNewDirectory
    /// 线上目录已移到 aside 位置——唯一真正的危险窗口：
    /// 此时 target 缺失，恢复动作是把 aside 移回 target。
    case movedCurrentAside
    /// staged 目录已安装到 target。
    case installedNewDirectory
    /// aside 旧目录已清理，整个 swap 完成。
    case completed
    /// 任一步骤失败；journal 保留现场供排查或重试。
    case failed
}

/// 附件目录 swap 的持久化日志。只描述文件系统状态，不涉数据库——
/// 数据库 swap 的编排在上层，两边的 commit 顺序由上层保证。
public struct AttachmentRestoreJournal: Codable, Equatable, Sendable {
    public var phase: AttachmentRestorePhase
    /// 线上附件目录的目标位置（swap 完成后新目录所在处）。
    public var targetPath: String
    /// 旧目录被移开后的 aside 路径；从未存在旧目录时为空串。
    public var oldPath: String
    /// staged 新目录的路径。
    public var newPath: String
    public var timestamp: Date

    public init(
        phase: AttachmentRestorePhase,
        targetPath: String,
        oldPath: String,
        newPath: String,
        timestamp: Date = Date()
    ) {
        self.phase = phase
        self.targetPath = targetPath
        self.oldPath = oldPath
        self.newPath = newPath
        self.timestamp = timestamp
    }
}

/// journal 文件的原子读写（pending 文件 + rename，与备份导出同一约定）。
public struct AttachmentRestoreJournalStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> AttachmentRestoreJournal? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AttachmentRestoreJournal.self, from: data)
    }

    public func save(_ journal: AttachmentRestoreJournal) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(journal)
        let pendingURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).pending-\(UUID().uuidString.lowercased())"
        )
        do {
            try data.write(to: pendingURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: pendingURL)
        } catch {
            try? FileManager.default.removeItem(at: pendingURL)
            throw error
        }
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public enum AttachmentRestoreStagingError: Error, Equatable, Sendable {
    /// staged 目录不存在或不是目录。
    case missingStagedDirectory(String)
    /// aside 目标路径已被占用。
    case asideDestinationOccupied(String)
    /// journal 指向的目录与期望不一致（现场已被外力改动）。
    case inconsistentJournal(String)
}

extension AttachmentRestoreStagingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .missingStagedDirectory(path):
            "待安装的附件目录不存在：\(path)"
        case let .asideDestinationOccupied(path):
            "附件回退目录已被占用：\(path)"
        case let .inconsistentJournal(reason):
            "附件恢复日志与文件系统状态不一致：\(reason)"
        }
    }
}

/// 附件目录的纯原子替换操作：rename 序列 + journal。
/// 不知道数据库的存在；调用方负责把 DB swap 编排进同一事务窗口。
public enum AttachmentDirectorySwap {
    /// `stagedURL` → `targetURL`：先把现有 target 移到 `asideURL`
    /// （若存在），再把 staged 安装到 target。每步之后写 journal。
    /// 成功后 stagedURL 不再存在（已就位 target）。
    @discardableResult
    public static func installStagedDirectory(
        stagedURL: URL,
        at targetURL: URL,
        asideURL: URL,
        journalStore: AttachmentRestoreJournalStore
    ) throws -> AttachmentRestoreJournal {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: stagedURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw AttachmentRestoreStagingError.missingStagedDirectory(stagedURL.path)
        }
        let targetExists = fileManager.fileExists(atPath: targetURL.path)
        if targetExists {
            guard !fileManager.fileExists(atPath: asideURL.path) else {
                throw AttachmentRestoreStagingError.asideDestinationOccupied(
                    asideURL.path
                )
            }
        }

        var journal = AttachmentRestoreJournal(
            phase: .stagedNewDirectory,
            targetPath: targetURL.path,
            oldPath: targetExists ? asideURL.path : "",
            newPath: stagedURL.path
        )
        do {
            try journalStore.save(journal)
            if targetExists {
                try fileManager.moveItem(at: targetURL, to: asideURL)
                journal.phase = .movedCurrentAside
                journal.timestamp = Date()
                try journalStore.save(journal)
            }
            try fileManager.moveItem(at: stagedURL, to: targetURL)
            journal.phase = .installedNewDirectory
            journal.timestamp = Date()
            try journalStore.save(journal)
            return journal
        } catch {
            journal.phase = .failed
            journal.timestamp = Date()
            try? journalStore.save(journal)
            throw error
        }
    }

    /// 收尾：删 aside 旧目录并把 journal 标为 completed（随后清文件）。
    public static func completeSwap(
        journal: AttachmentRestoreJournal,
        journalStore: AttachmentRestoreJournalStore
    ) throws {
        let fileManager = FileManager.default
        if !journal.oldPath.isEmpty,
           fileManager.fileExists(atPath: journal.oldPath) {
            try fileManager.removeItem(atPath: journal.oldPath)
        }
        var completed = journal
        completed.phase = .completed
        completed.timestamp = Date()
        try journalStore.save(completed)
        try journalStore.clear()
    }

    /// 崩溃恢复：按 journal 记录的阶段把附件目录收敛到一致状态。
    /// - stagedNewDirectory：target 未被触碰，直接丢弃 journal。
    /// - movedCurrentAside：target 缺失而 aside 在 → aside 移回 target。
    /// - installedNewDirectory / completed：新目录已就位 → 清 aside 收尾。
    /// - failed：按文件系统实际状态补做——target 缺失就回滚 aside。
    /// 返回恢复后的线上目录是否存在新内容（true = 用的是 staged 数据）。
    @discardableResult
    public static func recoverInterruptedSwap(
        journalStore: AttachmentRestoreJournalStore
    ) throws -> Bool? {
        guard let journal = try journalStore.load() else { return nil }
        let fileManager = FileManager.default
        let targetURL = URL(fileURLWithPath: journal.targetPath)
        let asideURL = URL(fileURLWithPath: journal.oldPath)
        let targetExists = fileManager.fileExists(atPath: targetURL.path)
        let asideExists = !journal.oldPath.isEmpty
            && fileManager.fileExists(atPath: asideURL.path)

        switch journal.phase {
        case .stagedNewDirectory:
            try journalStore.clear()
            return nil
        case .movedCurrentAside:
            // 崩溃发生在窗口期：线上目录缺失，把 aside 移回去。
            if !targetExists, asideExists {
                try fileManager.moveItem(at: asideURL, to: targetURL)
            }
            try journalStore.clear()
            return false
        case .installedNewDirectory:
            if asideExists {
                try? fileManager.removeItem(at: asideURL)
            }
            try journalStore.clear()
            return true
        case .completed:
            if asideExists {
                try? fileManager.removeItem(at: asideURL)
            }
            try journalStore.clear()
            return true
        case .failed:
            // 不确定窗口落在哪一步：target 缺失且 aside 在就回滚。
            if !targetExists, asideExists {
                try fileManager.moveItem(at: asideURL, to: targetURL)
                try journalStore.clear()
                return false
            }
            if targetExists, asideExists {
                try? fileManager.removeItem(at: asideURL)
                try journalStore.clear()
                return true
            }
            try journalStore.clear()
            return nil
        }
    }
}
