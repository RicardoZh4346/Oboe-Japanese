import Foundation

/// v0.7.5 S09：AI Resolver 响应分层校验器。
/// 依据：contracts-frozen rev2 §3.2（分层校验规则原样冻结）、§3.3
/// （BlockOutcome/Resolution）、技术文档 §7 校验规则表、S02-B §8
/// （候选集成员校验 + OOV no-candidate 路径）。
///
/// # 分层（§7 表逐行实现）
///
/// | 层 | 实现 |
/// |---|---|
/// | 外层 JSON | 大小 → 解析 → 深度 → 顶层对象 → schemaVersion →
/// |           | requestID → translation 类型 → words 数组与数量； |
/// |           | 任何外层失败 → `lexicalStatus == .failed` 整包拒， |
/// |           | 不用 `[Word].decode` 让单项错误带崩整段。 |
/// | 单项 | 逐元素 tolerant decode：tokenID 必须属于本请求；entry/sense |
/// |      | 必须属于**该 token**候选集（跨 token 偷换 = 非法）；sense |
/// |      | 表记/读音限制按候选内 matched 证据复核；confidence 必须 |
/// |      | finite ∈[0,1]。 |
/// | 重复项 | 同 tokenID 多次 → 该 token 整体降级 unresolved，其他保留。 |
/// | 缺项/未知 | 缺失目标 → unresolved；未知 tokenID 不创建对象只计数。 |
/// | 低置信 | <阈值（含 resolved 缺 confidence）→ lowConfidence 进确认。|
/// | 译文 | trim 非空 + 长度有界；失败仅 translationStatus=.failed， |
/// |      | 词义结果保留。 |
/// | malformed | 解析失败/截断 → 整包 failed，不猜半截 JSON。 |
///
/// 非法候选不形成 `selected`（§3.3：不产生任何有效选定）；token 行
/// 保留归因（rejected/unresolved + reasonCode）供持久层与统计使用。
public enum AIStudyResponseValidator {

