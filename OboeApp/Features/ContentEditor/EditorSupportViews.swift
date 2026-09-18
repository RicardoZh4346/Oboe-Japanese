import OboeDomain
import SwiftUI

struct DeckPickerOptions: View {
    let decks: [DeckSummary]

    var body: some View {
        Text("暂不选择").tag(nil as UUID?)
        ForEach(decks) { deck in
            Text(deck.name).tag(deck.id as UUID?)
        }
    }
}

struct KnowledgePointDetailDestination: View {
    let item: KnowledgePointSummary
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let knowledgePointService: KnowledgePointService
    let deckService: DeckManagementService
    let contentCardService: ContentCardService
    let historyService: StudyHistoryService
    let speechService: any SpeechService
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
        }
    }
}
