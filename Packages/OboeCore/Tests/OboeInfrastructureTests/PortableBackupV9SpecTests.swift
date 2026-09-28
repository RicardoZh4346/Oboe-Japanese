import Foundation
import XCTest
@testable import OboeInfrastructure

/// 记录协议 v9 的规格层断言（backup-v9-wire.md rev1 §2.1/§2.2/§2.3/§3）。
///
/// 本套测试只覆盖 S19 前置「可测部分」：记录清单、列白名单、记录顺序、
/// excludedScopes、registry 目标规格的映射形状。**不做** round-trip——
/// v23–v26 表尚未落地（由并行任务实现），本文件不触碰任何新表，
/// 也不需要数据库 fixture。
final class PortableBackupV9SpecTests: XCTestCase {

    // MARK: - wire §2.1 硬编码期望（防漂移：规格列必须逐字一致）

    /// (recordType, 源表 tableName, 导出列白名单) —— 直接抄录 wire §2.1
    /// 清单顺序；`readerLearningCoverageSnapshot` wire 未逐项枚举，按
    /// 详细技术实现 §4 冻结草案的 18 列全量展开。
    private static let expectedNewRecords: [(
        recordType: String, tableName: String, columns: [String]
    )] = [
        ("learningUnit", "lexical_learning_units", [
            "id", "identity_kind", "identity_key", "provider",
            "dictionary_entry_id", "semantic_fingerprint",
            "fingerprint_version", "lemma", "reading",
            "sense_snapshot_json", "binding_status", "revision",
            "created_at_ms", "updated_at_ms"
        ]),
        ("learningUnitAlias", "learning_unit_dictionary_aliases", [
            "unit_id", "provider", "dataset_version", "entry_id",
            "sense_id", "fingerprint", "fingerprint_version",
            "status", "resolved_at_ms"
        ]),
        ("learningUnitNoteLink", "learning_unit_note_links", [
            "unit_id", "note_id", "role", "origin", "created_at_ms"
        ]),
        ("learningUnitFlag", "learning_unit_flags", [
            "unit_id", "too_easy", "revision", "updated_at_ms"
        ]),
        ("learningUnitEvent", "learning_unit_events", [
            "id", "operation_id", "unit_id", "unit_id_snapshot", "kind",
            "before_json", "after_json", "payload_hash", "created_at_ms",
            "undone_at_ms"
        ]),
        ("learningUnitMigrationItem", "learning_unit_migration_items", [
            "source_key", "note_id", "legacy_lexeme_id", "old_state",
            "status", "evidence_json", "target_unit_id", "last_error"
        ]),
        ("readerStudyOccurrence", "reader_study_occurrences", [
            "id", "document_id", "content_revision", "locator_json",
            "block_source_hash", "tokenizer_version", "start_utf16",
            "length_utf16", "unit_id", "resolution_status", "resolution_id"
        ]),
        ("readerTranslationBlock", "reader_translation_blocks", [
            "id", "document_id", "locator_key", "locator_json",
            "source_hash", "translation_revision", "translated_text",
            "language", "provider", "model", "prompt_version",
            "request_hash", "created_at_ms", "is_current"
        ]),
        ("aiStudyJob", "ai_study_jobs", [
            "id", "document_id", "study_deck_id", "scope_json",
            "input_fingerprint", "content_revision",
            "provider_snapshot_json", "model", "pipeline_version",
            "prompt_version", "policy_version", "status", "epoch",
            "selection_revision", "resume_reason",
            "created_at_ms", "updated_at_ms"
        ]),
        ("aiStudyJobBlock", "ai_study_job_blocks", [
            "id", "job_id", "locator_json", "source_hash", "subblock_key",
            "candidate_set_hash", "request_hash", "status", "attempt_count",
            "next_retry_at_ms", "result_id", "last_error_code"
        ]),
        ("aiStudyResolution", "ai_study_resolutions", [
            "id", "job_id", "job_block_id", "document_id", "locator_json",
            "token_key", "request_hash", "selected_entry_id",
            "selected_sense_id", "selected_dataset_version", "unit_id",
            "confidence", "status", "reason_code", "origin", "revision",
            "created_at_ms"
        ]),
        ("aiStudyReceipt", "ai_study_receipts", [
            "operation_id", "action_key", "payload_hash", "outcome_json",
            "committed_at_ms"
        ]),
        ("aiStudySelection", "ai_study_selections", [
            "job_id", "unit_key", "selection_revision", "decision",
            "proposed_action", "evidence_revision", "applied_receipt_id"
        ]),
        ("readerLearningCoverageSnapshot", "reader_learning_coverage_snapshots", [
            "id", "document_id", "document_id_snapshot", "scope_hash",
            "content_revision", "knowledge_revision", "metric_version",
            "dictionary_version", "morphology_version", "resolved_unique",
            "unknown_unique", "learning_unique", "mastered_unique",
            "pending_occurrences", "oov_occurrences", "analyzed_blocks",
            "total_blocks", "calculated_at_ms"
        ])
    ]