    /// 唯一入口：原始响应字节 + 本请求 → 块级校验结果。
    /// 当前契约每请求一块（planner 保证）；多块请求按外层违规拒。
    public static func validate(
        responseData: Data,
        request: AIStudyRequest
    ) -> ValidatedBlockOutcome {
        guard request.blocks.count == 1, let block = request.blocks.first else {
            return envelopeFailure(
                .unsupportedBlockCount,
                blockKey: request.blocks.first?.blockKey ?? "",
                wantsTranslation: request.blocks.first?.wantsTranslation ?? false)
        }

        // ---- 外层：大小 → 解析 → 深度 → 结构/元信息 --------------------
        guard responseData.count <= AIStudyBudget.maxResponseBytes else {
            return envelopeFailure(.responseTooLarge, block: block)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: responseData)
        else {
            return envelopeFailure(.malformedJSON, block: block)
        }
        guard jsonDepth(raw) <= AIStudyBudget.maxJSONDepth else {
            return envelopeFailure(.depthExceeded, block: block)
        }
        guard let object = raw as? [String: Any] else {
            return envelopeFailure(.notAnObject, block: block)
        }
        guard int64Value(object["schemaVersion"]) == Int64(request.schemaVersion)
        else {
            return envelopeFailure(.schemaVersionMismatch, block: block)
        }
        guard object["requestID"] as? String == request.requestID else {
            return envelopeFailure(.requestIDMismatch, block: block)
        }
        var wordItems: [Any] = []
        if let rawWords = object["words"], !(rawWords is NSNull) {
            guard let array = rawWords as? [Any] else {
                return envelopeFailure(.invalidWordsField, block: block)
            }
            guard array.count <= AIStudyBudget.maxWordItems else {
                return envelopeFailure(.tooManyWords, block: block)
            }
            wordItems = array
        }

        // ---- 译文子状态（独立成败，不污染词义层） ----------------------
        let translationCheck = checkTranslation(object["translation"], block: block)

        // ---- 单项：逐元素 tolerant decode → tokenID 认领 ---------------
        var claims: [String: [DecodedWord]] = [:]
        var malformedItemCount = 0
        var droppedUnknownTokenCount = 0
        let knownTokenIDs = Set(block.tokens.map(\.tokenID))
        for item in wordItems {
            guard let dict = item as? [String: Any],
                  let tokenID = dict["tokenID"] as? String else {
                malformedItemCount += 1
                continue
            }
            guard knownTokenIDs.contains(tokenID) else {
                droppedUnknownTokenCount += 1
                continue // §7：未知 token 不创建任何对象，只记数
            }
            claims[tokenID, default: []].append(DecodedWord(dict: dict))
        }

        // ---- 逐 token 处置：每目标恰一行 resolution --------------------
        var resolutions: [AIStudyResolution] = []
        var duplicateTokenCount = 0
        var invalidItemCount = 0
        for token in block.tokens {
            let items = claims[token.tokenID] ?? []
            if items.count > 1 {
                // §7 重复项：整体降级，不 last-write-wins
                duplicateTokenCount += 1
                resolutions.append(AIStudyResolution(
                    tokenKey: token.tokenID,
                    selected: nil, confidence: nil,
                    status: .unresolved, reasonCode: .duplicateTokenID,
                    origin: .ai))
                continue
            }
            if let item = items.first {
                let (resolution, wasInvalid) = evaluate(
                    item: item, token: token,
                    datasetVersion: request.metadata.dictionaryDatasetVersion)
                if wasInvalid { invalidItemCount += 1 }
                resolutions.append(resolution)
            } else {
                // 缺项：OOV 目标记 noCandidate，其余记 missingWord。
                resolutions.append(AIStudyResolution(
                    tokenKey: token.tokenID,
                    selected: nil, confidence: nil,
                    status: .unresolved,
                    reasonCode: token.candidates.isEmpty
                        ? .noCandidate : .missingWord,
                    origin: .ai))
            }
        }

        // ---- 汇总 -------------------------------------------------------
        let cleanCount = resolutions.filter {
            $0.status == .aiResolved || $0.status == .userConfirmed
        }.count
        let withSelection = resolutions.filter { $0.selected != nil }.count
        let lexicalStatus: AIStudyLexicalStatus
        if block.tokens.isEmpty {
            lexicalStatus = .resolved   // 纯翻译块：无词义义务，恒 resolved
        } else if cleanCount == block.tokens.count {
            lexicalStatus = .resolved
        } else if withSelection > 0 {
            lexicalStatus = .partial    // 有可用选定（含 lowConfidence）
        } else {
            lexicalStatus = .unresolved
        }

        return ValidatedBlockOutcome(
            blockKey: block.blockKey,
            lexicalStatus: lexicalStatus,
            translationStatus: translationCheck.status,
            translation: translationCheck.text,
            envelopeRejection: nil,
            resolutions: resolutions,
            targetTokenCount: block.tokens.count,
            aiResolvedCount: cleanCount,
            lowConfidenceCount: resolutions.filter {
                $0.status == .lowConfidence }.count,
            unresolvedTokenCount: resolutions.filter {
                $0.status == .unresolved || $0.status == .rejected }.count,
            droppedUnknownTokenCount: droppedUnknownTokenCount,
            duplicateTokenCount: duplicateTokenCount,
            malformedItemCount: malformedItemCount,
            invalidItemCount: invalidItemCount
        )
    }

    // MARK: - 单项评估

    /// words[] 元素的宽松解码投影：tokenID 已在外层确认归属；
    /// 其余字段容忍缺失/错误类型，由评估层归因。
    private struct DecodedWord {
        let status: String?
        let entryID: Int64?
        let senseID: Int64?
        let confidence: Double?
        /// v2：token 所在句译文。类型错/空串/超长一律剥为 nil——
        /// 辅助字段不制造降级，不携带即不制卡译文。
        let sentenceTranslation: String?
        /// entryID/senseID/confidence 字段存在但类型不可解——
        /// 区别「字段缺席」与「字段坏值」（后者按降级计）。
        let hasUnreadableSelectionField: Bool
        let hasUnreadableConfidenceField: Bool

        init(dict: [String: Any]) {
            status = dict["status"] as? String
            entryID = AIStudyResponseValidator.int64Value(dict["entryID"])
            senseID = AIStudyResponseValidator.int64Value(dict["senseID"])
            confidence = AIStudyResponseValidator.doubleValue(dict["confidence"])
            if let raw = dict["sentenceTranslation"] as? String {
                let trimmed = raw.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                sentenceTranslation =
                    (trimmed.isEmpty
                        || trimmed.count
                            > AIStudyBudget.maxSentenceTranslationLength)
                        ? nil : trimmed
            } else {
                sentenceTranslation = nil
            }
            hasUnreadableSelectionField =
                (dict["entryID"] != nil && !(dict["entryID"] is NSNull)
                    && entryID == nil)
                || (dict["senseID"] != nil && !(dict["senseID"] is NSNull)
                    && senseID == nil)
            hasUnreadableConfidenceField =
                dict["confidence"] != nil && !(dict["confidence"] is NSNull)
                    && confidence == nil
        }
    }

