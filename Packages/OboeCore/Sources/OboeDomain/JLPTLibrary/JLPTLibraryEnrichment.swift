import Foundation

/// 词库为一条 sourceRef 提供的可回填字段（设计 §7.4）：
/// 音调与例句中文翻译。词库自身留 NULL 的字段按原样返回，
/// 由调度侧决定是否写入——服务不臆造值。
public struct BuiltinJLPTEnrichmentEntry: Equatable, Sendable {
    public let sourceRef: String
    public let pitchAccent: PitchAccent?
    public let examples: [BuiltinJLPTExample]

    public init(
        sourceRef: String,
        pitchAccent: PitchAccent?,
        examples: [BuiltinJLPTExample]
    ) {
        self.sourceRef = sourceRef
        self.pitchAccent = pitchAccent
        self.examples = examples
    }
}

/// 用户库中仍可能有空位可补的 `builtin_jlpt` Note。
/// `needsPitchAccent` 即 `pitch_accent IS NULL`；例句侧空位
/// 由存储层在写事务内逐行判定（`translation_zh IS NULL`）。
public struct JLPTEnrichmentCandidate: Equatable, Sendable {
    public let noteID: UUID
    public let sourceRef: String
    public let reading: String?
    public let needsPitchAccent: Bool

    public init(
        noteID: UUID,
        sourceRef: String,
        reading: String?,
        needsPitchAccent: Bool
    ) {
        self.noteID = noteID
        self.sourceRef = sourceRef
        self.reading = reading
        self.needsPitchAccent = needsPitchAccent
    }
}

/// 单条 Note 的一批次回填输入：`pitchAccent` 为 nil 时不写 notes；
/// `examples` 是词库侧条目，存储层按 (note_id, japanese, sort_order)
/// 匹配且仅在 `translation_zh IS NULL` 时回填。
public struct JLPTEnrichmentWrite: Equatable, Sendable {
    public let noteID: UUID
    public let pitchAccent: PitchAccent?
    public let examples: [BuiltinJLPTExample]

    public init(
        noteID: UUID,
        pitchAccent: PitchAccent?,
        examples: [BuiltinJLPTExample]
    ) {
        self.noteID = noteID
        self.pitchAccent = pitchAccent
        self.examples = examples
    }
}

public struct JLPTEnrichmentBatchResult: Equatable, Sendable {
    public var pitchFilled = 0
    public var examplesFilled = 0

    public init() {}
}

public struct JLPTEnrichmentProgress: Equatable, Sendable {
    public let processed: Int
    public let total: Int

    public init(processed: Int, total: Int) {
        self.processed = processed
        self.total = total
    }
}

/// 单次运行的可追溯汇总。`missingEntries` 记 sourceRef 在新版词库
/// 中不存在的 Note（安全跳过）；`pitchSkippedInconsistent` 记词库值与
/// 用户当前读音 mora 不一致而放弃的条数。
public struct JLPTEnrichmentReport: Equatable, Sendable {
    public var candidateCount = 0
    public var missingEntries = 0
    public var pitchFilled = 0
    public var pitchSkippedInconsistent = 0
    public var examplesFilled = 0
    public var batches = 0

    public init() {}
}

/// 词库回填状态（设计 §7.4「词库页面显示可重试状态」）。失败只携带
/// 面向用户的概括信息；详细错误走日志，不含用户正文。
public enum JLPTEnrichmentStatus: Equatable, Sendable {
    case idle
    case running(processed: Int, total: Int)
    case failed(message: String)
}

/// 只读词库侧批量取数。schema v1 词库没有新列，`offersEnrichmentData`
/// 为 false，调度方应直接视为无工作可做。
public protocol JLPTEnrichmentSource: Sendable {
    var offersEnrichmentData: Bool { get }
    func enrichmentEntries(
        for sourceRefs: [String]
    ) async throws -> [String: BuiltinJLPTEnrichmentEntry]
}

/// 用户库侧存取。所有写入只补 NULL，绝不覆盖用户已填值。
public protocol JLPTEnrichmentStore: Sendable {
    func enrichmentCandidates() async throws -> [JLPTEnrichmentCandidate]
    /// 单事务应用一批写入；返回实际落库的行数。
    func applyEnrichment(
        _ writes: [JLPTEnrichmentWrite]
    ) async throws -> JLPTEnrichmentBatchResult
}

/// 已导入 JLPT 内容的幂等回填（设计 §7.4）：启动、进入词库和备份
/// 恢复后重复运行结果不变；每批一个事务，中断后重跑继续补剩余空位。
/// 服务是纯协调器，不直接访问数据库。
public struct JLPTLibraryEnrichmentService: Sendable {
    /// 设计 §7.4：每批 100～300 条事务。
    public static let defaultBatchSize = 200

    private let source: any JLPTEnrichmentSource
    private let store: any JLPTEnrichmentStore
    private let batchSize: Int

    public init(
        source: any JLPTEnrichmentSource,
        store: any JLPTEnrichmentStore,
        batchSize: Int = JLPTLibraryEnrichmentService.defaultBatchSize
    ) {
        self.source = source
        self.store = store
        self.batchSize = max(1, batchSize)
    }

    @discardableResult
    public func enrich(
        progress: @escaping @Sendable (JLPTEnrichmentProgress) async -> Void = { _ in }
    ) async throws -> JLPTEnrichmentReport {
        var report = JLPTEnrichmentReport()
        guard source.offersEnrichmentData else { return report }

        let candidates = try await store.enrichmentCandidates()
        report.candidateCount = candidates.count
        var processed = 0
        while processed < candidates.count {
            try Task.checkCancellation()
            let end = min(processed + batchSize, candidates.count)
            let batch = candidates[processed..<end]
            let entries = try await source.enrichmentEntries(for: batch.map(\.sourceRef))
            var writes: [JLPTEnrichmentWrite] = []
            writes.reserveCapacity(batch.count)
            for candidate in batch {
                guard let entry = entries[candidate.sourceRef] else {
                    report.missingEntries += 1
                    continue
                }
                var pitch: PitchAccent?
                if candidate.needsPitchAccent, let offered = entry.pitchAccent {
                    // 只写与当前读音 mora 一致的值；读音被用户改短导致
                    // 越界时保持 NULL，不落违例数据。
                    if offered.isConsistent(withReading: candidate.reading) {
                        pitch = offered
                    } else {
                        report.pitchSkippedInconsistent += 1
                    }
                }
                writes.append(JLPTEnrichmentWrite(
                    noteID: candidate.noteID,
                    pitchAccent: pitch,
                    examples: entry.examples
                ))
            }
            let outcome = try await store.applyEnrichment(writes)
            report.pitchFilled += outcome.pitchFilled
            report.examplesFilled += outcome.examplesFilled
            report.batches += 1
            processed = end
            await progress(JLPTEnrichmentProgress(
                processed: processed,
                total: candidates.count
            ))
        }
        return report
    }
}
