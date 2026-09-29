import Foundation
import GRDB
import OboeDomain

/// v0.7.5 S17：译文锚点重挂——relink 单事务提交内的
/// `updateLocators` 迁移计划计算（「hash/locator 重挂」落点）。
///
/// # 触发面
///
/// `GRDBReaderRepository.commitRelink` 在块行替换 + 文档行覆写
/// 之后调用 `moves(...)`——译文行的 `locator_key`/`locator_json`
/// 随之迁移，`source_hash`/`is_current`/修订链不动（store 语义）。
///
/// # 匹配规则（缺原文恢复 / 同段重复文字 / 序数漂移）
///
/// - 每个 locator_key 组取**代表行**（current 优先、再按
///   `created_at` 最新——同 key 多语言/多 sourceHash 链的锚点
///   语义一致，移动是 key 粒度的整组迁移）。
/// - **一轮（序数直中）**：锚点 `(chapterOrdinal, blockOrdinal)`
///   在新块集仍有行且 `text_hash == 代表行.sourceHash` → 锚点
///   不变/仅规范化 key（旧 `doc:` 形态行也借此迁到 `tr:`）。
/// - **二轮（保序 zip）**：序数漂移（换 parser 版本等）时，同
///   `sourceHash` 的未决 key 组按旧序数排序、未占同 hash 新块
///   按新序数排序，依次配对——**同段重复文字**的两条译文各自
///   落到顺序对应的新块（相对顺序保守匹配；文本逐字节相同，
///   配错对也无渲染副作用）。
/// - **不落位**：无候选/区间越界的组原样保留——历史行不丢，
///   只是渲染侧核不到活动块（不渲染）。
/// - **冲突保护**：目标 key 已被静态组占用、或两组算到同一
///   新 key → 后者跳过迁移（部分唯一 current 不允许歧义合并；
///   store 层 `revisionConflict` 是最后防线，计划侧先规避）。
public enum ReaderTranslationReanchor {

