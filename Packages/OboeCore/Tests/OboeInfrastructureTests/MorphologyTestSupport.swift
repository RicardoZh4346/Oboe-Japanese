import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// S07 测试共享工具：随包词典定位、最小词典 schema 构造、
/// tokenizer/能力 seam fake、SQL 计数。
enum MorphologyTestSupport {
    /// 随包词典 sqlite（仓库内路径；测试 bundle 不内嵌）。
    static var bundledDictionaryURL: URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OboeInfrastructureTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // OboeCore/
            .deletingLastPathComponent() // Packages/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(
                "OboeApp/Resources/Dictionary/japanese-dictionary.sqlite")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func makeService(
        tokenizer: any MorphologySystemTokenizer = NaturalLanguageMorphologyTokenizer(),
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> NLJapaneseMorphologyService {
        let url = try XCTUnwrap(
            bundledDictionaryURL, "bundled dictionary missing", file: file, line: line)
        return NLJapaneseMorphologyService(
            resolver: GRDBMorphologyCandidateResolver(databaseURL: url),
            tokenizer: tokenizer
        )
    }

    static func makeBlock(_ text: String) -> MorphologyBlock {
        MorphologyBlock(blockID: UUID(), text: text, textHash: "t-\(text.count)")
    }

    // MARK: - 内存最小词典（resolver 单元测试用）

    /// 建一张 schema 形状与随包词典一致的内存库（metadata/entries/
    /// forms/readings/senses/sense_pos），填充给定 entry。
    struct TestEntry {
        var id: Int64
        var forms: [String]         // 写形（normalize 后入库）
        var readings: [String]      // 读音（normalize 后入库）
        var pos: [String]           // sense_pos.code
        var rank: Int?
    }

    static func makeDictionary(
        entries: [TestEntry]
    ) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE dictionary_metadata(key TEXT PRIMARY KEY, value TEXT);
                INSERT INTO dictionary_metadata(key, value)
                    VALUES ('schema_version','1'),('dataset_version','test-v1');
                CREATE TABLE entries(
                    id INTEGER PRIMARY KEY,
                    primary_form TEXT NOT NULL,
                    common_rank INTEGER);
                CREATE TABLE forms(
                    id INTEGER PRIMARY KEY,
                    entry_id INTEGER NOT NULL REFERENCES entries(id),
                    text TEXT NOT NULL,
                    normalized_text TEXT NOT NULL);
                CREATE TABLE readings(
                    id INTEGER PRIMARY KEY,
                    entry_id INTEGER NOT NULL REFERENCES entries(id),
                    reading TEXT NOT NULL,
                    normalized_reading TEXT NOT NULL);
                CREATE TABLE senses(
                    id INTEGER PRIMARY KEY,
                    entry_id INTEGER NOT NULL REFERENCES entries(id));
                CREATE TABLE sense_pos(
                    id INTEGER PRIMARY KEY,
                    sense_id INTEGER NOT NULL REFERENCES senses(id),
                    code TEXT NOT NULL);
                """)
            for entry in entries {
                try db.execute(
                    sql: "INSERT INTO entries(id, primary_form, common_rank) VALUES (?,?,?)",
                    arguments: [entry.id, entry.forms.first ?? "", entry.rank])
                for form in entry.forms {
                    try db.execute(
                        sql: """
                            INSERT INTO forms(entry_id, text, normalized_text)
                            VALUES (?,?,?)
                            """,
                        arguments: [entry.id, form,
                                    SearchTextNormalizer.normalize(form)])
                }
                for reading in entry.readings {
                    try db.execute(
                        sql: """
                            INSERT INTO readings(entry_id, reading, normalized_reading)
                            VALUES (?,?,?)
                            """,
                        arguments: [entry.id, reading,
                                    SearchTextNormalizer.normalize(reading)])
                }
                try db.execute(
                    sql: "INSERT INTO senses(entry_id) VALUES (?)",
                    arguments: [entry.id])
                let senseID = db.lastInsertedRowID
                for code in entry.pos {
                    try db.execute(
                        sql: "INSERT INTO sense_pos(sense_id, code) VALUES (?,?)",
                        arguments: [senseID, code])
                }
            }
        }
        return queue
    }
}

/// 能力/tokenizer seam fake：固定 scheme 集 + 固定 token 边界序列。
struct FakeMorphologySystemTokenizer: MorphologySystemTokenizer {
    var schemes: [String]
    /// 预给 token 序列；nil → 用简单按字符切分（非假名→1 字 1 token 太碎，
    /// 需要边界可控时直接给 tokens）。
    var tokens: [MorphologySystemToken]?

    init(
        schemes: [String] = ["TokenType", "Script", "Language"],
        tokens: [MorphologySystemToken]? = nil
    ) {
        self.schemes = schemes
        self.tokens = tokens
    }

    func availableWordTagSchemes() -> [String] { schemes }

    func wordTokens(in text: String) -> [MorphologySystemToken] {
        if let tokens { return tokens }
        // 默认：整段一个 Word token（只用于能力/cancellation 测试）。
        guard !text.isEmpty else { return [] }
        return [MorphologySystemToken(
            tokenType: "Word", script: "Jpan",
            rangeUTF16: 0..<text.utf16.count, surface: text)]
    }
}

/// 简单 token 构造器。
func sysToken(_ surface: String, start: Int, type: String = "Word") -> MorphologySystemToken {
    MorphologySystemToken(
        tokenType: type, script: "Jpan",
        rangeUTF16: start..<(start + surface.utf16.count), surface: surface)
}

/// SQL 语句计数器（trace 包装）。
final class SQLTraceCounter: @unchecked Sendable {
    private(set) var statements: [String] = []
    private let lock = NSLock()
    func record(_ sql: String) {
        lock.lock()
        statements.append(sql)
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return statements.count
    }
    func count(matching needle: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return statements.filter { $0.contains(needle) }.count
    }
}
