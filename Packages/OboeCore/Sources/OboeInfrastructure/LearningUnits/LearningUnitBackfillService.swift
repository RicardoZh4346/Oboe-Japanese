import CryptoKit
import Foundation
import GRDB
import OboeDomain

/// v0.7.5 S05：存量迁移回填服务 + 词典换库重绑定 + 守恒审计。
/// 依据：contracts-frozen rev2 §1/§2/§6、decisions D02/D03/D04/D19、
/// 技术文档 §3.2「无词典词与存量 Note」/§3.3「不依赖 AI 的迁移」、
/// identity-spike.md §1.2/§2（alias 重绑纪律）。
///
/// # 三件事
///
/// 1. **分批 checkpoint 回填**（默认 200/批，批间可中断续跑）：
///    每条既有 vocabulary Note 按证据分派——
///    `source_contexts.dictionary_sense_key`（`entryID:senseID`，须与
///    当前快照同 dataset_version）/ `lexeme_dictionary_bindings` /
///    `lexemes.entry_id` 能验证**同版本唯一义项** → dictionarySense
///    unit + verified alias（status=current）+ link；义项候选多份或
///    证据冲突 → `legacy-note:<noteUUID>` legacyUnresolved unit +
///    `learning_unit_migration_items(needsConfirmation)`；无证据 →
///    `local-note:<noteUUID>` localNote unit。
///    旧 `vocabulary_knowledge_overrides`：known 且唯一可靠义项 →
///    该 unit `too_easy=true`（flag CAS + `tooEasySet` provenance
///    event）；known 但义项不明 → migration item 留 `old_state='known'`
///    待确认，不猜停；ignored → `skipped` 证据存档，不转 tooEasy。
/// 2. **守恒审计**：`auditSummary()` 输出 notes/cards/review_logs
///    行数、ID 集合摘要与逐列内容摘要（cards 含全部 FSRS 调度列），
///    回填前后两个快照 `Equatable` 比较即守恒断言。
/// 3. **词典换库重绑定**（`rebindAliases`）：对全部 dictionarySense
///    unit 按 `semantic_fingerprint` 在新快照找候选——唯一 → 补
///    current alias、旧 alias 转 superseded、binding_status=current；
///    多候选 → needsConfirmation；零候选 → stale。**绝不改 unit
///    UUID / identity_key**（spike 纪律，§3.1）。
///
/// # Checkpoint 形态选择（任务二选一，本文说明）
///
/// **复用 `learning_unit_migration_items`**，不引入专门进度表：
/// - 每条已处理 Note/override 落一行审计项
///   （`source_key = note:<uuid>` / `override:<lexemeUUID>`），既是迁移
///   证据又是游标——「未处理 = 无对应 source_key 行」，中断后重跑
///   自然续扫剩余行，无需额外 checkpoint 列；
/// - 审计项**任何状态都遮蔽重扫**（含 needsConfirmation）：否则页
///   扫描反复命中同一批待确认行、单轮永不收敛。待确认行的后续
///   处置走人工确认/词典重绑等独立路径，不靠回填重扫；
/// - 完成时写 `backfill:run` 汇总行（status=applied）作整轮凭据。
/// 该选择在 v23 冻结 schema 内零加表，契合「迁移条目是兼容证据、
/// 不参与运行态」的冻结语义（§6）。
///
/// # 幂等
///
/// - unit：`identity_key` 解析不重建（S04 resolveOrCreate 语义）；
/// - link：note_id UNIQUE + 同三元组幂等；
/// - flag：`setFlagTooEasy` 走 operationID 幂等（opID 用
///   `s05-*` 命名空间确定性派生 UUID——重跑回放同 payload 不重写）；
/// - 事件：noteLinked/noteUnlinked/migrated 的 operationID 同样
///   确定性派生，重放不产生第二行；
/// - 审计项：source_key upsert。
/// 结论：整轮回放**零新增行**（测试断言行数守恒）。
///
/// # 多 Note 同 unit 的 primary 选举（§3.2）
///
/// 同义项历史重复 Note 不删不合：链接时按「Note `created_at_ms`
/// 最早、并列 `note_id` 字典序最小」确定性选 primary，其余
/// `legacy_secondary`。选举在写事务内对全体现有链接重算——扫描
/// 顺序不影响终态，后到但更「老」的 Note 会确定性接管 primary。
///
/// # 运行形态
///
/// 全部读写走 `static …(in db: Database)` 事务内形态（组合事务可
/// 复用，S06/S19 直接调用）；actor 门面只做 `pool.read/write`
/// 分批驱动 + 词典侧读取（词典是独立只读库，不进用户库写事务）。
public actor LearningUnitBackfillService {
    /// 回填规则版本——run marker 与报告引用；规则变更 bump。
    public static let backfillVersion = "s05-backfill-1"
    /// 重绑规则版本——报告引用。
    public static let rebindVersion = "s05-rebind-1"
    public static let defaultBatchSize = 200

    /// migration item `source_key` 前缀（审计/游标命名空间）。
    public static let noteItemPrefix = "note:"
    public static let overrideItemPrefix = "override:"
    public static let rebindItemPrefix = "rebind:"
    /// 整轮凭据行 source_key。
    public static let runMarkerSourceKey = "backfill:run"

    private let pool: DatabasePool
    private let batchSize: Int
    private let now: @Sendable () -> Date

    public init(
        pool: DatabasePool,
        batchSize: Int = defaultBatchSize,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pool = pool
        self.batchSize = max(1, batchSize)
        self.now = now
    }

    public init(
        database: OboeDatabase,
        batchSize: Int = defaultBatchSize,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(pool: database.pool, batchSize: batchSize, now: now)
    }

    // MARK: - 词典快照义项读取通道

    /// 当前词典快照内一个义项行的验证投影（重绑/回填共用输入）。
    /// `fingerprint` 由实现方按 `SemanticFingerprint`（sense-fp-1）
    /// 现场计算——调用方不假设上游行 id 稳定，只认指纹。
    public struct VerifiedSense: Equatable, Sendable {
        public let entryID: Int64
        public let senseID: Int64
        public let fingerprint: String
        public let fingerprintVersion: String
        /// 有序英文 gloss（指纹输入，快照证据入 unit snapshot）。
        public let glossesEN: [String]
        public let posCodes: [String]

        public init(
            entryID: Int64,
            senseID: Int64,
            fingerprint: String,
            fingerprintVersion: String = SemanticFingerprint
                .semanticFingerprintVersion,
            glossesEN: [String] = [],
            posCodes: [String] = []
        ) {
            self.entryID = entryID
            self.senseID = senseID
            self.fingerprint = fingerprint
            self.fingerprintVersion = fingerprintVersion
            self.glossesEN = glossesEN
            self.posCodes = posCodes
        }
    }

    /// 词典快照 sense 级验证通道（对 `LearningUnitBackfillService`
    /// 的两类用法：回填时验证 Note 指向的义项、换库时按指纹找候选）。
    /// 实现可来自真实词典 sqlite（`GRDBLearningUnitSenseSnapshotReader`）
    /// 或测试夹具。
    public protocol SenseSnapshotReader: Sendable {
        /// `dictionary_metadata.dataset_version`；nil/空 = 词典不可用。
        func datasetVersion() async throws -> String?
        /// 某 entry 在快照内的全部义项（含指纹）；entry 不存在 → []。
        /// 指纹候选查询按「fingerprint 内嵌 entry_id」归约到本调用。
        func verifiedSenses(entryID: Int64) async throws -> [VerifiedSense]
    }

    // MARK: - 报告类型

    /// 一轮 `run` 的统计快照（与 `backfill:run` 凭据行 evidence 同源）。
    public struct BackfillSummary: Equatable, Sendable {
        /// 扫描到的 vocabulary Note 数（含已关联跳过的）。
        public var notesScanned = 0
        /// 验证唯一义项 → dictionarySense（共享 key）的 Note 数。
        public var notesBoundVerified = 0
        /// 义项行明确但同 entry 指纹碰撞 → dictionarySense 隔离 key。
        public var notesBoundIsolated = 0
        /// 多义/冲突 → legacyUnresolved + needsConfirmation 的 Note 数。
        public var notesPendingConfirmation = 0
        /// 无词典证据 → localNote 的 Note 数。
        public var notesLocal = 0
        /// 已有关联且非本服务投影 → 跳过的 Note 数。
        public var notesAlreadyLinked = 0
        /// 「未回填投影」被真实决策替换的 Note 数。
        public var projectionsReplaced = 0
        /// 投影 unit 的 tooEasy flag 随迁到目标 unit 的次数。
        public var flagsCarried = 0
        /// known override 唯一义项 → 落 tooEasy flag 数。
        public var overridesKnownFlagged = 0
        /// known override 义项不明 → needsConfirmation 数。
        public var overridesKnownPending = 0
        /// ignored override 仅存档数。
        public var overridesIgnoredArchived = 0
        /// 读/写间隙被删除的 Note 数。
        public var skippedDeleted = 0
        /// 已提交批次数（中断续跑计数）。
        public var batchesCommitted = 0
        /// true = 命中 batchLimit/取消，未跑完（重跑续接）。
        public var interrupted = false
        public var notesPhaseComplete = false
        public var overridesPhaseComplete = false

        public init() {}
    }

    /// 一轮 `rebindAliases` 的统计快照。
    public struct RebindSummary: Equatable, Sendable {
        public var datasetVersion: String
        public var unitsScanned = 0
        /// 唯一指纹候选 → 新快照行重绑（含本就绑定的 current 行）。
        public var rebound = 0
        /// 重放/无位移——已绑同一行仍是 current。
        public var confirmedCurrent = 0
        /// 多候选 → needsConfirmation。
        public var markedAmbiguous = 0
        /// 零候选 → stale（保留旧行引用可重试）。
        public var markedStale = 0
        /// 目标四元组已被**另一** unit 占用（冲突不抢占）。
        public var aliasConflicts = 0
        public var batchesCommitted = 0
        public var interrupted = false

        public init(datasetVersion: String) {
            self.datasetVersion = datasetVersion
        }
    }

    /// 守恒审计快照：回填/重绑前后各取一次，`Equatable` 比较。
    /// - `*Count`：notes/cards/review_logs 行数；
    /// - `*IDsDigest`：主键集合 sha256（排序拼接）；
    /// - `*Digest`：逐列内容 sha256——cards 覆盖全部 FSRS/调度列
    ///   （stability/due/last_review/first_studied/state/reps 等）。
    public struct AuditSnapshot: Equatable, Sendable {
        public var notesCount = 0
        public var cardsCount = 0
        public var reviewLogsCount = 0
        public var noteIDsDigest = ""
        public var cardIDsDigest = ""
        public var reviewLogIDsDigest = ""
        public var notesDigest = ""
        public var cardsFSRSDigest = ""
        public var reviewLogsDigest = ""

        public init() {}

        /// 前后快照差异清单（空 = 守恒成立），供测试/迁移报告引用。
        public func differences(from before: AuditSnapshot) -> [String] {
            var diffs: [String] = []
            func check(_ name: String, _ a: String, _ b: String) {
                if a != b { diffs.append(name) }
            }
            check("notes.count", String(before.notesCount), String(notesCount))
            check("notes.ids", before.noteIDsDigest, noteIDsDigest)
            check("notes.rows", before.notesDigest, notesDigest)
            check("cards.count", String(before.cardsCount), String(cardsCount))
            check("cards.ids", before.cardIDsDigest, cardIDsDigest)
            check("cards.fsrs", before.cardsFSRSDigest, cardsFSRSDigest)
            check(
                "review_logs.count",
                String(before.reviewLogsCount), String(reviewLogsCount))
            check("review_logs.ids", before.reviewLogIDsDigest, reviewLogIDsDigest)
            check("review_logs.rows", before.reviewLogsDigest, reviewLogsDigest)
            return diffs
        }
    }

    // MARK: - 查询侧投影 helper（§3.3「未回填 Note 不漏计」）

    /// 未回填 vocabulary Note 的稳定临时投影 identity key——
    /// `legacy-note:<noteUUID 小写>`（contracts §1.1）。
    public static func legacyNoteIdentityKey(noteID: UUID) -> String {
        "legacy-note:\(DatabaseValueCodec.encode(noteID))"
    }

    /// localNote unit 的 identity key——`local-note:<noteUUID 小写>`。
    public static func localNoteIdentityKey(noteID: UUID) -> String {
        "local-note:\(DatabaseValueCodec.encode(noteID))"
    }

    /// Note 当前进度归属的 unit identity key：已有关联 → 其 unit 的
    /// identity_key；未关联 → `legacy-note:` 稳定投影。进度/覆盖率
    /// 查询对未回填 Note 用本函数归入 unit 计数，不漏计（§3.3）。
    public static func projectedUnitIdentityKey(
        noteID: UUID, in db: Database
    ) throws -> String {
        if let link = try GRDBLearningUnitRepository.fetchLink(
            noteID: noteID, in: db),
           let unit = try GRDBLearningUnitRepository.fetchUnit(
               id: link.unitID, in: db) {
            return unit.identityKey
        }
        return legacyNoteIdentityKey(noteID: noteID)
    }

    /// 「需写 Too Easy / 需稳定 unit 时先原子 ensure unit/link」
    /// （§3.3）：未关联的 vocabulary Note 就地建
    /// `legacy-note:` legacyUnresolved unit + primary link；已关联 →
    /// 返回既有 unit（无论投影还是正式绑定，幂等）。
    /// S06 统一写路径与 S07/S08 Too Easy 入口共用本函数。
    @discardableResult
    public static func ensureLegacyNoteUnit(
        noteID: UUID,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> LearningUnit {
        if let link = try GRDBLearningUnitRepository.fetchLink(
            noteID: noteID, in: db),
           let unit = try GRDBLearningUnitRepository.fetchUnit(
               id: link.unitID, in: db) {
            return unit
        }
        let noteRow = try noteRow(noteID: noteID, in: db)
        guard let noteRow else {
            throw LearningUnitRepositoryError.noteNotFound(noteID)
        }
        let key = legacyNoteIdentityKey(noteID: noteID)
        let unit = try GRDBLearningUnitRepository.resolveOrCreateUnit(
            identityKind: .legacyUnresolved,
            identityKey: key,
            lemma: noteRow.headword,
            reading: noteRow.reading,
            bindingStatus: .legacy,
            atMilliseconds: atMilliseconds,
            in: db)
        try insertUnitEventIfAbsent(
            unitID: unit.id, kind: .migrated,
            seed: "s05-unit|\(key)", afterJSON: nil,
            atMilliseconds: atMilliseconds, in: db)
        _ = try GRDBLearningUnitRepository.linkNote(
            unitID: unit.id, noteID: noteID, role: .primary,
            origin: .backfill, atMilliseconds: atMilliseconds, in: db)
        return unit
    }

    public func projectedUnitIdentityKey(
        noteID: UUID
    ) async throws -> String {
        try await pool.read { db in
            try Self.projectedUnitIdentityKey(noteID: noteID, in: db)
        }
    }

    @discardableResult
    public func ensureLegacyNoteUnit(
        noteID: UUID, at date: Date
    ) async throws -> LearningUnit {
        let atMs = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            try Self.ensureLegacyNoteUnit(
                noteID: noteID, atMilliseconds: atMs, in: db)
        }
    }

    // MARK: - 守恒审计（§3.3「迁移前后核对」）

    /// 事务内审计快照：notes/cards/review_logs 行数 + ID 集合摘要 +
    /// 逐列内容摘要（含 cards 全部 FSRS 调度列）。
    public static func auditSnapshot(in db: Database) throws -> AuditSnapshot {
        var snapshot = AuditSnapshot()
        snapshot.notesCount = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM notes") ?? 0
        snapshot.cardsCount = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM cards") ?? 0
        snapshot.reviewLogsCount = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM review_logs") ?? 0
        snapshot.noteIDsDigest = try idDigest(
            db, sql: "SELECT id FROM notes ORDER BY id")
        snapshot.cardIDsDigest = try idDigest(
            db, sql: "SELECT id FROM cards ORDER BY id")
        snapshot.reviewLogIDsDigest = try idDigest(
            db, sql: "SELECT id FROM review_logs ORDER BY id")
        snapshot.notesDigest = try rowsDigest(
            db,
            sql: """
                SELECT id, deck_id, kind, headword, reading, meaning_zh,
                       part_of_speech, jlpt, usage, connection, notes,
                       is_favorite, source_text, origin, source_ref,
                       content_version, created_at_ms, updated_at_ms,
                       pitch_accent
                FROM notes ORDER BY id
                """)
        snapshot.cardsFSRSDigest = try rowsDigest(
            db,
            sql: """
                SELECT id, note_id, template_kind, is_enabled, state,
                       due_at_ms, last_review_at_ms, stability, difficulty,
                       reps, lapses, scheduled_days, elapsed_days,
                       learning_step, first_studied_at_ms, state_version,
                       algorithm_version, profile_id
                FROM cards ORDER BY id
                """)
        snapshot.reviewLogsDigest = try rowsDigest(
            db,
            sql: """
                SELECT id, event_id, card_id, card_key, note_id,
                       deck_id_at_review, reviewed_at_ms, study_day_id,
                       was_first_study, rating, previous_state_json,
                       next_state_json, duration_ms, content_version,
                       profile_id, algorithm_version, undone_at_ms
                FROM review_logs ORDER BY id
                """)
        return snapshot
    }

    public func auditSummary() async throws -> AuditSnapshot {
        try await pool.read { db in try Self.auditSnapshot(in: db) }
    }

    // MARK: - 回填主入口（notes → overrides 两阶段）

    /// 跑一轮存量回填。中断续跑靠 migration items（见文件头说明）；
    /// `batchLimit` 仅供测试注入中断（达到批次上限提前返回，
    /// `interrupted=true`，不写 run marker——续跑不是回放）。
    ///
    /// `senseSource`/`entryVerifier` 指向**当前**词典快照：sense 级
    /// 验证与 entry 表记/读音校验分别在两个通道（沿袭
    /// `LexemeBackfillService` 把词典读留在用户库写事务外的纪律）。
    @discardableResult
    public func run(
        senseSource: any SenseSnapshotReader,
        entryVerifier: any LexemeEntryVerifier,
        batchLimit: Int? = nil
    ) async throws -> BackfillSummary {
        guard let datasetVersion = try await senseSource.datasetVersion(),
              !datasetVersion.isEmpty
        else {
            throw DictionaryError.unavailable("dataset version missing")
        }
        var summary = BackfillSummary()

        try await runNotesPhase(
            datasetVersion: datasetVersion,
            senseSource: senseSource,
            entryVerifier: entryVerifier,
            batchLimit: batchLimit,
            summary: &summary)
        guard !summary.interrupted else { return summary }

        try await runOverridesPhase(
            datasetVersion: datasetVersion,
            senseSource: senseSource,
            entryVerifier: entryVerifier,
            batchLimit: batchLimit,
            summary: &summary)
        guard !summary.interrupted else { return summary }

        // 整轮凭据：applied 标记 + 统计 evidence（重跑幂等 upsert）。
        let evidence = (try? Self.evidenceJSON([
            "backfill_version": Self.backfillVersion,
            "dataset_version": datasetVersion,
            "notes_scanned": summary.notesScanned,
            "notes_bound_verified": summary.notesBoundVerified,
            "notes_bound_isolated": summary.notesBoundIsolated,
            "notes_pending_confirmation": summary.notesPendingConfirmation,
            "notes_local": summary.notesLocal,
            "notes_already_linked": summary.notesAlreadyLinked,
            "overrides_known_flagged": summary.overridesKnownFlagged,
            "overrides_known_pending": summary.overridesKnownPending,
            "overrides_ignored_archived": summary.overridesIgnoredArchived,
        ])) ?? "{}"
        try await pool.write { db in
            try GRDBLearningUnitRepository.upsertMigrationItem(
                LearningUnitMigrationItem(
                    sourceKey: Self.runMarkerSourceKey,
                    status: .applied,
                    evidenceJSON: evidence),
                in: db)
        }
        return summary
    }

    // MARK: - notes 阶段

    private func runNotesPhase(
        datasetVersion: String,
        senseSource: any SenseSnapshotReader,
        entryVerifier: any LexemeEntryVerifier,
        batchLimit: Int?,
        summary: inout BackfillSummary
    ) async throws {
        while !summary.notesPhaseComplete {
            try Task.checkCancellation()
            if let batchLimit, summary.batchesCommitted >= batchLimit {
                summary.interrupted = true
                return
            }
            let page = try await fetchUnprocessedNotePage()
            guard !page.isEmpty else {
                summary.notesPhaseComplete = true
                break
            }

            // —— 证据行读取（用户库读事务）——
            let noteIDs = page.map(\.id)
            let evidenceRows = try await pool.read { db in
                try Self.fetchNoteEvidence(noteIDs: noteIDs, in: db)
            }
            // —— 词典侧读取（独立只读库，不进写事务）——
            let entryIDs = Self.candidateEntryIDs(evidence: evidenceRows)
            let surfaces = try await entryVerifier.entrySurfaces(
                entryIDs: Array(entryIDs))
            var sensesByEntry: [Int64: [VerifiedSense]] = [:]
            for entryID in entryIDs.sorted() {
                sensesByEntry[entryID] =
                    try await senseSource.verifiedSenses(entryID: entryID)
            }
            // 纯决策（事务外，确定性）。
            let plans = page.map { note in
                Self.decideNote(
                    note: note,
                    evidence: evidenceRows[note.id] ?? .empty,
                    datasetVersion: datasetVersion,
                    surfaces: surfaces,
                    sensesByEntry: sensesByEntry)
            }

            let atMs = try DatabaseValueCodec.encode(now())
            let batch = try await pool.write { db -> NotesBatchCounts in
                var counts = NotesBatchCounts()
                let liveIDs = Set(try String.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM notes
                        WHERE id IN (\(Self.placeholders(page.count)))
                        """,
                    arguments: StatementArguments(page.map(\.id))))
                counts.skippedDeleted = page.count - liveIDs.count
                for (note, plan) in zip(page, plans)
                where liveIDs.contains(note.id) {
                    let oldState =
                        (evidenceRows[note.id] ?? .empty).derivedOldState
                    try Self.applyNotePlan(
                        note: note, oldState: oldState, plan: plan,
                        atMilliseconds: atMs,
                        in: db, counts: &counts)
                    counts.scanned += 1
                }
                return counts
            }
            summary.notesScanned += batch.scanned
            summary.notesBoundVerified += batch.boundVerified
            summary.notesBoundIsolated += batch.boundIsolated
            summary.notesPendingConfirmation += batch.pendingConfirmation
            summary.notesLocal += batch.local
            summary.notesAlreadyLinked += batch.alreadyLinked
            summary.projectionsReplaced += batch.projectionsReplaced
            summary.flagsCarried += batch.flagsCarried
            summary.skippedDeleted += batch.skippedDeleted
            summary.batchesCommitted += 1
        }
    }

    // MARK: - overrides 阶段（known → tooEasy / ignored → 存档）

    private func runOverridesPhase(
        datasetVersion: String,
        senseSource: any SenseSnapshotReader,
        entryVerifier: any LexemeEntryVerifier,
        batchLimit: Int?,
        summary: inout BackfillSummary
    ) async throws {
        while !summary.overridesPhaseComplete {
            try Task.checkCancellation()
            if let batchLimit, summary.batchesCommitted >= batchLimit {
                summary.interrupted = true
                return
            }
            let page = try await fetchUnprocessedOverridePage()
            guard !page.isEmpty else {
                summary.overridesPhaseComplete = true
                break
            }

            let lexemeIDs = page.map(\.lexemeID)
            let bindings = try await pool.read { db in
                try Self.fetchBindings(lexemeIDs: lexemeIDs, in: db)
            }
            let entryIDs = Set(page.compactMap(\.entryID)
                + bindings.values.map(\.entryID))
            let surfaces = try await entryVerifier.entrySurfaces(
                entryIDs: Array(entryIDs))
            var fetchedSenses: [Int64: [VerifiedSense]] = [:]
            for entryID in entryIDs.sorted() {
                fetchedSenses[entryID] =
                    try await senseSource.verifiedSenses(entryID: entryID)
            }
            let sensesByEntry = fetchedSenses

            let atMs = try DatabaseValueCodec.encode(now())
            let batch = try await pool.write { db -> OverridesBatchCounts in
                var counts = OverridesBatchCounts()
                for row in page {
                    try Self.applyOverrideDecision(
                        row: row,
                        binding: bindings[row.lexemeID],
                        datasetVersion: datasetVersion,
                        surfaces: surfaces,
                        sensesByEntry: sensesByEntry,
                        atMilliseconds: atMs,
                        in: db, counts: &counts)
                }
                return counts
            }
            summary.overridesKnownFlagged += batch.knownFlagged
            summary.overridesKnownPending += batch.knownPending
            summary.overridesIgnoredArchived += batch.ignoredArchived
            summary.batchesCommitted += 1
        }
    }

    // MARK: - 词典换库重绑定（identity-spike §1.2 纪律落地）

    /// 对全部 dictionarySense unit 按 `semantic_fingerprint` 在新快照
    /// 找候选：唯一 → 补 current alias（新 dataset 行）+ 旧 alias 转
    /// superseded + binding_status=current；多候选 → needsConfirmation
    /// （保留旧行引用）；零候选 → stale（同上，下轮可重试）。
    /// **绝不改 unit UUID / identity_key / fingerprint**。
    @discardableResult
    public func rebindAliases(
        senseSource: any SenseSnapshotReader,
        batchLimit: Int? = nil
    ) async throws -> RebindSummary {
        guard let newVersion = try await senseSource.datasetVersion(),
              !newVersion.isEmpty
        else {
            throw DictionaryError.unavailable("dataset version missing")
        }
        var summary = RebindSummary(datasetVersion: newVersion)
        var cursor: String? = nil

        while true {
            try Task.checkCancellation()
            if let batchLimit, summary.batchesCommitted >= batchLimit {
                summary.interrupted = true
                return summary
            }
            let cursorSnapshot = cursor
            let page = try await pool.read { db in
                try Self.fetchDictionarySenseUnits(
                    after: cursorSnapshot, limit: batchSize, in: db)
            }
            guard !page.isEmpty else { break }
            cursor = page.last?.idRaw

            let entryIDs = Set(page.compactMap(\.entryID))
            var fetchedSenses: [Int64: [VerifiedSense]] = [:]
            for entryID in entryIDs.sorted() {
                fetchedSenses[entryID] =
                    try await senseSource.verifiedSenses(entryID: entryID)
            }
            let sensesByEntry = fetchedSenses
            let atMs = try DatabaseValueCodec.encode(now())
            let batch = try await pool.write { db -> RebindBatchCounts in
                var counts = RebindBatchCounts()
                for unit in page {
                    try Self.applyRebind(
                        unit: unit,
                        candidates: (sensesByEntry[unit.entryID ?? -1] ?? [])
                            .filter {
                                $0.fingerprint == unit.semanticFingerprint
                            },
                        newDatasetVersion: newVersion,
                        atMilliseconds: atMs,
                        in: db, counts: &counts)
                    counts.scanned += 1
                }
                return counts
            }
            summary.unitsScanned += batch.scanned
            summary.rebound += batch.rebound
            summary.confirmedCurrent += batch.confirmedCurrent
            summary.markedAmbiguous += batch.markedAmbiguous
            summary.markedStale += batch.markedStale
            summary.aliasConflicts += batch.aliasConflicts
            summary.batchesCommitted += 1
        }
        return summary
    }

    // MARK: - 决策（纯函数，事务外评估——确定性）

    /// Note 的迁移分派（纯值——apply 只消费本类型）。
    enum NotePlan: Equatable, Sendable {
        /// 同版本唯一义项 → dictionarySense 共享 key + current alias。
        case verified(BindingTarget)
        /// 义项行明确（sense_key 指定）但同 entry 指纹碰撞 →
        /// dictionarySense 隔离 key + needsConfirmation alias。
        case isolated(BindingTarget)
        /// 多义/冲突/证据失效 → legacy-note 投影 + 待确认审计。
        case legacyUnresolved(reason: String, detail: String)
        /// 无词典证据 → local-note unit。
        case localNote
    }

    struct BindingTarget: Equatable, Sendable {
        let entryID: Int64
        let senseID: Int64
        let fingerprint: String
        let datasetVersion: String
        let snapshotJSON: String
    }

    /// 单 Note 证据收集结果（用户库行）。
    struct NoteRow: Equatable, Sendable {
        let id: String           // 小写 UUID 文本
        let headword: String
        let reading: String?
        let createdAtMs: Int64

        var uuid: UUID {
            // 测试建库写入均走 DatabaseValueCodec——不可解析即数据损坏，
            // decode 失败时返回全零 UUID 让后续按未知处理而非崩溃。
            (try? DatabaseValueCodec.decodeUUID(id)) ?? UUID()
        }
    }

    struct ContextRow: Equatable, Sendable {
        let entryID: Int64?
        let datasetVersion: String?
        let senseKey: String?
    }

    struct LexemeRow: Equatable, Sendable {
        let lexemeID: String
        let provider: String
        let entryID: Int64?
        /// 该 lexeme 的 override 态（known/ignored，nil = 无行）——
        /// Note 迁移审计 `old_state` 推导用。
        let overrideState: String?
    }

    struct NoteEvidence: Equatable, Sendable {
        var contexts: [ContextRow] = []
        var lexemes: [LexemeRow] = []
        var bindingEntryIDs: [Int64] = []
        static let empty = NoteEvidence()

        /// 旧真值表推导态（ignored > known > learning > unknown），
        /// 写进审计项 `old_state`（D04/D19 留痕）。
        var derivedOldState: String {
            let states = lexemes.compactMap(\.overrideState)
            if states.contains("ignored") { return "ignored" }
            if states.contains("known") { return "known" }
            return lexemes.isEmpty ? "unknown" : "learning"
        }
    }

    struct SenseRef: Hashable, Sendable {
        let entryID: Int64
        let senseID: Int64
    }

    /// 候选 entry 全集（决策前批量取词典）。
    private static func candidateEntryIDs(
        evidence: [String: NoteEvidence]
    ) -> Set<Int64> {
        var ids = Set<Int64>()
        for rows in evidence.values {
            for ctx in rows.contexts {
                if let entryID = ctx.entryID { ids.insert(entryID) }
                if let ref = parseSenseKey(ctx.senseKey) {
                    ids.insert(ref.entryID)
                }
            }
            for lexeme in rows.lexemes where lexeme.provider == "jmdict" {
                if let entryID = lexeme.entryID { ids.insert(entryID) }
            }
            ids.formUnion(rows.bindingEntryIDs)
        }
        return ids
    }

    /// 纯决策：Note → NotePlan。`sensesByEntry`/`surfaces` 必须已含
    /// 全部候选 entry（缺省视为不可用——保守待确认）。
    static func decideNote(
        note: NoteRow,
        evidence: NoteEvidence,
        datasetVersion: String,
        surfaces: [Int64: LexemeEntrySurface],
        sensesByEntry: [Int64: [VerifiedSense]]
    ) -> NotePlan {
        // —— sense 级证据：sense_key 且与当前快照同 dataset_version ——
        var verifiedSenseRefs = Set<SenseRef>()
        var entryEvidence = Set<Int64>()
        for ctx in evidence.contexts {
            if let ref = parseSenseKey(ctx.senseKey) {
                entryEvidence.insert(ref.entryID)
                if ctx.datasetVersion == datasetVersion {
                    verifiedSenseRefs.insert(ref)
                }
            }
            if let entryID = ctx.entryID { entryEvidence.insert(entryID) }
        }
        for lexeme in evidence.lexemes where lexeme.provider == "jmdict" {
            if let entryID = lexeme.entryID { entryEvidence.insert(entryID) }
        }
        entryEvidence.formUnion(evidence.bindingEntryIDs)

        // —— 档 1：显式义项引用 ——
        if verifiedSenseRefs.count > 1 {
            let refs = verifiedSenseRefs.sorted {
                ($0.entryID, $0.senseID) < ($1.entryID, $1.senseID)
            }.map { "\($0.entryID):\($0.senseID)" }
            return .legacyUnresolved(
                reason: "conflicting_sense_refs",
                detail: refs.joined(separator: ","))
        }
        if let ref = verifiedSenseRefs.first {
            let senses = sensesByEntry[ref.entryID] ?? []
            guard !senses.isEmpty else {
                return .legacyUnresolved(
                    reason: "entry_missing", detail: "\(ref.entryID)")
            }
            guard let target = senses.first(where: {
                $0.senseID == ref.senseID
            }) else {
                return .legacyUnresolved(
                    reason: "sense_missing",
                    detail: "\(ref.entryID):\(ref.senseID)")
            }
            guard surfaceMatches(
                headword: note.headword, reading: note.reading,
                surface: surfaces[ref.entryID]) else {
                return .legacyUnresolved(
                    reason: "surface_mismatch", detail: "\(ref.entryID)")
            }
            let conflictingEntries = entryEvidence.subtracting([ref.entryID])
            guard conflictingEntries.isEmpty else {
                return .legacyUnresolved(
                    reason: "conflicting_entries",
                    detail: conflictingEntries.sorted()
                        .map(String.init).joined(separator: ","))
            }
            let targetFingerprintCount = senses.filter {
                $0.fingerprint == target.fingerprint
            }.count
            let binding = BindingTarget(
                entryID: ref.entryID, senseID: ref.senseID,
                fingerprint: target.fingerprint,
                datasetVersion: datasetVersion,
                snapshotJSON: senseSnapshotJSON(
                    target, entryID: ref.entryID))
            // 同 entry 不可区分重复指纹 → 隔离 key 待确认（§1.1）。
            if targetFingerprintCount > 1 { return .isolated(binding) }
            return .verified(binding)
        }

        // —— 档 2：entry 级证据（同版本验证存在 + 表记/读音相容）——
        let verifiedEntries = entryEvidence.filter { entryID in
            guard surfaces[entryID] != nil else { return false }
            return surfaceMatches(
                headword: note.headword, reading: note.reading,
                surface: surfaces[entryID])
        }
        if verifiedEntries.count > 1 {
            return .legacyUnresolved(
                reason: "conflicting_entries",
                detail: verifiedEntries.sorted()
                    .map(String.init).joined(separator: ","))
        }
        if let entryID = verifiedEntries.first {
            let senses = sensesByEntry[entryID] ?? []
            if senses.count == 1, let only = senses.first {
                return .verified(BindingTarget(
                    entryID: entryID, senseID: only.senseID,
                    fingerprint: only.fingerprint,
                    datasetVersion: datasetVersion,
                    snapshotJSON: senseSnapshotJSON(only, entryID: entryID)))
            }
            return .legacyUnresolved(
                reason: senses.isEmpty ? "entry_missing" : "multi_sense",
                detail: "\(entryID):\(senses.count)")
        }
        // —— 档 3：证据失效 → 待确认；无证据 → localNote ——
        if !entryEvidence.isEmpty {
            return .legacyUnresolved(
                reason: "evidence_unverifiable",
                detail: entryEvidence.sorted()
                    .map(String.init).joined(separator: ","))
        }
        return .localNote
    }

    /// 表记/读音相容校验（沿 `LexemeBackfillService` 档 1 纪律：
    /// headword 必须命中 normalizedForms；有读音时读音必须命中
    /// normalizedReadings——同形异音防线）。
    static func surfaceMatches(
        headword: String,
        reading: String?,
        surface: LexemeEntrySurface?
    ) -> Bool {
        guard let surface else { return false }
        guard surface.normalizedForms.contains(
            SearchTextNormalizer.normalize(headword)) else { return false }
        if let reading,
           !SearchTextNormalizer.normalize(reading).isEmpty {
            return surface.normalizedReadings.contains(
                SearchTextNormalizer.normalize(reading))
        }
        return true
    }

    /// `dictionary_sense_key` = `"<entryID>:<senseID>"`（mining
    /// `ReaderMiningSense.senseKey` 冻结值）；非此形态返回 nil。
    static func parseSenseKey(_ raw: String?) -> SenseRef? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let entryID = Int64(parts[0]),
              let senseID = Int64(parts[1])
        else { return nil }
        return SenseRef(entryID: entryID, senseID: senseID)
    }

    /// unit `sense_snapshot_json`（有界：entry/sense + 有序 en gloss +
    /// pos——不含正文/Prompt，v9 wire §2.3 口径）。
    static func senseSnapshotJSON(
        _ sense: VerifiedSense, entryID: Int64
    ) -> String {
        let payload: [String: Any] = [
            "entry_id": entryID,
            "sense_id": sense.senseID,
            "glosses_en": sense.glossesEN,
            "pos_codes": sense.posCodes,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8),
              json.count <= GRDBLearningUnitSchema.senseSnapshotMaxLength
        else {
            return "{\"entry_id\":\(entryID),\"sense_id\":\(sense.senseID)}"
        }
        return json
    }

    // MARK: - 应用（写事务内）

    struct NotesBatchCounts: Sendable {
        var scanned = 0
        var boundVerified = 0
        var boundIsolated = 0
        var pendingConfirmation = 0
        var local = 0
        var alreadyLinked = 0
        var projectionsReplaced = 0
        var flagsCarried = 0
        var skippedDeleted = 0
    }

    struct OverridesBatchCounts: Sendable {
        var knownFlagged = 0
        var knownPending = 0
        var ignoredArchived = 0
    }

    /// 单 Note 应用面（写事务内执行）：
    /// 已有非投影关联 → alreadyLinked 幂等跳过；
    /// 投影链接（unit key == `legacy-note:<note>`）→ 按决策替换或维持；
    /// 其余 → 建/复用 unit + primary 选举 link + verified alias + 审计项。
    static func applyNotePlan(
        note: NoteRow,
        oldState: String,
        plan: NotePlan,
        atMilliseconds: Int64,
        in db: Database,
        counts: inout NotesBatchCounts
    ) throws {
        let noteUUID = note.uuid
        let legacyKey = legacyNoteIdentityKey(noteID: noteUUID)
        let sourceKey = "\(noteItemPrefix)\(note.id)"

        // 既有关联：非本服务投影（dictionarySense/localNote/他人写入）
        // 一律幂等跳过——「一 Note 一有效 unit」不抢占既有决定（D02/D16）。
        // 已有审计项（如 needsConfirmation 待人工）不降级改写。
        if let link = try GRDBLearningUnitRepository.fetchLink(
            noteID: noteUUID, in: db),
           let existing = try GRDBLearningUnitRepository.fetchUnit(
               id: link.unitID, in: db),
           existing.identityKey != legacyKey {
            if try GRDBLearningUnitRepository.fetchMigrationItem(
                sourceKey: sourceKey, in: db) == nil {
                try upsertNoteItem(
                    noteID: noteUUID, oldState: oldState, status: .applied,
                    targetUnitID: existing.id,
                    evidence: [
                        "decision": "already_linked",
                        "unit_id": DatabaseValueCodec.encode(existing.id),
                    ], in: db)
            }
            counts.alreadyLinked += 1
            return
        }

        switch plan {
        case .verified(let target):
            let unit = try resolveDictionarySenseUnit(
                target: target, note: note,
                isolated: false, atMilliseconds: atMilliseconds, in: db)
            try GRDBLearningUnitRepository.upsertAlias(
                LearningUnitDictionaryAlias(
                    unitID: unit.id, provider: "jmdict",
                    datasetVersion: target.datasetVersion,
                    entryID: target.entryID, senseID: target.senseID,
                    fingerprint: target.fingerprint, status: .current),
                resolvedAtMs: atMilliseconds, in: db)
            try replaceProjectionIfNeeded(
                note: note, target: unit,
                atMilliseconds: atMilliseconds, in: db, counts: &counts)
            try applyLink(
                note: note, unit: unit,
                atMilliseconds: atMilliseconds, in: db)
            try upsertNoteItem(
                noteID: noteUUID, oldState: oldState, status: .applied,
                targetUnitID: unit.id,
                evidence: [
                    "decision": "verified_sense",
                    "binding": "\(target.entryID):\(target.senseID)",
                    "dataset": target.datasetVersion,
                ], in: db)
            counts.boundVerified += 1

        case .isolated(let target):
            let unit = try resolveDictionarySenseUnit(
                target: target, note: note,
                isolated: true, atMilliseconds: atMilliseconds, in: db)
            try GRDBLearningUnitRepository.upsertAlias(
                LearningUnitDictionaryAlias(
                    unitID: unit.id, provider: "jmdict",
                    datasetVersion: target.datasetVersion,
                    entryID: target.entryID, senseID: target.senseID,
                    fingerprint: target.fingerprint,
                    status: .needsConfirmation),
                resolvedAtMs: atMilliseconds, in: db)
            try replaceProjectionIfNeeded(
                note: note, target: unit,
                atMilliseconds: atMilliseconds, in: db, counts: &counts)
            try applyLink(
                note: note, unit: unit,
                atMilliseconds: atMilliseconds, in: db)
            try upsertNoteItem(
                noteID: noteUUID, oldState: oldState,
                status: .needsConfirmation, targetUnitID: unit.id,
                evidence: [
                    "decision": "isolated_fingerprint_collision",
                    "binding": "\(target.entryID):\(target.senseID)",
                    "dataset": target.datasetVersion,
                ], in: db)
            counts.boundIsolated += 1
            counts.pendingConfirmation += 1

        case .legacyUnresolved(let reason, let detail):
            let unit = try resolveNonDictionaryUnit(
                identityKind: .legacyUnresolved, identityKey: legacyKey,
                note: note, atMilliseconds: atMilliseconds, in: db)
            try replaceProjectionIfNeeded(
                note: note, target: unit,
                atMilliseconds: atMilliseconds, in: db, counts: &counts)
            try applyLink(
                note: note, unit: unit,
                atMilliseconds: atMilliseconds, in: db)
            try upsertNoteItem(
                noteID: noteUUID, oldState: oldState,
                status: .needsConfirmation, targetUnitID: unit.id,
                evidence: [
                    "decision": "legacy_unresolved",
                    "reason": reason, "detail": detail,
                ], in: db)
            counts.pendingConfirmation += 1

        case .localNote:
            let key = localNoteIdentityKey(noteID: noteUUID)
            let unit = try resolveNonDictionaryUnit(
                identityKind: .localNote, identityKey: key,
                note: note, atMilliseconds: atMilliseconds, in: db)
            try replaceProjectionIfNeeded(
                note: note, target: unit,
                atMilliseconds: atMilliseconds, in: db, counts: &counts)
            try applyLink(
                note: note, unit: unit,
                atMilliseconds: atMilliseconds, in: db)
            try upsertNoteItem(
                noteID: noteUUID, oldState: oldState, status: .applied,
                targetUnitID: unit.id,
                evidence: ["decision": "local_note"], in: db)
            counts.local += 1
        }
    }

    /// dictionarySense unit resolve-or-create：
    /// 共享 key `jmdict:sense-v1:<entryID>:<fp>`（唯一指纹）或隔离 key
    /// `jmdict:sense-v1-isolated:<dataset>:<entry>:<sense>`（碰撞）——
    /// 两种形态都由 `LearningUnitDictionaryAlias.identityKey` 单点生成
    /// （不重定义 key 编码）。
    private static func resolveDictionarySenseUnit(
        target: BindingTarget,
        note: NoteRow,
        isolated: Bool,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> LearningUnit {
        let probe = LearningUnitDictionaryAlias(
            unitID: UUID(), provider: "jmdict",
            datasetVersion: target.datasetVersion,
            entryID: target.entryID, senseID: target.senseID,
            fingerprint: target.fingerprint,
            status: isolated ? .needsConfirmation : .current)
        let key = probe.identityKey
        let existed = try GRDBLearningUnitRepository.fetchUnit(
            identityKey: key, in: db) != nil
        let unit = try GRDBLearningUnitRepository.resolveOrCreateUnit(
            identityKind: .dictionarySense,
            identityKey: key,
            lemma: note.headword, reading: note.reading,
            provider: "jmdict", entryID: target.entryID,
            fingerprint: target.fingerprint,
            fingerprintVersion: SemanticFingerprint.semanticFingerprintVersion,
            senseSnapshotJSON: target.snapshotJSON,
            bindingStatus: isolated ? .needsConfirmation : .current,
            atMilliseconds: atMilliseconds, in: db)
        if !existed {
            try insertUnitEventIfAbsent(
                unitID: unit.id, kind: .migrated,
                seed: "s05-unit|\(key)",
                afterJSON: target.snapshotJSON,
                atMilliseconds: atMilliseconds, in: db)
        }
        return unit
    }

    private static func resolveNonDictionaryUnit(
        identityKind: LearningUnitIdentityKind,
        identityKey: String,
        note: NoteRow,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> LearningUnit {
        let existed = try GRDBLearningUnitRepository.fetchUnit(
            identityKey: identityKey, in: db) != nil
        let unit = try GRDBLearningUnitRepository.resolveOrCreateUnit(
            identityKind: identityKind, identityKey: identityKey,
            lemma: note.headword, reading: note.reading,
            bindingStatus: .legacy,
            atMilliseconds: atMilliseconds, in: db)
        if !existed {
            try insertUnitEventIfAbsent(
                unitID: unit.id, kind: .migrated,
                seed: "s05-unit|\(identityKey)", afterJSON: nil,
                atMilliseconds: atMilliseconds, in: db)
        }
        return unit
    }

    /// 未回填投影替换：Note 已挂 `legacy-note:` 投影 unit 且决策指向
    /// 另一 unit（verified/local）时——投影 flag 随迁（用户曾对未回填
    /// Note 标 Too Easy，意图跟 Note 走）、解除投影 link + 留
    /// `noteUnlinked` 事件、投影 unit 无其他链接即删除（projector 是
    /// 临时物，不是用户身份）。决策仍落 legacy（`needsConfirmation`
    /// 重估同果）时 target == 投影 unit，自然零动作。
    private static func replaceProjectionIfNeeded(
        note: NoteRow,
        target: LearningUnit,
        atMilliseconds: Int64,
        in db: Database,
        counts: inout NotesBatchCounts
    ) throws {
        let noteUUID = note.uuid
        guard let link = try GRDBLearningUnitRepository.fetchLink(
            noteID: noteUUID, in: db), link.unitID != target.id,
           let projection = try GRDBLearningUnitRepository.fetchUnit(
               id: link.unitID, in: db),
           projection.identityKey == legacyNoteIdentityKey(noteID: noteUUID)
        else { return }

        // flag 随迁（Too Easy 意图跟 Note 走，不留在孤儿 unit 上）。
        if let flag = try GRDBLearningUnitRepository.fetchFlag(
            unitID: projection.id, in: db) {
            let targetFlag = try GRDBLearningUnitRepository.fetchFlag(
                unitID: target.id, in: db)
            if (targetFlag?.tooEasy ?? false) != flag.tooEasy {
                _ = try GRDBLearningUnitRepository.setFlagTooEasy(
                    unitID: target.id, value: flag.tooEasy,
                    expectedRevision: targetFlag?.revision ?? 0,
                    operationID: deterministicUUID(
                        "s05-flagcarry|\(note.id)"),
                    atMilliseconds: atMilliseconds, in: db)
                counts.flagsCarried += 1
            }
        }
        _ = try GRDBLearningUnitRepository.unlinkNote(
            unitID: projection.id, noteID: noteUUID, in: db)
        try insertUnitEventIfAbsent(
            unitID: projection.id, kind: .noteUnlinked,
            seed: "s05-unlink|\(note.id)",
            afterJSON: nil,
            atMilliseconds: atMilliseconds, in: db,
            unitIDSnapshot: projection.id)
        if try GRDBLearningUnitRepository.fetchLinks(
            unitID: projection.id, in: db).isEmpty {
            try db.execute(
                sql: "DELETE FROM lexical_learning_units WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(projection.id)])
            counts.projectionsReplaced += 1
        }
    }

    /// Note→unit 关联 + primary 确定性选举（§3.2：全体关联中
    /// `note.created_at_ms` 最早、并列 `note_id` 字典序最小为 primary，
    /// 其余 legacy_secondary；扫描序不影响终态）。
    private static func applyLink(
        note: NoteRow,
        unit: LearningUnit,
        atMilliseconds: Int64,
        in db: Database
    ) throws {
        let noteUUID = note.uuid
        let encodedNote = note.id
        let encodedUnit = DatabaseValueCodec.encode(unit.id)

        if let existing = try GRDBLearningUnitRepository.fetchLink(
            noteID: noteUUID, in: db) {
            guard existing.unitID == unit.id else {
                throw LearningUnitRepositoryError.noteAlreadyLinked(
                    noteID: noteUUID, existingUnitID: existing.unitID)
            }
            return // 同 unit 已关联——幂等
        }

        var role: LearningUnitNoteLinkRole = .legacySecondary
        let linkedRows = try Row.fetchAll(
            db,
            sql: """
                SELECT l.note_id, l.role, n.created_at_ms
                FROM learning_unit_note_links l
                JOIN notes n ON n.id = l.note_id
                WHERE l.unit_id = ?
                """,
            arguments: [encodedUnit])
        let primaryRow = linkedRows.first { (row: Row) -> Bool in
            let role: String = row["role"]
            return role == "primary"
        }
        if let primaryRow {
            let primaryID: String = primaryRow["note_id"]
            let primaryCreated: Int64 = primaryRow["created_at_ms"]
            // 新 Note 更「老」（created 更早，并列 id 更小）→ 接管 primary。
            if (note.createdAtMs, encodedNote)
                < (primaryCreated, primaryID) {
                role = .primary
                try db.execute(
                    sql: """
                        UPDATE learning_unit_note_links
                        SET role = 'legacy_secondary'
                        WHERE unit_id = ? AND role = 'primary'
                        """,
                    arguments: [encodedUnit])
            }
        } else if linkedRows.isEmpty {
            role = .primary
        } else {
            // 无 primary 但有 secondary（用户删除 primary 后等提升）：
            // 全体候选（含新 Note）最小者 primary，其余维持。
            var candidates = linkedRows.map { (row: Row) -> (String, Int64) in
                (row["note_id"], row["created_at_ms"])
            }
            candidates.append((encodedNote, note.createdAtMs))
            candidates.sort { ($0.1, $0.0) < ($1.1, $1.0) }
            if let winner = candidates.first {
                if winner.0 == encodedNote {
                    role = .primary
                } else {
                    try db.execute(
                        sql: """
                            UPDATE learning_unit_note_links
                            SET role = 'primary'
                            WHERE unit_id = ? AND note_id = ?
                            """,
                        arguments: [encodedUnit, winner.0])
                }
            }
        }

        _ = try GRDBLearningUnitRepository.linkNote(
            unitID: unit.id, noteID: noteUUID, role: role,
            origin: .backfill, atMilliseconds: atMilliseconds, in: db)
        let payload = "{\"note_id\":\"\(encodedNote)\","
            + "\"role\":\"\(role.rawValue)\","
            + "\"unit_id\":\"\(encodedUnit)\"}"
        try insertUnitEventIfAbsent(
            unitID: unit.id, kind: .noteLinked,
            seed: "s05-link|\(note.id)", afterJSON: payload,
            atMilliseconds: atMilliseconds, in: db)
    }

    // MARK: - overrides 应用

    struct OverrideRow: Equatable, Sendable {
        let lexemeID: String
        let state: String              // known | ignored
        let provider: String           // jmdict | local
        let entryID: Int64?
        let writtenForm: String
        let reading: String?

        var lexemeUUID: UUID {
            (try? DatabaseValueCodec.decodeUUID(lexemeID)) ?? UUID()
        }
    }

    struct BindingRow: Equatable, Sendable {
        let lexemeID: String
        let entryID: Int64
        let datasetVersion: String
        let status: String
        let matchTier: String
    }

    /// 单 override 应用（写事务内）。known → 唯一可靠义项才落
    /// tooEasy（D03 收紧）；ignored → skipped 存档（D04/D19）。
    static func applyOverrideDecision(
        row: OverrideRow,
        binding: BindingRow?,
        datasetVersion: String,
        surfaces: [Int64: LexemeEntrySurface],
        sensesByEntry: [Int64: [VerifiedSense]],
        atMilliseconds: Int64,
        in db: Database,
        counts: inout OverridesBatchCounts
    ) throws {
        let lexemeUUID = row.lexemeUUID
        let sourceKey = "\(overrideItemPrefix)\(row.lexemeID)"

        if row.state == "ignored" {
            // D04：ignored 退出运行态、不转 tooEasy——仅留审计旧值。
            try GRDBLearningUnitRepository.upsertMigrationItem(
                LearningUnitMigrationItem(
                    sourceKey: sourceKey, legacyLexemeID: lexemeUUID,
                    oldState: "ignored", status: .skipped,
                    evidenceJSON: try evidenceJSON([
                        "decision": "ignored_archived",
                        "runtime": "removed_from_three_state",
                    ])),
                in: db)
            counts.ignoredArchived += 1
            return
        }

        // known：唯一可靠义项判定（同 notes 档 2 纪律）。
        var entries = Set<Int64>()
        if let binding { entries.insert(binding.entryID) }
        if row.provider == "jmdict", let entryID = row.entryID {
            entries.insert(entryID)
        }
        func pending(_ reason: String, _ detail: String) throws {
            try GRDBLearningUnitRepository.upsertMigrationItem(
                LearningUnitMigrationItem(
                    sourceKey: sourceKey, legacyLexemeID: lexemeUUID,
                    oldState: "known", status: .needsConfirmation,
                    evidenceJSON: try evidenceJSON([
                        "decision": "known_pending",
                        "reason": reason, "detail": detail,
                    ])),
                in: db)
            counts.knownPending += 1
        }

        guard row.provider == "jmdict", !entries.isEmpty else {
            try pending("no_sense_evidence", row.provider)
            return
        }
        let verifiedEntries = entries.filter { entryID in
            surfaces[entryID] != nil && surfaceMatches(
                headword: row.writtenForm, reading: row.reading,
                surface: surfaces[entryID])
        }
        guard verifiedEntries.count <= 1 else {
            try pending(
                "conflicting_entries",
                verifiedEntries.sorted().map(String.init).joined(separator: ","))
            return
        }
        guard let entryID = verifiedEntries.first else {
            try pending(
                "entry_unverifiable",
                entries.sorted().map(String.init).joined(separator: ","))
            return
        }
        let senses = sensesByEntry[entryID] ?? []
        guard senses.count == 1, let only = senses.first else {
            try pending(
                senses.isEmpty ? "entry_missing" : "multi_sense",
                "\(entryID):\(senses.count)")
            return
        }

        // 唯一义项 → resolve-or-create dictionarySense unit +
        // verified alias + tooEasy flag（无 Note 的 unit 同样允许，§2.2）。
        let probe = LearningUnitDictionaryAlias(
            unitID: UUID(), provider: "jmdict",
            datasetVersion: datasetVersion,
            entryID: entryID, senseID: only.senseID,
            fingerprint: only.fingerprint, status: .current)
        let key = probe.identityKey
        let existed = try GRDBLearningUnitRepository.fetchUnit(
            identityKey: key, in: db) != nil
        let unit = try GRDBLearningUnitRepository.resolveOrCreateUnit(
            identityKind: .dictionarySense, identityKey: key,
            lemma: row.writtenForm, reading: row.reading,
            provider: "jmdict", entryID: entryID,
            fingerprint: only.fingerprint,
            fingerprintVersion: SemanticFingerprint.semanticFingerprintVersion,
            senseSnapshotJSON: senseSnapshotJSON(only, entryID: entryID),
            bindingStatus: .current,
            atMilliseconds: atMilliseconds, in: db)
        if !existed {
            try insertUnitEventIfAbsent(
                unitID: unit.id, kind: .migrated,
                seed: "s05-unit|\(key)",
                afterJSON: senseSnapshotJSON(only, entryID: entryID),
                atMilliseconds: atMilliseconds, in: db)
        }
        try GRDBLearningUnitRepository.upsertAlias(
            LearningUnitDictionaryAlias(
                unitID: unit.id, provider: "jmdict",
                datasetVersion: datasetVersion,
                entryID: entryID, senseID: only.senseID,
                fingerprint: only.fingerprint, status: .current),
            resolvedAtMs: atMilliseconds, in: db)
        // flag：既有 tooEasy 不重复写；CAS 以当前 revision 为期望。
        let flag = try GRDBLearningUnitRepository.fetchFlag(
            unitID: unit.id, in: db)
        if flag?.tooEasy != true {
            _ = try GRDBLearningUnitRepository.setFlagTooEasy(
                unitID: unit.id, value: true,
                expectedRevision: flag?.revision ?? 0,
                operationID: deterministicUUID(
                    "s05-known|\(row.lexemeID)"),
                atMilliseconds: atMilliseconds, in: db)
        }
        try GRDBLearningUnitRepository.upsertMigrationItem(
            LearningUnitMigrationItem(
                sourceKey: sourceKey, legacyLexemeID: lexemeUUID,
                oldState: "known", status: .applied,
                evidenceJSON: try evidenceJSON([
                    "decision": "known_too_easy",
                    "binding": "\(entryID):\(only.senseID)",
                ]),
                targetUnitID: unit.id),
            in: db)
        counts.knownFlagged += 1
    }

    // MARK: - 重绑定应用（写事务内）

    struct UnitRow: Equatable, Sendable {
        let idRaw: String
        let identityKey: String
        let entryID: Int64?
        let semanticFingerprint: String?
        let fingerprintVersion: String?
        let bindingStatus: String
        let senseSnapshotJSON: String?
        let revision: Int64

        var uuid: UUID {
            (try? DatabaseValueCodec.decodeUUID(idRaw)) ?? UUID()
        }
    }

    private static func fetchDictionarySenseUnits(
        after cursor: String?, limit: Int, in db: Database
    ) throws -> [UnitRow] {
        let sql = """
            SELECT id, identity_key, dictionary_entry_id,
                   semantic_fingerprint, fingerprint_version,
                   binding_status, sense_snapshot_json, revision
            FROM lexical_learning_units
            WHERE identity_kind = 'dictionarySense'
            \(cursor == nil ? "" : "AND id > ?")
            ORDER BY id
            LIMIT \(limit)
            """
        let arguments: StatementArguments =
            cursor.map { StatementArguments([$0]) } ?? []
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map {
            UnitRow(
                idRaw: $0["id"], identityKey: $0["identity_key"],
                entryID: $0["dictionary_entry_id"],
                semanticFingerprint: $0["semantic_fingerprint"],
                fingerprintVersion: $0["fingerprint_version"],
                bindingStatus: $0["binding_status"],
                senseSnapshotJSON: $0["sense_snapshot_json"],
                revision: $0["revision"])
        }
    }

    /// 单批重绑计数（写事务内返回，避免闭包内直接改汇总）。
    struct RebindBatchCounts: Sendable {
        var scanned = 0
        var rebound = 0
        var confirmedCurrent = 0
        var markedAmbiguous = 0
        var markedStale = 0
        var aliasConflicts = 0
    }

    /// 单 unit 重绑应用。候选由调用方按指纹过滤后传入。
    static func applyRebind(
        unit: UnitRow,
        candidates: [VerifiedSense],
        newDatasetVersion: String,
        atMilliseconds: Int64,
        in db: Database,
        counts: inout RebindBatchCounts
    ) throws {
        let unitUUID = unit.uuid
        let sourceKey = "\(rebindItemPrefix)\(unit.idRaw)"
        let bindings = try GRDBLearningUnitRepository.fetchAliases(
            unitID: unitUUID, in: db)
        let active = bindings.filter { $0.alias.status != .superseded }
        let fingerprintVersion = unit.fingerprintVersion
            ?? SemanticFingerprint.semanticFingerprintVersion

        func markActive(
            _ status: LearningUnitDictionaryAlias.Status
        ) throws {
            for binding in active {
                _ = try GRDBLearningUnitRepository.upsertAlias(
                    LearningUnitDictionaryAlias(
                        unitID: unitUUID,
                        provider: binding.alias.provider,
                        datasetVersion: binding.alias.datasetVersion,
                        entryID: binding.alias.entryID,
                        senseID: binding.alias.senseID,
                        fingerprint: binding.alias.fingerprint,
                        status: status),
                    fingerprintVersion: binding.fingerprintVersion,
                    resolvedAtMs: atMilliseconds, in: db)
            }
        }
        func updateBindingStatus(
            _ status: LearningUnitBindingStatus,
            snapshotJSON: String? = nil
        ) throws {
            // 幂等：status 相同且快照未变 → 零写（重跑不 bump revision）。
            let snapshotChanged = snapshotJSON != nil
                && snapshotJSON != unit.senseSnapshotJSON
            guard status.rawValue != unit.bindingStatus
                      || snapshotChanged else { return }
            try db.execute(
                sql: """
                    UPDATE lexical_learning_units
                    SET binding_status = ?,
                        sense_snapshot_json = COALESCE(?, sense_snapshot_json),
                        revision = revision + 1,
                        updated_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    status.rawValue, snapshotJSON,
                    atMilliseconds, unit.idRaw,
                ])
        }

        switch candidates.count {
        case 1:
            let candidate = candidates[0]
            let newAlias = LearningUnitDictionaryAlias(
                unitID: unitUUID, provider: "jmdict",
                datasetVersion: newDatasetVersion,
                entryID: candidate.entryID, senseID: candidate.senseID,
                fingerprint: unit.semanticFingerprint ?? candidate.fingerprint,
                status: .current)
            let outcome = try GRDBLearningUnitRepository.upsertAlias(
                newAlias, fingerprintVersion: fingerprintVersion,
                resolvedAtMs: atMilliseconds, in: db)
            if case .markedNeedsConfirmation(let existing) = outcome {
                // 目标行被另一 unit 占用——不抢占，留待人工（§3.1）。
                counts.aliasConflicts += 1
                try updateBindingStatus(.needsConfirmation)
                try GRDBLearningUnitRepository.upsertMigrationItem(
                    LearningUnitMigrationItem(
                        sourceKey: sourceKey,
                        oldState: unit.bindingStatus,
                        status: .needsConfirmation,
                        evidenceJSON: try evidenceJSON([
                            "decision": "alias_conflict",
                            "existing_unit_id":
                                DatabaseValueCodec.encode(existing),
                        ]),
                        targetUnitID: unitUUID),
                    in: db)
                return
            }
            // 旧 alias 全部转 superseded（历史留史不删除）。
            for binding in active {
                let a = binding.alias
                guard !(a.provider == "jmdict"
                        && a.datasetVersion == newDatasetVersion
                        && a.entryID == candidate.entryID
                        && a.senseID == candidate.senseID) else { continue }
                _ = try GRDBLearningUnitRepository.upsertAlias(
                    LearningUnitDictionaryAlias(
                        unitID: unitUUID, provider: a.provider,
                        datasetVersion: a.datasetVersion,
                        entryID: a.entryID, senseID: a.senseID,
                        fingerprint: a.fingerprint, status: .superseded),
                    fingerprintVersion: binding.fingerprintVersion,
                    resolvedAtMs: atMilliseconds, in: db)
            }
            let alreadyBound = active.contains {
                $0.alias.provider == "jmdict"
                    && $0.alias.datasetVersion == newDatasetVersion
                    && $0.alias.entryID == candidate.entryID
                    && $0.alias.senseID == candidate.senseID
                    && $0.alias.status == .current
            }
            try updateBindingStatus(
                .current,
                snapshotJSON: senseSnapshotJSON(
                    candidate, entryID: candidate.entryID))
            try GRDBLearningUnitRepository.upsertMigrationItem(
                LearningUnitMigrationItem(
                    sourceKey: sourceKey,
                    oldState: unit.bindingStatus,
                    status: .applied,
                    evidenceJSON: try evidenceJSON([
                        "decision": alreadyBound ? "current" : "rebound",
                        "to": "\(candidate.entryID):\(candidate.senseID)",
                        "dataset": newDatasetVersion,
                    ]),
                    targetUnitID: unitUUID),
                in: db)
            if alreadyBound { counts.confirmedCurrent += 1 }
            else { counts.rebound += 1 }
        case 0:
            try markActive(.stale)
            try updateBindingStatus(.stale)
            try GRDBLearningUnitRepository.upsertMigrationItem(
                LearningUnitMigrationItem(
                    sourceKey: sourceKey,
                    oldState: unit.bindingStatus,
                    status: .pending,
                    evidenceJSON: try evidenceJSON([
                        "decision": "stale_no_candidate",
                        "dataset": newDatasetVersion,
                    ]),
                    targetUnitID: unitUUID),
                in: db)
            counts.markedStale += 1
        default:
            try markActive(.needsConfirmation)
            try updateBindingStatus(.needsConfirmation)
            try GRDBLearningUnitRepository.upsertMigrationItem(
                LearningUnitMigrationItem(
                    sourceKey: sourceKey,
                    oldState: unit.bindingStatus,
                    status: .needsConfirmation,
                    evidenceJSON: try evidenceJSON([
                        "decision": "ambiguous_candidates",
                        "candidates": candidates.map {
                            "\($0.entryID):\($0.senseID)"
                        },
                        "dataset": newDatasetVersion,
                    ]),
                    targetUnitID: unitUUID),
                in: db)
            counts.markedAmbiguous += 1
        }
    }

    // MARK: - 页面读取

    /// 未处理 vocabulary Note 页：`note:<id>` 审计项（任何状态）
    /// 不存在即未处理——经典 checkpoint：needsConfirmation 项同样遮蔽，
    /// 防止页循环反复扫到同一批「待确认」行导致本轮不收敛；
    /// 人工确认/换库重估走独立路径，不靠重扫。
    private func fetchUnprocessedNotePage() async throws -> [NoteRow] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT n.id, n.headword, n.reading, n.created_at_ms
                    FROM notes n
                    WHERE n.kind = 'vocabulary'
                      AND NOT EXISTS (
                          SELECT 1 FROM learning_unit_migration_items mi
                          WHERE mi.source_key = 'note:' || n.id)
                    ORDER BY n.id
                    LIMIT \(batchSize)
                    """).map {
                NoteRow(
                    id: $0["id"], headword: $0["headword"],
                    reading: $0["reading"], createdAtMs: $0["created_at_ms"])
            }
        }
    }

    /// 未处理 override 页（同上 checkpoint 语义——任何状态审计项
    /// 均遮蔽重扫）。
    private func fetchUnprocessedOverridePage() async throws -> [OverrideRow] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT o.lexeme_id, o.state, x.provider, x.entry_id,
                           x.written_form, x.reading
                    FROM vocabulary_knowledge_overrides o
                    JOIN lexemes x ON x.id = o.lexeme_id
                    WHERE NOT EXISTS (
                        SELECT 1 FROM learning_unit_migration_items mi
                        WHERE mi.source_key = 'override:' || o.lexeme_id)
                    ORDER BY o.lexeme_id
                    LIMIT \(batchSize)
                    """).map {
                OverrideRow(
                    lexemeID: $0["lexeme_id"], state: $0["state"],
                    provider: $0["provider"], entryID: $0["entry_id"],
                    writtenForm: $0["written_form"], reading: $0["reading"])
            }
        }
    }

    /// 批内全部 Note 的 SourceContext + lexeme 链接快照（一次读事务）。
    private static func fetchNoteEvidence(
        noteIDs: [String], in db: Database
    ) throws -> [String: NoteEvidence] {
        guard !noteIDs.isEmpty else { return [:] }
        var result: [String: NoteEvidence] = [:]
        for chunk in noteIDs.chunked(400) {
            let placeholders = self.placeholders(chunk.count)
            let args = StatementArguments(Array(chunk))
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT note_id, dictionary_entry_id, dictionary_version,
                           dictionary_sense_key
                    FROM source_contexts
                    WHERE note_id IN (\(placeholders))
                      AND (dictionary_entry_id IS NOT NULL
                           OR dictionary_sense_key IS NOT NULL)
                    ORDER BY is_primary DESC, created_at_ms
                    """,
                arguments: args) {
                let noteID: String = row["note_id"]
                result[noteID, default: .empty].contexts.append(
                    ContextRow(
                        entryID: row["dictionary_entry_id"],
                        datasetVersion: row["dictionary_version"],
                        senseKey: row["dictionary_sense_key"]))
            }
            var lexemesByNote: [String: [LexemeRow]] = [:]
            var lexemeIDs = Set<String>()
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT l.note_id, x.id, x.provider, x.entry_id, o.state
                    FROM lexeme_note_links l
                    JOIN lexemes x ON x.id = l.lexeme_id
                    LEFT JOIN vocabulary_knowledge_overrides o
                        ON o.lexeme_id = l.lexeme_id
                    WHERE l.note_id IN (\(placeholders))
                    """,
                arguments: args) {
                let noteID: String = row["note_id"]
                let lexemeID: String = row["id"]
                lexemeIDs.insert(lexemeID)
                lexemesByNote[noteID, default: []].append(
                    LexemeRow(
                        lexemeID: lexemeID,
                        provider: row["provider"],
                        entryID: row["entry_id"],
                        overrideState: row["state"]))
            }
            if !lexemeIDs.isEmpty {
                let lexemeList = Array(lexemeIDs)
                let lexemePH = self.placeholders(lexemeList.count)
                let lexemeArgs = StatementArguments(lexemeList)
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT lexeme_id, entry_id
                        FROM lexeme_dictionary_bindings
                        WHERE lexeme_id IN (\(lexemePH))
                        """,
                    arguments: lexemeArgs) {
                    let lexemeID: String = row["lexeme_id"]
                    let entryID: Int64 = row["entry_id"]
                    for (noteID, lexemes) in lexemesByNote
                    where lexemes.contains(where: {
                        $0.lexemeID == lexemeID
                    }) {
                        result[noteID, default: .empty].bindingEntryIDs
                            .append(entryID)
                    }
                }
            }
            for (noteID, lexemes) in lexemesByNote {
                result[noteID, default: .empty].lexemes = lexemes
            }
        }
        return result
    }

    private static func fetchBindings(
        lexemeIDs: [String], in db: Database
    ) throws -> [String: BindingRow] {
        guard !lexemeIDs.isEmpty else { return [:] }
        var result: [String: BindingRow] = [:]
        for chunk in lexemeIDs.chunked(400) {
            let placeholders = self.placeholders(chunk.count)
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT lexeme_id, entry_id, dataset_version, status,
                           match_tier
                    FROM lexeme_dictionary_bindings
                    WHERE lexeme_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(Array(chunk))) {
                let lexemeID: String = row["lexeme_id"]
                result[lexemeID] = BindingRow(
                    lexemeID: lexemeID,
                    entryID: row["entry_id"],
                    datasetVersion: row["dataset_version"],
                    status: row["status"],
                    matchTier: row["match_tier"])
            }
        }
        return result
    }

    // MARK: - 共享小工具

    private static func noteRow(
        noteID: UUID, in db: Database
    ) throws -> NoteRow? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, headword, reading, created_at_ms
                FROM notes WHERE id = ?
                """,
            arguments: [DatabaseValueCodec.encode(noteID)])
        .map {
            NoteRow(
                id: $0["id"], headword: $0["headword"],
                reading: $0["reading"], createdAtMs: $0["created_at_ms"])
        }
    }

    private static func upsertNoteItem(
        noteID: UUID,
        oldState: String?,
        status: LearningUnitMigrationItemStatus,
        targetUnitID: UUID?,
        evidence: [String: Any],
        in db: Database
    ) throws {
        try GRDBLearningUnitRepository.upsertMigrationItem(
            LearningUnitMigrationItem(
                sourceKey: "\(noteItemPrefix)\(noteID.uuidString.lowercased())",
                noteID: noteID, oldState: oldState, status: status,
                evidenceJSON: try evidenceJSON(evidence),
                targetUnitID: targetUnitID),
            in: db)
    }

    /// 确定性 operationID 派生（SHA-256(seed) 前 16 字节 → UUID v5
    /// 形态）——重跑同种子同 opID，幂等第三层回放零新增。
    static func deterministicUUID(_ seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant 10
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// 写审计事件（operationID 已存在 → 幂等跳过）。
    private static func insertUnitEventIfAbsent(
        unitID: UUID,
        kind: LearningUnitEventKind,
        seed: String,
        afterJSON: String?,
        atMilliseconds: Int64,
        in db: Database,
        unitIDSnapshot: UUID? = nil
    ) throws {
        let operationID = deterministicUUID(seed)
        guard try GRDBLearningUnitRepository.fetchEvent(
            operationID: operationID, in: db) == nil else { return }
        try GRDBLearningUnitRepository.insertEvent(
            LearningUnitEventRecord(
                id: UUID(), operationID: operationID,
                unitID: unitID,
                unitIDSnapshot: unitIDSnapshot ?? unitID,
                kind: kind, afterJSON: afterJSON,
                payloadHash: afterJSON.map(sha256Hex),
                createdAtMs: atMilliseconds),
            in: db)
    }

    static func evidenceJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func idDigest(
        _ db: Database, sql: String
    ) throws -> String {
        let ids = try String.fetchAll(db, sql: sql)
        return sha256Hex(ids.joined(separator: "\n"))
    }

    /// 逐列内容摘要：按 `DatabaseValue` 原始 storage 序列化——
    /// REAL 位级精确，NULL 显式标记；行按 SQL 给定序。
    private static func rowsDigest(
        _ db: Database, sql: String
    ) throws -> String {
        var buffer = ""
        for row in try Row.fetchAll(db, sql: sql) {
            for column in row.columnNames {
                let value: DatabaseValue = row[column]
                switch value.storage {
                case .null: buffer.append("∅")
                case .int64(let int): buffer.append(String(int))
                case .double(let double): buffer.append(String(double))
                case .string(let string): buffer.append(string)
                case .blob(let data):
                    buffer.append(data.base64EncodedString())
                }
                buffer.append("\u{1}")
            }
            buffer.append("\u{2}")
        }
        return sha256Hex(buffer)
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

// MARK: - GRDB 词典快照 sense 读取

/// `SenseSnapshotReader` 的 GRDB 实现：读词典库
/// senses/sense_pos/sense_tags/glosses(eng)/sense_form_restrictions/
/// sense_reading_restrictions + forms/readings，按 `SemanticFingerprint`
/// 现场算指纹（与 `GRDBDictionaryRepository.fetchEntries` 同形状查询）。
public struct GRDBLearningUnitSenseSnapshotReader: LearningUnitBackfillService.SenseSnapshotReader {
    private let reader: any DatabaseReader
    private let versionOverride: String?

    public init(reader: any DatabaseReader, datasetVersion: String? = nil) {
        self.reader = reader
        self.versionOverride = datasetVersion
    }

    public func datasetVersion() async throws -> String? {
        if let versionOverride { return versionOverride }
        return try await reader.read { db in
            guard try db.tableExists("dictionary_metadata") else { return nil }
            var values: [String: String] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT key, value FROM dictionary_metadata") {
                values[row["key"]] = row["value"]
            }
            return values["dataset_version"] ?? values["dictionary_version"]
        }
    }

    public func verifiedSenses(
        entryID: Int64
    ) async throws -> [LearningUnitBackfillService.VerifiedSense] {
        try await reader.read { db in
            try Self.verifiedSenses(entryID: entryID, in: db)
        }
    }

    /// 事务内形态（组合读可复用）。entry 不存在返回 []。
    public static func verifiedSenses(
        entryID: Int64, in db: Database
    ) throws -> [LearningUnitBackfillService.VerifiedSense] {
        let senseRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, sense_order FROM senses
                WHERE entry_id = ? ORDER BY sense_order, id
                """,
            arguments: [entryID])
        guard !senseRows.isEmpty else { return [] }
        let senseIDs: [Int64] = senseRows.map { $0["id"] }
        let placeholders = Array(
            repeating: "?", count: senseIDs.count).joined(separator: ",")
        let args = StatementArguments(senseIDs)

        var posBySense: [Int64: [String]] = [:]
        var tagsBySense: [Int64: [DictionarySenseTag]] = [:]
        var glossesBySense: [Int64: [String]] = [:]
        var restrictedForms: [Int64: [String]] = [:]
        var restrictedReadings: [Int64: [String]] = [:]

        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT sense_id, code FROM sense_pos
                WHERE sense_id IN (\(placeholders))
                ORDER BY sense_id, code
                """,
            arguments: args) {
            posBySense[row["sense_id"], default: []].append(row["code"])
        }
        if try db.tableExists("sense_tags") {
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT sense_id, category, code FROM sense_tags
                    WHERE sense_id IN (\(placeholders))
                    ORDER BY sense_id, category, code
                    """,
                arguments: args) {
                tagsBySense[row["sense_id"], default: []].append(
                    DictionarySenseTag(
                        category: row["category"], code: row["code"]))
            }
        }
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT sense_id, text FROM glosses
                WHERE language = 'eng' AND sense_id IN (\(placeholders))
                ORDER BY sense_id, gloss_order
                """,
            arguments: args) {
            glossesBySense[row["sense_id"], default: []].append(row["text"])
        }
        if try db.tableExists("sense_form_restrictions") {
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT sfr.sense_id, f.text
                    FROM sense_form_restrictions sfr
                    JOIN forms f ON f.id = sfr.form_id
                    WHERE sfr.sense_id IN (\(placeholders))
                    ORDER BY sfr.sense_id, sfr.form_id
                    """,
                arguments: args) {
                restrictedForms[row["sense_id"], default: []]
                    .append(row["text"])
            }
        }
        if try db.tableExists("sense_reading_restrictions") {
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT srr.sense_id, r.reading
                    FROM sense_reading_restrictions srr
                    JOIN readings r ON r.id = srr.reading_id
                    WHERE srr.sense_id IN (\(placeholders))
                    ORDER BY srr.sense_id, srr.reading_id
                    """,
                arguments: args) {
                restrictedReadings[row["sense_id"], default: []]
                    .append(row["reading"])
            }
        }

        return senseRows.map { row in
            let senseID: Int64 = row["id"]
            let glosses = glossesBySense[senseID] ?? []
            return LearningUnitBackfillService.VerifiedSense(
                entryID: entryID,
                senseID: senseID,
                fingerprint: SemanticFingerprint.compute(
                    entryID: entryID,
                    normalizedGlosses: glosses,
                    posCodes: posBySense[senseID] ?? [],
                    restrictedForms: restrictedForms[senseID] ?? [],
                    restrictedReadings: restrictedReadings[senseID] ?? [],
                    tags: tagsBySense[senseID] ?? []),
                glossesEN: glosses,
                posCodes: posBySense[senseID] ?? [])
        }
    }
}

private extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [] }
        var result: [ArraySlice<Element>] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(
                index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[index..<next])
            index = next
        }
        return result
    }
}
