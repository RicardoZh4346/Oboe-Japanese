import SwiftUI

struct CardFacePreview: View {
    let title: String
    let front: [String]
    let back: [String]
    let identifier: String

    @State private var isShowingAnswer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            previewLines(front)
            if isShowingAnswer {
                Divider()
                previewLines(back)
                    .accessibilityIdentifier("card-preview-answer-\(identifier)")
            }
            Button(isShowingAnswer ? "隐藏答案" : "显示答案") {
                isShowingAnswer.toggle()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("card-preview-flip-\(identifier)")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func previewLines(_ lines: [String]) -> some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            Text(line)
                .font(index == 0 ? .title3.bold() : .body)
                .foregroundStyle(index == 0 ? .primary : .secondary)
        }
    }
}
