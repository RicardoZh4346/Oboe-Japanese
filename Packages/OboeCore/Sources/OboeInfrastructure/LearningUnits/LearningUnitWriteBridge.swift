import Foundation
import GRDB
import OboeDomain

/// v0.7.5 S06（contracts §1、分步开发计划 S06）：所有词汇 Note 写路径的
/// 统一 Learning Unit 绑定入口。
///
/// 每走 `GRDBContentWriteExecutor.commitVocabulary` 落库的新词汇 Note，
/// 与 Note/Card/membership/来源/receipt **同一事务**内获得正式 unit
/// 链接——任一入口都不得写出游离 Note。
///
/// 绑定分两类（D01/D05 冻结）：
/// - 装配方给出 `DictionarySenseBinding`（装配方已用当前词典快照验算
///   过义项）→ resolve-or-create `jmdict:sense-v1:<entryID>:<fp>` unit
///   + current alias + primary link；
/// - 无绑定（手动创建/CSV/导入等无可靠义项证据）→ `localNote` unit
///   + primary link。
///
/// 两条路径对「已有链接」都幂等：Replay/重试不再写、也不换绑——
/// 换绑只能走显式 `unlinkNote`+`linkNote`（S05 回填/S16 UI 的职责）。
public enum LearningUnitWriteBridge {
    /// 为已插入的词汇 Note 确保正式 unit 链接；返回绑定的 unit。
    ///
    /// - Parameter binding: 装配方验证过的词典义项绑定；nil → localNote。
    /// - Parameter linkOrigin: link 行记录的写入口（manual/reader→
    ///   userConfirmed/ai→automaticHighConfidence/import→imported…），
    ///   由 `linkOrigin(for:)` 统一映射。
    @discardableResult
    public static func ensureUnit(
        noteID: UUID,
        headword: String,
        reading: String?,
        binding: DictionarySenseBinding?,
        linkOrigin: LearningUnitNoteLinkOrigin,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> LearningUnit {
        // 已有正式链接 → 幂等返回（Replay/重试/并发重入全收敛于此）。
        if let existing = try GRDBLearningUnitRepository.fetchLink(
            noteID: noteID, in: db),
           let unit = try GRDBLearningUnitRepository.fetchUnit(
            id: existing.unitID, in: db) {
            return unit
        }

        let normalizedReading = reading?.isEmpty == true ? nil : reading
        let unit = try resolveUnit(
            noteID: noteID, headword: headword, reading: normalizedReading,
            binding: binding, atMilliseconds: atMilliseconds, in: db
        )
        // dictionarySense unit 可能已有 primary（别处已学的同一义项）——
        // 本 Note 降级非主链接（schema 只有 primary|legacy_secondary
        // 两档；共享义项的非主归属一律落 legacy_secondary，语义即
        // 「该 Note 共享 unit，primary 保留在原 Note」），
        // localNote unit 每 Note 专属，恒为 primary。
        let role: LearningUnitNoteLinkRole =
            binding == nil ? .primary : resolvedRole(unitID: unit.id, in: db)
        try GRDBLearningUnitRepository.linkNote(
            unitID: unit.id, noteID: noteID, role: role,
            origin: linkOrigin, atMilliseconds: atMilliseconds, in: db
        )
        return unit
    }

    /// `ContentOrigin` → link origin 映射：写入口的语义记录进
    /// `learning_unit_note_links.origin`（审计/回放可读）。
    public static func linkOrigin(for origin: ContentOrigin) -> LearningUnitNoteLinkOrigin {
        switch origin {
        case .manual: .manual
        case .reader: .userConfirmed
        case .ai: .automaticHighConfidence
        case .builtinJLPT, .import: .imported
        }
    }

    /// `dictionaryBinding`（commit 字段）→ resolve-or-create dictionarySense
    /// unit + current alias；否则 resolve-or-create localNote unit。
    private static func resolveUnit(
        noteID: UUID,
        headword: String,
        reading: String?,
        binding: DictionarySenseBinding?,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> LearningUnit {
        guard let binding else {
            return try GRDBLearningUnitRepository.resolveOrCreateUnit(
                identityKind: .localNote,
                identityKey: "local-note:\(noteID.uuidString.lowercased())",
                lemma: headword, reading: reading,
                atMilliseconds: atMilliseconds, in: db
            )
        }
        let unit = try GRDBLearningUnitRepository.resolveOrCreateUnit(
            identityKind: .dictionarySense,
            identityKey: binding.identityKey,
            lemma: headword, reading: reading,
            provider: "jmdict", entryID: binding.entryID,
            fingerprint: binding.fingerprint,
            fingerprintVersion: SemanticFingerprint.semanticFingerprintVersion,
            senseSnapshotJSON: binding.senseSnapshotJSON,
            bindingStatus: .current,
            atMilliseconds: atMilliseconds, in: db
        )
        // 当前快照 alias——同 (provider,entryID) 已有 alias 时
        // upsertAlias 内部判等/needsConfirmation，不静默换绑。
        try GRDBLearningUnitRepository.upsertAlias(
            LearningUnitDictionaryAlias(
                unitID: unit.id,
                provider: "jmdict",
                datasetVersion: binding.datasetVersion,
                entryID: binding.entryID,
                senseID: binding.senseID,
                fingerprint: binding.fingerprint,
                status: .current
            ),
            resolvedAtMs: atMilliseconds,
            in: db
        )
        return unit
    }

    /// dictionarySense unit：已有 primary 时新 Note 降级
    /// `legacy_secondary`（contracts §1 unit↔primary 1:1；同义项的
    /// 非主 Note 归附属「共享 unit、primary 保留」语义）。
    private static func resolvedRole(
        unitID: UUID, in db: Database
    ) -> LearningUnitNoteLinkRole {
        let hasPrimary = (try? GRDBLearningUnitRepository.fetchLinks(
            unitID: unitID, in: db
        ).contains { $0.role == .primary }) ?? false
        return hasPrimary ? .legacySecondary : .primary
    }
}
