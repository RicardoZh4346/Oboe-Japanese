import OboeDomain
import SwiftUI

struct KnowledgePointDetailDestination: View {
    let item: KnowledgePointSummary
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let knowledgePointService: KnowledgePointService
    let deckService: DeckManagementService
    let contentCardService: ContentCardService
    let historyService: StudyHistoryService
    let speechService: any SpeechService
    /// S12：sentence 详情页读取挖空定义；nil 时降级为摘要展示。
    var clozeRepository: (any ClozeRepository)? = nil
    let onChanged: () async -> Void

    var body: some View {
        switch item.kind {
        case .vocabulary:
            VocabularyDetailView(
                noteID: item.id,
                service: vocabularyService,
                knowledgeService: knowledgePointService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService
            ) {
                await onChanged()
            }
        case .grammar:
            GrammarDetailView(
                noteID: item.id,
                service: grammarService,
                knowledgeService: knowledgePointService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService
            ) {
                await onChanged()
            }
        case .sentence:
            SentenceNoteDetailView(
                noteID: item.id,
                headword: item.headword,
                meaningZH: item.meaningZH,
                clozeRepository: clozeRepository,
                knowledgeService: knowledgePointService
            ) {
                await onChanged()
            }
        }
    }
}