    /// 单个已认领元素的评估。返回 (resolution, 是否计 invalidItem)。
    private static func evaluate(
        item: DecodedWord,
        token: AIStudyToken,
        datasetVersion: String
    ) -> (AIStudyResolution, Bool) {
        // status 缺席时按字段形态推断（resolved ⇔ 带了 entry/sense）——
        // 宽容解码，推断出的选择仍要走完整候选校验。
        let effectiveStatus = item.status
            ?? ((item.entryID != nil || item.senseID != nil)
                ? "resolved" : "unresolved")

        switch effectiveStatus {
        case "unresolved":
            // AI 明确放弃：合法路径；OOV 目标归 noCandidate。
            // 句译仍保留——翻译与选义是独立子状态。
            return (AIStudyResolution(
                tokenKey: token.tokenID, selected: nil, confidence: nil,
                status: .unresolved,
                reasonCode: token.candidates.isEmpty ? .noCandidate : nil,
                origin: .ai,
                sentenceTranslation: item.sentenceTranslation), false)

        case "resolved":
            // 字段类型坏值 → 该项降级（不产生选定）。
            if item.hasUnreadableSelectionField {
                return (AIStudyResolution(
                    tokenKey: token.tokenID, selected: nil, confidence: nil,
                    status: .unresolved, reasonCode: .incompleteSelection,
                    origin: .ai,
                    sentenceTranslation: item.sentenceTranslation), true)
            }
            guard let entryID = item.entryID, let senseID = item.senseID else {
                return (AIStudyResolution(
                    tokenKey: token.tokenID, selected: nil, confidence: nil,
                    status: .unresolved, reasonCode: .incompleteSelection,
                    origin: .ai,
                    sentenceTranslation: item.sentenceTranslation), true)
            }
            // 候选集成员校验：entry ∈ 该 token 候选 且 sense ∈ 该 entry
            // 的已发送 sense 集——跨 token 合法 ID 偷换同样命中此拒绝
            // （S02-B：validator 必须拒绝非候选 entry 的直接动机）。
            guard let candidate = token.candidates.first(where: {
                        $0.entryID == entryID }),
                  let sense = candidate.senses.first(where: {
                        $0.senseID == senseID }) else {
                return (AIStudyResolution(
                    tokenKey: token.tokenID, selected: nil, confidence: nil,
                    status: .rejected, reasonCode: .candidateNotInSet,
                    origin: .ai,
                    sentenceTranslation: item.sentenceTranslation), true)
            }
            // §7 单项层：sense 表记/读音限制必须对该 occurrence 仍有效。
            guard restrictionSatisfied(
                    sense: sense, candidate: candidate, token: token) else {
                return (AIStudyResolution(
                    tokenKey: token.tokenID, selected: nil, confidence: nil,
                    status: .rejected, reasonCode: .restrictionNotSatisfied,
                    origin: .ai,
                    sentenceTranslation: item.sentenceTranslation), true)
            }
            // confidence：finite ∈[0,1]；坏值/越界 → 该项降级。
            if item.hasUnreadableConfidenceField {
                return (AIStudyResolution(
                    tokenKey: token.tokenID, selected: nil, confidence: nil,
                    status: .unresolved, reasonCode: .invalidConfidence,
                    origin: .ai,
                    sentenceTranslation: item.sentenceTranslation), true)
            }
            if let confidence = item.confidence,
               !(confidence.isFinite && confidence >= 0 && confidence <= 1) {
                return (AIStudyResolution(
                    tokenKey: token.tokenID, selected: nil, confidence: nil,
                    status: .unresolved, reasonCode: .invalidConfidence,
                    origin: .ai,
                    sentenceTranslation: item.sentenceTranslation), true)
            }
            let selection = AIStudySelection(
                entryID: entryID, senseID: senseID,
                datasetVersion: datasetVersion)
            // 候选组被 planner 标「过多需确认」（entry 超上限或序列化
            // 超预算）→ 无论置信度都进确认队列（§6.3：不静默砍义项
            // 换表面置信度，被截/超载的候选组必须人工过目）。
            if token.needsCandidateConfirmation {
                return (AIStudyResolution(
                    tokenKey: token.tokenID, selected: selection,
                    confidence: item.confidence, status: .lowConfidence,
                    reasonCode: .candidateOverflow, origin: .ai,
                    sentenceTranslation: item.sentenceTranslation), false)
            }
            // 低置信路由：≥阈值才 aiResolved；缺席或低于
            // lowConfidenceThreshold → lowConfidence 进确认队列（选定
            // 保留——用户可在原候选中确认，不许填伪造 ID）。
            guard let confidence = item.confidence,
                  confidence >= AIStudyBudget.lowConfidenceThreshold else {
                return (AIStudyResolution(
                    tokenKey: token.tokenID, selected: selection,
                    confidence: item.confidence, status: .lowConfidence,
                    reasonCode: .belowConfidenceThreshold, origin: .ai,
                    sentenceTranslation: item.sentenceTranslation), false)
            }
            return (AIStudyResolution(
                tokenKey: token.tokenID, selected: selection,
                confidence: confidence, status: .aiResolved,
                reasonCode: nil, origin: .ai,
                sentenceTranslation: item.sentenceTranslation), false)

        default:
            return (AIStudyResolution(
                tokenKey: token.tokenID, selected: nil, confidence: nil,
                status: .unresolved, reasonCode: .unknownStatus,
                origin: .ai,
                sentenceTranslation: item.sentenceTranslation), true)
        }
    }