    /// 提交事务内调用：返回 `GRDBReaderTranslationStore.updateLocators`
    /// 的 `moves` 参数。空 = 全部锚点仍有效（序数+hash 未动）。
    public static func moves(
        documentID: UUID,
        chapters: [ReaderChapterMetadata],
        blocks: [ReaderBlock],
        in db: Database
    ) throws -> [(
        oldLocatorKey: String,
        newLocatorKey: String,
        newLocatorJSON: String
    )] {
        let documentKey = DatabaseValueCodec.encode(documentID)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT locator_key, locator_json, source_hash,
                       is_current, created_at_ms
                FROM reader_translation_blocks
                WHERE document_id = ?
                ORDER BY locator_key, is_current DESC, created_at_ms DESC
                """,
            arguments: [documentKey])
        guard !rows.isEmpty else { return [] }

        // 新块索引：(chapterOrdinal, blockOrdinal) → block；
        // 以及 textHash → [blocks]（按 (co,bo) 序，二轮 zip 用）。
        let chapterOrdinalByID = Dictionary(
            uniqueKeysWithValues: chapters.map { ($0.id, $0.ordinal) })
        var blockByOrdinals: [Int: [Int: ReaderBlock]] = [:]
        var blocksByHash: [String: [(co: Int, bo: Int, block: ReaderBlock)]] =
            [:]
        for block in blocks {
            guard let co = chapterOrdinalByID[block.chapterID] else {
                continue
            }
            blockByOrdinals[co, default: [:]][block.ordinal] = block
            blocksByHash[block.textHash, default: []].append(
                (co, block.ordinal, block))
        }
        for hash in blocksByHash.keys {
            blocksByHash[hash]?.sort {
                ($0.co, $0.bo) < ($1.co, $1.bo)
            }
        }

        // 分组：locator_key → 代表行（排序后首行——current 优先、
        // 同态按 created_at 最新）。
        struct Group {
            let key: String
            var anchor: ReaderTranslationLocator.Anchor?
            var repSourceHash: String
            var repLocatorJSON: String
        }
        var groups: [String: Group] = [:]
        var groupOrder: [String] = []
        for row in rows {
            let key: String = row["locator_key"]
            if groups[key] == nil {
                let locatorJSON: String = row["locator_json"]
                groups[key] = Group(
                    key: key,
                    anchor: ReaderTranslationLocator.anchor(
                        locatorKey: key, locatorJSON: locatorJSON),
                    repSourceHash: row["source_hash"],
                    repLocatorJSON: locatorJSON)
                groupOrder.append(key)
            }
        }

        var claimedTargets: Set<String> = []
        var moves: [(
            oldLocatorKey: String, newLocatorKey: String,
            newLocatorJSON: String)] = []
        var unresolved: [(key: String, group: Group)] = []
        var usedBlockKeys: Set<String> = []

        func blockSlotKey(_ co: Int, _ bo: Int) -> String { "\(co):\(bo)" }

        func planMove(
            _ group: Group, to block: ReaderBlock, co: Int, bo: Int
        ) {
            guard let anchor = group.anchor else { return }
            guard anchor.range.lowerBound >= 0,
                  anchor.range.upperBound
                    <= block.text.utf16.count else { return }
            guard let newJSON = try? ReaderTranslationLocator
                .locatorJSON(
                    sourceText: block.text,
                    blockTextHash: block.textHash,
                    chapterOrdinal: co,
                    blockOrdinal: bo,
                    targetRange: anchor.range)
            else { return }
            let newKey = ReaderTranslationLocator.key(
                chapterOrdinal: co, blockOrdinal: bo,
                utf16Range: anchor.range)
            if newKey == group.key && newJSON == group.repLocatorJSON {
                return   // 锚点已规范——零迁移。
            }
            // 目标 key 冲突（另一组已占/已计划）→ 跳过，不合并。
            guard newKey != group.key else {
                // key 不变仅刷 locatorJSON —— 允许（同组刷新）。
                moves.append((group.key, newKey, newJSON))
                return
            }
            guard !claimedTargets.contains(newKey),
                  groups[newKey] == nil || moves.contains(where: {
                      $0.oldLocatorKey == newKey && $0.newLocatorKey != newKey
                  })
            else { return }
            claimedTargets.insert(newKey)
            moves.append((group.key, newKey, newJSON))
        }

        // 一轮：序数直中。
        for key in groupOrder {
            guard let group = groups[key], let anchor = group.anchor
            else { continue }
            if let block = blockByOrdinals[anchor.chapterOrdinal]?[
                anchor.blockOrdinal],
               block.textHash == group.repSourceHash {
                usedBlockKeys.insert(blockSlotKey(
                    anchor.chapterOrdinal, anchor.blockOrdinal))
                planMove(
                    group, to: block,
                    co: anchor.chapterOrdinal, bo: anchor.blockOrdinal)
            } else {
                unresolved.append((key, group))
            }
        }

        // 二轮：同 hash 未决组（旧序数序）↔ 同 hash 未占新块
        // （新序数序）保序配对——重复文字各归各位。
        var candidatePool = blocksByHash
        for (_, group) in unresolved.sorted(by: {
            let lhs = $0.group.anchor
            let rhs = $1.group.anchor
            return (lhs?.chapterOrdinal ?? 0, lhs?.blockOrdinal ?? 0,
                    $0.key) < (rhs?.chapterOrdinal ?? 0,
                               rhs?.blockOrdinal ?? 0, $1.key)
        }) {
            var candidates = candidatePool[group.repSourceHash] ?? []
            candidates.removeAll {
                usedBlockKeys.contains(blockSlotKey($0.co, $0.bo))
            }
            guard let target = candidates.first else { continue }
            candidatePool[group.repSourceHash]?.removeAll {
                $0.block.id == target.block.id
            }
            usedBlockKeys.insert(blockSlotKey(target.co, target.bo))
            planMove(group, to: target.block, co: target.co, bo: target.bo)
        }
        return moves
    }
}
