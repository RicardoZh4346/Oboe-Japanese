import Foundation
import Observation
import OboeDomain

/// PR3 split: 听力播放、自动播放与失败跳过的会话状态，
/// 由 `ReviewViewModel` 以计算属性原样转发，行为不变。
@MainActor
@Observable
final class ReviewAudioController {
    /// Listening prompt playback for the CURRENT `presentationID` only.
    var listeningPromptStatus: ListeningPromptPlaybackStatus = .idle
    var listeningPromptRequestID: UUID?
    /// One completed prompt per presentation gates reveal/confirm — a
    /// listening card that never produced audio must not be rated.
    var listeningPromptCompleted = false
    /// Session-scoped skip set (memory only): cards whose prompt audio is
    /// unplayable are not re-picked this round, so failures can't loop. A new
    /// session (new view model) re-checks every card.
    var skippedListeningIDs: Set<UUID> = []
    /// Lightweight notice shown after a skip; cleared by the explicit retry.
    var listeningSkipNotice: String?
    var speechErrorMessage: String?
}

// MARK: - T18 listening playback & session skip (设计 §8.3)

extension ReviewViewModel {
    var isSpeechAvailable: Bool { speechService.availability.isAvailable }

    func playPrimarySpeech() {
        guard let card else { return }
        play([ReviewSpeechPolicy(content: card.content).primaryText])
    }

    /// T17/T18: the listening question-face prompt — reading (or headword
    /// when no reading), never the example sentence. Manual replay is always
    /// allowed regardless of the autoplay preference. A question-face
    /// failure skips the card for this session; an answer-face playback
    /// (word/example buttons) uses the legacy error-only path and never
    /// skips — see `play(_:)`.
    func playListeningPrompt() {
        // No `!isLoading` here: autoplay fires from inside loadNextCard while
        // the flag is still set — the guard would silently swallow it.
        guard let card,
              card.content.templateKind == .vocabularyListening,
              let prompt = ReviewSpeechPolicy(content: card.content).listeningPromptText,
              !isMutating, !hasCommittedCurrentCard
        else { return }
        let cardID = card.content.cardID
        // A prompt that can never play is a skip on the question face — the
        // load-time pre-check normally prevents reaching this path — but on
        // the answer face it's just a replay failure (设计 §8.3).
        if let reason = listeningPromptUnavailableReason(for: card.content) {
            if isAnswerVisible {
                speechErrorMessage = Self.speechMessage(for: reason)
            } else {
                skipCurrentListeningCard(cardID: cardID, reason: reason)
            }
            return
        }
        let presentation = presentationID
        listeningPromptStatus = .playing
        listeningPromptRequestID = speechService.speakWithEvents([prompt]) {
            [weak self] event in
            self?.handleListeningPromptEvent(
                event, presentation: presentation, cardID: cardID
            )
        }
    }

    /// T18 (设计 §8.3): events carry presentationToken + requestID — a late
    /// callback from a superseded request or a previous card can never skip
    /// or mutate the card currently on screen.
    private func handleListeningPromptEvent(
        _ event: SpeechPlaybackEvent,
        presentation: UUID,
        cardID: UUID
    ) {
        guard presentation == presentationID,
              card?.content.cardID == cardID,
              event.requestID == listeningPromptRequestID else { return }
        switch event {
        case .started:
            listeningPromptStatus = .playing
        case .completed:
            listeningPromptStatus = .played
            listeningPromptCompleted = true
        case .cancelled:
            // Interruption/route change/page exit: not a failure — stay on
            // the card and let the user replay. `listeningPromptCompleted`
            // is left untouched so a cancelled first play still gates.
            listeningPromptStatus = .idle
        case let .failed(_, error):
            listeningPromptStatus = .idle
            if isAnswerVisible {
                // 设计 §8.3: only QUESTION-face failure skips the card. A
                // failed replay on the answer face is a plain speech error —
                // the completed recall is never discarded.
                speechErrorMessage = Self.speechMessage(for: error)
            } else {
                skipCurrentListeningCard(cardID: cardID, reason: error)
            }
        }
    }

