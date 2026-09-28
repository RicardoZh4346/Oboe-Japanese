import Foundation

/// v0.7.5 S06：写路径携带的「已验证词典义项」绑定意图（contracts §1、
/// decisions D01）。由具备词典访问的装配方（ReaderMiningService、
/// 未来的 AI Pipeline 应用层）在构建 commit 前用当前快照计算——
/// 事务内不再回查词典，只消费这里的快照值。
///
/// `nil` = 无可靠义项证据 → 写路径落 `localNote` unit。
public struct DictionarySenseBinding: Equatable, Sendable, Codable {
    /// JMdict `ent_seq`。
    public let entryID: Int64
    /// 当前快照 `senses.id`——本快照内行 ID，非义项序号。
    public let senseID: Int64
    /// 词典构建版本串（alias.dataset_version）。
    public let datasetVersion: String
    /// `SemanticFingerprint.compute` 输出（sense-fp-1）。
    public let fingerprint: String
    /// 有界义项快照 JSON（写入 `sense_snapshot_json`，不含正文/Prompt）。
    public let senseSnapshotJSON: String

    public init(
        entryID: Int64,
        senseID: Int64,
        datasetVersion: String,
        fingerprint: String,
        senseSnapshotJSON: String
    ) {
        self.entryID = entryID
        self.senseID = senseID
        self.datasetVersion = datasetVersion
        self.fingerprint = fingerprint
        self.senseSnapshotJSON = senseSnapshotJSON
    }

    /// dictionarySense unit 的共享 identity key（contracts §1.1）。
    public var identityKey: String {
        "jmdict:sense-v1:\(entryID):\(fingerprint)"
    }

    /// 从当前词典快照的 `DictionarySense` 装配：指纹 + 有界快照 JSON。
    /// 快照只收指纹输入字段 + 行 id/datasetVersion（stale 标记与未来
    /// rebind 复核所需），不含正文/Prompt/原始 gloss 之外的大对象。
    public static func from(
        sense: DictionarySense,
        entryID: Int64,
        datasetVersion: String
    ) throws -> DictionarySenseBinding {
        let snapshot: [String: Any] = [
            "entry_id": entryID,
            "sense_id": sense.id,
            "dataset_version": datasetVersion,
            "glosses_en": sense.glosses(language: DictionaryGlossLanguage.english)
                .map(\.text),
            "pos_codes": sense.posCodes,
            "restricted_forms": sense.restrictedForms,
            "restricted_readings": sense.restrictedReadings,
            "tags": sense.tags.map { [$0.category, $0.code] },
            "fingerprint_version": SemanticFingerprint.semanticFingerprintVersion,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: snapshot, options: [.sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return DictionarySenseBinding(
            entryID: entryID,
            senseID: sense.id,
            datasetVersion: datasetVersion,
            fingerprint: SemanticFingerprint.compute(entryID: entryID, sense: sense),
            senseSnapshotJSON: json
        )
    }
}
