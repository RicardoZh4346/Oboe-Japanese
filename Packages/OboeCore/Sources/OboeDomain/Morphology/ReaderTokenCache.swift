import Foundation

/// token 缓存持久化边界（v0.7.0 S07；技术文档 §6.1 缓存键）。
///
/// `reader_token_cache` 表由 **v17 迁移**落地（owner：agent A / 主 agent）；
/// 本文件冻结其上的协议形状与行编码，供 Morphology pipeline 与测试使用。
/// GRDB 实现待 v17 表存在后在 OboeInfrastructure 注册——不要在此臆造表结构。
///
/// 行模型（对齐 `TokenCacheKey`）：每块每 token 一行
/// `(block_hash, parser_version, morphology_version,
///   dictionary_dataset_version, os_build, token_ordinal, payload_json)`。
/// 命中要求全部五个键字段相等；任一版本字段变化 → 旧行失效
/// （`evictStaleVersions` 全局清理或 `load` 时按键失配跳过）。
public protocol ReaderTokenCacheStore: Sendable {
    /// 全键相等才命中；返回块内按序的 token 序列。未命中/部分失配 → nil。
    func load(key: TokenCacheKey) async throws -> [ReaderToken]?

    /// 覆写同一键下的全部 token 行（`store` 语义为整块替换）。
    func store(_ tokens: [ReaderToken], for key: TokenCacheKey) async throws

    /// 原文变更失效：删除该 `blockHash` 的全部版本行。
    func evict(blockHash: String) async throws

    /// 版本面失效（跨块全局）：删除「`blockHash` 之外任一字段与
    /// `probe` 不一致」的行。词典更新 / 规则 bump / OS 升级后调用。
    func evictStaleVersions(probe: TokenCacheKey) async throws

    /// 清空全部缓存（诊断/调试入口）。
    func removeAll() async throws
}

/// `ReaderToken` 的持久化行编码（Codable）。
/// `ReaderToken` 本身不是 Codable（冻结契约只承诺 Equatable/Sendable），
/// GRDB 落表时 payload 用本结构的 JSON 序列化。
public struct CachedReaderToken: Codable, Equatable, Sendable {
    public struct Candidate: Codable, Equatable, Sendable {
        public var lemma: String
        public var normalizedForm: String
        public var reading: String?
        public var posCodes: [String]
        public var entryID: Int64?
        public var reasons: [String]
        public var cost: Int
    }

    public var surface: String
    public var sourceStartUTF16: Int
    public var sourceLengthUTF16: Int
    public var mergedStartUTF16: Int
    public var mergedLengthUTF16: Int
    public var systemTokenIndexStart: Int
    public var systemTokenIndexLength: Int
    public var tokenClass: String
    public var reading: String?
    public var lexicalKeyProvider: String?
    public var lexicalKeyExternalID: String?
    public var lexicalKeyIdentityKey: String?
    public var resolutionStatus: String
    public var candidates: [Candidate]
    public var provenance: [String]

    public init(token: ReaderToken) {
        surface = token.surface
        sourceStartUTF16 = token.sourceRangeUTF16.lowerBound
        sourceLengthUTF16 = token.sourceRangeUTF16.count
        mergedStartUTF16 = token.mergedSpanUTF16.lowerBound
        mergedLengthUTF16 = token.mergedSpanUTF16.count
        systemTokenIndexStart = token.systemTokenIndexes.lowerBound
        systemTokenIndexLength = token.systemTokenIndexes.count
        tokenClass = token.tokenClass.rawValue
        reading = token.reading
        lexicalKeyProvider = token.lexicalKey?.provider.rawValue
        lexicalKeyExternalID = token.lexicalKey?.externalID
        lexicalKeyIdentityKey = token.lexicalKey?.identityKey
        resolutionStatus = token.resolutionStatus.rawValue
        candidates = token.candidates.map { candidate in
            Candidate(
                lemma: candidate.lemma,
                normalizedForm: candidate.normalizedForm,
                reading: candidate.reading,
                posCodes: candidate.posCodes,
                entryID: candidate.entryID,
                reasons: candidate.reasons,
                cost: candidate.cost
            )
        }
        provenance = token.provenance
    }

    public func materialize() -> ReaderToken {
        let lexicalKey: LexicalKey? = {
            guard let providerRaw = lexicalKeyProvider,
                  let provider = LexicalKey.Provider(rawValue: providerRaw),
                  let externalID = lexicalKeyExternalID,
                  let identityKey = lexicalKeyIdentityKey
            else { return nil }
            return LexicalKey(
                provider: provider, externalID: externalID, identityKey: identityKey
            )
        }()
        return ReaderToken(
            surface: surface,
            sourceRangeUTF16: sourceStartUTF16..<(sourceStartUTF16 + sourceLengthUTF16),
            mergedSpanUTF16: mergedStartUTF16..<(mergedStartUTF16 + mergedLengthUTF16),
            systemTokenIndexes: systemTokenIndexStart..<(systemTokenIndexStart + systemTokenIndexLength),
            candidates: candidates.map { candidate in
                MorphologyCandidate(
                    lemma: candidate.lemma,
                    normalizedForm: candidate.normalizedForm,
                    reading: candidate.reading,
                    posCodes: candidate.posCodes,
                    entryID: candidate.entryID,
                    reasons: candidate.reasons,
                    cost: candidate.cost
                )
            },
            tokenClass: ReaderTokenClass(rawValue: tokenClass) ?? .lexical,
            reading: reading,
            lexicalKey: lexicalKey,
            resolutionStatus: TokenResolutionStatus(rawValue: resolutionStatus) ?? .unresolved,
            provenance: provenance
        )
    }
}

/// payload JSON 编解码（GRDB 行 `payload_json` 列的内容）。
public enum ReaderTokenCacheCodec {
    /// 编码版本：与 morphologyVersion 无关——payload 布局变化时 bump，
    /// 解码端未知版本一律按 miss 处理。
    public static let payloadFormatVersion = 1

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func encode(_ tokens: [ReaderToken]) throws -> Data {
        let rows = tokens.map(CachedReaderToken.init(token:))
        return try makeEncoder().encode(rows)
    }

    /// 解码失败/版本不符 → nil（调用方按 miss 重新 tokenize）。
    public static func decode(_ data: Data) -> [ReaderToken]? {
        guard let rows = try? JSONDecoder().decode([CachedReaderToken].self, from: data)
        else { return nil }
        return rows.map { $0.materialize() }
    }
}

/// 进程内内存实现：契约语义参考实现 + 单元测试 double。
/// v17 表落地前的唯一可用实现；GRDB 版在 OboeInfrastructure 增补。
public actor InMemoryReaderTokenCacheStore: ReaderTokenCacheStore {
    private var storage: [TokenCacheKey: [ReaderToken]] = [:]

    public init() {}

    public func load(key: TokenCacheKey) -> [ReaderToken]? {
        storage[key]
    }

    public func store(_ tokens: [ReaderToken], for key: TokenCacheKey) {
        storage[key] = tokens
    }

    public func evict(blockHash: String) {
        storage = storage.filter { $0.key.blockHash != blockHash }
    }

    public func evictStaleVersions(probe: TokenCacheKey) {
        storage = storage.filter { entry in
            let key = entry.key
            return key.parserVersion == probe.parserVersion
                && key.morphologyVersion == probe.morphologyVersion
                && key.dictionaryDatasetVersion == probe.dictionaryDatasetVersion
                && key.osBuild == probe.osBuild
        }
    }

    public func removeAll() {
        storage.removeAll()
    }
}
