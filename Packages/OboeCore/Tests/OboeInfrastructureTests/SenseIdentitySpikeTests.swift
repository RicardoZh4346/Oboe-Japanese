import Foundation
import OboeDomain
import XCTest

/// v0.7.5 S02 工作包 A spike——义项身份与词典快照重绑定（D01/§3.1）。
///
/// 用 `Fixtures/identity-spike/snapshot-v{1,2}.json` 模拟一次词典换库：
/// v1 是「已绑定」快照，v2 在同一个小词典上编码了真实上游变更——
/// sense 行 id 重排、义项中间插入导致行 id 位移、中文 gloss 润色、
/// 同 entry 不可区分的重复指纹、义项被上游删除。
///
/// `bind`/`rebind` 是本文件的 spike 版纯函数实现（正式实现归
/// S03/S04 契约与服务层），语义与 `LexemeRebindService` 纪律一致：
/// - 唯一指纹候选 → `current`：alias 更新到新快照行，unit UUID 不变；
/// - 多候选（重复指纹）→ `needsConfirmation`：保留旧行引用 + 隔离
///   identity key，禁止自动合并/互指；
/// - 零候选 → `stale`：保留旧行引用与旧 dataset_version，下轮可重试，
///   不静默换绑。
///
/// 候选按 fingerprint 全快照匹配（fingerprint 内嵌 entry_id，
/// 无需再按 entry 过滤）。
final class SenseIdentitySpikeTests: XCTestCase {

    // MARK: - fixture 解码（字段镜像 DictionarySense 聚合输入）

    private struct SnapshotTag: Decodable {
        let category: String
        let code: String
    }

    private struct SnapshotSense: Decodable {
        let senseID: Int64
        let senseOrder: Int
        let glossesEN: [String]
        let glossesZH: [String]
        let posCodes: [String]
        let restrictedForms: [String]
        let restrictedReadings: [String]
        let tags: [SnapshotTag]

        enum CodingKeys: String, CodingKey {
            case senseID = "sense_id"
            case senseOrder = "sense_order"
            case glossesEN = "glosses_en"
            case glossesZH = "glosses_zh"
            case posCodes = "pos_codes"
            case restrictedForms = "restricted_forms"
            case restrictedReadings = "restricted_readings"
            case tags
        }
    }

    private struct SnapshotEntry: Decodable {
        let entryID: Int64
        let senses: [SnapshotSense]

        enum CodingKeys: String, CodingKey {
            case entryID = "entry_id"
            case senses
        }
    }

    private struct Snapshot: Decodable {
        let datasetVersion: String
        let entries: [SnapshotEntry]

        enum CodingKeys: String, CodingKey {
            case datasetVersion = "dataset_version"
            case entries
        }

        /// 展平为 (entryID, sense) 序列，保持文件内发射顺序。
        var allSenses: [(entryID: Int64, sense: SnapshotSense)] {
            entries.flatMap { entry in
                entry.senses.map { (entry.entryID, $0) }
            }
        }

        func row(entryID: Int64, senseID: Int64) -> SnapshotSense? {
            allSenses.first {
                $0.entryID == entryID && $0.sense.senseID == senseID
            }?.sense
        }
    }

    private func loadSnapshot(
        _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Snapshot {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name, withExtension: "json",
                subdirectory: "Fixtures/identity-spike"),
            "\(name).json missing from test bundle",
            file: file, line: line)
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    private func fingerprint(
        of sense: SnapshotSense, entryID: Int64
    ) -> String {
        SemanticFingerprint.compute(
            entryID: entryID,
            normalizedGlosses: sense.glossesEN,
            posCodes: sense.posCodes,
            restrictedForms: sense.restrictedForms,
            restrictedReadings: sense.restrictedReadings,
            tags: sense.tags.map {
                DictionarySenseTag(category: $0.category, code: $0.code)
            }
        )
    }

    // MARK: - spike 版 bind / rebind 纯函数

