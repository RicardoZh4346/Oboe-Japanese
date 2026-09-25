import OboeDomain
import SwiftUI

struct ReviewRatingBar: View {
    let choices: ReviewChoices
    let isSubmitting: Bool
    let submittingRating: ReviewRating?
    /// S09 practiceOnly：四档只表示掌握程度，不显示 FSRS 间隔（§7.4）。
    var showsIntervals: Bool = true
    let onRate: (ReviewRating) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                grid(columns: 2)
            } else {
                ViewThatFits(in: .horizontal) {
                    grid(columns: 4)
                    grid(columns: 2)
                }
            }
        }
        .accessibilityIdentifier("review-rating-controls")
    }

    private func grid(columns: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: OboeTheme.Spacing.xs),
                count: columns
            ),
            spacing: OboeTheme.Spacing.xs
        ) {
            ForEach(ReviewRating.allCases, id: \.self) { rating in
                button(for: rating)
            }
        }
    }

    private func button(for rating: ReviewRating) -> some View {
        let dueAt = choices[rating].dueAt
        let isActiveSubmission = isSubmitting && submittingRating == rating
        return Button {
            onRate(rating)
        } label: {
            VStack(spacing: OboeTheme.Spacing.xxs) {
                Text(rating.title)
                    .font(.subheadline.weight(.semibold))
                if isActiveSubmission {
                    ProgressView()
                        .controlSize(.small)
                } else if showsIntervals {
                    Text(StudyTimeText.interval(until: dueAt))
                        .font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(rating.foregroundTint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .padding(.vertical, OboeTheme.Spacing.xxs)
            .background(
                rating.tint.opacity(0.14),
                in: RoundedRectangle(
                    cornerRadius: OboeTheme.Radius.medium,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: OboeTheme.Radius.medium,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .opacity(isSubmitting && !isActiveSubmission ? 0.45 : 1)
        .accessibilityLabel(
            showsIntervals
                ? "\(rating.title)，预计\(StudyTimeText.interval(until: dueAt))"
                : rating.title
        )
        .accessibilityIdentifier("review-rating-\(rating.identifier)")
    }
}
