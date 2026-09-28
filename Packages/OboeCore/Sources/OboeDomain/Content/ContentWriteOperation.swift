import Foundation

/// v0.7.0 S03：共用内容写入的事务边界。
/// `VocabularyContentCommit`/`GrammarContentCommit` 是 validated
/// command（由 ContentCardService 构建）；本类型把命令与可选的
/// capture 幂等上下文打包，使批量调用方（导入/挖词/Cloze）能在
/// **同一事务**内执行多条命令，而不是在 async service 里嵌套
/// 数据库事务。
///
/// 幂等回放：带 capture 的 operation 走既有 inbox receipt
/// （operationID + 内容 digest；重复重放返回同结果，digest 冲突拒绝）。
/// 其他域的 operation 级幂等（import_row_receipts /
/// reader_mining_receipts）由各自仓储在同一事务内记录——本协议
/// 不臆造通用 receipt 表。

/// 已验证的内容命令。扩展新命令类型时同时扩展执行器与 digest。
public enum ValidatedContentCommand: Sendable {
    case vocabulary(VocabularyContentCommit)
    case grammar(GrammarContentCommit)
    /// v0.7.0 S12：sentence Note + `sentence_cloze` Card +
    /// `cloze_definitions` 行的原子创建（§9.1–9.3）。
    case sentence(SentenceContentCommit)
}

/// 一条事务内可执行的内容写操作。
public struct ContentWriteOperation: Sendable {
    public let command: ValidatedContentCommand
    /// Inbox 捕获流程的幂等上下文；非捕获来源为 nil。
    public let capture: CaptureCommitContext?

    public init(command: ValidatedContentCommand, capture: CaptureCommitContext? = nil) {
        self.command = command
        self.capture = capture
    }
}

/// 批量事务写入边界（S17 导入执行、S11 挖词批量的依赖点）。
/// 实现方（GRDBContentCardRepository）把整批放进一次 `pool.write`：
/// 任一命令失败 → 整批回滚——批失败不得被记成部分成功。
public protocol ContentBatchWriter: Sendable {
    /// 按顺序应用整批命令；返回与输入等长的结果数组。
    /// 抛错 = 整批未提交。
    func apply(_ operations: [ContentWriteOperation]) async throws -> [ContentCommitResult]
}