    /// §7「sense 的表记/读音限制有效」复核：
    /// 证据 = {候选 matched 值, 候选 lemma/reading, token lemma/surface/
    /// reading}——与 planner 放行时所用证据同源，只松不紧
    /// （planner 已放行的 sense 在这里不会被误杀）。
    private static func restrictionSatisfied(
        sense: AIStudyCandidateSense,
        candidate: AIStudyCandidate,
        token: AIStudyToken
    ) -> Bool {
        if !sense.restrictedForms.isEmpty {
            let evidence = Set([
                candidate.matchedForm, candidate.lemma,
                token.lemma, token.surface,
            ].compactMap { $0 })
            if Set(sense.restrictedForms).isDisjoint(with: evidence) {
                return false
            }
        }
        if !sense.restrictedReadings.isEmpty {
            let evidence = Set([
                candidate.matchedReading, candidate.reading, token.reading,
            ].compactMap { $0 })
            if Set(sense.restrictedReadings).isDisjoint(with: evidence) {
                return false
            }
        }
        return true
    }

    // MARK: - 译文子状态

    private static func checkTranslation(
        _ raw: Any?, block: AIStudyBlock
    ) -> (status: AIStudyTranslationStatus, text: String?) {
        guard block.wantsTranslation else { return (.notRequested, nil) }
        guard let raw, !(raw is NSNull) else { return (.failed, nil) }
        guard let text = raw as? String else { return (.failed, nil) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= AIStudyBudget.maxTranslationLength else {
            return (.failed, nil)
        }
        return (.done, trimmed)
    }

    // MARK: - 外层拒绝出口

    private static func envelopeFailure(
        _ reason: AIStudyEnvelopeRejection,
        blockKey: String,
        wantsTranslation: Bool
    ) -> ValidatedBlockOutcome {
        ValidatedBlockOutcome(
            blockKey: blockKey,
            lexicalStatus: .failed,
            translationStatus: wantsTranslation ? .failed : .notRequested,
            translation: nil,
            envelopeRejection: reason,
            resolutions: [],
            targetTokenCount: 0,
            aiResolvedCount: 0, lowConfidenceCount: 0,
            unresolvedTokenCount: 0,
            droppedUnknownTokenCount: 0, duplicateTokenCount: 0,
            malformedItemCount: 0, invalidItemCount: 0
        )
    }

    private static func envelopeFailure(
        _ reason: AIStudyEnvelopeRejection, block: AIStudyBlock
    ) -> ValidatedBlockOutcome {
        envelopeFailure(
            reason, blockKey: block.blockKey,
            wantsTranslation: block.wantsTranslation)
    }

    // MARK: - JSON 工具

    /// 递归深度：叶子 = 0，容器 = 1 + max(子深度)。
    private static func jsonDepth(_ value: Any) -> Int {
        if let dict = value as? [String: Any] {
            return 1 + (dict.values.map(jsonDepth).max() ?? 0)
        }
        if let array = value as? [Any] {
            return 1 + (array.map(jsonDepth).max() ?? 0)
        }
        return 0
    }

    /// NSNumber → Int64：拒绝 Bool 桥接与非整数值。
    private static func int64Value(_ raw: Any?) -> Int64? {
        guard let number = raw as? NSNumber, !isBool(number) else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(),
              double >= -9.0e18, double <= 9.0e18 else { return nil }
        return number.int64Value
    }

    /// NSNumber → Double：拒绝 Bool 桥接；NaN/Inf 由调用方判。
    private static func doubleValue(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, !isBool(number) else {
            return nil
        }
        return number.doubleValue
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