    private var positions: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: PortableBackupFormatV9.recordTypes
                .enumerated().map { ($0.element, $0.offset) }
        )
    }

    // MARK: - 记录清单与顺序（wire §3）

    /// v9 记录总数 = v8 36 类 + wire §2.1 新增 14 类；扩列不新增类型。
    func testRecordTypeCountIsV8Plus14() {
        XCTAssertEqual(PortableBackupFormatV8.recordTypes.count, 36)
        XCTAssertEqual(PortableBackupFormatV9.recordTypes.count, 50)
    }

    /// wire §3：v8 全部记录类型的相对顺序在 v9 中一字不动。
    /// 过滤出 v8 既有类型后必须与 v8 顺序完全相等。
    func testV8RelativeOrderIsPreserved() {
        let v8Types = Set(PortableBackupFormatV8.recordTypes)
        let v8TypesInV9Order = PortableBackupFormatV9.recordTypes.filter {
            v8Types.contains($0)
        }
        XCTAssertEqual(v8TypesInV9Order, PortableBackupFormatV8.recordTypes)
    }

    /// wire §3 插入锚点：learningUnit 组在 noteDeck 之后、lexeme 之前；
    /// Reader 派生 + aiStudy 组在 scheduledReviewOrigin 之后、
    /// readerActivityEvent 之前；readerLearningCoverageSnapshot 紧随
    /// readerCoverageSnapshot。父先子后：note→learningUnitNoteLink、
    /// learningUnit→各 unit 子记录、aiStudyJob→block/resolution/selection。
    func testNewRecordsSitAtWireAnchorsParentsFirst() throws {
        let position = positions
        let pairs: [(String, String)] = [
            // learningUnit 组锚点：noteDeck 之后、lexeme 之前。
            ("noteDeck", "learningUnit"),
            ("learningUnitMigrationItem", "lexeme"),
            // unit 组内父先子后。
            ("learningUnit", "learningUnitAlias"),
            ("learningUnit", "learningUnitNoteLink"),
            ("learningUnit", "learningUnitFlag"),
            ("learningUnit", "learningUnitEvent"),
            ("learningUnit", "learningUnitMigrationItem"),
            ("learningUnitAlias", "learningUnitNoteLink"),
            ("learningUnitNoteLink", "learningUnitFlag"),
            ("learningUnitFlag", "learningUnitEvent"),
            ("learningUnitEvent", "learningUnitMigrationItem"),
            // link 引用 note 与 unit——两侧父记录都必须先落。
            ("note", "learningUnitNoteLink"),
            // Reader 派生锚点：scheduledReviewOrigin 之后、
            // readerActivityEvent 之前（aiStudy 组随后）。
            ("scheduledReviewOrigin", "readerStudyOccurrence"),
            ("readerStudyOccurrence", "readerTranslationBlock"),
            ("readerTranslationBlock", "aiStudyJob"),
            ("aiStudyReceipt", "readerActivityEvent"),
            // aiStudy 组内父先子后。
            ("aiStudyJob", "aiStudyJobBlock"),
            ("aiStudyJob", "aiStudyResolution"),
            ("aiStudyJob", "aiStudySelection"),
            ("aiStudyJob", "aiStudyReceipt"),
            ("aiStudyJobBlock", "aiStudyResolution"),
            ("aiStudyResolution", "aiStudySelection"),
            ("aiStudySelection", "aiStudyReceipt"),
            // v26 快照紧随 v8 旧快照。
            ("readerCoverageSnapshot", "readerLearningCoverageSnapshot"),
            ("readerLearningCoverageSnapshot", "importJob")
        ]
        for (parent, child) in pairs {
            let parentIndex = try XCTUnwrap(
                position[parent], "\(parent) 不在 v9 recordTypes 中"
            )
            let childIndex = try XCTUnwrap(
                position[child], "\(child) 不在 v9 recordTypes 中"
            )
            XCTAssertLessThan(
                parentIndex, childIndex,
                "\(parent) 必须排在 \(child) 之前"
            )
        }
        // settings 恒在末尾（沿用 v8 不变式）。
        XCTAssertEqual(
            position["settings"], PortableBackupFormatV9.recordTypes.count - 1
        )
    }

    /// 新类型集合与 wire §2.1 的 14 类逐字一致——不多不少。
    func testNewRecordTypeSetMatchesWire() {
        let expected = Set(Self.expectedNewRecords.map(\.recordType))
        XCTAssertEqual(expected.count, 14)
        let v8Types = Set(PortableBackupFormatV8.recordTypes)
        let added = PortableBackupFormatV9.recordTypes.filter {
            !v8Types.contains($0)
        }
        XCTAssertEqual(Set(added), expected)
    }

    // MARK: - 列白名单（wire §2.1/§2.2）

    /// 每个新规格的 tableName 与导出列必须与 wire §2.1 逐字一致；
    /// orderBy 列 ⊆ columns；lease_epoch/凭据类字段不得出现。
    func testNewSpecificationsMatchWireColumns() throws {
        for expected in Self.expectedNewRecords {
            let spec = try XCTUnwrap(
                PortableBackupFormatV9.specificationByRecordType[
                    expected.recordType
                ],
                "\(expected.recordType) 缺少规格"
            )
            XCTAssertEqual(
                spec.tableName, expected.tableName,
                "\(expected.recordType) tableName 不符"
            )
            XCTAssertFalse(spec.tableName.isEmpty)
            XCTAssertEqual(
                spec.columns, expected.columns,
                "\(expected.recordType) 导出列与 wire §2.1 不符"
            )
            assertOrderByIsSubset(of: spec.columns, spec: spec)
        }
        // wire §2.1 红线抽查：lease_epoch 是运行态租借字段，不导出。
        let jobBlock = PortableBackupFormatV9.aiStudyJobBlock
        XCTAssertFalse(jobBlock.columns.contains("lease_epoch"))
        XCTAssertFalse(jobBlock.columns.contains("lease"))
    }

    /// wire §2.2 扩列：readerDocument = v8 列 + study_deck_id /
    /// study_deck_name_follows_title；sourceContext = v8 列 +
    /// study_dedup_key。旧列做前缀，新增列按序追加。
    func testExtendedSpecificationsMatchWire() throws {
        let readerDocument = PortableBackupFormatV9.readerDocument
        XCTAssertEqual(readerDocument.tableName, "reader_documents")
        XCTAssertEqual(readerDocument.recordType, "readerDocument")
        XCTAssertEqual(
            readerDocument.columns,
            PortableBackupFormatV8.readerDocument.columns
                + ["study_deck_id", "study_deck_name_follows_title"]
        )
        XCTAssertEqual(
            PortableBackupFormatV9.readerDocumentColumnsAddedInV9,
            ["study_deck_id", "study_deck_name_follows_title"]
        )
        assertOrderByIsSubset(
            of: readerDocument.columns, spec: readerDocument
        )

        let sourceContext = PortableBackupFormatV9.sourceContext
        XCTAssertEqual(sourceContext.tableName, "source_contexts")
        XCTAssertEqual(sourceContext.recordType, "sourceContext")
        XCTAssertEqual(
            sourceContext.columns,
            PortableBackupFormatV8.sourceContext.columns + ["study_dedup_key"]
        )
        XCTAssertEqual(
            PortableBackupFormatV9.sourceContextColumnsAddedInV9,
            ["study_dedup_key"]
        )
        assertOrderByIsSubset(of: sourceContext.columns, spec: sourceContext)

        // tableSpecifications 里的实例必须就是扩列版（而非残留 v8 版）。
        let tableSpecsByType = Dictionary(
            uniqueKeysWithValues: PortableBackupFormatV9.tableSpecifications
                .map { ($0.recordType, $0) }
        )
        XCTAssertEqual(
            tableSpecsByType["readerDocument"]?.columns,
            readerDocument.columns
        )
        XCTAssertEqual(
            tableSpecsByType["sourceContext"]?.columns,
            sourceContext.columns
        )
    }

    /// 全部 v9 规格（含继承 v8 的）的 orderBy 列 ⊆ columns——恢复端
    /// 插序与导出端排共用同一白名单，越界即规格漂移。
    func testOrderByColumnsAreSubsetAcrossAllSpecs() {
        for spec in PortableBackupFormatV9.tableSpecifications {
            assertOrderByIsSubset(of: spec.columns, spec: spec)
        }
    }

    // MARK: - 排除范围（wire §2.3）

    /// additionalExcludedScopes 恰为 wire §2.3 新增两项，无重复；
    /// 与 v8 既有排除集合叠加后整链仍无重复、互不覆盖。
    func testAdditionalExcludedScopes() {
        let additional = PortableBackupFormatV9.additionalExcludedScopes
        XCTAssertEqual(additional, ["aiStudyRuntime", "providerSecrets"])
        XCTAssertEqual(Set(additional).count, additional.count)

        let chain = PortableBackupFormat.excludedScopes
            + PortableBackupFormatV8.additionalExcludedScopes
            + additional
        XCTAssertEqual(
            Set(chain).count, chain.count,
            "v9 排除范围与既有集合存在重复项"
        )
        for scope in ["aiStudyRuntime", "providerSecrets"] {
            XCTAssertTrue(chain.contains(scope))
        }
    }

    // MARK: - specificationByRecordType 映射形状

    /// recordType 无重复（否则 Dictionary(uniqueKeysWithValues:) 会截断
    /// 语义）、tableName 无重复（units 相关表不得与既有表撞名）、
    /// 映射完整覆盖 tableSpecifications。
    func testSpecificationByRecordTypeIsUniqueAndComplete() {
        let specs = PortableBackupFormatV9.tableSpecifications
        let recordTypes = specs.map(\.recordType)
        XCTAssertEqual(
            Set(recordTypes).count, recordTypes.count,
            "v9 recordType 存在重复"
        )
        let tableNames = specs.map(\.tableName)
        XCTAssertEqual(
            Set(tableNames).count, tableNames.count,
            "v9 tableName 存在重复"
        )
        XCTAssertEqual(
            PortableBackupFormatV9.specificationByRecordType.count,
            specs.count
        )
        for spec in specs {
            XCTAssertEqual(
                PortableBackupFormatV9.specificationByRecordType[
                    spec.recordType
                ]?.tableName,
                spec.tableName
            )
        }
        // 新表名不得与 v8 既有表名撞车（除扩列复用的两张表）。
        let v8TableNames = Set(
            PortableBackupFormatV8.tableSpecifications.map(\.tableName)
        )
        for expected in Self.expectedNewRecords {
            XCTAssertFalse(
                v8TableNames.contains(expected.tableName),
                "\(expected.tableName) 与既有表名冲突"
            )
        }
    }

    // MARK: - helpers

    private func assertOrderByIsSubset(
        of columns: [String],
        spec: PortableBackupTableSpecification,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let orderColumns = spec.orderBy
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(orderColumns.isEmpty, "\(spec.recordType) orderBy 为空")
        for column in orderColumns {
            XCTAssertTrue(
                spec.columns.contains(column),
                "\(spec.recordType) orderBy 列 \(column) 不在导出列中",
                file: file, line: line
            )
        }
    }
}