    /// T18: question-face audio failure — mark the card skipped for this
    /// session, surface a light notice, and advance to the next candidate.
    /// No rating, no FSRS write, no daily_tasks cancellation.
    private func skipCurrentListeningCard(cardID: UUID, reason: JapaneseSpeechError) {
        guard card?.content.cardID == cardID,
              card?.content.templateKind == .vocabularyListening,
              skippedListeningIDs.insert(cardID).inserted else { return }
        speechService.stop()
        listeningSkipNotice = "音频暂不可用，已跳过这张听力卡。"
        // T21 (§9.2): a skipped card never produced a valid question — roll
        // back its presentation so it does not pollute sibling memory.
        lastPresentedNoteID = lastPresentedNoteIDBeforeCurrent
        Task {
            // A card-preserving refresh may be in flight — its early-return
            // guard would swallow this advance, leaving a failed card stuck
            // on screen. Wait it out, then re-pick with the skip applied.
            while self.isRefreshing {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled else { return }
            }
            await self.loadNextCard()
        }
    }

    /// T18: "重试音频卡" — explicit clear-and-recheck. A fresh session does
    /// this implicitly since the skip set is memory-only.
    func retrySkippedListeningCards() {
        guard !skippedListeningIDs.isEmpty, !isMutating else { return }
        skippedListeningIDs.removeAll()
        listeningSkipNotice = nil
        Task { await loadNextCard() }
    }

    /// Skipped listening cards still due in this scope — surfaced as
    /// "剩余 X 张听力卡暂无法播放" instead of a false completion state.
    var scopedSkippedListeningCount: Int {
        guard let plan else { return skippedListeningIDs.count }
        let inScope = Set(
            (plan.availableNow + plan.availableLater)
                .filter { item in
                    scope.deckID.map { item.deckIDs.contains($0) } ?? true
                }
                .map(\.cardID)
        )
        return skippedListeningIDs.intersection(inScope).count
    }

    /// T18 load-time pre-check reasons: no voice, or no prompt text at all.
    func listeningPromptUnavailableReason(
        for content: ReviewCardContent
    ) -> JapaneseSpeechError? {
        if !speechService.availability.isAvailable { return .voiceUnavailable }
        let prompt = ReviewSpeechPolicy(content: content).listeningPromptText
        if prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .noSpeakableText
        }
        return nil
    }

    /// T18: a listening card whose prompt never completed playback this
    /// presentation cannot be revealed or confirmed — no audio, no answer.
    /// With no voice the card is skipped at load, so the gate only applies
    /// while playback is actually possible.
    var mustPlayListeningPromptFirst: Bool {
        card?.content.templateKind == .vocabularyListening
            && !isAnswerVisible
            && !listeningPromptCompleted
            && isSpeechAvailable
    }

    func playExampleSpeech() {
        guard let example = card.flatMap({ ReviewSpeechPolicy(content: $0.content).exampleText })
        else { return }
        play([example])
    }

    func stopSpeech() {
        speechService.stop()
    }

    func playAutomatically(onAnswer: Bool) {
        guard let card else { return }
        // T18: the listening prompt rides its own `autoPlayListeningAudio`
        // channel — at most once per presentationToken, driven only from the
        // fresh-selection path so body re-computes and card-preserving
        // refreshes never replay.
        if !onAnswer, card.content.templateKind == .vocabularyListening {
            guard adaptivePreferences.autoPlayListeningAudio else { return }
            playListeningPrompt()
            return
        }
        let policy = ReviewSpeechPolicy(content: card.content)
        let texts = onAnswer
            ? policy.automaticAnswerTexts(preferences: speechPreferences)
            : policy.automaticQuestionTexts(preferences: speechPreferences)
        guard !texts.isEmpty else { return }
        play(texts)
    }

    private func play(_ texts: [String]) {
        speechErrorMessage = nil
        speechService.speak(texts) { [weak self] error in
            self?.speechErrorMessage = Self.speechMessage(for: error)
        }
    }

    private static func speechMessage(for error: Error) -> String {
        guard let error = error as? JapaneseSpeechError else {
            return "系统语音暂时无法播放，请稍后重试。"
        }
        return switch error {
        case .voiceUnavailable:
            "设备未安装可用的日语语音。请在系统设置的辅助功能“朗读内容”中下载日语声音；学习可继续进行。"
        case .noSpeakableText:
            "当前内容没有可朗读的日语文本。"
        case .audioSessionUnavailable:
            "音频正被其他应用或通话占用，请稍后重试。"
        }
    }
}
