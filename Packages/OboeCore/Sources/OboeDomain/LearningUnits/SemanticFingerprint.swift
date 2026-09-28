import CryptoKit
import Foundation

/// v0.7.5 S02 工作包 A spike——义项语义指纹 + 词典快照 alias 值类型
///（decisions.md D01、技术文档 §3.1「身份分三层」）。
///
/// # 字段取舍（对齐 D01 冻结措辞）
///
/// 进入 canonical JSON 的字段：
/// - `entry_id`：JMdict `ent_seq`，词条级锚点（换库时 entryID 本身
///   消失/合并属于另一决策，本指纹不负责追踪）；
/// - `glosses_en`：sense 内按 gloss 顺序的英文 gloss 列表，经
///   `normalizeGloss`（NFKC + trim + lowercase）规范化——gloss **有序**
///   是语义输入（沿用 build_dictionary.py `sense_fingerprint` 的
///   有序 join 语义，首个 gloss 是主要释义）；
/// - `pos_codes`：sense_pos code 集合，去重排序；
/// - `restricted_forms` / `restricted_readings`：stagk/stagr 解析出的
///   表记/读音**文本**集合，去重排序（限定的是 surface 文本而非行 id，
///   行 id 本身跨快照不稳定）；
/// - `tags`：sense_tags 的 (category, code) 对，去重后按
///   (category, code) UTF-8 序排列——D01「有序语义属性 / 必要
///   disambiguation tags」。S02 实测：当前快照中 65 组同 entry、同
///   gloss+POS 的义项全靠 tags（field/xref/misc/s_inf）区分，tags
///   是消歧的承重字段，不可省略。
///
/// 明确排除（D01 冻结理由）：
/// - `senses.id` 本地行 id、`sense_order`：构建递增/位置量，跨快照不承诺
///   稳定（旧 `sense_fingerprint` 含 sense_order，不可沿用）；
/// - 中文 gloss：机器生成层，润色不改义项身份；
/// - lemma/reading/表记全集：展示与候选校验属性，不进主键；
/// - `dataset_version`：指纹描述义项内容，不绑定快照（alias 层才记版本）。
///
/// # Canonical JSON 约定（sense-fp-1）
///
/// `{"entry_id":<int>,"glosses_en":[..],"pos_codes":[..],
///  "restricted_forms":[..],"restricted_readings":[..],
///  "tags":[[cat,code],..],"v":"sense-fp-1"}`
///
/// - 对象键按 UTF-8 字节序排序；数组按上述字段语义决定次序；
/// - 无空白（`,`、`:` 紧邻）；非 ASCII 原文 UTF-8 输出；
/// - 字符串转义最小集：`\"` `\\` `\b` `\f` `\n` `\r` `\t`，其余
///   标量值 < 0x20 的字符转 `\u00XX`（小写 hex），>= 0x20 一律原文
///   ——与 Python `json.dumps(ensure_ascii=False, sort_keys=True,
///   separators=(",",":"))` 的字节流一致，构建侧可逐位复算；
/// - `"v"` 字段内嵌算法版本：版本升级必然改变指纹，两个版本的 hash
///   永不可能意外同值；落库时 `fingerprint_version` 列另存版本。
///
/// `normalizeGloss` 对齐 Python `unicodedata.normalize("NFKC", s).strip()
/// .casefold()`：`precomposedStringWithCompatibilityMapping` = NFKC；
/// `lowercased()` 与 `casefold()` 在 ß→ss 等个别映射上有已知差异
/// （英文 gloss 域内影响可忽略，若未来做构建端指纹复算需在 Python
/// 侧同样改用 `lower()` 或在此处显式 casefold 映射表——记入 spike 报告）。
///
/// # 重绑纪律（spike 范围约定，S03 契约冻结前可修订）
///
/// 指纹是重绑**证据**：换快照后按 fingerprint 在 entry 内找候选——
/// 唯一候选→alias 更新到新行、unit UUID 不变；多候选（同 entry 无法
/// 区分的重复 fingerprint）→ `needsConfirmation` + 隔离 key，禁止
/// 自动合并；零候选→ `stale`，保留旧引用不静默换绑。
///
/// 纯值类型：不依赖 GRDB/网络；`LearningUnitDictionaryAlias` 镜像
/// 技术文档 §4 `learning_unit_dictionary_aliases` 列
/// （unit_id, provider, dataset_version, entry_id, sense_id,
/// fingerprint, status），resolved_at_ms 等时间列留待 S03/S04。
public enum SemanticFingerprint {
    /// 指纹算法版本——嵌入 canonical payload 的 `"v"` 字段。
    /// 字段集、规范化或序列化约定任何一处变更都必须 bump 版本，
    /// 新旧指纹不可混用比较。
    public static let semanticFingerprintVersion = "sense-fp-1"

