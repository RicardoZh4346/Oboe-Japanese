import Foundation

/// 东京式日语音调核位置（T01 冻结口径）。
///
/// `rawValue` 是从词首数起的 mora 位置，`0` 表示平板型（无音调核）。
/// 不设人工上限——5、6 等合法值按真实值保存；SQLite 仅约束 `>= 0`，
/// 依赖 reading 的上限校验由 `isConsistent(withReading:)` 在领域层、
/// AI decoder 和 JLPT 构建脚本各执行一次。
public struct PitchAccent: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init?(rawValue: Int) {
        guard rawValue >= 0 else { return nil }
        self.rawValue = rawValue
    }

    /// pitch 与给定读音的 mora 数一致性：
    /// 非空 pitch 必须有非空读音；正值必须 `<= moraCount(reading)`；
    /// `0`（平板）只要求读音非空。
    public func isConsistent(withReading reading: String?) -> Bool {
        guard let reading, !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if rawValue == 0 { return true }
        return rawValue <= JapaneseMoraCounter.moraCount(of: reading)
    }
}
