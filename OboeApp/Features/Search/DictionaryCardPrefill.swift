import OboeDomain

/// S07 查词→制卡预填（技术文档 §4.4）：把 `DictionaryEntry` 折成
/// `VocabularyFormData` 交给现有 AddContent 编辑器——牌组选择、方向、
/// 重复提示、草稿机制全部沿用编辑器既有路径；取消即丢弃表单值，不产生
/// 孤立 Note 或 SourceContext。
enum DictionaryCardPrefill {

    /// 词条 → 单词表单：词头取 primaryForm，读音取首个 reading（词条至少
    /// 一个表记），释义取 zh→en 优先链的拼接，词性做 JMdict→白名单映射
    /// （无法映射的 code 丢弃——预填是便利而非事实源，用户可再选）。
    static func vocabularyForm(from entry: DictionaryEntry) -> VocabularyFormData {
        let preferred = entry.preferredGlosses()
        let meaning = preferred?.glosses
            .map(\.text)
            .joined(separator: "；") ?? ""
        return VocabularyFormData(
            headword: entry.primaryForm,
            reading: entry.readings.first?.reading ?? "",
            meaningZH: meaning,
            partOfSpeech: mapPartOfSpeech(entry.partOfSpeechCodes) ?? ""
        )
    }

    /// 词条 → 来源草稿：词典快照字段（entryID/dataset_version/所选释义
    /// 语言）如实记录；查词入口若带着原始语境（OCR 句/分享文本），由
    /// `lookup` 提供并原样并入——保存后复习背面可回放原句。
    static func sourceContextDraft(
        from entry: DictionaryEntry,
        datasetVersion: String?,
        lookup: SourceContextDraft? = nil
    ) -> SourceContextDraft {
        let preferred = entry.preferredGlosses()
        var draft = lookup ?? SourceContextDraft(sourceType: .dictionary)
        draft.dictionaryEntryID = entry.id
        draft.dictionaryVersion = datasetVersion
        draft.selectedGlossLanguage = preferred?.language
        return draft
    }

    /// JMdict POS code → `VocabularyPartOfSpeech` 白名单原子。
    /// 前缀归类覆盖同族 code（n-* 名词系、v5* 五段、vs* する系等）。
    private static func mapPartOfSpeech(_ codes: Set<String>) -> String? {
        var atoms = Set<VocabularyPartOfSpeech>()
        for code in codes {
            switch code {
            case "n", "n-adv", "n-t", "n-pref", "n-suf":
                atoms.insert(.noun)
            case "pn":
                atoms.insert(.pronoun)
            case "v1":
                atoms.insert(.ichidanVerb)
            case _ where code.hasPrefix("v5"):
                atoms.insert(.godanVerb)
            case "vk":
                atoms.insert(.kuruVerb)
            case "vs", "vs-i", "vs-s", "vs-c":
                atoms.insert(.suruVerb)
            case "vt":
                atoms.insert(.transitive)
            case "vi":
                atoms.insert(.intransitive)
            case "adj-i", "adj-ix":
                atoms.insert(.iAdjective)
            case "adj-na", "adj-nari", "adj-shiku", "adj-ku", "adj-no", "adj-pn",
                 "adj-t", "adj-f", "adj-kari":
                atoms.insert(.naAdjective)
            case "adv", "adv-to":
                atoms.insert(.adverb)
            case "prt":
                atoms.insert(.particle)
            case "aux", "aux-v", "aux-adj":
                atoms.insert(.auxiliaryVerb)
            case "conj":
                atoms.insert(.conjunction)
            case "int":
                atoms.insert(.interjection)
            case "ctr":
                atoms.insert(.counter)
            case "pref":
                atoms.insert(.prefix)
            case "suf":
                atoms.insert(.suffix)
            case "exp":
                atoms.insert(.expression)
            default:
                break
            }
        }
        return VocabularyPartOfSpeech.format(atoms)
    }
}