    /// 计算义项语义指纹（lower-hex SHA-256，64 字符）。
    ///
    /// - Parameter normalizedGlosses: sense 内**按顺序**的英文 gloss。
    ///   期望调用方已用 `normalizeGloss` 规范化；实现内部幂等地再规范化
    ///   一次作防御（NFKC+trim+lowercase 幂等，重复应用不改变结果）。
    /// - Parameter posCodes: 原始 POS code（`v1`/`v5u`/`n`…），内部去重排序。
    /// - Parameter restrictedForms/restrictedReadings: stagk/stagr 解析出的
    ///   表记/读音**文本**，内部去重排序；空集 = 未限定。
    /// - Parameter tags: sense_tags 行（category+code），内部去重排序。
    public static func compute(
        entryID: Int64,
        normalizedGlosses: [String],
        posCodes: [String],
        restrictedForms: [String],
        restrictedReadings: [String],
        tags: [DictionarySenseTag]
    ) -> String {
        let payload: CanonicalJSONValue = .object([
            ("entry_id", .integer(entryID)),
            ("glosses_en", .array(
                normalizedGlosses.map { .string(normalizeGloss($0)) })),
            ("pos_codes", .array(
                canonicalSortedSet(posCodes).map { .string($0) })),
            ("restricted_forms", .array(
                canonicalSortedSet(restrictedForms).map { .string($0) })),
            ("restricted_readings", .array(
                canonicalSortedSet(restrictedReadings).map { .string($0) })),
            ("tags", .array(
                canonicalSortedTags(tags).map {
                    .array([.string($0.category), .string($0.code)])
                })),
            ("v", .string(semanticFingerprintVersion)),
        ])
        var canonical = ""
        payload.serialize(into: &canonical)
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// `DictionarySense` 便捷入口：取英文 gloss（按 gloss_order）+
    /// pos/tags/限定，等价于逐参数 `compute`。
    public static func compute(entryID: Int64, sense: DictionarySense) -> String {
        compute(
            entryID: entryID,
            normalizedGlosses: sense.glosses(language: DictionaryGlossLanguage.english)
                .map(\.text),
            posCodes: sense.posCodes,
            restrictedForms: sense.restrictedForms,
            restrictedReadings: sense.restrictedReadings,
            tags: sense.tags
        )
    }

    /// 英文 gloss 规范化（对齐 Python `NFKC + strip + casefold`）。
    /// 详见文件头「已知差异」说明。幂等。
    public static func normalizeGloss(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - 内部规范化

    /// 集合语义字段：去重 + UTF-8 字节序排序（确定性 canonical 次序）。
    private static func canonicalSortedSet(_ values: [String]) -> [String] {
        Array(Set(values)).sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
    }

    /// tags 集合语义：按 (category, code) 去重，UTF-8 序排序。
    private static func canonicalSortedTags(
        _ tags: [DictionarySenseTag]
    ) -> [DictionarySenseTag] {
        var seen = Set<String>()
        var unique: [DictionarySenseTag] = []
        for tag in tags where seen.insert("\(tag.category)\u{0}\(tag.code)").inserted {
            unique.append(tag)
        }
        return unique.sorted {
            if $0.category == $1.category {
                return $0.code.utf8.lexicographicallyPrecedes($1.code.utf8)
            }
            return $0.category.utf8.lexicographicallyPrecedes($1.category.utf8)
        }
    }
}

// MARK: - canonical JSON 写出（sense-fp-1 序列化层）

/// 固定形态的 canonical JSON 值。序列化规则见 `SemanticFingerprint`
/// 文件头：键按 UTF-8 字节序排序、无空白、非 ASCII 原文、最小转义集。
/// 自包含实现（不依赖 JSONEncoder），保证指纹算法跨平台/跨版本
/// 字节稳定，且与 Python `json.dumps(ensure_ascii=False, sort_keys=True,
/// separators=(",",":"))` 输出逐位一致。
private indirect enum CanonicalJSONValue {
    case string(String)
    case integer(Int64)
    case array([CanonicalJSONValue])
    case object([(String, CanonicalJSONValue)])

    func serialize(into out: inout String) {
        switch self {
        case .string(let value):
            Self.serializeString(value, into: &out)
        case .integer(let value):
            out.append(String(value))
        case .array(let items):
            out.append("[")
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(",") }
                item.serialize(into: &out)
            }
            out.append("]")
        case .object(let pairs):
            let sorted = pairs.sorted {
                $0.0.utf8.lexicographicallyPrecedes($1.0.utf8)
            }
            out.append("{")
            for (index, pair) in sorted.enumerated() {
                if index > 0 { out.append(",") }
                Self.serializeString(pair.0, into: &out)
                out.append(":")
                pair.1.serialize(into: &out)
            }
            out.append("}")
        }
    }

