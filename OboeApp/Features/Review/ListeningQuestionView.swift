import SwiftUI

/// T18 listening prompt playback state — shared by the view model and the
/// question face. `failed` never persists: a failure skips the card.
enum ListeningPromptPlaybackStatus: Equatable {
    case idle, playing, played
}

/// T17 (设计 §8.2): the listening card's question face. Its only interactive
/// element is the play button — no headword/reading/meaning/example text is
/// ever constructed here, so nothing can leak visually or through the
/// accessibility tree (the full VoiceOver traversal audit lands in T19).
/// T18: `status` surfaces generic playback state only — "playing"/"played"
/// carry no answer content either.
struct ListeningQuestionView: View {
    let isSpeechAvailable: Bool
    let status: ListeningPromptPlaybackStatus
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
            Text("请听音频，回忆含义")
                .oboeFont(.hint)
                .foregroundStyle(.secondary)
            OboeSpeechButton(
                status == .idle ? "播放日语音频" : "重播日语音频",
                systemImage: "headphones",
                accessibilityLabel: status == .idle ? "播放日语音频" : "重播日语音频",
                action: onPlay
            )
            .disabled(!isSpeechAvailable)
            .accessibilityHint("听音后回忆含义")
            .accessibilityIdentifier("review-listening-play-button")
            if status != .idle {
                Text(status == .playing ? "正在播放…" : "已播放")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review-listening-status")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-question")
    }
}

#Preview {
    ListeningQuestionView(isSpeechAvailable: true, status: .idle, onPlay: {})
        .padding()
}

#Preview {
    ListeningQuestionView(isSpeechAvailable: true, status: .played, onPlay: {})
        .padding()
}