    /// v1 绑定时刻：按指纹在快照内查候选；唯一 → current（可共享
    /// `provider:sense-v1:...` key），同 entry 不可区分的重复指纹 →
    /// needsConfirmation + 隔离 key，禁止自动合并。
    private func bind(
        unitID: UUID = UUID(),
        provider: String = "jmdict",
        entryID: Int64,
        senseID: Int64,
        in snapshot: Snapshot,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> LearningUnitDictionaryAlias {
        let row = try XCTUnwrap(
            snapshot.row(entryID: entryID, senseID: senseID),
            "fixture row \(entryID):\(senseID) missing",
            file: file, line: line)
        let fp = fingerprint(of: row, entryID: entryID)
        let matches = snapshot.allSenses.filter {
            fingerprint(of: $0.sense, entryID: $0.entryID) == fp
        }
        return LearningUnitDictionaryAlias(
            unitID: unitID,
            provider: provider,
            datasetVersion: snapshot.datasetVersion,
            entryID: entryID,
            senseID: senseID,
            fingerprint: fp,
            status: matches.count == 1 ? .current : .needsConfirmation
        )
    }

    private enum SpikeOutcome: String {
        case rebound
        case needsConfirmation
        case stale
    }

    private struct SpikeRebindResult {
        let outcome: SpikeOutcome
        let alias: LearningUnitDictionaryAlias
        /// 新快照中与本 alias 指纹相同的候选 sense_id 集合（排序）。
        let candidateSenseIDs: [Int64]
    }

    /// 换快照重绑：以绑定时刻 fingerprint 在新快照找候选。
    /// 唯一 → 更新 alias 到新行；零/多候选 → 保留旧行引用
    /// （dataset_version 停在旧版，可重试），只改 status。
    private func rebind(
        _ alias: LearningUnitDictionaryAlias,
        to snapshot: Snapshot
    ) -> SpikeRebindResult {
        let candidates = snapshot.allSenses.filter {
            fingerprint(of: $0.sense, entryID: $0.entryID) == alias.fingerprint
        }
        let candidateIDs = candidates.map { $0.sense.senseID }.sorted()
        switch candidates.count {
        case 1:
            let candidate = candidates[0]
            let updated = LearningUnitDictionaryAlias(
                unitID: alias.unitID,
                provider: alias.provider,
                datasetVersion: snapshot.datasetVersion,
                entryID: candidate.entryID,
                senseID: candidate.sense.senseID,
                fingerprint: alias.fingerprint,
                status: .current
            )
            return SpikeRebindResult(
                outcome: .rebound, alias: updated,
                candidateSenseIDs: candidateIDs)
        case 0:
            let kept = LearningUnitDictionaryAlias(
                unitID: alias.unitID,
                provider: alias.provider,
                datasetVersion: alias.datasetVersion,
                entryID: alias.entryID,
                senseID: alias.senseID,
                fingerprint: alias.fingerprint,
                status: .stale
            )
            return SpikeRebindResult(
                outcome: .stale, alias: kept,
                candidateSenseIDs: [])
        default:
            let kept = LearningUnitDictionaryAlias(
                unitID: alias.unitID,
                provider: alias.provider,
                datasetVersion: alias.datasetVersion,
                entryID: alias.entryID,
                senseID: alias.senseID,
                fingerprint: alias.fingerprint,
                status: .needsConfirmation
            )
            return SpikeRebindResult(
                outcome: .needsConfirmation, alias: kept,
                candidateSenseIDs: candidateIDs)
        }
    }

    // MARK: - 快照健全性

    func testSnapshotsLoadWithExpectedShape() throws {
        let v1 = try loadSnapshot("snapshot-v1")
        let v2 = try loadSnapshot("snapshot-v2")
        XCTAssertEqual(v1.datasetVersion, "jmdict-spike-v1")
        XCTAssertEqual(v2.datasetVersion, "jmdict-spike-v2")
        XCTAssertEqual(v1.allSenses.count, 12)
        XCTAssertEqual(v2.allSenses.count, 12)
        XCTAssertEqual(Set(v1.entries.map(\.entryID)).count, 7)
        XCTAssertEqual(Set(v2.entries.map(\.entryID)).count, 7)
        // fixture 必须真的编码了差异，否则下方断言在测空集。
        XCTAssertNotEqual(
            v1.row(entryID: 100002, senseID: 3)?.glossesEN,
            v2.row(entryID: 100002, senseID: 3)?.glossesEN)
        XCTAssertEqual(
            v1.entries.first { $0.entryID == 100007 }?.senses.count, 2)
        XCTAssertEqual(
            v2.entries.first { $0.entryID == 100007 }?.senses.count, 1,
            "v2 必须真的删掉了「origin」义项")
    }

    // MARK: - (a) sense id 重排：内容跟指纹走，行 id 只是载体

    func testSenseIDReorderKeepsUnitBinding() throws {
        let v1 = try loadSnapshot("snapshot-v1")
        let v2 = try loadSnapshot("snapshot-v2")

        // v1：「to eat」在 (100002, sense_id=3)，「to live on」在 4。
        let eatUnit = UUID()
        let liveUnit = UUID()
        let eatAlias = try bind(
            unitID: eatUnit, entryID: 100002, senseID: 3, in: v1)
        let liveAlias = try bind(
            unitID: liveUnit, entryID: 100002, senseID: 4, in: v1)
        XCTAssertEqual(eatAlias.status, .current)
        XCTAssertEqual(liveAlias.status, .current)

        // v2：两个义项发射顺序互换 → 行 id 互换，内容不变。
        let eatResult = rebind(eatAlias, to: v2)
        let liveResult = rebind(liveAlias, to: v2)

        XCTAssertEqual(eatResult.outcome, .rebound)
        XCTAssertEqual(eatResult.alias.status, .current)
        XCTAssertEqual(eatResult.alias.unitID, eatUnit, "重绑不得换 unit")
        XCTAssertEqual(eatResult.alias.senseID, 4,
                       "「to eat」应按指纹落到 v2 的行 4，而不是黏在行 3")
        XCTAssertEqual(eatResult.alias.datasetVersion, "jmdict-spike-v2")
        XCTAssertEqual(
            v2.row(entryID: 100002, senseID: 4)?.glossesEN, ["to eat"])

        XCTAssertEqual(liveResult.outcome, .rebound)
        XCTAssertEqual(liveResult.alias.unitID, liveUnit)
        XCTAssertEqual(liveResult.alias.senseID, 3)
        XCTAssertEqual(
            v2.row(entryID: 100002, senseID: 3)?.glossesEN.first,
            "to live on")

        // 共享 identity key 用的是指纹而非行 id：两个 unit 的 key 不同
        // 且重绑前后同一个 unit 的 key 不变。
        XCTAssertEqual(
            eatResult.alias.identityKey,
            "jmdict:sense-v1:100002:\(eatAlias.fingerprint)")
        XCTAssertNotEqual(
            eatResult.alias.identityKey, liveResult.alias.identityKey)
        XCTAssertEqual(
            eatResult.alias.identityKey,
            "jmdict:sense-v1:100002:"
                + fingerprint(of: v2.row(entryID: 100002, senseID: 4)!,
                              entryID: 100002))
    }

    // MARK: - (b) 中间插入义项：位移的行 id 不得错绑到新义项

    func testInsertedSenseShiftRebindsToNewRowID() throws {
        let v1 = try loadSnapshot("snapshot-v1")
        let v2 = try loadSnapshot("snapshot-v2")

        // v1：「to proceed」在 (100003, sense_id=6)。
        let proceedUnit = UUID()
        let proceedAlias = try bind(
            unitID: proceedUnit, entryID: 100003, senseID: 6, in: v1)

        // v2：新义项「to be held」插在 order=1 占了行 6，原义项位移到 7。
        XCTAssertEqual(
            v2.row(entryID: 100003, senseID: 6)?.glossesEN.first,
            "to be held")
        let insertedFP = fingerprint(
            of: try XCTUnwrap(v2.row(entryID: 100003, senseID: 6)),
            entryID: 100003)
        XCTAssertNotEqual(insertedFP, proceedAlias.fingerprint,
                          "插入义项与原义项的语义内容不同，指纹必须区分")

        let result = rebind(proceedAlias, to: v2)
        XCTAssertEqual(result.outcome, .rebound)
        XCTAssertEqual(result.candidateSenseIDs, [7],
                       "插入的行 6 不得成为候选——位移由指纹追踪")
        XCTAssertEqual(result.alias.unitID, proceedUnit)
        XCTAssertEqual(result.alias.senseID, 7)
        XCTAssertEqual(result.alias.status, .current)

        // 同 entry 未位移义项不受影响。
        let goAlias = try bind(
            unitID: UUID(), entryID: 100003, senseID: 5, in: v1)
        let goResult = rebind(goAlias, to: v2)
        XCTAssertEqual(goResult.outcome, .rebound)
        XCTAssertEqual(goResult.alias.senseID, 5)
    }

    // MARK: - (c) 中文 gloss 润色：不进指纹，绑定无损

    func testChineseGlossRewriteKeepsFingerprintAndBinding() throws {
        let v1 = try loadSnapshot("snapshot-v1")
        let v2 = try loadSnapshot("snapshot-v2")

        let v1Row = try XCTUnwrap(v1.row(entryID: 100004, senseID: 7))
        let v2Row = try XCTUnwrap(v2.row(entryID: 100004, senseID: 8))
        XCTAssertNotEqual(v1Row.glossesZH, v2Row.glossesZH,
                          "fixture 必须真的改了中文 gloss")
        XCTAssertEqual(v1Row.glossesEN, v2Row.glossesEN)
        XCTAssertEqual(
            fingerprint(of: v1Row, entryID: 100004),
            fingerprint(of: v2Row, entryID: 100004),
            "机器中文层润色不得拆分义项身份（D01）")

        let unit = UUID()
        let alias = try bind(
            unitID: unit, entryID: 100004, senseID: 7, in: v1)
        let result = rebind(alias, to: v2)
        XCTAssertEqual(result.outcome, .rebound)
        XCTAssertEqual(result.alias.unitID, unit)
        XCTAssertEqual(result.alias.senseID, 8)
    }

    // MARK: - (d) 重复指纹：隔离 + needsConfirmation，绝不自动合并

    func testFingerprintCollisionNeverAutoMerges() throws {
        let v1 = try loadSnapshot("snapshot-v1")
        let v2 = try loadSnapshot("snapshot-v2")

        // fixture 前提：同 entry 两义项 en gloss+POS+限定+tags 全同。
        let v2RowA = try XCTUnwrap(v2.row(entryID: 100005, senseID: 9))
        let v2RowB = try XCTUnwrap(v2.row(entryID: 100005, senseID: 10))
        XCTAssertEqual(
            fingerprint(of: v2RowA, entryID: 100005),
            fingerprint(of: v2RowB, entryID: 100005),
            "collision pair 必须真的产出同一指纹")
        XCTAssertNotEqual(v2RowA.glossesZH, v2RowB.glossesZH,
                          "仅中文层不同——这正是不可自动合并的场景")

        // v1 绑定时刻即无法区分 → 两个 alias 都是 needsConfirmation，
        // 各自拿隔离 key（含 dataset+senseID，互不相同）。
        let unitA = UUID(), unitB = UUID()
        let aliasA = try bind(
            unitID: unitA, entryID: 100005, senseID: 8, in: v1)
        let aliasB = try bind(
            unitID: unitB, entryID: 100005, senseID: 9, in: v1)
        XCTAssertEqual(aliasA.status, .needsConfirmation)
        XCTAssertEqual(aliasB.status, .needsConfirmation)
        XCTAssertEqual(aliasA.fingerprint, aliasB.fingerprint)
        XCTAssertNotEqual(aliasA.identityKey, aliasB.identityKey)
        XCTAssertTrue(aliasA.identityKey.contains("isolated"))
        XCTAssertTrue(aliasA.identityKey.hasSuffix(":100005:8"))
        XCTAssertTrue(aliasB.identityKey.hasSuffix(":100005:9"))

        // v2 重绑：仍是两个候选 → 维持 needsConfirmation，
        // 保留各自 v1 行引用，谁都不许认领对方的行、也不许升级为
        // current 把两个 unit 合并。
        let resultA = rebind(aliasA, to: v2)
        let resultB = rebind(aliasB, to: v2)
        XCTAssertEqual(resultA.outcome, .needsConfirmation)
        XCTAssertEqual(resultB.outcome, .needsConfirmation)
        XCTAssertEqual(resultA.candidateSenseIDs, [9, 10])
        XCTAssertEqual(resultB.candidateSenseIDs, [9, 10])

        XCTAssertEqual(resultA.alias.unitID, unitA)
        XCTAssertEqual(resultB.alias.unitID, unitB)
        XCTAssertNotEqual(resultA.alias.unitID, resultB.alias.unitID,
                          "禁止把两个 unit 自动合并")
        XCTAssertEqual(resultA.alias.senseID, 8,
                       "多候选时保留自己的旧行引用，不指向对方/不猜新行")
        XCTAssertEqual(resultB.alias.senseID, 9)
        XCTAssertEqual(resultA.alias.datasetVersion, "jmdict-spike-v1",
                       "未确认的 alias 留在旧版，下轮仍可重试")
        XCTAssertNotEqual(resultA.alias.identityKey,
                          resultB.alias.identityKey)
    }

    // MARK: - (e) 上游删除义项：stale，不静默换绑

    func testDroppedSenseBecomesStale() throws {
        let v1 = try loadSnapshot("snapshot-v1")
        let v2 = try loadSnapshot("snapshot-v2")

        let unit = UUID()
        let originAlias = try bind(
            unitID: unit, entryID: 100007, senseID: 12, in: v1)
        XCTAssertEqual(originAlias.status, .current)

        let result = rebind(originAlias, to: v2)
        XCTAssertEqual(result.outcome, .stale)
        XCTAssertTrue(result.candidateSenseIDs.isEmpty)
        XCTAssertEqual(result.alias.unitID, unit)
        XCTAssertEqual(result.alias.status, .stale)
        // 保留旧行引用与旧版本号：可审计、可在 v3 重试。
        XCTAssertEqual(result.alias.senseID, 12)
        XCTAssertEqual(result.alias.datasetVersion, "jmdict-spike-v1")
        XCTAssertTrue(result.alias.identityKey.contains("isolated"))

        // 同 entry 存活义项正常重绑（行 id 12→12 只是恰好同号）。
        let bookAlias = try bind(
            unitID: UUID(), entryID: 100007, senseID: 11, in: v1)
        let bookResult = rebind(bookAlias, to: v2)
        XCTAssertEqual(bookResult.outcome, .rebound)
        XCTAssertEqual(bookResult.alias.senseID, 12)
        XCTAssertEqual(bookResult.candidateSenseIDs, [12])
    }

    // MARK: - 指纹成分证明：不含 row id / sense_order / 中文 gloss

    func testFingerprintIgnoresVolatileIdentityFields() throws {
        let v1 = try loadSnapshot("snapshot-v1")
        let v2 = try loadSnapshot("snapshot-v2")

        // 同一「to eat」义项：v1 行 3 order 0 → v2 行 4 order 1。
        // 行 id 与 sense_order 都不是 compute 的输入，同内容必然同指纹。
        let eatV1 = fingerprint(
            of: try XCTUnwrap(v1.row(entryID: 100002, senseID: 3)),
            entryID: 100002)
        let eatV2 = fingerprint(
            of: try XCTUnwrap(v2.row(entryID: 100002, senseID: 4)),
            entryID: 100002)
        XCTAssertEqual(eatV1, eatV2,
                       "行 id/sense_order 变化不得影响指纹")

        // 中文 gloss 改写前后指纹相等（fixture 行级证据）。
        XCTAssertEqual(
            fingerprint(of: try XCTUnwrap(v1.row(entryID: 100004, senseID: 7)),
                        entryID: 100004),
            fingerprint(of: try XCTUnwrap(v2.row(entryID: 100004, senseID: 8)),
                        entryID: 100004))
    }

    // MARK: - 指纹成分证明：语义字段确实参与（反向控制）

    func testFingerprintCoversSemanticFields() throws {
        let base: (Int64, [String], [String], [String], [String], [DictionarySenseTag]) = (
            100001, ["to go up", "to rise"], ["v1", "vi"],
            ["上がる"], ["あがる"],
            [DictionarySenseTag(category: "misc", code: "uk")]
        )
        func fp(
            entryID: Int64? = nil,
            glosses: [String]? = nil,
            pos: [String]? = nil,
            forms: [String]? = nil,
            readings: [String]? = nil,
            tags: [DictionarySenseTag]? = nil
        ) -> String {
            SemanticFingerprint.compute(
                entryID: entryID ?? base.0,
                normalizedGlosses: glosses ?? base.1,
                posCodes: pos ?? base.2,
                restrictedForms: forms ?? base.3,
                restrictedReadings: readings ?? base.4,
                tags: tags ?? base.5)
        }

        let reference = fp()
        XCTAssertEqual(reference.count, 64, "lower-hex sha256")
        XCTAssertEqual(reference, fp(), "同输入必须确定性同指纹")
        // gloss 规范化：大小写/首尾空白/全半角不区分（幂等防御）。
        XCTAssertEqual(reference, fp(glosses: ["  TO GO UP ", "To Rise"]))
        // 集合字段次序/重复不影响指纹。
        XCTAssertEqual(reference, fp(pos: ["vi", "v1", "vi"]))
        XCTAssertEqual(reference, fp(forms: ["上がる", "上がる"]))
        XCTAssertEqual(
            reference,
            fp(tags: [
                DictionarySenseTag(category: "misc", code: "uk"),
                DictionarySenseTag(category: "misc", code: "uk"),
            ]))

        // 每个语义字段变化都必须改变指纹——防止指纹退化成常数。
        XCTAssertNotEqual(reference, fp(entryID: 100002))
        XCTAssertNotEqual(reference, fp(glosses: ["to go up"]))
        XCTAssertNotEqual(reference, fp(glosses: ["to rise", "to go up"]),
                          "gloss 有序：换序即不同义项快照")
        XCTAssertNotEqual(reference, fp(pos: ["v1"]))
        XCTAssertNotEqual(reference, fp(forms: ["上る"]))
        XCTAssertNotEqual(reference, fp(readings: []))
        XCTAssertNotEqual(reference, fp(tags: []))
        XCTAssertNotEqual(
            reference,
            fp(tags: [DictionarySenseTag(category: "field", code: "uk")]))
    }

    // MARK: - 未变更义项：平凡路径仍成立

    func testUnchangedSenseRebindsToSameContent() throws {
        let v1 = try loadSnapshot("snapshot-v1")
        let v2 = try loadSnapshot("snapshot-v2")

        // 行 id 碰巧也没变（id 1）——关键是按内容而非行号命中。
        let unit = UUID()
        let alias = try bind(
            unitID: unit, entryID: 100001, senseID: 1, in: v1)
        let result = rebind(alias, to: v2)
        XCTAssertEqual(result.outcome, .rebound)
        XCTAssertEqual(result.alias.unitID, unit)
        XCTAssertEqual(result.alias.senseID, 1)
        XCTAssertEqual(result.alias.datasetVersion, "jmdict-spike-v2")
        XCTAssertEqual(result.alias.status, .current)
    }
}