    /// 字符串转义 = Python json `ensure_ascii=False` 语义：
    /// 必要短转义 + 标量值 < 0x20 一律 `\u00XX` 小写 hex，其余原文。
    private static func serializeString(_ value: String, into out: inout String) {
        out.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x08: out.append("\\b")
            case 0x0C: out.append("\\f")
            case 0x0A: out.append("\\n")
            case 0x0D: out.append("\\r")
            case 0x09: out.append("\\t")
            case 0x00...0x1F:
                out.append(String(format: "\\u%04x", scalar.value))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
    }
}

// MARK: - 词典快照 alias（§4 learning_unit_dictionary_aliases 值投影）

/// unit → 某词典快照具体义项行的绑定证据。
///
/// `(provider, dataset_version, entry_id, sense_id)` 唯一确定一行；
/// `fingerprint` 是绑定时刻的语义快照——换库重绑以它找候选。
/// 仅值语义，不含 resolved_at 等时间列（S03/S04 落库契约再定）。
public struct LearningUnitDictionaryAlias: Codable, Equatable, Sendable {
    /// `lexical_learning_units.id`——永久身份，重绑不改变。
    public let unitID: UUID
    /// 词典来源（`jmdict`…）。
    public let provider: String
    /// 绑定时所在快照 `dataset_version`。
    public let datasetVersion: String
    /// JMdict `ent_seq`。
    public let entryID: Int64
    /// 该快照内 `senses.id`——跨快照不直接可比。
    public let senseID: Int64
    /// `SemanticFingerprint.compute` 输出（绑定时刻值）。
    public let fingerprint: String
    /// 绑定状态（spike 三态，S03 契约再冻结）。
    public let status: Status

    public enum Status: String, Codable, Sendable {
        /// 当前快照内唯一指纹候选，绑定有效。
        case current
        /// 同 entry 出现不可区分的重复指纹——保留旧行引用 + 隔离 key，
        /// 待用户确认，禁止自动合并。
        case needsConfirmation
        /// 新快照内无指纹候选——保留旧行引用待查/重试，不静默换绑。
        case stale
        /// 已被重绑到新快照行替代的历史 alias——保留审计（S03 契约 rev2）。
        case superseded
    }

    public init(
        unitID: UUID,
        provider: String,
        datasetVersion: String,
        entryID: Int64,
        senseID: Int64,
        fingerprint: String,
        status: Status
    ) {
        self.unitID = unitID
        self.provider = provider
        self.datasetVersion = datasetVersion
        self.entryID = entryID
        self.senseID = senseID
        self.fingerprint = fingerprint
        self.status = status
    }

    /// §3.1 identity key 约定（spike 版）：
    /// 唯一指纹 → 共享 key `provider:sense-v1:<entryID>:<fingerprint>`
    /// （同快照内无法区分的候选会拿到同一个共享 key，因此必须先判
    /// 唯一再生成）；重复指纹/失配 → 隔离 key
    /// `provider:sense-v1-isolated:<datasetVersion>:<entryID>:<senseID>`，
    /// 防止 UNIQUE 冲突把两个候选项合并。
    public var identityKey: String {
        switch status {
        case .current:
            return "\(provider):sense-v1:\(entryID):\(fingerprint)"
        case .needsConfirmation, .stale, .superseded:
            // superseded 是已被重绑替代的历史行——共享 key 属于替代者，
            // 历史行只能落到隔离 key，绝不反向认领。
            return "\(provider):sense-v1-isolated:"
                + "\(datasetVersion):\(entryID):\(senseID)"
        }
    }
}
