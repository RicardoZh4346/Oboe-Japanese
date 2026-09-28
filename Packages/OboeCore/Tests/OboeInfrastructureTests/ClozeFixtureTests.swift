import Foundation
import OboeDomain
import XCTest

/// v0.7.0 S12：`Fixtures/cloze/s12_cloze_cases.json` 是 S23 备份/回放
/// 测试将复用的合成样本。本测试现在就把它跑起来——每条 valid 样本必须
/// 过 `ValidatedClozeContent` 全链校验且 hash/遮罩/答案归一化与声明一致，
/// 每条 invalid 样本必须抛出声明的 `ClozeError`。fixture 自身因此持续受测，
/// S23 拿到的是已验证数据而不是按约定手写的 JSON。
final class ClozeFixtureTests: XCTestCase {

    private struct FixtureFile: Decodable {
        let schemaVersion: Int
        let blank: String
        let validCases: [ValidCase]
        let invalidCases: [InvalidCase]
    }

    private struct ValidCase: Decodable {
        let id: String
        let sentence: String
        let sentenceSHA256: String
        let targetSurface: String
        let targetLemma: String?
        let targetReading: String?
        let rangeUtf16Start: Int
        let rangeUtf16Length: Int
        let acceptedAnswers: [String]
        let expectedNormalizedAnswers: [String]?
        let hint: String?
        let meaningZh: String?
        let expectedMasked: String
    }

    private struct InvalidCase: Decodable {
        let id: String
        let sentence: String
        let sentenceSHA256: String?
        let targetSurface: String
        let rangeVersion: Int?
        let rangeUtf16Start: Int
        let rangeUtf16Length: Int
        let acceptedAnswers: [String]
        let expectedError: String
    }

    private func loadFixture(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> FixtureFile {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "s12_cloze_cases",
                withExtension: "json",
                subdirectory: "Fixtures/cloze"
            ),
            "cloze fixture 未打进测试 bundle",
            file: file,
            line: line
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureFile.self, from: data)
    }

    /// valid 样本：创建路径与恢复路径（声明 hash 的重放）都必须接受，
    /// 且两端产出的内容等价。
    func testValidCasesPassCreationAndRestorePaths() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertFalse(fixture.validCases.isEmpty)

        for sample in fixture.validCases {
            let created = try ValidatedClozeContent(
                sentenceSnapshot: sample.sentence,
                utf16Start: sample.rangeUtf16Start,
                utf16Length: sample.rangeUtf16Length,
                targetSurface: sample.targetSurface,
                targetLemma: sample.targetLemma,
                targetReading: sample.targetReading,
                acceptedAnswers: sample.acceptedAnswers,
                hint: sample.hint
            )

            XCTAssertEqual(
                created.sentenceSHA256, sample.sentenceSHA256,
                "\(sample.id)：fixture 声明的 hash 与实算不符"
            )
            XCTAssertEqual(
                created.sentenceSHA256,
                ClozeValidator.snapshotSHA256(sample.sentence),
                "\(sample.id)"
            )
            XCTAssertEqual(created.targetSurface, sample.targetSurface, "\(sample.id)")
            XCTAssertEqual(
                created.acceptedAnswers,
                sample.expectedNormalizedAnswers ?? sample.acceptedAnswers,
                "\(sample.id)：答案归一化不符"
            )
            XCTAssertTrue(
                created.acceptedAnswers.contains(sample.targetSurface),
                "\(sample.id)：acceptedAnswers 必须含 surface"
            )

            // 遮罩只发生在 ranged span 上。surface 在句中仅出现一次时，
            // 正面字符串绝不含答案；重复出现属于合法语境（未被选中的那处
            // 保留原文），由 expectedMasked 逐字断言覆盖。
            let masked = ClozeValidator.maskedSentence(
                created.sentenceSnapshot,
                range: created.range,
                blank: fixture.blank
            )
            XCTAssertEqual(masked, sample.expectedMasked, "\(sample.id)")
            let surfaceOccurrences = sample.sentence.components(
                separatedBy: sample.targetSurface
            ).count - 1
            if surfaceOccurrences == 1 {
                XCTAssertFalse(
                    masked.contains(sample.targetSurface),
                    "\(sample.id)：正面泄露了答案"
                )
            }

            // 恢复路径：声明 hash 重放必须产出等价内容。
            let restored = try ValidatedClozeContent(
                restoringSentenceSnapshot: sample.sentence,
                sentenceSHA256: sample.sentenceSHA256,
                range: created.range,
                targetSurface: sample.targetSurface,
                targetLemma: sample.targetLemma,
                targetReading: sample.targetReading,
                acceptedAnswers: sample.acceptedAnswers,
                hint: sample.hint
            )
            XCTAssertEqual(restored, created, "\(sample.id)")
        }
    }

    /// invalid 样本：按声明的入口（persisted range 版本 → 恢复校验 →
    /// 创建校验）驱动，必须抛出与 `ClozeError` case 同名的错误。
    func testInvalidCasesThrowDeclaredError() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.invalidCases.isEmpty)

        for sample in fixture.invalidCases {
            do {
                let range = try ClozeRange(
                    persistedVersion: sample.rangeVersion ?? ClozeRange.currentVersion,
                    utf16Start: sample.rangeUtf16Start,
                    utf16Length: sample.rangeUtf16Length
                )
                // 统一走恢复路径——它覆盖 validate + surface 成员检查 +
                // hash 校验三类失败；未声明 hash 时用实算值。
                _ = try ValidatedClozeContent(
                    restoringSentenceSnapshot: sample.sentence,
                    sentenceSHA256: sample.sentenceSHA256
                        ?? ClozeValidator.snapshotSHA256(sample.sentence),
                    range: range,
                    targetSurface: sample.targetSurface,
                    targetLemma: nil,
                    targetReading: nil,
                    acceptedAnswers: sample.acceptedAnswers,
                    hint: nil
                )
                XCTFail("\(sample.id)：应抛出 \(sample.expectedError)")
            } catch let error as ClozeError {
                XCTAssertEqual(
                    error,
                    Self.clozeError(named: sample.expectedError),
                    "\(sample.id)：错误类型不符"
                )
            }
        }
    }

    /// fixture 里声明的错误名 → `ClozeError` 字面映射；刻意手写——
    /// 名字漂移时测试自身先报警而不是静默漏测。
    private static func clozeError(named name: String) -> ClozeError {
        switch name {
        case "invalidRange": return .invalidRange
        case "rangeSurfaceMismatch": return .rangeSurfaceMismatch
        case "emptySentence": return .emptySentence
        case "emptyAcceptedAnswers": return .emptyAcceptedAnswers
        case "inconsistentCardLink": return .inconsistentCardLink
        case "staleContentVersion": return .staleContentVersion
        case "acceptedAnswersMissingSurface": return .acceptedAnswersMissingSurface
        case "snapshotHashMismatch": return .snapshotHashMismatch
        case "unsupportedRangeVersion": return .unsupportedRangeVersion
        default:
            XCTFail("未知 expectedError：\(name)")
            return .invalidRange
        }
    }
}
